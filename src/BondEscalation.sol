// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IBondEscalation} from "./interfaces/IBondEscalation.sol";
import {IBondEscalationAdmin} from "./interfaces/IBondEscalationAdmin.sol";
import {AIRuling} from "./interfaces/DisputeTypes.sol";
import {ICompositeMediator} from "./interfaces/ICompositeMediator.sol";
import {IOptimisticOracleV3} from "./interfaces/IOptimisticOracleV3.sol";
import {IACTPKernel} from "./interfaces/IACTPKernel.sol";
import {IEscrowValidator} from "./interfaces/IEscrowValidator.sol";

/// @title BondEscalation — Tier-0/1/2 bond-escalation dispute engine (AIP-14b §7, §4.4-4.9, §8.4-8.5).
/// @notice Implements the challengeable bond-escalation game (Tier 1) plus the UMA OOV3 bridge (Tier 2).
///         The kernel remains the sole fund authority over escrow; this contract holds ONLY its own
///         Tier-1 escalation bonds (`accumulatedBonds`). It never calls `kernel.transitionState`
///         directly — final rulings are enacted through `compositeMediator.resolve` (P0-3).
/// @dev    EIP-712 signed AI rulings (Tier 0) enter through the same challengeable Tier-1 path as any
///         direct proposal (INV-16). Recovery/sync paths (`finalize`, `forceResolveStale`,
///         `claimEscalationRefund`, `syncExternalResolution`) are NEVER pausable (INV-9).
contract BondEscalation is IBondEscalation, IBondEscalationAdmin, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------
    // §7.4 Constants
    // ---------------------------------------------------------------------
    uint16 internal constant ESCALATION_INITIAL_BPS = 200; // 2% of escrow
    uint256 internal constant MIN_ESCALATION_BOND = 1_000_000; // $1 USDC
    uint256 internal constant MAX_ESCALATION_BOND = 500_000_000; // $500 ceiling
    uint8 internal constant ESCALATION_MULTIPLIER = 2;
    uint256 internal constant MAX_DISPUTE_DURATION = 30 days;
    uint16 internal constant FINALIZATION_BOUNTY_BPS = 1000; // 10%
    uint256 internal constant MIN_FINALIZATION_BOUNTY = 100_000; // $0.10
    /// @dev Canonical UMA OptimisticOracleV3 on Base mainnet. Used as the default for `UMA_OOV3`
    ///      when the constructor is passed `address(0)` (production deploys). Tests may inject a
    ///      mock OOV3 by passing a non-zero address — a testability-only override that NEVER changes
    ///      production semantics (deploy scripts pass 0 → this canonical address). See §8.4.
    address internal constant DEFAULT_UMA_OOV3 = 0x2aBf1Bd76655de80eDB3086114315Eec75AF500c;
    uint256 internal constant UMA_BOND = 500_000_000; // $500
    uint64 internal constant UMA_LIVENESS = 7200; // 2 hours

    // EIP-712 / governance timing (§4.5)
    uint64 internal constant RULING_FRESHNESS = 1 hours;
    uint64 internal constant EVALUATOR_UPDATE_DELAY = 2 days;

    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 internal constant RULING_TYPEHASH = keccak256(
        "AIRuling(bytes32 disputeId,uint8 ruling,uint16 confidence,uint16 splitBps,uint64 timestamp,bytes32 reasoningHash,bytes32 bundleHash)"
    );

    // ---------------------------------------------------------------------
    // Local events (F-4 graceful-degradation recovery; not part of IBondEscalation)
    // ---------------------------------------------------------------------
    /// @notice Emitted when the UMA callback distributed Tier-1 bonds + locally resolved the dispute,
    ///         but the kernel-side escrow leg (`compositeMediator.resolve`) reverted/OOG'd and was
    ///         deferred. The escrow movement is re-drivable permissionlessly via `retryMediatorResolution`.
    event MediatorResolutionDeferred(bytes32 indexed disputeId, bytes32 indexed txId, uint8 ruling, uint16 splitBps);
    /// @notice Emitted when a previously-deferred escrow leg was successfully re-driven.
    event MediatorResolutionRetried(bytes32 indexed disputeId, bytes32 indexed txId, uint8 ruling, uint16 splitBps);

    // ---------------------------------------------------------------------
    // Wiring (immutable where possible — §G4 write-once not needed here)
    // ---------------------------------------------------------------------
    IACTPKernel public immutable kernel;
    IERC20 public immutable USDC;
    ICompositeMediator public immutable compositeMediator;
    bytes32 public immutable DOMAIN_SEPARATOR;
    /// @notice The UMA OptimisticOracleV3 this contract escalates to / accepts callbacks from.
    /// @dev    Immutable for testability (AIP-14b §8.4): production deploys pass `address(0)` to the
    ///         constructor and get the canonical Base-mainnet `DEFAULT_UMA_OOV3`. Unit tests pass a
    ///         deployed MockOOV3 so the Tier-2 path (assertTruth bond custody + callbacks) is fully
    ///         exercised without `vm.etch`. The on-chain semantics are identical to the previous
    ///         hardcoded constant whenever the constructor arg is zero.
    address public immutable UMA_OOV3;

    address public admin;
    bool public paused;

    // ---------------------------------------------------------------------
    // §7.3 Storage
    // ---------------------------------------------------------------------
    struct DisputeState {
        bytes32 transactionId;
        uint8 currentRuling;
        uint16 splitBps;
        uint256 currentBond;
        uint256 accumulatedBonds; // Tier-1 bonds ONLY (never the UMA bond). LIVE during the bond game; on a SPLIT finalize it becomes a FROZEN distribution snapshot (the claimEscalationRefund numerator) and is intentionally NOT decremented as depositors pull — so post-split it is NOT a live balance (see claimEscalationRefund snapshot note).
        uint64 livenessEnd;
        uint64 disputedAt; // Immutable - set once at openDispute()
        address lastProposer;
        uint8 tier; // 0=opened, 1=proposed/challenged, 2=UMA
        bool resolved;
        bool winnerPaid;
        uint256 originalPool; // Snapshot of accumulatedBonds at resolution
        uint256 escrowAmount; // Cached at openDispute()
    }

    mapping(bytes32 => DisputeState) public disputes;

    // Per-address deposit tracking for Tier 1 bonds (for split refunds)
    mapping(bytes32 disputeId => mapping(address => uint256)) public deposits;

    // Winner tracking by ruling direction (for UMA resolution)
    mapping(bytes32 disputeId => mapping(uint8 ruling => address)) public lastProposerForRuling;

    // UMA assertion mappings
    mapping(bytes32 assertionId => bytes32 disputeId) public assertionToDispute;
    mapping(bytes32 disputeId => bytes32 assertionId) public disputeToAssertion;

    // ---------------------------------------------------------------------
    // §4.6 Evaluator Registry
    // ---------------------------------------------------------------------
    address[2] public fixedEvaluators;
    address[] public rotatingPool;

    // Pending updates (timelocked)
    address[2] public pendingFixedEvaluators;
    uint64[2] public fixedEvaluatorUnlockTime;
    address[] public pendingRotatingAdditions;
    uint64[] public rotatingAdditionUnlockTime;

    /// @notice §4.2 canonical evaluator-prompt CID, committed on-chain so anyone can verify WHICH prompt
    ///         the evaluators used. Governed by the same 2-day EVALUATOR_UPDATE_DELAY as evaluator changes.
    string public activePromptCID;
    string public pendingPromptCID;
    uint64 public promptCIDUnlockTime;

    // ---------------------------------------------------------------------
    // F-4 / F-6 storage (appended at the END of the layout so the slots of all pre-existing state —
    // notably `rotatingPool` (slot 8) which some adversarial tests address via `vm.store` — are
    // UNCHANGED. Do NOT relocate these above the evaluator registry.)
    // ---------------------------------------------------------------------
    /// @notice F-6 settle-bounty: the keeper that drove the current UMA settlement, recorded by
    ///         `settleUMAAssertion` immediately BEFORE it calls `OOV3.settleAssertion`, so the
    ///         synchronous `assertionResolvedCallback` (which runs with `msg.sender == UMA_OOV3`,
    ///         NOT the keeper) can pay the settle-bounty to the right address. Cleared after use.
    ///         A bare `OOV3.settleAssertion` (not routed through our helper) leaves this zero → no
    ///         bounty is paid and the full Tier-1 pool is preserved for the winner (safe degradation).
    mapping(bytes32 disputeId => address settler) public pendingSettler;

    /// @notice F-4 graceful degradation: set true when `assertionResolvedCallback` distributed the
    ///         Tier-1 bonds and locally resolved the dispute, but the kernel-side escrow leg
    ///         (`compositeMediator.resolve`) reverted/OOG'd. The callback then does NOT revert (so the
    ///         UMA settlement still commits and the UMA bond is returned); instead the escrow leg is
    ///         left re-drivable, permissionlessly, via `retryMediatorResolution` (or, after 30 days,
    ///         `forceResolveStale` — but that path is blocked once `d.resolved` latches, so the retry
    ///         entrypoint is the primary escrow-recovery route for this case).
    mapping(bytes32 disputeId => bool pending) public mediatorRetryPending;

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------
    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "Paused");
        _;
    }

    // ---------------------------------------------------------------------
    // Constructor — wires immutables, seeds evaluator registry (OQ-5 genesis,
    // NON-timelocked, so first use is not blocked for 2 days).
    // ---------------------------------------------------------------------
    /// @param umaOOV3_ The UMA OptimisticOracleV3 address. Pass `address(0)` in production to use the
    ///        canonical Base-mainnet deployment (`DEFAULT_UMA_OOV3`); tests pass a deployed MockOOV3.
    constructor(
        IACTPKernel kernel_,
        IERC20 usdc_,
        ICompositeMediator compositeMediator_,
        address admin_,
        address[2] memory fixedEvaluators_,
        address[] memory rotatingPool_,
        address umaOOV3_
    ) {
        require(address(kernel_) != address(0), "Zero kernel");
        require(address(usdc_) != address(0), "Zero USDC");
        require(address(compositeMediator_) != address(0), "Zero mediator");
        require(admin_ != address(0), "Zero admin");
        require(fixedEvaluators_[0] != address(0) && fixedEvaluators_[1] != address(0), "Zero evaluator");
        require(rotatingPool_.length >= 1, "Rotating pool empty");

        kernel = kernel_;
        USDC = usdc_;
        compositeMediator = compositeMediator_;
        admin = admin_;
        // Testability override (§8.4): zero → canonical Base-mainnet OOV3 (production default).
        UMA_OOV3 = umaOOV3_ == address(0) ? DEFAULT_UMA_OOV3 : umaOOV3_;

        // MAJOR-1 defense-in-depth: the two fixed slots must themselves be distinct, otherwise one
        // keypair already controls 2 of the 3 evaluator roles.
        require(fixedEvaluators_[0] != fixedEvaluators_[1], "Fixed slots must differ");

        // OQ-5 genesis seeding (non-timelocked): set the live registry directly.
        fixedEvaluators[0] = fixedEvaluators_[0];
        fixedEvaluators[1] = fixedEvaluators_[1];
        for (uint256 i = 0; i < rotatingPool_.length; i++) {
            require(rotatingPool_[i] != address(0), "Zero rotating");
            // MAJOR-1 defense-in-depth: no rotating member may overlap a fixed slot, so the rotating
            // pick can never duplicate a fixed evaluator's vote (the verification path also guards this).
            require(
                rotatingPool_[i] != fixedEvaluators_[0] && rotatingPool_[i] != fixedEvaluators_[1],
                "Rotating overlaps fixed"
            );
            rotatingPool.push(rotatingPool_[i]);
        }

        // §4.5 EIP-712 domain separator (bound to chainid + this address).
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("ACTPDisputeEvaluator"), keccak256("1"), block.chainid, address(this))
        );
    }

    // =====================================================================
    // §7.5 openDispute
    // =====================================================================
    function openDispute(bytes32 txId) external override whenNotPaused returns (bytes32 disputeId) {
        disputeId = keccak256(abi.encode("ACTP_DISPUTE_V1", txId));
        require(disputes[disputeId].disputedAt == 0, "Already opened");

        IACTPKernel.TransactionView memory txn = kernel.getTransaction(txId);
        require(txn.state == IACTPKernel.State.DISPUTED, "Not in DISPUTED state");

        IEscrowValidator vault = IEscrowValidator(txn.escrowContract);
        uint256 escrowAmount = vault.remaining(txn.escrowId);

        disputes[disputeId] = DisputeState({
            transactionId: txId,
            currentRuling: 0,
            splitBps: 0,
            currentBond: 0,
            accumulatedBonds: 0,
            livenessEnd: 0,
            disputedAt: uint64(block.timestamp),
            lastProposer: address(0),
            tier: 0,
            resolved: false,
            winnerPaid: false,
            originalPool: 0,
            escrowAmount: escrowAmount
        });

        emit DisputeOpened(disputeId, txId, escrowAmount, msg.sender);
    }

    // =====================================================================
    // §7.6 proposeDirectly
    // =====================================================================
    function proposeDirectly(bytes32 disputeId, uint8 ruling, uint16 splitBps)
        external
        override
        whenNotPaused
        nonReentrant
    {
        DisputeState storage d = disputes[disputeId];
        require(d.disputedAt != 0, "Dispute not opened");
        require(!d.resolved, "Already resolved");
        require(d.tier == 0, "Already has proposal");
        require(ruling <= 2, "Invalid ruling");
        require(ruling == 2 || splitBps == 0, "splitBps only for splits");
        require(splitBps <= 10000, "Invalid splitBps");

        uint256 bond = _calculateInitialBond(d.escrowAmount);

        d.currentRuling = ruling;
        d.splitBps = splitBps;
        d.lastProposer = msg.sender;
        d.currentBond = bond;
        d.accumulatedBonds = bond;
        d.livenessEnd = uint64(block.timestamp) + _livenessForEscrow(d.escrowAmount);
        d.tier = 1;

        lastProposerForRuling[disputeId][ruling] = msg.sender;
        deposits[disputeId][msg.sender] += bond;

        USDC.safeTransferFrom(msg.sender, address(this), bond);

        emit DirectProposalSubmitted(disputeId, ruling, splitBps, msg.sender, bond);
    }

    // =====================================================================
    // §7.7 submitAIRuling
    // =====================================================================
    function submitAIRuling(bytes32 disputeId, AIRuling calldata ruling, bytes[] calldata signatures)
        external
        override
        whenNotPaused
        nonReentrant
    {
        DisputeState storage d = disputes[disputeId];
        require(d.disputedAt != 0, "Dispute not opened");
        require(!d.resolved, "Already resolved");
        require(d.tier == 0, "Already escalated");
        require(ruling.disputeId == disputeId, "Mismatched disputeId");
        require(ruling.ruling <= 2, "Invalid ruling");
        require(ruling.ruling == 2 || ruling.splitBps == 0, "splitBps only for splits");
        require(ruling.splitBps <= 10000, "Invalid splitBps");

        // §4.1 CONFIDENCE IS AN OFF-CHAIN RULE (intentionally NOT gated here). `ruling.confidence`
        // (>= 9000 bps per §4.1) is the evaluator ensemble's OWN decision rule for choosing
        // submitAIRuling over proposeDirectly; it is signed (attested) and surfaced in the event, but
        // the chain does NOT enforce a threshold: the AI verdict is non-authoritative (INV-16/21) — it
        // enters as a CHALLENGEABLE Tier-1 proposal, so a low-confidence ruling is corrected by the bond
        // game, not by an on-chain require. There is deliberately no on-chain confidence invariant.
        _verifyEvaluatorSignatures(disputeId, ruling, signatures);

        uint256 bond = _calculateInitialBond(d.escrowAmount);

        d.currentRuling = ruling.ruling;
        d.splitBps = ruling.splitBps;
        d.lastProposer = msg.sender;
        d.currentBond = bond;
        d.accumulatedBonds = bond;
        d.livenessEnd = uint64(block.timestamp) + _livenessForEscrow(d.escrowAmount);
        d.tier = 1;

        lastProposerForRuling[disputeId][ruling.ruling] = msg.sender;
        deposits[disputeId][msg.sender] += bond;

        USDC.safeTransferFrom(msg.sender, address(this), bond);

        emit AIRulingSubmitted(disputeId, ruling.ruling, ruling.confidence, msg.sender, bond);
    }

    // =====================================================================
    // §7.8 challenge
    // =====================================================================
    function challenge(bytes32 disputeId, uint8 counterRuling, uint16 counterSplitBps)
        external
        override
        whenNotPaused
        nonReentrant
    {
        DisputeState storage d = disputes[disputeId];

        require(d.disputedAt != 0, "Dispute not opened");
        require(!d.resolved, "Already resolved");
        require(d.tier == 1, "Not in Tier 1");
        require(block.timestamp <= d.livenessEnd, "Liveness expired");

        require(counterRuling <= 2, "Invalid ruling");
        require(counterRuling == 2 || counterSplitBps == 0, "splitBps only for splits");
        require(counterSplitBps <= 10000, "Invalid splitBps");

        bool isDifferent =
            (counterRuling != d.currentRuling) || (counterRuling == 2 && counterSplitBps != d.splitBps);
        require(isDifferent, "Must propose different outcome");

        uint256 nextBond = d.currentBond * ESCALATION_MULTIPLIER;
        if (nextBond > MAX_ESCALATION_BOND) {
            nextBond = MAX_ESCALATION_BOND;
        }

        d.currentRuling = counterRuling;
        d.splitBps = counterSplitBps;
        d.lastProposer = msg.sender;
        d.currentBond = nextBond;
        d.accumulatedBonds += nextBond;
        d.livenessEnd = uint64(block.timestamp) + _livenessForEscrow(d.escrowAmount);

        lastProposerForRuling[disputeId][counterRuling] = msg.sender;
        deposits[disputeId][msg.sender] += nextBond;

        USDC.safeTransferFrom(msg.sender, address(this), nextBond);

        emit ChallengeSubmitted(disputeId, counterRuling, counterSplitBps, msg.sender, nextBond);
    }

    // =====================================================================
    // §7.9 finalize (NOT pausable — INV-9)
    // =====================================================================
    function finalize(bytes32 disputeId) external override nonReentrant {
        DisputeState storage d = disputes[disputeId];
        require(d.disputedAt != 0, "Dispute not opened");
        require(!d.resolved, "Already resolved");
        require(d.tier == 1, "Not in Tier 1");
        require(block.timestamp > d.livenessEnd, "Liveness active");

        IACTPKernel.TransactionView memory txn = kernel.getTransaction(d.transactionId);
        if (txn.state != IACTPKernel.State.DISPUTED) {
            // Kernel already moved on (admin/external resolution). Sync locally, no payout.
            d.resolved = true;
            d.originalPool = d.accumulatedBonds;
            d.currentRuling = 2;
            d.splitBps = 5000;
            emit ExternalResolutionSynced(disputeId, d.transactionId, uint8(txn.state));
            return;
        }

        d.resolved = true;
        d.originalPool = d.accumulatedBonds;

        // Finalization bounty: incentivize the keeper that finalizes. Deducted BEFORE winner payout.
        uint256 bounty = (d.accumulatedBonds * FINALIZATION_BOUNTY_BPS) / 10000;
        if (bounty < MIN_FINALIZATION_BOUNTY) bounty = MIN_FINALIZATION_BOUNTY;
        if (bounty > d.accumulatedBonds) bounty = d.accumulatedBonds;
        d.accumulatedBonds -= bounty;
        if (bounty > 0) {
            USDC.safeTransfer(msg.sender, bounty);
        }

        if (d.currentRuling == 2) {
            // Split: depositors claim proportionally via claimEscalationRefund().
        } else {
            // Winner-takes-all (ruling 0/1): push remaining pool to last proposer.
            d.winnerPaid = true;
            address winner = d.lastProposer;
            uint256 payout = d.accumulatedBonds;
            d.accumulatedBonds = 0;
            if (payout > 0 && winner != address(0)) {
                USDC.safeTransfer(winner, payout);
            }
        }

        compositeMediator.resolve(d.transactionId, d.currentRuling, d.splitBps);

        emit DisputeFinalized(disputeId, d.currentRuling, d.lastProposer, msg.sender, bounty);
    }

    // =====================================================================
    // §7.10 claimEscalationRefund (NOT pausable — INV-9)
    // -----------------------------------------------------------------------------------------------
    // SNAPSHOT SEMANTICS (load-bearing for the P1-8 solvency invariant): on a SPLIT, `accumulatedBonds`
    // is a FROZEN snapshot of the post-bounty pool (the numerator) and `originalPool` is the frozen total
    // deposits (the divisor). Neither is decremented as depositors pull; each share is
    //   deposits[addr] * accumulatedBonds / originalPool,  with  Σ shares == accumulatedBonds (no over/under-pay).
    // CONSEQUENCE: post-split, `USDC.balanceOf(this) >= accumulatedBonds` is NOT a valid invariant.
    // The correct live-solvency invariant is the sum of UNCLAIMED shares:
    //   balance >= Σ_{addr : deposits[addr] > 0} deposits[addr] * accumulatedBonds / originalPool.
    // P1-8 invariant/fuzz MUST assert that form, never `>= accumulatedBonds`.
    // =====================================================================
    function claimEscalationRefund(bytes32 disputeId) external override nonReentrant {
        DisputeState storage d = disputes[disputeId];
        require(d.resolved, "Not resolved");
        require(d.currentRuling == 2, "Not a split - winner takes all");

        uint256 deposited = deposits[disputeId][msg.sender];
        require(deposited > 0, "Nothing to claim");

        deposits[disputeId][msg.sender] = 0;

        uint256 share = (deposited * d.accumulatedBonds) / d.originalPool;
        if (share > 0) {
            USDC.safeTransfer(msg.sender, share);
        }

        emit EscalationRefundClaimed(disputeId, msg.sender, share);
    }

    // =====================================================================
    // §7.11 syncExternalResolution (NOT pausable — INV-9)
    // =====================================================================
    function syncExternalResolution(bytes32 disputeId) external override {
        DisputeState storage d = disputes[disputeId];
        require(d.disputedAt != 0, "Dispute not opened");
        require(!d.resolved, "Already resolved");

        IACTPKernel.TransactionView memory txn = kernel.getTransaction(d.transactionId);
        require(txn.state != IACTPKernel.State.DISPUTED, "Still disputed in kernel");

        d.resolved = true;
        d.originalPool = d.accumulatedBonds;
        d.currentRuling = 2;
        d.splitBps = 5000;

        emit ExternalResolutionSynced(disputeId, d.transactionId, uint8(txn.state));
    }

    // =====================================================================
    // §7.12 forceResolveStale (NOT pausable — INV-9)
    // =====================================================================
    function forceResolveStale(bytes32 disputeId) external override nonReentrant {
        DisputeState storage d = disputes[disputeId];
        require(d.disputedAt != 0, "Dispute not opened");
        require(!d.resolved, "Already resolved");
        require(block.timestamp > d.disputedAt + MAX_DISPUTE_DURATION, "Not stale");

        IACTPKernel.TransactionView memory txn = kernel.getTransaction(d.transactionId);
        if (txn.state != IACTPKernel.State.DISPUTED) {
            // Kernel already moved on — sync only, no mediator call.
            d.resolved = true;
            d.originalPool = d.accumulatedBonds;
            d.currentRuling = 2;
            d.splitBps = 5000;
            emit ExternalResolutionSynced(disputeId, d.transactionId, uint8(txn.state));
            return;
        }

        d.resolved = true;
        d.originalPool = d.accumulatedBonds;
        d.currentRuling = 2;
        d.splitBps = 5000;

        compositeMediator.resolve(d.transactionId, 2, 5000);

        emit StaleDisputeResolved(disputeId, msg.sender);
    }

    // =====================================================================
    // §8.4 escalateToUMA
    // =====================================================================
    function escalateToUMA(bytes32 disputeId, string calldata evidenceCID)
        external
        override
        whenNotPaused
        nonReentrant
    {
        DisputeState storage d = disputes[disputeId];

        require(d.disputedAt != 0, "Dispute not opened");
        require(!d.resolved, "Already resolved");
        require(d.tier == 1, "Not in Tier 1");
        require(d.currentBond >= MAX_ESCALATION_BOND, "Bond ceiling not reached");
        require(block.timestamp <= d.livenessEnd, "Liveness expired - use finalize()");
        require(disputeToAssertion[disputeId] == bytes32(0), "Already escalated");
        require(bytes(evidenceCID).length > 0, "Evidence CID required");

        bytes memory claim = abi.encodePacked(
            "Provider delivered the service as specified for ACTP dispute 0x",
            _toHexString(disputeId),
            ". Evidence bundle: ipfs://",
            evidenceCID,
            ". Resolution policy: per AGIRAILS AIP-14b dispute resolution rules."
        );

        // Transfer UMA bond from caller to this contract, then approve OOV3 to pull it.
        USDC.safeTransferFrom(msg.sender, address(this), UMA_BOND);
        USDC.forceApprove(UMA_OOV3, UMA_BOND);

        // Identifier: use the oracle's approved default (read at runtime, NEVER hardcode).
        bytes32 identifier = IOptimisticOracleV3(UMA_OOV3).defaultIdentifier();

        bytes32 assertionId = IOptimisticOracleV3(UMA_OOV3).assertTruth(
            claim,
            msg.sender, // asserter - receives bond back if TRUE
            address(this), // callbackRecipient - receives callbacks
            address(0), // escalationManager
            UMA_LIVENESS, // liveness
            USDC, // currency
            UMA_BOND, // bond
            identifier, // = oracle default ("ASSERT_TRUTH" on Base mainnet)
            bytes32(0) // domainId
        );

        assertionToDispute[assertionId] = disputeId;
        disputeToAssertion[disputeId] = assertionId;

        d.tier = 2;
        // NOTE: UMA bond is NOT added to accumulatedBonds - UMA now holds it.

        // F-3 (audit HIGH) FIX: do NOT overwrite the ruling-0 winner-of-record with the escalator.
        // The escalator is merely the party that posts the $500 UMA bond (returned by UMA on a TRUE
        // resolution); they are NOT necessarily a Tier-1 bond depositor. Overwriting the slot let a
        // zero-bond, front-running non-participant displace the genuine last ruling-0 proposer and
        // capture the whole Tier-1 pool (assertionResolvedCallback pays accumulatedBonds to
        // lastProposerForRuling[ruling]). By leaving the slot untouched, the honest last ruling-0
        // proposer keeps it; the Tier-1 pool flows to the genuine Tier-1 bonders. If NO ruling-0
        // proposer ever existed and UMA resolves ruling 0, the callback's winner==address(0) branch
        // degrades to a 50/50 split so depositors recover proportionally (no stranded funds).

        emit EscalatedToUMA(disputeId, assertionId, msg.sender, UMA_BOND, evidenceCID);
    }

    // =====================================================================
    // §8.5 UMA Callbacks
    // =====================================================================
    function assertionResolvedCallback(bytes32 assertionId, bool assertedTruthfully) external nonReentrant {
        require(msg.sender == UMA_OOV3, "Only UMA");

        bytes32 disputeId = assertionToDispute[assertionId];
        DisputeState storage d = disputes[disputeId];
        require(d.disputedAt != 0, "Unknown dispute");

        // Graceful no-op if already resolved via forceResolveStale(), syncExternalResolution(), or admin (INV-19).
        if (d.resolved) {
            emit UMACallbackIgnored(disputeId, assertionId, "Already resolved locally");
            return;
        }

        // MAJOR-2 (INV-19 / §8.1 / §8.5): re-read the KERNEL state, mirroring finalize() and
        // forceResolveStale(). If an admin used the always-available INV-6 override to move the kernel
        // out of DISPUTED (e.g. DISPUTED -> CANCELLED) WITHOUT touching this contract, d.resolved is
        // still false, so a naive callback would call compositeMediator.resolve -> kernel.transitionState
        // for an illegal transition (CANCELLED -> SETTLED reverts "Invalid transition", SETTLED -> SETTLED
        // reverts "No-op"). Because UMA's real OOV3 fires this callback from inside settleAssertion and
        // reverts the whole settlement if the callback reverts, that would strand the UMA bond until the
        // 30-day forceResolveStale fallback. Instead we sync locally and RETURN without calling the
        // mediator — making admin-via-kernel resolution a true graceful no-op (no revert, no stuck bond).
        IACTPKernel.TransactionView memory txn = kernel.getTransaction(d.transactionId);
        if (txn.state != IACTPKernel.State.DISPUTED) {
            d.resolved = true;
            d.originalPool = d.accumulatedBonds;
            d.currentRuling = 2;
            d.splitBps = 5000;
            emit ExternalResolutionSynced(disputeId, d.transactionId, uint8(txn.state));
            return;
        }

        // TRUE = "provider delivered" = ruling 0; FALSE = "provider did NOT deliver" = ruling 1.
        uint8 ruling = assertedTruthfully ? 0 : 1;

        d.resolved = true;
        d.originalPool = d.accumulatedBonds; // snapshot BEFORE the bounty deduction (mirrors finalize()).
        d.currentRuling = ruling;
        d.splitBps = 0;

        // F-6 (audit MED) settle-bounty — EXACTLY mirrors finalize()'s keeper bounty so a clean UMA win
        // does not silently degrade to a forced 50/50 at 30 days for lack of a settle incentive. Funded
        // from the Tier-1 pool (this contract's own bonds), deducted BEFORE the winner payout, and
        // capped at the pool so Σ(bounty + winner payout) == originalPool — never exceeds the pool
        // (solvency preserved). The recipient is the keeper that drove settlement via
        // `settleUMAAssertion` (recorded in `pendingSettler`); a bare OOV3.settleAssertion path leaves
        // it zero → no bounty, full pool to the winner. The bounty is paid only on the winner-takes-all
        // leg; on the no-winner SPLIT leg the pool stays intact for proportional `claimEscalationRefund`
        // (matching finalize(), which pays the bounty then leaves the split pool for depositors — but
        // here we MUST NOT pre-deduct from a split pool because the snapshot/originalPool divisor is the
        // FULL pool; deducting only on the winner leg keeps the split refund math exact).
        address settler = pendingSettler[disputeId];

        // Winner of Tier 1 bonds is whoever last proposed the winning direction.
        address winner = lastProposerForRuling[disputeId][ruling];

        // Distribute Tier 1 bonds ONLY (UMA already handled the UMA bond distribution).
        if (winner != address(0)) {
            d.winnerPaid = true;

            // Settle-bounty: max(pool * bps, floor), clamped to the pool. Deducted from accumulatedBonds
            // BEFORE the winner payout, identical in shape to finalize() (FINALIZATION_BOUNTY_BPS /
            // MIN_FINALIZATION_BOUNTY). Only paid when a real settler is recorded.
            uint256 bounty = 0;
            if (settler != address(0)) {
                bounty = (d.accumulatedBonds * FINALIZATION_BOUNTY_BPS) / 10000;
                if (bounty < MIN_FINALIZATION_BOUNTY) bounty = MIN_FINALIZATION_BOUNTY;
                if (bounty > d.accumulatedBonds) bounty = d.accumulatedBonds;
            }
            d.accumulatedBonds -= bounty;

            uint256 payout = d.accumulatedBonds;
            d.accumulatedBonds = 0;
            if (bounty > 0) {
                USDC.safeTransfer(settler, bounty);
            }
            if (payout > 0) {
                USDC.safeTransfer(winner, payout);
            }
            emit UMAResolutionReceived(disputeId, assertionId, ruling, winner, payout);
        } else {
            // Edge case: no one proposed the winning direction in Tier 1.
            // Treat as split - depositors can claim proportionally. NO bounty is taken here: the split
            // refund divisor (`originalPool`) is the FULL pool and every depositor's share is
            // deposits[addr] * accumulatedBonds / originalPool; deducting a bounty would make Σ shares <
            // accumulatedBonds and strand the bounty-sized remainder. The settle incentive is therefore
            // only attached to the clean (winner-takes-all) UMA win, which is the F-6 degradation case.
            d.currentRuling = 2;
            d.splitBps = 5000;
            emit UMAResolutionReceived(disputeId, assertionId, ruling, address(0), 0);
        }

        // F-4 (audit MED) graceful degradation: the kernel-side escrow leg is the unbounded part of this
        // callback (mediator -> kernel.transitionState -> _distributeFee/_releaseEscrow/reputation). The
        // real OOV3 reverts the WHOLE settlement (and strands the UMA bond) if this callback reverts, so
        // an under-provisioned settle caller could brick the dispute. Mirror the reputation-leg
        // try/catch: attempt the mediator resolve, and on failure DO NOT revert — flag the escrow leg as
        // re-drivable via retryMediatorResolution (permissionless). The Tier-1 bonds are already
        // distributed correctly above; only the escrow movement is deferred, and the dispute stays
        // recoverable. CEI is preserved: all state writes/payouts above complete before this external
        // call, and nonReentrant still guards the whole callback.
        try compositeMediator.resolve(d.transactionId, d.currentRuling, d.splitBps) {
            // Escrow settled in the same tx — nothing pending.
        } catch {
            mediatorRetryPending[disputeId] = true;
            emit MediatorResolutionDeferred(disputeId, d.transactionId, d.currentRuling, d.splitBps);
        }
    }

    // =====================================================================
    // §8.5b settleUMAAssertion — permissionless settle helper (F-6 settle-bounty)
    // -----------------------------------------------------------------------------------------------
    // Drives UMA's `settleAssertion`, which synchronously fires `assertionResolvedCallback` back into
    // this contract. Records the caller as `pendingSettler` FIRST so the callback (whose msg.sender is
    // the OOV3, not the keeper) can pay the settle-bounty to the keeper. INTENTIONALLY NOT
    // `nonReentrant`: the real OOV3 invokes the (nonReentrant) callback from inside settleAssertion, so
    // guarding this wrapper too would self-deadlock against the genuine oracle. Reentrancy safety is
    // unaffected — this function performs no fund movement itself; every payout happens inside the
    // already-guarded callback under CEI. A second concurrent call is a no-op: the first callback latches
    // d.resolved, after which any re-entry to the callback returns early (UMACallbackIgnored).
    // =====================================================================
    function settleUMAAssertion(bytes32 disputeId) external whenNotPaused {
        DisputeState storage d = disputes[disputeId];
        require(d.disputedAt != 0, "Dispute not opened");
        require(!d.resolved, "Already resolved");
        require(d.tier == 2, "Not escalated to UMA");

        bytes32 assertionId = disputeToAssertion[disputeId];
        require(assertionId != bytes32(0), "No assertion");

        // Record the settler for the callback's bounty payout, then clear after settlement returns.
        pendingSettler[disputeId] = msg.sender;
        IOptimisticOracleV3(UMA_OOV3).settleAssertion(assertionId);
        delete pendingSettler[disputeId];
    }

    // =====================================================================
    // §8.5c retryMediatorResolution — re-drive a deferred escrow leg (F-4 recovery, NOT pausable — INV-9)
    // -----------------------------------------------------------------------------------------------
    // When the UMA callback distributed the Tier-1 bonds and locally resolved the dispute but the escrow
    // leg (compositeMediator.resolve) reverted/OOG'd, the dispute is left `mediatorRetryPending`. Anyone
    // can re-drive the (now well-provisioned) escrow movement here. Idempotent: clears the flag only on a
    // successful resolve, so a still-failing kernel state leaves it retryable.
    // =====================================================================
    function retryMediatorResolution(bytes32 disputeId) external nonReentrant {
        DisputeState storage d = disputes[disputeId];
        require(d.resolved, "Not resolved");
        require(mediatorRetryPending[disputeId], "No pending retry");

        // Clear BEFORE the external call (CEI). If resolve reverts, the whole tx reverts and the flag is
        // restored — so the dispute stays retryable.
        mediatorRetryPending[disputeId] = false;
        compositeMediator.resolve(d.transactionId, d.currentRuling, d.splitBps);

        emit MediatorResolutionRetried(disputeId, d.transactionId, d.currentRuling, d.splitBps);
    }

    function assertionDisputedCallback(bytes32 assertionId) external nonReentrant {
        require(msg.sender == UMA_OOV3, "Only UMA");
        // Defensive existence guard (mirrors the resolved-callback): a spurious assertionId from a
        // misbehaving OOV3 must not emit a zero-disputeId trace event.
        bytes32 disputeId = assertionToDispute[assertionId];
        require(disputes[disputeId].disputedAt != 0, "Unknown dispute");
        // Dispute is now with the DVM - resolution will arrive via assertionResolvedCallback.
        // 30-day stale fallback still applies if the DVM takes too long.
        emit UMADisputeEscalated(disputeId, assertionId);
    }

    // =====================================================================
    // §4.8 Signature Verification (VERBATIM)
    // =====================================================================
    function _verifyEvaluatorSignatures(bytes32 disputeId, AIRuling calldata ruling, bytes[] calldata signatures)
        internal
        view
    {
        require(signatures.length >= 2 && signatures.length <= 3, "Need 2-3 signatures");
        require(block.timestamp <= ruling.timestamp + RULING_FRESHNESS, "Ruling stale");
        require(rotatingPool.length >= 1, "Rotating pool empty");

        address thirdEvaluator = rotatingPool[uint256(keccak256(abi.encode(disputeId))) % rotatingPool.length];

        bytes32 structHash = keccak256(
            abi.encode(
                RULING_TYPEHASH,
                ruling.disputeId,
                ruling.ruling,
                ruling.confidence,
                ruling.splitBps,
                ruling.timestamp,
                ruling.reasoningHash,
                ruling.bundleHash
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));

        // MAJOR-1 (overlap bypass): if the per-dispute rotating pick collides with a fixed slot, the
        // rotating slot contributes NO independent vote. Without this, a single keypair that occupies
        // BOTH a fixed slot AND the selected rotating slot could sign the same digest twice and reach
        // validCount==2 (fixed branch fills seen[0/1], rotating branch fills seen[2]), collapsing the
        // 2-of-3 threshold to 1-of-1. We zero the rotating candidate on overlap so its branch can never
        // fire. (Write-time disjointness checks in the constructor / governance are defense-in-depth.)
        address thirdCandidate = thirdEvaluator;
        if (thirdCandidate == fixedEvaluators[0] || thirdCandidate == fixedEvaluators[1]) {
            thirdCandidate = address(0);
        }

        bool[3] memory seen;
        uint8 validCount = 0;

        for (uint256 i = 0; i < signatures.length; i++) {
            // §4.7 step 6: malformed/malleable signatures are silently ignored (no revert), so a single
            // garbage signature cannot DoS an otherwise-valid 2/3. tryRecover returns an error instead
            // of reverting on wrong-length or high-s sigs; we skip those entries (treat as "unknown").
            (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signatures[i]);
            if (err != ECDSA.RecoverError.NoError) {
                continue;
            }

            if (signer == fixedEvaluators[0] && !seen[0]) {
                seen[0] = true;
                validCount++;
            } else if (signer == fixedEvaluators[1] && !seen[1]) {
                seen[1] = true;
                validCount++;
            } else if (signer != address(0) && signer == thirdCandidate && !seen[2]) {
                seen[2] = true;
                validCount++;
            }
        }

        require(validCount >= 2, "Insufficient valid signatures");
    }

    // =====================================================================
    // §7.13 Internal Helpers
    // =====================================================================
    function _calculateInitialBond(uint256 escrowAmount) internal pure returns (uint256) {
        uint256 percentBond = (escrowAmount * ESCALATION_INITIAL_BPS) / 10000;
        uint256 bond = percentBond > MIN_ESCALATION_BOND ? percentBond : MIN_ESCALATION_BOND;
        // F-5 (audit MED) FIX: cap the initial bond at MAX_ESCALATION_BOND so it is symmetric with the
        // $500-capped challenge ceiling (challenge clamps `nextBond` to MAX_ESCALATION_BOND at L320-322).
        // Without this cap a large escrow (e.g. $1M) yields a ~$20k uncapped initial bond while a griefer
        // re-defends each round for only $500, enabling cheap large-bond winner-takes-all griefing.
        if (bond > MAX_ESCALATION_BOND) bond = MAX_ESCALATION_BOND;
        return bond;
    }

    function _livenessForEscrow(uint256 escrowAmount) internal pure returns (uint64) {
        if (escrowAmount < 50_000_000) return 1 hours;
        if (escrowAmount < 500_000_000) return 2 hours;
        if (escrowAmount < 5_000_000_000) return 4 hours;
        return 8 hours;
    }

    function _toHexString(bytes32 value) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory str = new bytes(64);
        for (uint256 i = 0; i < 32; i++) {
            str[i * 2] = alphabet[uint8(value[i] >> 4)];
            str[i * 2 + 1] = alphabet[uint8(value[i] & 0x0f)];
        }
        return string(str);
    }

    // =====================================================================
    // §7.14 / §4.9 Pause & Governance (IBondEscalationAdmin)
    // =====================================================================
    function pause() external override onlyAdmin {
        paused = true;
    }

    function unpause() external override onlyAdmin {
        paused = false;
    }

    // --- Fixed Evaluator Updates (Timelocked) ---

    function proposeFixedEvaluatorUpdate(uint8 slot, address newEvaluator) external override onlyAdmin {
        require(slot < 2, "Invalid slot");
        require(newEvaluator != address(0), "Zero address");
        pendingFixedEvaluators[slot] = newEvaluator;
        fixedEvaluatorUnlockTime[slot] = uint64(block.timestamp) + EVALUATOR_UPDATE_DELAY;
        emit FixedEvaluatorUpdateProposed(slot, newEvaluator, fixedEvaluatorUnlockTime[slot]);
    }

    function executeFixedEvaluatorUpdate(uint8 slot) external override {
        require(slot < 2, "Invalid slot");
        require(pendingFixedEvaluators[slot] != address(0), "No pending update");
        require(block.timestamp >= fixedEvaluatorUnlockTime[slot], "Timelock active");
        // MAJOR-1 defense-in-depth: the new fixed evaluator must not collide with the OTHER fixed slot
        // or any current rotating member (which would re-introduce the overlap bypass).
        address newEvaluator = pendingFixedEvaluators[slot];
        require(newEvaluator != fixedEvaluators[slot == 0 ? 1 : 0], "Fixed slots must differ");
        for (uint256 i = 0; i < rotatingPool.length; i++) {
            require(rotatingPool[i] != newEvaluator, "Fixed overlaps rotating");
        }
        fixedEvaluators[slot] = newEvaluator;
        emit FixedEvaluatorUpdated(slot, fixedEvaluators[slot]);
        delete pendingFixedEvaluators[slot];
        delete fixedEvaluatorUnlockTime[slot];
    }

    function cancelFixedEvaluatorUpdate(uint8 slot) external override onlyAdmin {
        require(slot < 2, "Invalid slot");
        delete pendingFixedEvaluators[slot];
        delete fixedEvaluatorUnlockTime[slot];
        emit FixedEvaluatorUpdateCancelled(slot);
    }

    // --- Canonical Prompt-CID Governance (Timelocked, §4.2) ---
    // The evaluator prompt is pinned to IPFS; its CID is committed on-chain so anyone can verify WHICH
    // prompt the evaluators used. Updates follow the same 2-day EVALUATOR_UPDATE_DELAY as evaluator
    // changes; execute is permissionless after the delay (mirrors executeFixedEvaluatorUpdate). The AI
    // ruling is advisory/Tier-1-challengeable, so this is a transparency commitment, not a fund path.
    // Genesis: the deployer proposes the initial CID at deploy and executes after the delay (parallel
    // with the mediator-approval timelock), so no separate non-timelocked init surface is introduced.

    function proposePromptCID(string calldata newCID) external override onlyAdmin {
        require(bytes(newCID).length != 0, "Empty CID");
        pendingPromptCID = newCID;
        promptCIDUnlockTime = uint64(block.timestamp) + EVALUATOR_UPDATE_DELAY;
        emit PromptCIDProposed(newCID, promptCIDUnlockTime);
    }

    function executePromptCID() external override {
        require(promptCIDUnlockTime != 0, "No pending update");
        require(block.timestamp >= promptCIDUnlockTime, "Timelock active");
        activePromptCID = pendingPromptCID;
        emit PromptCIDUpdated(activePromptCID);
        delete pendingPromptCID;
        delete promptCIDUnlockTime;
    }

    function cancelPromptCID() external override onlyAdmin {
        delete pendingPromptCID;
        delete promptCIDUnlockTime;
        emit PromptCIDProposalCancelled();
    }

    // --- Rotating Pool Additions (Timelocked) ---

    function proposeRotatingPoolAddition(address evaluator) external override onlyAdmin {
        require(evaluator != address(0), "Zero address");
        // MAJOR-1 defense-in-depth: a rotating addition must not overlap either fixed slot.
        require(
            evaluator != fixedEvaluators[0] && evaluator != fixedEvaluators[1],
            "Rotating overlaps fixed"
        );
        pendingRotatingAdditions.push(evaluator);
        rotatingAdditionUnlockTime.push(uint64(block.timestamp) + EVALUATOR_UPDATE_DELAY);
        emit RotatingPoolAdditionProposed(evaluator, rotatingAdditionUnlockTime[rotatingAdditionUnlockTime.length - 1]);
    }

    function executeRotatingPoolAddition(uint256 index) external override {
        require(index < pendingRotatingAdditions.length, "Invalid index");
        require(block.timestamp >= rotatingAdditionUnlockTime[index], "Timelock active");
        address evaluator = pendingRotatingAdditions[index];
        // MAJOR-1 (execute-time re-check — NOT only propose-time): a fixed slot may have been changed to
        // this address while the addition sat in the 2-day queue (the route: propose-rotating X → update
        // a fixed slot to X → execute-rotating X). Without this re-check the config-time protection is
        // incomplete and the pool could be left with rotating==fixed (the runtime guard still saves the
        // 2/3 threshold, but we keep the config honest). Re-verify disjointness NOW.
        require(evaluator != fixedEvaluators[0] && evaluator != fixedEvaluators[1], "Rotating overlaps fixed");
        rotatingPool.push(evaluator);
        emit RotatingPoolUpdated(evaluator, true);
        // Remove from pending (swap and pop).
        pendingRotatingAdditions[index] = pendingRotatingAdditions[pendingRotatingAdditions.length - 1];
        rotatingAdditionUnlockTime[index] = rotatingAdditionUnlockTime[rotatingAdditionUnlockTime.length - 1];
        pendingRotatingAdditions.pop();
        rotatingAdditionUnlockTime.pop();
    }

    // --- Rotating Pool Removals (Immediate) ---

    function removeFromRotatingPool(uint256 index) external override onlyAdmin {
        require(index < rotatingPool.length, "Invalid index");
        require(rotatingPool.length > 1, "Pool minimum is 1");
        address removed = rotatingPool[index];
        rotatingPool[index] = rotatingPool[rotatingPool.length - 1];
        rotatingPool.pop();
        emit RotatingPoolUpdated(removed, false);
    }

    // =====================================================================
    // View helpers (registry introspection)
    // =====================================================================
    function rotatingPoolLength() external view returns (uint256) {
        return rotatingPool.length;
    }

    function pendingRotatingAdditionsLength() external view returns (uint256) {
        return pendingRotatingAdditions.length;
    }
}
