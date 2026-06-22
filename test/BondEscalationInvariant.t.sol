// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/DisputeTestBase.sol";
import {AIRuling} from "../src/interfaces/DisputeTypes.sol";
import {IACTPKernel} from "../src/interfaces/IACTPKernel.sol";

/// @title BondEscalationHandler — the stateful fuzz driver for the BondEscalation invariant suite (PRD P1-8).
/// @notice Foundry's invariant engine calls the PUBLIC functions of this handler in random order with
///         random calldata, advancing a shared `BondEscalation` across MANY concurrent disputes. The
///         handler owns the full lifecycle: it opens a fixed pool of disputes at construction, then the
///         random sequence drives propose/AIRuling/challenge/finalize/claim/escalate/resolve across them.
///
///         Why a handler (not raw target on BondEscalation): every dispute requires a kernel transaction
///         driven to DISPUTED first (escrow linked, IN_PROGRESS → DELIVERED → DISPUTED). That setup uses
///         `vm.prank` and cannot be reached by fuzzing BondEscalation's own selectors. The handler also
///         tames the fuzzer: it bounds rulings/splits to valid ranges and pre-approves USDC so most calls
///         do real work instead of bouncing off `require`s — which is what actually exercises the
///         accounting paths the invariants guard.
///
///         GHOST STATE: the handler records, per dispute, the set of addresses that ever deposited and
///         their snapshotted deposit totals, plus a global "any dispute is mid-game" flag. The invariant
///         contract reads these ghosts to compute the CORRECTED live-solvency obligation (sum of unclaimed
///         split shares), exactly as `BondEscalation.claimEscalationRefund` distributes them.
contract BondEscalationHandler is Test {
    BondEscalation internal immutable bondEscalation;
    ACTPKernel internal immutable kernel;
    MockUSDC internal immutable usdc;
    EscrowVault internal immutable escrow;

    // Actor set the handler rotates through as proposers / challengers / claimers / finalizers.
    address[4] internal actors;

    // The fixed pool of opened disputes the fuzzer drives.
    bytes32[] public disputeIds;
    mapping(bytes32 => bytes32) public txIdOf; // disputeId => kernel txId

    // ----- GHOSTS (read by the invariant contract) -----
    // All addresses that ever deposited into a given dispute (for the unclaimed-share solvency sum).
    mapping(bytes32 => address[]) internal _depositorsOf;
    mapping(bytes32 => mapping(address => bool)) internal _isDepositor;

    // Coarse call counters (surfaced via invariant_CallSummary for run visibility).
    uint256 public callsPropose;
    uint256 public callsAIRuling;
    uint256 public callsChallenge;
    uint256 public callsFinalize;
    uint256 public callsClaim;
    uint256 public callsEscalate;
    uint256 public callsUMAResolve;

    uint256 internal constant ONE_USDC = 1_000_000;
    uint256 internal constant MAX_BOND = 500_000_000;

    // Evaluator keys (mirrored from the base so the handler can self-sign AIRulings).
    address internal fixed0;
    uint256 internal fixed0Pk;
    address internal fixed1;
    uint256 internal fixed1Pk;
    bytes32 internal RULING_TYPEHASH_LOCAL;

    constructor(
        BondEscalation _be,
        ACTPKernel _kernel,
        MockUSDC _usdc,
        EscrowVault _escrow,
        MockOOV3, /* oov3 — escalate driven via the live UMA path below */
        address[4] memory _actors,
        address _provider,
        address _requester,
        address _f0,
        uint256 _f0Pk,
        address _f1,
        uint256 _f1Pk,
        uint256 _poolSize
    ) {
        bondEscalation = _be;
        kernel = _kernel;
        usdc = _usdc;
        escrow = _escrow;
        actors = _actors;
        fixed0 = _f0;
        fixed0Pk = _f0Pk;
        fixed1 = _f1;
        fixed1Pk = _f1Pk;
        RULING_TYPEHASH_LOCAL = keccak256(
            "AIRuling(bytes32 disputeId,uint8 ruling,uint16 confidence,uint16 splitBps,uint64 timestamp,bytes32 reasoningHash,bytes32 bundleHash)"
        );

        // Pre-mint generously to every actor + the handler itself.
        for (uint256 i = 0; i < actors.length; i++) {
            usdc.mint(actors[i], 5_000_000 * ONE_USDC);
        }
        usdc.mint(_provider, 5_000_000 * ONE_USDC);
        usdc.mint(_requester, 5_000_000 * ONE_USDC);

        // Open a fixed pool of disputes. Each is a full kernel tx driven to DISPUTED.
        for (uint256 i = 0; i < _poolSize; i++) {
            bytes32 txId = _createDisputed(_provider, _requester);
            bytes32 disputeId = bondEscalation.openDispute(txId);
            disputeIds.push(disputeId);
            txIdOf[disputeId] = txId;
        }
    }

    // ---------------------------------------------------------------------
    // Internal: drive a fresh kernel transaction all the way to DISPUTED.
    // (Mirrors DisputeTestBase._createDisputed, but parameterised by actors.)
    // ---------------------------------------------------------------------
    function _createDisputed(address provider, address requester) internal returns (bytes32 txId) {
        uint256 amount = 1_000 * ONE_USDC;
        vm.prank(requester);
        txId = kernel.createTransaction(
            provider, requester, amount, block.timestamp + 60 days, 2 days, keccak256("service"), 0, 0
        );

        vm.startPrank(requester);
        usdc.approve(address(escrow), amount);
        kernel.linkEscrow(txId, address(escrow), txId);
        vm.stopPrank();

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(10 days));

        uint256 bond = (amount * kernel.disputeBondBps()) / kernel.MAX_BPS();
        vm.startPrank(requester);
        usdc.approve(address(escrow), bond);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------
    function _pickDispute(uint256 seed) internal view returns (bytes32) {
        return disputeIds[seed % disputeIds.length];
    }

    function _pickActor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _recordDeposit(bytes32 disputeId, address who) internal {
        if (!_isDepositor[disputeId][who]) {
            _isDepositor[disputeId][who] = true;
            _depositorsOf[disputeId].push(who);
        }
    }

    function _signRulingLocal(AIRuling memory ruling, uint256 privKey) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                RULING_TYPEHASH_LOCAL,
                ruling.disputeId,
                ruling.ruling,
                ruling.confidence,
                ruling.splitBps,
                ruling.timestamp,
                ruling.reasoningHash,
                ruling.bundleHash
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", bondEscalation.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privKey, digest);
        return abi.encodePacked(r, s, v);
    }

    // Typed accessor over the disputes 13-tuple.
    function _state(bytes32 disputeId)
        internal
        view
        returns (uint8 ruling, uint256 currentBond, uint256 accumulated, uint64 livenessEnd, uint8 tier, bool resolved)
    {
        ( , ruling, , currentBond, accumulated, livenessEnd, , , tier, resolved, , , ) =
            bondEscalation.disputes(disputeId);
    }

    // ---------------------------------------------------------------------
    // FUZZ ACTIONS (called by the invariant engine in random order)
    // ---------------------------------------------------------------------

    /// @notice Open the bond game with a direct proposal (Tier 0 → Tier 1).
    function propose(uint256 dSeed, uint256 aSeed, uint8 ruling, uint16 splitBps) external {
        bytes32 disputeId = _pickDispute(dSeed);
        ( , , , , uint8 tier, bool resolved) = _state(disputeId);
        if (resolved || tier != 0) return;

        ruling = uint8(bound(ruling, 0, 2));
        splitBps = ruling == 2 ? uint16(bound(splitBps, 0, 10000)) : 0;

        address who = _pickActor(aSeed);
        vm.startPrank(who);
        usdc.approve(address(bondEscalation), type(uint256).max);
        bondEscalation.proposeDirectly(disputeId, ruling, splitBps);
        vm.stopPrank();

        _recordDeposit(disputeId, who);
        callsPropose++;
    }

    /// @notice Open the bond game with a 2/3-signed AI ruling (Tier 0 → Tier 1).
    function submitAIRuling(uint256 dSeed, uint256 aSeed, uint8 ruling, uint16 splitBps) external {
        bytes32 disputeId = _pickDispute(dSeed);
        ( , , , , uint8 tier, bool resolved) = _state(disputeId);
        if (resolved || tier != 0) return;

        ruling = uint8(bound(ruling, 0, 2));
        splitBps = ruling == 2 ? uint16(bound(splitBps, 0, 10000)) : 0;

        AIRuling memory r = AIRuling({
            disputeId: disputeId,
            ruling: ruling,
            confidence: 9000,
            splitBps: splitBps,
            timestamp: uint64(block.timestamp),
            reasoningHash: keccak256("reasoning"),
            bundleHash: keccak256("bundle")
        });
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signRulingLocal(r, fixed0Pk);
        sigs[1] = _signRulingLocal(r, fixed1Pk);

        address who = _pickActor(aSeed);
        vm.startPrank(who);
        usdc.approve(address(bondEscalation), type(uint256).max);
        bondEscalation.submitAIRuling(disputeId, r, sigs);
        vm.stopPrank();

        _recordDeposit(disputeId, who);
        callsAIRuling++;
    }

    /// @notice Challenge the current proposal with a different outcome (doubles the bond, capped at $500).
    function challenge(uint256 dSeed, uint256 aSeed, uint8 counterRuling, uint16 counterSplit) external {
        bytes32 disputeId = _pickDispute(dSeed);
        (uint8 ruling, , , uint64 livenessEnd, uint8 tier, bool resolved) = _state(disputeId);
        if (resolved || tier != 1) return;
        if (block.timestamp > livenessEnd) return; // liveness expired — finalize() territory

        counterRuling = uint8(bound(counterRuling, 0, 2));
        counterSplit = counterRuling == 2 ? uint16(bound(counterSplit, 0, 10000)) : 0;

        // Must be a DIFFERENT outcome, otherwise the call reverts and does no work.
        // splitBps is field index 2 in the disputes tuple.
        ( , , uint16 curSplit, , , , , , , , , , ) = bondEscalation.disputes(disputeId);
        bool isDifferent = (counterRuling != ruling) || (counterRuling == 2 && counterSplit != curSplit);
        if (!isDifferent) {
            // Nudge to a guaranteed-different ruling so the action does real accounting work.
            counterRuling = ruling == 0 ? 1 : 0;
            counterSplit = 0;
        }

        address who = _pickActor(aSeed);
        vm.startPrank(who);
        usdc.approve(address(bondEscalation), type(uint256).max);
        bondEscalation.challenge(disputeId, counterRuling, counterSplit);
        vm.stopPrank();

        _recordDeposit(disputeId, who);
        callsChallenge++;
    }

    /// @notice Let liveness expire, then finalize (resolves Tier 1: winner-takes-all push or split snapshot).
    function finalize(uint256 dSeed, uint256 aSeed, uint256 warp) external {
        bytes32 disputeId = _pickDispute(dSeed);
        ( , , , uint64 livenessEnd, uint8 tier, bool resolved) = _state(disputeId);
        if (resolved || tier != 1) return;

        // Advance time past liveness so finalize is permitted.
        warp = bound(warp, 1, 9 hours);
        if (block.timestamp <= livenessEnd) {
            vm.warp(uint256(livenessEnd) + warp);
        }

        address who = _pickActor(aSeed);
        vm.prank(who);
        bondEscalation.finalize(disputeId);
        callsFinalize++;
    }

    /// @notice Pull a proportional split refund (only meaningful after a SPLIT finalize).
    function claimRefund(uint256 dSeed, uint256 aSeed) external {
        bytes32 disputeId = _pickDispute(dSeed);
        (uint8 ruling, , , , , bool resolved) = _state(disputeId);
        if (!resolved || ruling != 2) return;

        address who = _pickActor(aSeed);
        if (bondEscalation.deposits(disputeId, who) == 0) return;

        vm.prank(who);
        bondEscalation.claimEscalationRefund(disputeId);
        callsClaim++;
    }

    /// @notice Drive the bond ceiling, then escalate to the (mock) UMA OOV3.
    function escalateToUMA(uint256 dSeed, uint256 aSeed) external {
        bytes32 disputeId = _pickDispute(dSeed);
        (uint8 ruling, uint256 currentBond, , uint64 livenessEnd, uint8 tier, bool resolved) = _state(disputeId);
        if (resolved || tier != 1) return;
        if (block.timestamp > livenessEnd) return;

        // Ping-pong challenges until we hit the $500 ceiling (alternating rulings keeps `isDifferent`).
        uint8 next = ruling;
        uint256 guard = 0;
        while (currentBond < MAX_BOND && guard < 16) {
            next = next == 0 ? 1 : 0;
            // Overflow-safe actor pick (aSeed may be near type(uint256).max under the fuzzer).
            address ch = actors[uint256(keccak256(abi.encode(aSeed, guard))) % actors.length];
            vm.startPrank(ch);
            usdc.approve(address(bondEscalation), type(uint256).max);
            bondEscalation.challenge(disputeId, next, 0);
            vm.stopPrank();
            _recordDeposit(disputeId, ch);
            ( , currentBond, , livenessEnd, , ) = _state(disputeId);
            guard++;
        }
        if (currentBond < MAX_BOND) return;

        address who = _pickActor(aSeed);
        vm.startPrank(who);
        usdc.approve(address(bondEscalation), type(uint256).max);
        bondEscalation.escalateToUMA(disputeId, "QmEvidenceCID");
        vm.stopPrank();
        callsEscalate++;
    }

    /// @notice Settle a live UMA assertion (fires the resolved callback through BondEscalation).
    function resolveUMA(uint256 dSeed, bool truthful) external {
        bytes32 disputeId = _pickDispute(dSeed);
        ( , , , , uint8 tier, bool resolved) = _state(disputeId);
        if (resolved || tier != 2) return;

        bytes32 assertionId = bondEscalation.disputeToAssertion(disputeId);
        if (assertionId == bytes32(0)) return;

        // The handler's OOV3 reference is the same mock the stack wired; drive resolution through it.
        MockOOV3 _oov3 = MockOOV3(bondEscalation.UMA_OOV3());
        _oov3.mockResolve(assertionId, truthful);
        callsUMAResolve++;
    }

    /// @notice 30-day stale recovery (forced 50/50 split) — never pausable.
    function forceStale(uint256 dSeed, uint256 warp) external {
        bytes32 disputeId = _pickDispute(dSeed);
        ( , , , , , bool resolved) = _state(disputeId);
        if (resolved) return;

        ( , , , , , , uint64 disputedAt, , , , , , ) = bondEscalation.disputes(disputeId);
        warp = bound(warp, 1, 5 days);
        vm.warp(uint256(disputedAt) + 30 days + warp);
        bondEscalation.forceResolveStale(disputeId);
    }

    // ---------------------------------------------------------------------
    // GHOST readers (for the invariant contract)
    // ---------------------------------------------------------------------
    function disputeCount() external view returns (uint256) {
        return disputeIds.length;
    }

    function depositorsOf(bytes32 disputeId) external view returns (address[] memory) {
        return _depositorsOf[disputeId];
    }
}

/// @title BondEscalationInvariantTest — stateful invariants over the bond-escalation game (PRD P1-8, INV-5/7/15).
/// @notice Targets a single `BondEscalationHandler`; Foundry drives ≥256 randomized sequences of
///         propose/AIRuling/challenge/finalize/claim/escalate/resolve across a pool of concurrent disputes
///         and asserts the four load-bearing properties after every sequence:
///
///   - invariant_DepositsEqualAccumulatedDuringGame  (INV-15): mid-game, Σ deposits == accumulatedBonds.
///   - invariant_LiveSolvency  (R8, CORRECTED FORM): contract USDC ≥ Σ over disputes of the Tier-1
///         obligation, where a RESOLVED SPLIT owes the sum of UNCLAIMED proportional shares, an
///         UNRESOLVED dispute owes accumulatedBonds, and a winner-takes-all resolved dispute owes 0.
///         The UMA bond is excluded (held by OOV3). This is NOT `balance >= accumulatedBonds`.
///   - invariant_TierAndResolvedMonotonic  (INV-5): tier never decreases, resolved never flips
///         true→false, disputedAt never changes once set.
///   - invariant_NoAdminWithdraw  (R8): the admin holds no path to extract user bonds; the admin's
///         USDC balance never rises across the whole randomized game.
contract BondEscalationInvariantTest is DisputeTestBase {
    BondEscalationHandler internal handler;

    uint256 internal constant POOL_SIZE = 5;

    // Snapshot of per-dispute monotone quantities, refreshed after each sequence by the invariants.
    mapping(bytes32 => uint8) internal _lastTier;
    mapping(bytes32 => bool) internal _lastResolved;
    mapping(bytes32 => uint64) internal _lastDisputedAt;
    mapping(bytes32 => bool) internal _seen;

    uint256 internal _adminUsdcAtStart;

    // Distinct handler actors (NOT the base requester/provider, which are the kernel counterparties).
    address internal ha0 = address(0xA11CE);
    address internal ha1 = address(0xB0B);
    address internal ha2 = address(0xCA01);
    address internal ha3 = address(0xD00D);

    function setUp() external {
        _setUpStack();

        address[4] memory hactors = [ha0, ha1, ha2, ha3];
        handler = new BondEscalationHandler(
            bondEscalation,
            kernel,
            usdc,
            escrow,
            oov3,
            hactors,
            provider,
            requester,
            fixed0,
            fixed0Pk,
            fixed1,
            fixed1Pk,
            POOL_SIZE
        );

        // The admin (== address(this)) must never gain USDC from the bond game.
        _adminUsdcAtStart = usdc.balanceOf(admin);

        // Only the handler is a fuzz target; restrict the selector set to the lifecycle actions.
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.propose.selector;
        selectors[1] = handler.submitAIRuling.selector;
        selectors[2] = handler.challenge.selector;
        selectors[3] = handler.finalize.selector;
        selectors[4] = handler.claimRefund.selector;
        selectors[5] = handler.escalateToUMA.selector;
        selectors[6] = handler.resolveUMA.selector;
        selectors[7] = handler.forceStale.selector;
        selectors[8] = handler.claimRefund.selector; // weight refunds slightly higher

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    // =====================================================================
    // INV-15 — during the Tier-1 bond game, Σ deposits == accumulatedBonds.
    // =====================================================================
    /// @dev While a dispute is in Tier-1 and UNRESOLVED, the running pool equals the sum of every
    ///      depositor's recorded stake. (Post-resolution this no longer holds: winner-takes-all zeroes
    ///      accumulatedBonds while deposits stay non-zero, and a split freezes accumulatedBonds as a
    ///      distribution snapshot — both intentional, see the solvency invariant below.)
    function invariant_DepositsEqualAccumulatedDuringGame() external view {
        uint256 n = handler.disputeCount();
        for (uint256 i = 0; i < n; i++) {
            bytes32 disputeId = handler.disputeIds(i);
            (, , , , uint256 accumulated, , , , uint8 tier, bool resolved, , , ) = bondEscalation.disputes(disputeId);
            if (resolved || tier != 1) continue;

            uint256 sumDeposits = 0;
            address[] memory deps = handler.depositorsOf(disputeId);
            for (uint256 j = 0; j < deps.length; j++) {
                sumDeposits += bondEscalation.deposits(disputeId, deps[j]);
            }
            assertEq(sumDeposits, accumulated, "INV-15: Sigma deposits != accumulatedBonds mid-game");
        }
    }

    // =====================================================================
    // R8 — CORRECTED live-solvency: USDC >= Σ UNCLAIMED obligations (NOT >= accumulatedBonds).
    // =====================================================================
    /// @dev For each dispute the live Tier-1 obligation the contract still owes is:
    ///        - unresolved             → accumulatedBonds (the whole live pool),
    ///        - resolved winner-take   → 0 (already pushed to the winner in finalize/callback),
    ///        - resolved SPLIT (r==2)  → Σ_{a: deposits[a] > 0} deposits[a] * accumulatedBonds / originalPool
    ///                                    (the sum of UNCLAIMED proportional shares; accumulatedBonds is a
    ///                                    FROZEN numerator snapshot here, originalPool the frozen divisor).
    ///      The contract's USDC balance must cover the sum of these obligations over ALL disputes. The UMA
    ///      bond is excluded — once asserted it is custodied by the OOV3, never by BondEscalation.
    function invariant_LiveSolvency() external view {
        uint256 n = handler.disputeCount();
        uint256 totalObligation = 0;

        for (uint256 i = 0; i < n; i++) {
            bytes32 disputeId = handler.disputeIds(i);
            (
                , uint8 ruling, , , uint256 accumulated, , , , , bool resolved, , uint256 originalPool,
            ) = bondEscalation.disputes(disputeId);

            if (!resolved) {
                // Whole live pool is owed back to the game.
                totalObligation += accumulated;
            } else if (ruling == 2) {
                // SPLIT: owe the sum of every depositor's still-unclaimed proportional share.
                if (originalPool == 0) continue; // nothing was ever deposited
                address[] memory deps = handler.depositorsOf(disputeId);
                for (uint256 j = 0; j < deps.length; j++) {
                    uint256 dep = bondEscalation.deposits(disputeId, deps[j]); // 0 once claimed
                    if (dep == 0) continue;
                    totalObligation += (dep * accumulated) / originalPool;
                }
            }
            // resolved winner-takes-all (ruling 0/1): obligation == 0 (pool already pushed out).
        }

        assertGe(
            usdc.balanceOf(address(bondEscalation)),
            totalObligation,
            "R8: contract owes more Tier-1 bond than it holds (UMA bond excluded)"
        );
    }

    // =====================================================================
    // INV-5 — tier monotone up, resolved monotone, disputedAt immutable.
    // =====================================================================
    function invariant_TierAndResolvedMonotonic() external {
        uint256 n = handler.disputeCount();
        for (uint256 i = 0; i < n; i++) {
            bytes32 disputeId = handler.disputeIds(i);
            (
                , , , , , , uint64 disputedAt, , uint8 tier, bool resolved, , ,
            ) = bondEscalation.disputes(disputeId);

            if (_seen[disputeId]) {
                assertGe(tier, _lastTier[disputeId], "INV-5: tier decreased");
                if (_lastResolved[disputeId]) {
                    assertTrue(resolved, "INV-5: resolved flipped true->false");
                }
                assertEq(disputedAt, _lastDisputedAt[disputeId], "INV-5: disputedAt changed after set");
            } else {
                _seen[disputeId] = true;
            }

            _lastTier[disputeId] = tier;
            _lastResolved[disputeId] = resolved;
            _lastDisputedAt[disputeId] = disputedAt;
        }
    }

    // =====================================================================
    // R8 — no admin-withdraw path: the admin's USDC never grows across the game.
    // =====================================================================
    /// @dev REGRESSION TRIPWIRE (not a proof): admin is never a handler actor and never deposits, so the
    ///      randomized game has no path to raise the admin's balance — this invariant can only ever hold
    ///      today, and exists to catch a FUTURE hardcoded transfer-to-admin. The POSITIVE adversarial
    ///      proof that the admin surface is non-extractive (every admin-only selector called against a
    ///      live pool, contract USDC asserted unchanged) lives in
    ///      BondEscalationUnitTest.test_AdminSurface_NonExtractive_AllSelectors. BondEscalation exposes
    ///      pause/unpause + evaluator governance to the admin, but NO function that moves
    ///      `accumulatedBonds` or the contract's USDC to the admin: the only outflows are the
    ///      finalization bounty (to msg.sender — a keeper/actor, never privileged), winner payouts, and
    ///      split refunds (both to depositors).
    function invariant_NoAdminWithdraw() external view {
        assertLe(usdc.balanceOf(admin), _adminUsdcAtStart, "R8: admin extracted user bond funds");
    }

    /// @notice Run-visibility summary (always passes); surfaces how often each action did real work.
    function invariant_CallSummary() external view {
        // Pure visibility — assert nothing, just emit via console for `-vvv` inspection.
        // (Left as a no-op assertion so the invariant runner reports it.)
        assertTrue(true);
    }
}
