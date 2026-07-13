// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/**
 * AGIRAILS — Agent Commerce Transaction Protocol (ACTP)
 * https://agirails.io
 */

import {IACTPKernel} from "./interfaces/IACTPKernel.sol";
import {IEscrowValidator} from "./interfaces/IEscrowValidator.sol";
import {IAgentRegistry} from "./interfaces/IAgentRegistry.sol";
import {IArchiveTreasury} from "./interfaces/IArchiveTreasury.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title ACTPKernel - ACTP Transaction Coordinator
 * @notice Minimal implementation of the ACTP on-chain coordinator.
 */
contract ACTPKernel is IACTPKernel, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Transaction {
        bytes32 transactionId;
        address requester;
        address provider;
        State state;
        uint256 amount;
        uint256 createdAt;
        uint256 updatedAt;
        uint256 deadline;
        bytes32 serviceHash;
        address escrowContract;
        bytes32 escrowId;
        bytes32 attestationUID;
        uint256 disputeWindow; // timestamp (expiry)
        bytes32 metadata; // For quote hash (AIP-2) or other protocol metadata
        uint16 platformFeeBpsLocked; // AIP-5: Lock platform fee % at creation time
        uint16 requesterPenaltyBpsLocked; // Lock penalty rate at creation time
        uint16 disputeBondBpsLocked; // INV-30: Lock dispute bond rate at creation
        bool wasDisputed; // AIP-7: Track if transaction went through dispute. AIP-14: semantic change to "provider at fault"
        uint256 agentId; // ERC-8004 agent ID for provider (0 if not applicable)
        uint256 requesterAgentId; // AIP-14: Requester's ERC-8004 agent ID (0 if not an agent)
        address disputeInitiator; // AIP-14: Who opened the dispute (for bond return)
        uint256 disputeBond; // AIP-14: Bond amount locked at dispute time
        bytes32 resultHash; // AIP-14c: keccak of delivered result (public plaintext / encrypted envelope), committed at DELIVERED
        bytes32 agreementHash; // AIP-14c: keccak of request+input+SLA (NOT the quote), committed at createTransaction
    }

    mapping(bytes32 => Transaction) private transactions;
    mapping(address => uint256) public requesterNonces;

    uint256 public constant DEFAULT_DISPUTE_WINDOW = 2 days;
    uint256 public constant MIN_DISPUTE_WINDOW = 1 hours; // Minimum 1 hour to prevent instant finalization
    uint256 public constant MAX_DISPUTE_WINDOW = 30 days;
    uint256 public constant MAX_BPS = 10_000;
    uint16 public constant MAX_PLATFORM_FEE_CAP = 500; // 5%
    uint256 public constant MIN_FEE = 50_000; // $0.05 USDC (6 decimals)
    uint16 public constant MAX_REQUESTER_PENALTY_CAP = 5_000; // 50%
    uint16 public constant MAX_MEDIATOR_FEE_BPS = 1_000; // 10% max mediator fee
    uint256 public constant MIN_TRANSACTION_AMOUNT = 50_000; // $0.05 USDC — anti-spam minimum (original value restored)
    uint256 public constant MAX_TRANSACTION_AMOUNT = 1_000_000_000e6; // 1B USDC (with 6 decimals)
    uint256 public constant MAX_DEADLINE = 365 days; // Maximum 1 year deadline
    uint256 public constant MIN_DEADLINE = 1 hours; // F-6: floor delivery window so a requester cannot manufacture an instant strand
    uint256 public constant MIN_RECOVERY_GRACE = 1 hours; // F-6: non-zero grace floor — no deadline-boundary front-run
    uint256 public constant ECONOMIC_PARAM_DELAY = 2 days;
    uint256 public constant MEDIATOR_APPROVAL_DELAY = 2 days; // Time-lock for mediator approvals
    // AIP-14: Dispute bond parameters
    uint256 public constant MIN_DISPUTE_BOND = 1_000_000; // $1 USDC minimum
    uint16 public constant MAX_DISPUTE_BOND_BPS = 2_000; // 20% cap
    // [M-1 AUDIT FIX] Emergency recovery exists for edge case where archive treasury
    // AND fallback transfer both fail, leaving USDC stranded in kernel. See _distributeFee().
    address public admin;
    address public pauser;
    address public feeRecipient;
    address public pendingAdmin;
    uint16 public platformFeeBps;
    uint16 public requesterPenaltyBps;
    bool public paused;
    IAgentRegistry public agentRegistry; // AIP-7: Agent registry for reputation tracking
    uint16 public disputeBondBps; // AIP-14: Dispute bond percentage (default 500 = 5%)

    /// @notice Archive treasury contract for permanent storage funding
    address public archiveTreasury;

    /// @notice Basis points allocated to archive treasury (0.1% = 10 bps of platform fee)
    uint16 public constant ARCHIVE_ALLOCATION_BPS = 10;

    /// @notice USDC token address for fee transfers
    IERC20 public USDC;

    /// @notice F-6: global immutable stalled-IN_PROGRESS recovery grace, added to deadline. Mainnet 7 days; testnet/local short.
    uint256 public immutable recoveryGrace;

    mapping(address => bool) public approvedEscrowVaults;
    /// @notice [Apex 2026-07-12 H4] Scheduled vault-revocation unlock time (0 = none pending).
    mapping(address => uint256) public pendingVaultRevocationAt;
    mapping(address => bool) public approvedMediators;
    mapping(address => uint256) public mediatorApprovedAt;
    mapping(address => uint256) public mediatorRevokedAt; // [C-1 FIX] Track revocation time to prevent timelock bypass
    mapping(address => mapping(bytes32 => bool)) private usedEscrowIds;
    mapping(bytes32 => address) public reputationProcessedBy; // [C-2 FIX] Track which registry processed reputation for each transaction

    event MediatorApproved(address indexed mediator, bool approved);
    event AdminTransferInitiated(address indexed currentAdmin, address indexed pendingAdmin);
    /// @notice [Apex 2026-07-12 H4] Timelocked vault-revocation lifecycle.
    event EscrowVaultRevocationScheduled(address indexed vault, uint256 executeAfter);
    event EscrowVaultRevocationCancelled(address indexed vault);
    /// @notice [Apex 2026-07-12 F-III] Live dispute-bond-rate change (in-flight txns keep the locked rate, INV-30).
    event DisputeBondBpsUpdated(uint16 oldBps, uint16 newBps);
    event AgentRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);
    event AgentRegistryUpdateScheduled(address indexed newRegistry, uint256 executeAfter);
    event AgentRegistryUpdateCancelled(address indexed newRegistry, uint256 timestamp);
    event ArchiveTreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    struct PendingEconomicParams {
        uint16 platformFeeBps;
        uint16 requesterPenaltyBps;
        uint256 executeAfter;
        bool active;
    }

    struct PendingRegistryUpdate {
        address newRegistry;
        uint256 executeAfter;
        bool active;
    }

    PendingEconomicParams private pendingEconomicParams;
    PendingRegistryUpdate private pendingRegistryUpdate;

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    modifier onlyPauser() {
        require(msg.sender == pauser || msg.sender == admin, "Not pauser");
        _;
    }

    modifier whenNotPaused() {
        // Pause blocks state changes, not fund recovery
        require(!paused, "Kernel paused");
        _;
    }

    constructor(
        address _admin,
        address _pauser,
        address _feeRecipient,
        address _agentRegistry,
        address _usdc,
        uint256 _recoveryGrace
    ) {
        require(_admin != address(0), "Admin required");
        require(_feeRecipient != address(0), "Fee recipient required");
        require(_usdc != address(0), "USDC required");
        require(_recoveryGrace >= MIN_RECOVERY_GRACE, "Recovery grace too short");
        admin = _admin;
        pauser = _pauser == address(0) ? _admin : _pauser;
        feeRecipient = _feeRecipient;
        USDC = IERC20(_usdc);
        recoveryGrace = _recoveryGrace;
        _validatePlatformFee(100);
        _validateRequesterPenalty(500);
        platformFeeBps = 100;
        requesterPenaltyBps = 500;

        disputeBondBps = 500; // AIP-14: 5% default

        _setInitialAgentRegistry(_agentRegistry);
    }

    // ---------------------------------------------------------------------
    // Transaction lifecycle
    // ---------------------------------------------------------------------

    /**
     * @notice Creates a new transaction between requester and provider
     * @dev IMPORTANT: Before calling this function, ensure that:
     *      1. At least one escrow vault is approved by the admin
     *      2. You have sufficient funds to create escrow in an approved vault
     *      3. The provider address is correct and trusted
     * @dev transactionId is generated deterministically from the inputs
     * @param provider Address of the service provider
     * @param requester Address of the requester (must match msg.sender)
     * @param amount Amount in tokens (must be > 0 and <= MAX_TRANSACTION_AMOUNT)
     * @param deadline Timestamp when the transaction expires
     * @param disputeWindow Duration in seconds for the dispute window
     * @param serviceHash Hash of the service agreement
     * @return transactionId The generated transaction ID
     */
    function createTransaction(
        address provider,
        address requester,
        uint256 amount,
        uint256 deadline,
        uint256 disputeWindow,
        bytes32 serviceHash,
        bytes32 agreementHash,
        uint256 agentId,
        uint256 requesterAgentId
    ) external override whenNotPaused returns (bytes32 transactionId) {
        require(msg.sender == requester, "Requester mismatch");
        require(provider != address(0), "Zero provider");
        require(requester != provider, "Self-transaction not allowed");
        require(amount >= MIN_TRANSACTION_AMOUNT, "Amount below minimum");
        require(amount <= MAX_TRANSACTION_AMOUNT, "Amount exceeds maximum");
        require(deadline > block.timestamp, "Deadline in past");
        require(deadline >= block.timestamp + MIN_DEADLINE, "Deadline too soon");
        require(deadline <= block.timestamp + MAX_DEADLINE, "Deadline too far");
        require(disputeWindow >= MIN_DISPUTE_WINDOW, "Dispute window too short");
        require(disputeWindow <= MAX_DISPUTE_WINDOW, "Dispute window too long");

        // Generate deterministic transactionId with nonce for uniqueness
        uint256 currentNonce = requesterNonces[requester];
        require(currentNonce < type(uint256).max, "Nonce overflow");
        transactionId = keccak256(
            abi.encodePacked(requester, provider, amount, serviceHash, currentNonce)
        );
        requesterNonces[requester] = currentNonce + 1;
        require(transactions[transactionId].createdAt == 0, "Tx exists");

        Transaction storage txn = transactions[transactionId];
        txn.transactionId = transactionId;
        txn.requester = requester;
        txn.provider = provider;
        txn.state = State.INITIATED;
        txn.amount = amount;
        txn.createdAt = block.timestamp;
        txn.updatedAt = block.timestamp;
        txn.deadline = deadline;
        txn.disputeWindow = disputeWindow;
        txn.serviceHash = serviceHash;
        txn.agreementHash = agreementHash; // AIP-14c: request+input+SLA commitment (0 = no auto AI ruling)
        txn.platformFeeBpsLocked = platformFeeBps; // AIP-5: Lock current platform fee % at creation
        txn.requesterPenaltyBpsLocked = requesterPenaltyBps; // Lock penalty rate at creation
        txn.disputeBondBpsLocked = disputeBondBps; // INV-30: Lock dispute bond rate at creation (immune to live updateDisputeBondBps changes)
        txn.agentId = agentId; // ERC-8004 agent ID (0 if not applicable)
        txn.requesterAgentId = requesterAgentId; // AIP-14: Requester's ERC-8004 agent ID

        // State changes must be observable
        emit TransactionCreated(transactionId, requester, provider, amount, serviceHash, deadline, block.timestamp, agentId, agreementHash);
    }

    /// @notice The single general-purpose state-machine entrypoint. Frozen by pause.
    /// @dev `whenNotPaused` freezes ALL forward/normal transitions during an emergency pause.
    ///      The ONE exception — honest DISPUTED→{SETTLED,CANCELLED} recovery by an approved resolver —
    ///      is served by the pause-exempt `resolveDisputeWhilePaused` below (F-2 / INV-9), NOT here.
    function transitionState(
        bytes32 transactionId,
        State newState,
        bytes calldata proof
    ) external override whenNotPaused nonReentrant {
        _transitionState(transactionId, newState, proof);
    }

    /// @notice [F-2 AUDIT FIX] Pause-exempt entrypoint for honest dispute recovery only.
    /// @dev INV-9 / walk-away rationale: the dispute system's headline guarantee is automated,
    ///      permissionless, walk-away resolution. `transitionState` carries `whenNotPaused`, so before
    ///      this fix a single `pause()` transitively bricked EVERY dispute-recovery path
    ///      (CompositeMediator.resolve → kernel, BondEscalation.finalize / forceResolveStale /
    ///      assertionResolvedCallback), defeating INV-9: while paused NO actor — not even admin — could
    ///      move a DISPUTED txn out of DISPUTED, freezing escrow + bonds for the pause duration (worst
    ///      case: permanent loss if the system is abandoned-AND-paused). `releaseEscrow` already omits
    ///      `whenNotPaused` (pause blocks state changes, not fund recovery); this restores the same
    ///      asymmetry for the dispute-resolution kernel boundary.
    ///
    ///      NARROW SCOPE — this grants NO new power:
    ///        - Restricted to `_isApprovedResolver(msg.sender)` — the EXACT same resolver set
    ///          ({admin (INV-6)} ∪ {approved + timelocked mediators, e.g. CompositeMediator}) that may
    ///          already drive DISPUTED→exit via `transitionState`. No new caller is admitted.
    ///        - Restricted to the DISPUTED→{SETTLED,CANCELLED} transition only (enforced below). ALL
    ///          normal/forward transitions stay frozen under pause exactly as before.
    ///        - Runs the SAME audited `_transitionState` body — same `_enforceAuthorization`
    ///          (which re-applies `_isApprovedResolver` on the DISPUTED branch), same
    ///          `_handleDisputeSettlement` / `_handleCancellation` distribution, same solvency
    ///          `totalDistributed == remaining` checks. ONLY the `whenNotPaused` gate is relaxed.
    ///      Net effect: honest dispute recovery survives a pause; everything else stays frozen.
    function resolveDisputeWhilePaused(
        bytes32 transactionId,
        State newState,
        bytes calldata proof
    ) external nonReentrant {
        // Pause-exempt scope guard: ONLY the dispute exit, ONLY an approved resolver.
        require(newState == State.SETTLED || newState == State.CANCELLED, "Resolve only");
        require(_getTransaction(transactionId).state == State.DISPUTED, "Not disputed");
        require(_isApprovedResolver(msg.sender), "Resolver only");
        _transitionState(transactionId, newState, proof);
    }

    function _transitionState(
        bytes32 transactionId,
        State newState,
        bytes calldata proof
    ) internal {
        Transaction storage txn = _getTransaction(transactionId);
        State oldState = txn.state;
        require(newState != oldState, "No-op");
        // State machine monotonicity: no backwards transitions
        require(_isValidTransition(oldState, newState), "Invalid transition");
        _enforceAuthorization(txn, oldState, newState);
        _enforceTiming(txn, oldState, newState);

        if (newState == State.DELIVERED) {
            // AIP-14c (D1): the DELIVERED proof MUST be the 64-byte (window, resultHash) tuple with an
            // explicit bounded non-zero window and a non-zero resultHash. Legacy empty/32-byte proofs are
            // rejected on v2 — no default-window sentinel, and every delivery commits its result hash so a
            // dispute always has an on-chain-anchored deliverable to authenticate against.
            (uint256 window, bytes32 resultHash) = _decodeDeliveryProof(proof);
            require(block.timestamp <= type(uint256).max - window, "Timestamp overflow");
            txn.disputeWindow = block.timestamp + window;
            txn.resultHash = resultHash;
        } else if (newState == State.QUOTED && proof.length > 0) {
            // AIP-2: Store quote hash for verification (optional - only if proof provided)
            require(proof.length == 32, "Quote hash must be 32 bytes");
            bytes32 quoteHash = abi.decode(proof, (bytes32));
            require(quoteHash != bytes32(0), "Invalid quote hash");
            txn.metadata = quoteHash;
        } else if (newState == State.DISPUTED) {
            // AIP-7: Mark transaction as disputed for reputation tracking
            txn.wasDisputed = true;
            // AIP-14: Dispute bond + initiator tracking
            txn.disputeInitiator = msg.sender;
            // INV-30: use rate locked at creation, not live disputeBondBps, so admin changes cannot affect in-flight transactions
            uint256 bond = (txn.amount * txn.disputeBondBpsLocked) / MAX_BPS;
            if (bond < MIN_DISPUTE_BOND) bond = MIN_DISPUTE_BOND;
            // Bond is a separate deposit — does not affect escrow split accounting
            require(txn.escrowContract != address(0), "Escrow missing for dispute");
            IEscrowValidator vault = IEscrowValidator(txn.escrowContract);
            vault.depositBond(txn.escrowId, msg.sender, bond);
            txn.disputeBond = bond;
        }

        txn.state = newState;
        txn.updatedAt = block.timestamp;

        emit StateTransitioned(transactionId, oldState, newState, msg.sender, block.timestamp);

        // AIP-14: Emit DisputeOpened event
        if (newState == State.DISPUTED) {
            emit DisputeOpened(transactionId, msg.sender, txn.disputeBond, block.timestamp);
        }

        if (newState == State.SETTLED) {
            if (oldState == State.DISPUTED) {
                _handleDisputeSettlement(txn, proof);
            } else {
                _releaseEscrow(txn);
            }
            _clearUsedEscrowId(txn);
        } else if (newState == State.CANCELLED) {
            _handleCancellation(txn, oldState, proof, msg.sender);
            _clearUsedEscrowId(txn);
        }
    }

    function getTransaction(bytes32 transactionId) external view override returns (TransactionView memory) {
        Transaction storage txn = _getTransaction(transactionId);
        return
            TransactionView({
                transactionId: txn.transactionId,
                requester: txn.requester,
                provider: txn.provider,
                state: txn.state,
                amount: txn.amount,
                createdAt: txn.createdAt,
                updatedAt: txn.updatedAt,
                deadline: txn.deadline,
                serviceHash: txn.serviceHash,
                escrowContract: txn.escrowContract,
                escrowId: txn.escrowId,
                attestationUID: txn.attestationUID,
                disputeWindow: txn.disputeWindow,
                metadata: txn.metadata,
                platformFeeBpsLocked: txn.platformFeeBpsLocked, // AIP-5: Return locked fee %
                requesterPenaltyBpsLocked: txn.requesterPenaltyBpsLocked, // AIP-14 / d9c6e8e
                disputeBondBpsLocked: txn.disputeBondBpsLocked, // INV-30: Return locked dispute bond rate
                agentId: txn.agentId, // ERC-8004 agent ID
                requesterAgentId: txn.requesterAgentId, // AIP-14
                disputeInitiator: txn.disputeInitiator, // AIP-14
                disputeBond: txn.disputeBond, // AIP-14
                resultHash: txn.resultHash, // AIP-14c
                agreementHash: txn.agreementHash // AIP-14c
            });
    }

    /// @notice Deterministic on-chain identity of this kernel build (AIP-14c §6). Deploy gates pin
    ///         this PLUS the network-specific audited runtime codehash — never a human version string.
    function kernelVersion() external pure returns (bytes32) {
        return keccak256("ACTP_KERNEL_V2_AIP14C_REV2");
    }

    // ---------------------------------------------------------------------
    // Escrow & Attestation hooks
    // ---------------------------------------------------------------------

    function linkEscrow(bytes32 transactionId, address escrowContract, bytes32 escrowId) external override whenNotPaused nonReentrant {
        require(escrowContract != address(0), "Escrow addr");
        require(escrowId != bytes32(0), "Invalid escrow ID");
        require(approvedEscrowVaults[escrowContract], "Escrow not approved");
        require(!usedEscrowIds[escrowContract][escrowId], "Escrow ID already used");
        usedEscrowIds[escrowContract][escrowId] = true;

        Transaction storage txn = _getTransaction(transactionId);
        require(txn.state == State.INITIATED || txn.state == State.QUOTED, "Invalid state for linkEscrow");
        // Authorization: only transaction requester
        require(msg.sender == txn.requester, "Only requester");
        require(block.timestamp <= txn.deadline, "Transaction expired");

        State oldState = txn.state;

        // Create escrow - vault pulls funds from requester
        IEscrowValidator(escrowContract).createEscrow(
            escrowId,
            txn.requester,
            txn.provider,
            txn.amount
        );

        // Verify escrow was actually funded
        (bool isActive, uint256 escrowAmount) = IEscrowValidator(escrowContract).verifyEscrow(
            escrowId,
            txn.requester,
            txn.provider,
            txn.amount
        );
        require(isActive && escrowAmount >= txn.amount, "Escrow funding failed");

        txn.escrowContract = escrowContract;
        txn.escrowId = escrowId;
        txn.state = State.COMMITTED;
        txn.updatedAt = block.timestamp;

        emit EscrowLinked(transactionId, escrowContract, escrowId, txn.amount, block.timestamp);
        emit StateTransitioned(transactionId, oldState, State.COMMITTED, msg.sender, block.timestamp);
    }


    function acceptQuote(bytes32 transactionId, uint256 newAmount) external override whenNotPaused {
        require(newAmount >= MIN_TRANSACTION_AMOUNT, "Below minimum");
        require(newAmount <= MAX_TRANSACTION_AMOUNT, "Above maximum");

        Transaction storage txn = _getTransaction(transactionId);
        require(txn.state == State.QUOTED, "Not quoted");
        require(msg.sender == txn.requester, "Only requester");
        require(block.timestamp <= txn.deadline, "Expired");

        uint256 oldAmount = txn.amount;
        txn.amount = newAmount;
        txn.platformFeeBpsLocked = platformFeeBps;
        txn.updatedAt = block.timestamp;

        emit QuoteAccepted(transactionId, oldAmount, newAmount, block.timestamp);
    }

    function releaseMilestone(bytes32 transactionId, uint256 amount) external override whenNotPaused nonReentrant {
        require(amount > 0, "Amount zero");
        Transaction storage txn = _getTransaction(transactionId);
        require(txn.state == State.IN_PROGRESS, "Not in progress");
        require(msg.sender == txn.requester, "Only requester");
        require(txn.escrowContract != address(0), "Escrow missing");

        IEscrowValidator vault = IEscrowValidator(txn.escrowContract);
        uint256 remaining = vault.remaining(txn.escrowId);
        // Solvency invariant: guarantee before commitment
        require(amount <= remaining, "Insufficient escrow");

        _payoutProviderAmount(txn, vault, amount);
        emit EscrowMilestoneReleased(transactionId, amount, block.timestamp);
        txn.updatedAt = block.timestamp;
    }

    /// @notice Release escrowed funds for a settled transaction
    /// @dev Intentionally omits whenNotPaused — pause blocks state changes, not fund recovery.
    ///      This allows participants to withdraw funds even during an emergency pause.
    ///      Note: fee distribution and reputation updates also execute during pause via this path.
    function releaseEscrow(bytes32 transactionId) external override nonReentrant {
        Transaction storage txn = _getTransaction(transactionId);
        require(txn.state == State.SETTLED, "Not settled");
        _releaseEscrow(txn);
    }

    /// @notice [F-6] Permissionless liveness backstop for a stalled IN_PROGRESS escrow.
    /// @dev Intentionally omits whenNotPaused — pause blocks state changes, not fund recovery
    ///      (same precedent as releaseEscrow / resolveDisputeWhilePaused). After deadline+recoveryGrace,
    ///      anyone may cancel the txn and full-refund the remaining escrow to the requester.
    ///      This is a SEPARATE entrypoint, not the cancellation path: the H-4 guard in _enforceTiming
    ///      is untouched and still blocks the requester from cancelling IN_PROGRESS via transitionState.
    function recoverStalledInProgress(bytes32 transactionId) external override nonReentrant {
        Transaction storage txn = _getTransaction(transactionId);
        require(txn.state == State.IN_PROGRESS, "Not in progress");
        require(block.timestamp >= txn.deadline + recoveryGrace, "Recovery not yet available");
        require(txn.escrowContract != address(0), "Escrow missing");

        IEscrowValidator vault = IEscrowValidator(txn.escrowContract);
        uint256 remaining = vault.remaining(txn.escrowId);

        // Effects before interactions (CEI). CANCELLED is terminal — re-entry reverts on the state check.
        txn.state = State.CANCELLED;
        txn.updatedAt = block.timestamp;
        txn.wasDisputed = true; // F-6: provider at fault (non-delivery) for reputation accounting

        emit StateTransitioned(transactionId, State.IN_PROGRESS, State.CANCELLED, msg.sender, block.timestamp);
        emit StalledInProgressRecovered(transactionId, txn.requester, remaining);

        // [C-2 FIX] Reputation mark — same guarded pattern as settlement. provider at fault (true): non-delivery.
        if (address(agentRegistry) != address(0) && reputationProcessedBy[txn.transactionId] == address(0)) {
            reputationProcessedBy[txn.transactionId] = address(agentRegistry);
            try agentRegistry.updateReputationOnSettlement{gas: 150000}(
                txn.provider,
                txn.transactionId,
                txn.amount,
                true
            ) {} catch {}
        }

        if (remaining > 0) {
            _refundRequester(txn, vault, remaining);
        }
        _clearUsedEscrowId(txn);
    }

    function anchorAttestation(bytes32 transactionId, bytes32 attestationUID) external override whenNotPaused {
        require(attestationUID != bytes32(0), "Attestation missing");
        Transaction storage txn = _getTransaction(transactionId);
        require(txn.state == State.SETTLED, "Only settled");
        require(msg.sender == txn.requester || msg.sender == txn.provider, "Not participant");

        txn.attestationUID = attestationUID;
        emit AttestationAnchored(transactionId, attestationUID, msg.sender, block.timestamp);
    }

    // ---------------------------------------------------------------------
    // Governance
    // ---------------------------------------------------------------------

    function pause() external override onlyPauser {
        require(!paused, "Already paused");
        paused = true;
        emit KernelPaused(msg.sender, block.timestamp);
    }

    function unpause() external override onlyPauser {
        require(paused, "Not paused");
        paused = false;
        emit KernelUnpaused(msg.sender, block.timestamp);
    }

    /// @notice Emitted when admin recovers stranded USDC from kernel during emergency
    event EmergencyUSDCRecovered(address indexed recipient, uint256 amount, uint256 timestamp);
    // F-6: StalledInProgressRecovered is declared in IACTPKernel (inherited) — not re-declared here to avoid a duplicate-event error.

    /// @notice Recover USDC stranded in kernel due to archive treasury double-failure
    /// @dev [M-1 AUDIT FIX] Only callable by admin while paused. The kernel should never
    ///      hold USDC under normal operation — this is strictly for the edge case where
    ///      _distributeFee() archive payout AND fallback transfer both fail.
    /// @param recipient Address to send recovered USDC to
    /// @param amount Amount of USDC to recover
    function emergencyRecoverUSDC(address recipient, uint256 amount) external onlyAdmin {
        require(paused, "Must be paused");
        require(recipient != address(0), "Zero recipient");
        require(amount > 0, "Zero amount");
        uint256 balance = USDC.balanceOf(address(this));
        require(amount <= balance, "Exceeds kernel balance");
        USDC.safeTransfer(recipient, amount);
        emit EmergencyUSDCRecovered(recipient, amount, block.timestamp);
    }

    function updatePauser(address newPauser) external onlyAdmin {
        require(newPauser != address(0), "Zero pauser");
        address oldPauser = pauser;
        pauser = newPauser;
        emit PauserUpdated(oldPauser, newPauser);
    }

    function updateFeeRecipient(address newRecipient) external onlyAdmin {
        require(newRecipient != address(0), "Zero recipient");
        address oldRecipient = feeRecipient;
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(oldRecipient, newRecipient);
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "Zero admin");
        pendingAdmin = newAdmin;
        emit AdminTransferInitiated(admin, newAdmin);
    }

    function acceptAdmin() external {
        require(msg.sender == pendingAdmin, "Not pending admin");
        address oldAdmin = admin;
        admin = pendingAdmin;
        delete pendingAdmin;
        emit AdminTransferred(oldAdmin, admin);
    }

    function approveEscrowVault(address vault, bool approved) external onlyAdmin {
        require(vault != address(0), "Zero vault");
        // [Apex 2026-07-12 H4] Approval stays immediate (grants no withdrawal power), but
        // REVOCATION is the dangerous direction: every payout/refund/mediator path hard-requires
        // the approval flag, so an instant revoke would freeze ALL in-flight escrow in that vault
        // in a single tx (compromised admin / fat-finger). Revocation must go through the
        // ECONOMIC_PARAM_DELAY schedule below — same discipline as economic params.
        require(approved, "Revocation must be scheduled");
        // Re-approval doubles as the CANCEL of any scheduled revocation (a fresh admin
        // approval statement supersedes the pending removal — no surprise execution later).
        if (pendingVaultRevocationAt[vault] != 0) {
            delete pendingVaultRevocationAt[vault];
            emit EscrowVaultRevocationCancelled(vault);
        }
        approvedEscrowVaults[vault] = true;
        emit EscrowVaultApproved(vault, true);
    }

    /// @notice [Apex H4] Schedule a vault revocation behind the 2-day economic-param delay.
    /// @dev Cancel by re-calling `approveEscrowVault(vault, true)` before execution.
    function scheduleEscrowVaultRevocation(address vault) external onlyAdmin {
        require(approvedEscrowVaults[vault], "Vault not approved");
        require(pendingVaultRevocationAt[vault] == 0, "Revocation already scheduled");
        pendingVaultRevocationAt[vault] = block.timestamp + ECONOMIC_PARAM_DELAY;
        emit EscrowVaultRevocationScheduled(vault, pendingVaultRevocationAt[vault]);
    }

    /// @notice [Apex H4] Execute a scheduled vault revocation after the timelock expires.
    /// @dev Permissionless post-timelock (same rationale as executeAgentRegistryUpdate);
    ///      admin can cancel instead. The 2-day window gives in-flight transactions and
    ///      watchers time to settle/react before the vault is frozen out.
    function executeEscrowVaultRevocation(address vault) external {
        uint256 executeAfter = pendingVaultRevocationAt[vault];
        require(executeAfter != 0, "No scheduled revocation");
        require(block.timestamp >= executeAfter, "Timelock not expired");
        delete pendingVaultRevocationAt[vault];
        approvedEscrowVaults[vault] = false;
        emit EscrowVaultApproved(vault, false);
    }

    /**
     * @notice Approve or revoke mediator with timelock protection
     * @dev [C-1 SECURITY FIX] Prevents timelock bypass via revoke-and-reapprove attack
     *      - If mediator was recently revoked, must wait MEDIATOR_APPROVAL_DELAY before re-approval
     *      - Only sets new timelock if mediator is NOT already approved
     *      - Tracks revocation timestamp to enforce cooling period
     * @param mediator Address of the mediator to approve/revoke
     * @param approved True to approve, false to revoke
     */
    function approveMediator(address mediator, bool approved) external onlyAdmin {
        require(mediator != address(0), "Zero mediator");

        if (approved) {
            // [C-1 FIX] Prevent bypass: if recently revoked, must wait MEDIATOR_APPROVAL_DELAY
            if (mediatorRevokedAt[mediator] > 0) {
                require(
                    block.timestamp >= mediatorRevokedAt[mediator] + MEDIATOR_APPROVAL_DELAY,
                    "Revoke-reapprove timelock"
                );
            }

            // Only set new timelock if not already approved (prevent timelock reset on existing mediators)
            if (!approvedMediators[mediator]) {
                mediatorApprovedAt[mediator] = block.timestamp + MEDIATOR_APPROVAL_DELAY;
            }
            approvedMediators[mediator] = true;
            delete mediatorRevokedAt[mediator];
        } else {
            approvedMediators[mediator] = false;
            mediatorRevokedAt[mediator] = block.timestamp; // Track revocation time
            delete mediatorApprovedAt[mediator];
        }

        emit MediatorApproved(mediator, approved);
    }

    function scheduleAgentRegistryUpdate(address newRegistry) external onlyAdmin {
        require(newRegistry != address(0), "Zero registry");
        require(!pendingRegistryUpdate.active, "Pending update - cancel first");

        pendingRegistryUpdate = PendingRegistryUpdate({
            newRegistry: newRegistry,
            executeAfter: block.timestamp + ECONOMIC_PARAM_DELAY, // 2-day delay
            active: true
        });

        emit AgentRegistryUpdateScheduled(newRegistry, pendingRegistryUpdate.executeAfter);
    }

    function cancelAgentRegistryUpdate() external onlyAdmin {
        require(pendingRegistryUpdate.active, "No pending update");
        address cancelledRegistry = pendingRegistryUpdate.newRegistry;
        delete pendingRegistryUpdate;
        emit AgentRegistryUpdateCancelled(cancelledRegistry, block.timestamp);
    }

    /// @notice Execute a scheduled agent registry update after timelock expires.
    /// @dev Intentionally callable by anyone post-timelock — permissionless execution
    /// prevents admin from holding back a scheduled update. Admin can cancel instead.
    function executeAgentRegistryUpdate() external {
        PendingRegistryUpdate memory pending = pendingRegistryUpdate;
        require(pending.active, "No pending update");
        require(block.timestamp >= pending.executeAfter, "Timelock not expired");

        address oldRegistry = address(agentRegistry);
        agentRegistry = IAgentRegistry(pending.newRegistry);
        delete pendingRegistryUpdate;

        emit AgentRegistryUpdated(oldRegistry, pending.newRegistry);
    }

    /// @notice Set the archive treasury address
    /// @param _archiveTreasury New archive treasury contract address
    function setArchiveTreasury(address _archiveTreasury) external onlyAdmin {
        require(_archiveTreasury != address(0), "Zero address");
        address oldTreasury = archiveTreasury;
        archiveTreasury = _archiveTreasury;
        emit ArchiveTreasuryUpdated(oldTreasury, _archiveTreasury);
    }

    function _setInitialAgentRegistry(address registry) internal {
        if (registry != address(0)) {
            agentRegistry = IAgentRegistry(registry);
        }
    }

    function scheduleEconomicParams(uint16 newPlatformFeeBps, uint16 newRequesterPenaltyBps) external override onlyAdmin {
        require(!pendingEconomicParams.active, "Pending update - cancel first");
        _validatePlatformFee(newPlatformFeeBps);
        _validateRequesterPenalty(newRequesterPenaltyBps);

        pendingEconomicParams = PendingEconomicParams({
            platformFeeBps: newPlatformFeeBps,
            requesterPenaltyBps: newRequesterPenaltyBps,
            executeAfter: block.timestamp + ECONOMIC_PARAM_DELAY,
            active: true
        });

        emit EconomicParamsUpdateScheduled(newPlatformFeeBps, newRequesterPenaltyBps, pendingEconomicParams.executeAfter);
    }

    function cancelEconomicParamsUpdate() external override onlyAdmin {
        require(pendingEconomicParams.active, "No pending");
        emit EconomicParamsUpdateCancelled(
            pendingEconomicParams.platformFeeBps,
            pendingEconomicParams.requesterPenaltyBps,
            block.timestamp
        );
        delete pendingEconomicParams;
    }

    /// @notice Execute a scheduled economic params update after timelock expires.
    /// @dev Intentionally callable by anyone post-timelock — permissionless execution
    /// prevents admin from holding back a scheduled update. Admin can cancel instead.
    function executeEconomicParamsUpdate() external override {
        PendingEconomicParams memory pending = pendingEconomicParams;
        require(pending.active, "No pending");
        // Economic changes require advance notice
        require(block.timestamp >= pending.executeAfter, "Too early");

        platformFeeBps = pending.platformFeeBps;
        requesterPenaltyBps = pending.requesterPenaltyBps;
        delete pendingEconomicParams;

        emit EconomicParamsUpdated(platformFeeBps, requesterPenaltyBps, block.timestamp);
    }

    function getPendingEconomicParams()
        external
        view
        override
        returns (uint16, uint16, uint256, bool)
    {
        PendingEconomicParams memory pending = pendingEconomicParams;
        return (pending.platformFeeBps, pending.requesterPenaltyBps, pending.executeAfter, pending.active);
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    function _getTransaction(bytes32 transactionId) internal view returns (Transaction storage) {
        require(transactions[transactionId].createdAt != 0, "Tx missing");
        return transactions[transactionId];
    }

    function _isValidTransition(State fromState, State toState) internal pure returns (bool) {
        if (fromState == State.INITIATED && toState == State.QUOTED) return true;
        // INITIATED/QUOTED → COMMITTED only allowed via linkEscrow() to ensure escrow is funded
        if (fromState == State.COMMITTED && toState == State.IN_PROGRESS) return true;
        if (fromState == State.IN_PROGRESS && toState == State.DELIVERED) return true;
        if (fromState == State.DELIVERED && (toState == State.SETTLED || toState == State.DISPUTED)) return true;
        // Note: DELIVERED → CANCELLED is intentionally omitted. Post-delivery cancellation
        // must go through DISPUTED → CANCELLED to ensure fair resolution with mediator involvement.
        if (fromState == State.DISPUTED && (toState == State.SETTLED || toState == State.CANCELLED)) return true;
        if (
            (fromState == State.INITIATED || fromState == State.QUOTED || fromState == State.COMMITTED
                || fromState == State.IN_PROGRESS) && toState == State.CANCELLED
        ) return true;
        return false;
    }

    /// @notice True if `sender` may resolve a DISPUTED transaction (DISPUTED → SETTLED/CANCELLED).
    /// @dev Resolver set = {admin} ∪ {approved mediators past their MEDIATOR_APPROVAL_DELAY timelock}.
    ///      Per decision G1 (DISPUTE SYSTEM/AIP14B-DECISIONS.md) the pauser is intentionally NOT a resolver.
    ///      Scope of the timelock (precise): `mediatorApprovedAt` only gates a *newly-added* mediator —
    ///      it is a 2-day window to detect/cancel a mistaken or rushed approval before that mediator can
    ///      resolve. It does NOT protect against a compromised admin/Safe: INV-6 deliberately keeps admin
    ///      able to resolve immediately, so admin-key risk is mitigated by key custody (Safe 2-of-3),
    ///      not by this timelock. The `approvedAt != 0` guard rejects any inconsistent
    ///      (approvedMediators == true, mediatorApprovedAt == 0) state from a storage/migration path.
    function _isApprovedResolver(address sender) internal view returns (bool) {
        uint256 approvedAt = mediatorApprovedAt[sender];
        return sender == admin
            || (approvedMediators[sender] && approvedAt != 0 && block.timestamp >= approvedAt);
    }

    function _enforceAuthorization(Transaction storage txn, State fromState, State toState) internal view {
        if (fromState == State.INITIATED && toState == State.QUOTED) {
            require(msg.sender == txn.provider, "Only provider");
        // Note: QUOTED → COMMITTED is handled by linkEscrow(), not transitionState()
        } else if (fromState == State.COMMITTED && toState == State.IN_PROGRESS) {
            require(msg.sender == txn.provider, "Only provider");
        } else if (fromState == State.IN_PROGRESS && toState == State.DELIVERED) {
            require(msg.sender == txn.provider, "Only provider");
        } else if (fromState == State.DELIVERED && toState == State.SETTLED) {
            // Permissionless auto-settle: after dispute window, anyone can settle
            // Before window: only requester/provider. Timing enforced in _enforceTiming.
            bool isParticipant = msg.sender == txn.requester || msg.sender == txn.provider;
            bool autoSettleEligible = block.timestamp > txn.disputeWindow;
            require(isParticipant || autoSettleEligible, "Not authorized to settle");
        } else if (fromState == State.DELIVERED && toState == State.DISPUTED) {
            require(msg.sender == txn.requester || msg.sender == txn.provider, "Party only");
        } else if (
            fromState == State.DISPUTED && (toState == State.SETTLED || toState == State.CANCELLED)
        ) {
            // AIP-14b P0-3: admin OR approved+timelocked mediator (e.g. CompositeMediator). G1: no pauser.
            require(_isApprovedResolver(msg.sender), "Resolver only");
        } else if (toState == State.CANCELLED) {
            // State-specific cancellation authorization
            if (fromState == State.INITIATED || fromState == State.QUOTED) {
                // Only requester can cancel before commitment
                require(msg.sender == txn.requester, "Only requester can cancel");
            } else if (fromState == State.COMMITTED || fromState == State.IN_PROGRESS) {
                // Both parties can cancel after commitment
                require(msg.sender == txn.requester || msg.sender == txn.provider, "Party only");
            }
        }
    }

    function _enforceTiming(Transaction storage txn, State fromState, State toState) internal view {
        // Enforce deadline for forward progressions (not cancellation, dispute, or settlement)
        // I-1 fix: DELIVERED → SETTLED is exempt from deadline — delivery is confirmed,
        // blocking settlement after deadline serves no purpose and forces unnecessary disputes.
        if (toState != State.CANCELLED && toState != State.DISPUTED && toState != State.SETTLED) {
            // F-6 Option A: the IN_PROGRESS→DELIVERED edge may land during the recovery grace window,
            // so an honest one-block-late provider is not robbed by recovery. All other forward
            // progressions stay strictly deadline-gated.
            if (fromState == State.IN_PROGRESS && toState == State.DELIVERED) {
                require(block.timestamp < txn.deadline + recoveryGrace, "Delivery grace expired"); // strict < : mutually exclusive with recovery's >=
            } else {
                require(block.timestamp <= txn.deadline, "Transaction expired");
            }
        }

        // [H-4 FIX] Prevent requester from canceling after work started (IN_PROGRESS state)
        if (fromState == State.IN_PROGRESS && toState == State.CANCELLED) {
            require(msg.sender != txn.requester, "No cancel after work started");
        }

        if (fromState == State.COMMITTED && toState == State.CANCELLED) {
            // Provider can cancel anytime (voluntary refund), requester must wait for deadline
            if (msg.sender == txn.requester) {
                require(block.timestamp >= txn.deadline, "Deadline not reached");
            }
            // Provider (msg.sender == txn.provider) can cancel immediately without penalty
        }
        if (fromState == State.DELIVERED && toState == State.DISPUTED) {
            require(block.timestamp <= txn.disputeWindow, "Dispute window closed");
        }
        if (
            fromState == State.DELIVERED && toState == State.SETTLED && msg.sender != txn.requester
        ) {
            require(block.timestamp > txn.disputeWindow, "Requester decision pending");
        }
    }

    /// @dev AIP-14c (D1): decode + validate the DELIVERED-transition proof. MUST be exactly 64 bytes,
    ///      `abi.encode(uint256 window, bytes32 resultHash)`, with an explicit bounded non-zero `window`
    ///      (`window == 0` forbidden — NOT a default sentinel) and a non-zero `resultHash`. Legacy
    ///      empty/32-byte proofs are rejected. `resultHash` is the on-chain commitment of the delivered
    ///      result (public plaintext hash or encrypted-envelope hash — see AIP-14c §2 D2).
    function _decodeDeliveryProof(bytes calldata proof)
        internal
        pure
        returns (uint256 window, bytes32 resultHash)
    {
        require(proof.length == 64, "Delivery proof must be (window,resultHash)");
        (window, resultHash) = abi.decode(proof, (uint256, bytes32));
        require(window >= MIN_DISPUTE_WINDOW, "Dispute window too short");
        require(window <= MAX_DISPUTE_WINDOW, "Dispute window too long");
        require(resultHash != bytes32(0), "resultHash required");
    }

    function _decodeResolutionProof(bytes calldata proof)
        internal
        pure
        returns (
            uint256 requesterAmount,
            uint256 providerAmount,
            address mediator,
            uint256 mediatorAmount,
            bool hasResolution,
            bool providerAtFault
        )
    {
        if (proof.length == 0) {
            return (0, 0, address(0), 0, false, false);
        }
        if (proof.length == 64) {
            // Legacy: no mediator, assume provider at fault (conservative)
            (requesterAmount, providerAmount) = abi.decode(proof, (uint256, uint256));
            require(requesterAmount > 0 || providerAmount > 0, "Empty resolution");
            return (requesterAmount, providerAmount, address(0), 0, true, true);
        }
        if (proof.length == 96) {
            // AIP-14: no mediator, explicit fault determination
            (requesterAmount, providerAmount, providerAtFault) =
                abi.decode(proof, (uint256, uint256, bool));
            require(requesterAmount > 0 || providerAmount > 0, "Empty resolution");
            return (requesterAmount, providerAmount, address(0), 0, true, providerAtFault);
        }
        if (proof.length == 128) {
            // Legacy: with mediator, assume provider at fault (conservative)
            (requesterAmount, providerAmount, mediator, mediatorAmount) =
                abi.decode(proof, (uint256, uint256, address, uint256));
            require(requesterAmount > 0 || providerAmount > 0 || mediatorAmount > 0, "Empty resolution");
            require(mediatorAmount == 0 || mediator != address(0), "Mediator address required");
            return (requesterAmount, providerAmount, mediator, mediatorAmount, true, true);
        }
        // AIP-14: with mediator, explicit fault determination
        require(proof.length == 160, "Invalid resolution proof");
        (requesterAmount, providerAmount, mediator, mediatorAmount, providerAtFault) =
            abi.decode(proof, (uint256, uint256, address, uint256, bool));
        require(requesterAmount > 0 || providerAmount > 0 || mediatorAmount > 0, "Empty resolution");
        require(mediatorAmount == 0 || mediator != address(0), "Mediator address required");
        return (requesterAmount, providerAmount, mediator, mediatorAmount, true, providerAtFault);
    }

    /**
     * @notice Release escrow to provider after successful delivery
     * @dev [C-2 SECURITY FIX] Prevents reputation double-counting if AgentRegistry is upgraded
     *      - Only updates reputation if current registry hasn't processed this transaction yet
     *      - Tracks which registry version processed the update (prevents replay across registry upgrades)
     */
    function _releaseEscrow(Transaction storage txn) internal {
        require(txn.escrowContract != address(0), "Escrow missing");
        IEscrowValidator vault = IEscrowValidator(txn.escrowContract);
        uint256 remaining = vault.remaining(txn.escrowId);

        // [C-2 FIX] Update reputation only if not yet processed by current registry (prevents double-counting on registry upgrade)
        if (address(agentRegistry) != address(0) && reputationProcessedBy[txn.transactionId] == address(0)) {
            reputationProcessedBy[txn.transactionId] = address(agentRegistry);
            try agentRegistry.updateReputationOnSettlement{gas: 150000}(
                txn.provider,
                txn.transactionId,
                txn.amount,
                txn.wasDisputed
            ) {} catch {}
        }

        // If milestones already released all funds, settlement still succeeds
        // (reputation was updated above, state transition was already validated).
        if (remaining > 0) {
            _payoutProviderAmount(txn, vault, remaining);
        }
    }

    /**
     * @notice Handle dispute settlement with custom resolution
     * @dev [C-2 SECURITY FIX] Prevents reputation double-counting if AgentRegistry is upgraded
     */
    function _handleDisputeSettlement(Transaction storage txn, bytes calldata proof) internal {
        if (txn.escrowContract == address(0)) return;
        IEscrowValidator vault = IEscrowValidator(txn.escrowContract);
        uint256 remaining = vault.remaining(txn.escrowId);

        (uint256 requesterAmount, uint256 providerAmount, address mediator, uint256 mediatorAmount, bool hasResolution, bool providerAtFault) =
            _decodeResolutionProof(proof);

        // [M-2 AUDIT FIX] Require explicit resolution proof for dispute settlement.
        // Previously, empty proof defaulted to full payout to provider — this allowed
        // a compromised admin to resolve disputes without evidence. Now reverts.
        // Must be checked BEFORE any state changes (CEI pattern).
        require(hasResolution, "Explicit resolution required");

        // [C-2 FIX] Update reputation only if not yet processed by current registry (prevents double-counting on registry upgrade)
        // AIP-14: Pass providerAtFault instead of txn.wasDisputed — only at-fault disputes affect reputation
        if (address(agentRegistry) != address(0) && reputationProcessedBy[txn.transactionId] == address(0)) {
            reputationProcessedBy[txn.transactionId] = address(agentRegistry);
            try agentRegistry.updateReputationOnSettlement{gas: 150000}(
                txn.provider,
                txn.transactionId,
                txn.amount,
                providerAtFault
            ) {} catch {}
        }

        if (mediator != address(0)) {
            require(approvedMediators[mediator], "Mediator not approved");
            require(block.timestamp >= mediatorApprovedAt[mediator], "Mediator approval pending");
        }

        if (remaining > 0) {
            uint256 totalDistributed = requesterAmount + providerAmount + mediatorAmount;
            require(totalDistributed > 0, "Empty resolution not allowed");
            require(totalDistributed == remaining, "Must distribute ALL funds");

            if (providerAmount > 0) {
                _payoutProviderAmount(txn, vault, providerAmount);
            }
            if (requesterAmount > 0) {
                _refundRequester(txn, vault, requesterAmount);
            }
            if (mediatorAmount > 0) {
                _payoutMediator(txn, vault, mediator, mediatorAmount);
            }
        }

        // AIP-14: Bond distribution after escrow split (runs even if remaining was 0)
        _distributeBond(txn, vault, providerAtFault);
    }

    function _handleCancellation(
        Transaction storage txn,
        State oldState,
        bytes calldata proof,
        address triggeredBy
    ) internal {
        if (txn.escrowContract == address(0)) return;
        IEscrowValidator vault = IEscrowValidator(txn.escrowContract);
        uint256 remaining = vault.remaining(txn.escrowId);

        (uint256 requesterAmount, uint256 providerAmount, address mediator, uint256 mediatorAmount, bool hasResolution,) =
            _decodeResolutionProof(proof);
        if (oldState == State.DISPUTED && hasResolution) {
            // AIP-14b P0-3: admin OR approved+timelocked mediator. NOTE on symmetry: _enforceAuthorization
            // (site 1) already gates BOTH SETTLED and CANCELLED; this site 2 is the additional CANCELLED-path
            // check inside _handleCancellation. Both must allow the mediator or the CANCELLED/split path breaks. G1: no pauser.
            require(_isApprovedResolver(triggeredBy), "Resolver only");

            // NOTE: the `mediator` below is a DIFFERENT concept — a PAID mediator decoded from the
            // resolution proof (receives `mediatorAmount`), not the caller-authorization above.
            if (mediator != address(0)) {
                require(approvedMediators[mediator], "Mediator not approved");
                require(block.timestamp >= mediatorApprovedAt[mediator], "Mediator approval pending");
            }

            if (remaining > 0) {
                uint256 totalDistributed = requesterAmount + providerAmount + mediatorAmount;
                require(totalDistributed > 0, "Empty resolution not allowed");
                require(totalDistributed == remaining, "Must distribute ALL funds");
                require(totalDistributed <= txn.amount, "Resolution exceeds amount");

                if (providerAmount > 0) {
                    _payoutProviderAmount(txn, vault, providerAmount);
                }
                if (requesterAmount > 0) {
                    _refundRequester(txn, vault, requesterAmount);
                }
                if (mediatorAmount > 0) {
                    _payoutMediator(txn, vault, mediator, mediatorAmount);
                }
            }

            // AIP-14: Return bond to disputer on cancellation (no fault determined)
            _distributeBondOnCancellation(txn, vault);
            return;
        }

        // AIP-14: Return bond on non-resolution DISPUTED→CANCELLED
        if (oldState == State.DISPUTED) {
            // [Apex 2026-07-12 F-II] M-2 proof symmetry now also guards the CANCELLED path: on a
            // v2 kernel every DISPUTED transaction passed DELIVERED (resultHash committed), so an
            // EMPTY-proof dismissal falling through to a FULL requester refund would let a resolver
            // silently zero out a provider whose delivery is anchored on-chain. A full-refund
            // dismissal stays possible — but only via an EXPLICIT (remaining, 0) resolution proof,
            // which keeps the distribution auditable. (Pre-delivery disputes cannot exist on v2:
            // DELIVERED is the only edge into DISPUTED.)
            require(hasResolution || txn.resultHash == bytes32(0), "Explicit resolution required");
            _distributeBondOnCancellation(txn, vault);
        }

        if (remaining == 0) return;

        if (triggeredBy == txn.requester && (oldState == State.COMMITTED || oldState == State.IN_PROGRESS)) {
            uint256 penalty = (remaining * txn.requesterPenaltyBpsLocked) / MAX_BPS;
            uint256 refund = remaining - penalty;
            _refundRequester(txn, vault, refund);
            if (penalty > 0) {
                _payoutProviderAmount(txn, vault, penalty);
            }
            return;
        }

        // Provider cancellation from COMMITTED or IN_PROGRESS: full refund to requester.
        // Provider's penalty is implicit — they forfeit any work effort and earn nothing.
        _refundRequester(txn, vault, remaining);
    }

    function _payoutProviderAmount(
        Transaction storage txn,
        IEscrowValidator vault,
        uint256 grossAmount
    ) internal {
        require(grossAmount > 0, "Amount zero");
        require(approvedEscrowVaults[address(vault)], "Vault not approved");

        uint256 available = vault.remaining(txn.escrowId);
        require(available >= grossAmount, "Insufficient escrow balance");

        uint256 fee = _calculateFee(grossAmount, txn.platformFeeBpsLocked);
        // [F-1 AUDIT FIX] Solvency invariant: _calculateFee now clamps the MIN_FEE floor to gross,
        // so this never reverts on a tiny payout (it used to brick dispute finalization). Kept as a
        // defense-in-depth assertion guaranteeing providerNet + fee == grossAmount.
        require(fee <= grossAmount, "Fee exceeds amount");
        uint256 providerNet = grossAmount - fee;

        if (providerNet > 0) {
            uint256 actualPayout = vault.payoutToProvider(txn.escrowId, providerNet);
            require(actualPayout == providerNet, "Partial payout not allowed");
            emit EscrowReleased(txn.transactionId, txn.provider, actualPayout, block.timestamp);
        }
        if (fee > 0) {
            _distributeFee(txn, vault, fee);
        }
    }

    /// @notice Event emitted when archive treasury fee distribution fails
    event ArchiveTreasuryFailed(bytes32 indexed transactionId, uint256 amount, bytes reason);

    /// @notice Event emitted when vault payout returns unexpected amount (forensic tracing)
    event ArchivePayoutMismatch(bytes32 indexed transactionId, uint256 expected, uint256 actual);

    /**
     * @notice Distribute platform fees between archive treasury and fee recipient
     * @dev [H-1 SECURITY FIX] Wraps ALL vault transfers in try-catch to prevent fund loss
     *      - If treasury transfer fails, funds are redirected to feeRecipient
     *      - Clears dangling approvals before fallback transfer
     *      - Emits forensic events for all failure scenarios
     */
    function _distributeFee(Transaction storage txn, IEscrowValidator vault, uint256 totalFee) internal {
        // Split fee: 0.1% to archive treasury, 99.9% to fee recipient
        uint256 archiveFee;
        // [AIP-14c] Amount of the archive portion ACTUALLY removed from escrow. Used below to size the
        // remaining treasury fee so the archive slice is never double-counted — previously, when
        // receiveFunds failed, the fee was redirected out of escrow AND still subtracted as if it stayed,
        // stranding ~archiveFee in the terminal escrow (recoverable by the provider via releaseEscrow).
        uint256 escrowedArchive;
        if (archiveTreasury != address(0)) {
            archiveFee = (totalFee * ARCHIVE_ALLOCATION_BPS) / MAX_BPS;
            if (archiveFee > 0) {
                // Payout archive fee to kernel first, then forward to treasury
                // [H-1 FIX] Wrap outer vault.payout in try-catch to prevent entire settlement failure
                try vault.payout(txn.escrowId, address(this), archiveFee) returns (uint256 payoutResult) {
                    if (payoutResult == archiveFee) {
                        // archiveFee has LEFT the escrow (paid to the kernel); account it here regardless
                        // of whether receiveFunds succeeds or we redirect it to feeRecipient below.
                        escrowedArchive = archiveFee;
                        USDC.forceApprove(archiveTreasury, archiveFee);
                        try IArchiveTreasury(archiveTreasury).receiveFunds(archiveFee) {
                            // Delivered to the archive treasury. [Apex 2026-07-12 F-C] Clear the
                            // allowance even on success: a non-canonical treasury that RETURNS
                            // without pulling must not leave a live approval dangling over
                            // kernel-held USDC (the canonical ArchiveTreasury consumes it fully).
                            USDC.forceApprove(archiveTreasury, 0);
                        } catch (bytes memory reason) {
                            // Archive treasury failed - redirect to fee recipient
                            emit ArchiveTreasuryFailed(txn.transactionId, archiveFee, reason);
                            // [H-1 FIX] Clear dangling approval before redirecting to fee recipient
                            USDC.forceApprove(archiveTreasury, 0);
                            // [H-1 FIX] Wrap fallback transfer in try-catch to prevent total failure
                            try USDC.transfer(feeRecipient, archiveFee) returns (bool success) {
                                require(success, "Fallback transfer failed");
                            } catch {
                                // Emergency: Both archive treasury AND fee recipient failed
                                // Funds remain in kernel - emit emergency event for manual recovery
                                emit ArchivePayoutMismatch(txn.transactionId, archiveFee, 0);
                            }
                        }
                    } else {
                        // [AUDIT FIX] Emit event for forensic tracing when vault payout fails
                        emit ArchivePayoutMismatch(txn.transactionId, archiveFee, payoutResult);
                        // Redirect any partial payout to feeRecipient (don't leave stuck in escrow)
                        if (payoutResult > 0) {
                            USDC.safeTransfer(feeRecipient, payoutResult);
                            escrowedArchive = payoutResult; // this much already left the escrow
                        }
                        archiveFee = 0;
                    }
                } catch (bytes memory reason) {
                    // [H-1 FIX] Outer vault.payout failed - emit event and redirect to main fee recipient
                    emit ArchiveTreasuryFailed(txn.transactionId, archiveFee, reason);
                    archiveFee = 0;
                }
            }
        }
        // [AIP-14c fix] Subtract only what the archive path ACTUALLY removed from escrow (never the
        // nominal archiveFee when it stayed in escrow), so the remaining fee empties the escrow exactly.
        uint256 treasuryFee = totalFee - escrowedArchive;
        if (treasuryFee > 0) {
            // [AUDIT FIX] Wrap in try-catch to prevent a misconfigured feeRecipient
            // from DOSing all settlements. On failure, fee stays in vault (recoverable).
            try vault.payout(txn.escrowId, feeRecipient, treasuryFee) returns (uint256 feeResult) {
                require(feeResult == treasuryFee, "Partial fee");
                emit PlatformFeeAccrued(txn.transactionId, feeRecipient, treasuryFee, block.timestamp);
            } catch {
                // [Apex 2026-07-12 F-IV] Fee remains in the escrow vault for this escrowId. There is
                // NO in-contract retry on a terminal transaction — recovery is operational: rotate
                // `feeRecipient` for FUTURE settlements; this txn's stranded fee is surfaced via
                // ArchivePayoutMismatch for accounting. Only platform fee is affected, never principal.
                emit ArchivePayoutMismatch(txn.transactionId, treasuryFee, 0);
            }
        }
    }

    function _refundRequester(Transaction storage txn, IEscrowValidator vault, uint256 amount) internal {
        require(amount > 0, "Refund amount zero");
        require(approvedEscrowVaults[address(vault)], "Vault not approved");
        uint256 actualRefund = vault.refundToRequester(txn.escrowId, amount);
        require(actualRefund == amount, "Partial refund not allowed");
        emit EscrowRefunded(txn.transactionId, txn.requester, actualRefund, block.timestamp);
    }

    function _payoutMediator(Transaction storage txn, IEscrowValidator vault, address mediator, uint256 amount) internal {
        require(mediator != address(0), "Mediator zero");
        require(approvedMediators[mediator], "Mediator not approved");
        require(block.timestamp >= mediatorApprovedAt[mediator], "Mediator approval pending");
        require(amount > 0, "Mediator amount zero");
        require(approvedEscrowVaults[address(vault)], "Vault not approved");

        uint256 maxMediatorFee = (txn.amount * MAX_MEDIATOR_FEE_BPS) / MAX_BPS;
        require(amount <= maxMediatorFee, "Mediator fee exceeds maximum");

        uint256 actualPayout = vault.payout(txn.escrowId, mediator, amount);
        require(actualPayout == amount, "Partial mediator payout");
        emit EscrowMediatorPaid(txn.transactionId, mediator, actualPayout, block.timestamp);
    }

    // AIP-14: Bond distribution helpers

    function _distributeBond(Transaction storage txn, IEscrowValidator vault, bool providerAtFault) internal {
        if (txn.disputeBond == 0) return;

        // Bond goes to the winning party, regardless of who initiated the dispute
        address bondRecipient = providerAtFault ? txn.requester : txn.provider;
        uint256 bondAmount = txn.disputeBond;
        txn.disputeBond = 0; // [CEI FIX] Zero before external call to prevent double distribution
        vault.releaseBond(txn.escrowId, bondRecipient, bondAmount);

        emit DisputeResolved(
            txn.transactionId,
            bytes32(0),
            txn.disputeInitiator,
            providerAtFault,
            bondAmount,
            block.timestamp
        );
    }

    function _distributeBondOnCancellation(Transaction storage txn, IEscrowValidator vault) internal {
        if (txn.disputeBond == 0) return;

        uint256 bondAmount = txn.disputeBond;
        txn.disputeBond = 0; // Defense-in-depth: prevent double distribution

        // Cancellation: bond always returned to disputer (no fault determined)
        vault.releaseBond(txn.escrowId, txn.disputeInitiator, bondAmount);

        emit DisputeResolved(
            txn.transactionId,
            bytes32(0),
            txn.disputeInitiator,
            false,
            bondAmount,
            block.timestamp
        );
    }

    // AIP-14: Admin setter for dispute bond percentage

    function updateDisputeBondBps(uint16 newBps) external onlyAdmin {
        require(newBps <= MAX_DISPUTE_BOND_BPS, "Exceeds max bond cap");
        // [Apex 2026-07-12 F-III] Observability: emit the change. No timelock needed — INV-30
        // locks the rate per-transaction at creation (disputeBondBpsLocked), so a live update
        // never touches in-flight transactions and is capped by MAX_DISPUTE_BOND_BPS.
        emit DisputeBondBpsUpdated(disputeBondBps, newBps);
        disputeBondBps = newBps;
    }

    /**
     * @notice Calculate platform fee using locked fee percentage from transaction creation
     * @dev AIP-5: Uses locked fee % to guarantee 1% fee commitment.
     *      [F-1 AUDIT FIX] The MIN_FEE floor ($0.05) can exceed `grossAmount` on a tiny payout
     *      (e.g. a dust split share `remaining * splitBps / 10000` landing in (0, MIN_FEE), or a
     *      milestone-drained escrow whose remaining tail is sub-$0.05). Before this clamp, the
     *      downstream `require(fee <= grossAmount)` in `_payoutProviderAmount` reverted, rolling
     *      back the whole DISPUTED→SETTLED/CANCELLED transition and BRICKING dispute finalization
     *      (incl. the permissionless `forceResolveStale` walk-away) for up to 30 days. We clamp the
     *      floored fee to `grossAmount`: on a sub-MIN_FEE gross the provider nets 0 and the fee
     *      simply absorbs the dust. Solvency is preserved — `fee <= grossAmount` always, so
     *      `providerNet + fee == grossAmount` exactly and `totalDistributed == remaining` still holds.
     *      This is the single fee-charging chokepoint (only caller: `_payoutProviderAmount`), so the
     *      clamp covers BOTH the split provider-amount path and the normal `_releaseEscrow` tiny-tail path.
     * @param grossAmount Amount before fee deduction
     * @param lockedFeeBps Locked platform fee basis points from transaction creation
     */
    function _calculateFee(uint256 grossAmount, uint16 lockedFeeBps) internal pure returns (uint256) {
        uint256 bpsFee = (grossAmount * lockedFeeBps) / MAX_BPS;
        uint256 fee = bpsFee > MIN_FEE ? bpsFee : MIN_FEE;
        // [F-1 AUDIT FIX] Clamp the floored fee to gross so a sub-MIN_FEE payout cannot revert.
        if (fee > grossAmount) fee = grossAmount;
        return fee;
    }

    function _validatePlatformFee(uint16 newFee) internal pure {
        require(newFee > 0, "Fee cannot be zero");
        require(newFee <= MAX_PLATFORM_FEE_CAP, "Fee cap");
    }

    function _validateRequesterPenalty(uint16 newPenalty) internal pure {
        require(newPenalty <= MAX_REQUESTER_PENALTY_CAP, "Penalty cap");
    }

    /**
     * @dev [H-3 SECURITY FIX] INTENTIONALLY DISABLED - Never clear usedEscrowIds to prevent ID reuse
     *
     *      RATIONALE:
     *      - Previously, escrow IDs were cleared immediately on settlement, allowing potential reuse
     *      - This created a race condition where same escrow ID could be used for multiple transactions
     *      - Security-first approach: Keep permanent record of ALL escrow IDs ever used
     *
     *      IMPLICATIONS:
     *      - Each escrow ID can only be used ONCE across entire contract lifetime
     *      - Escrow vaults must generate unique IDs for each transaction (recommended: keccak256(requester, provider, nonce, timestamp))
     *      - No storage cleanup = slightly higher gas over time (but negligible, boolean mapping)
     *
     *      ALTERNATIVE (if needed): Add time-based expiration (e.g., allow reuse after 1 year)
     *      But current approach is safest - storage is cheap on L2, security is priceless
     */
    function _clearUsedEscrowId(Transaction storage txn) internal {
        // [H-3 FIX] INTENTIONALLY DISABLED - Never clear usedEscrowIds to prevent race condition
        // Previously: delete usedEscrowIds[txn.escrowContract][txn.escrowId];
        // Now: Keep permanent record to prevent ID reuse attacks

        // NOTE: This function is now a no-op but kept for backwards compatibility
        // Do not re-enable clearing without comprehensive security review
    }
}
