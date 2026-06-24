// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/DisputeTestBase.sol";
import {AIRuling} from "../src/interfaces/DisputeTypes.sol";
import {IACTPKernel} from "../src/interfaces/IACTPKernel.sol";
import {ICompositeMediator} from "../src/interfaces/ICompositeMediator.sol";

/// @title BondEscalationUnitTest — AIP-14b §7.5-7.13 + §11 unit matrix (PRD task P1-6).
/// @notice The fuller §11 / §9 unit matrix for Tier-0/1, written to GAP-FILL on top of:
///           - BondEscalation.t.sol            (happy-path lifecycle + UMA)
///           - BondEscalationAdversarial.t.sol (MAJOR-1/2, sig DoS, INV-9 under kernel pause)
///         Nothing here duplicates those files. Every test below either (a) covers a §11
///         "Required Integration Tests" row not yet present, or (b) probes a §9 sub-state guard /
///         boundary that the existing happy-path tests skip.
///
///         Coverage added here (cross-referenced to AIP-14b §11 + §9):
///           §11 test_Challenge_DoublesAndCaps ........... bond doubling + ceiling clamp in ONE arc
///           §11 test_Challenge_RequiresDifferent ........ same ruling-2 + same split rejected
///           §11 test_Challenge_UpdatesLastProposerForRuling  direction map per challenge
///           §7.9 bounty-ordering ........................ bounty deducted BEFORE winner payout
///                bounty floor / clamp / paid-to-msg.sender (finalizer != winner)
///           §7.13 _livenessForEscrow boundaries ......... exact 50e6 / 500e6 / 5e9 (< vs <=)
///           §4.9 governance swap-and-pop ................ multiple pending indices + clears pending
///                + cancelFixed + rejects bad slot / zero address
///           §7.10 split refund .......................... Σ payouts == post-bounty pool, deposits→0,
///                no double-claim, dust <= sub-cent
///           §7.14 / INV-9 pausable matrix ............... all 5 pausable fns revert; all 4 recovery
///                fns succeed while paused (both directions)
///           §9 sub-state guards ......................... challenge-after-resolved, propose-after-tier>0,
///                finalize-before-liveness, double openDispute, AI-ruling-after-tier1
contract BondEscalationUnitTest is DisputeTestBase {
    // --- constants for the canonical 1,000 USDC escrow (1e9 units) ---
    uint256 internal constant ESCROW = TRANSACTION_AMOUNT; // 1e9
    uint256 internal constant INITIAL_BOND = 20_000_000; // 1e9 * 200 / 10000 = $20
    uint64 internal constant LIVENESS = 4 hours; // escrow in [500M, 5B)
    uint256 internal constant MAX_BOND = 500_000_000; // $500 ceiling
    uint256 internal constant MIN_BOND = 1_000_000; // $1 escalation-bond floor
    uint16 internal constant BOUNTY_BPS = 1000; // 10%
    uint256 internal constant MIN_BOUNTY = 100_000; // $0.10
    uint256 internal constant UMA_BOND = 500_000_000; // $500

    // Mirror events for vm.expectEmit.
    event ChallengeSubmitted(
        bytes32 indexed disputeId, uint8 counterRuling, uint16 counterSplitBps, address indexed challenger, uint256 bond
    );
    event DisputeFinalized(
        bytes32 indexed disputeId, uint8 ruling, address indexed winner, address indexed finalizer, uint256 bounty
    );
    event DisputeSplitRecorded(
        bytes32 indexed txId, address indexed requester, address indexed provider, uint16 splitBps
    );
    event ExternalResolutionSynced(bytes32 indexed disputeId, bytes32 indexed txId, uint8 kernelState);
    event StaleDisputeResolved(bytes32 indexed disputeId, address indexed caller);

    function setUp() external {
        _setUpStack();
    }

    // =====================================================================
    // §11: test_Challenge_DoublesAndCaps — one arc proving BOTH double + clamp.
    //      (BondEscalation.t.sol tests doubling and capping in SEPARATE tests; this
    //       combines them into the §11 row and asserts every intermediate bond value.)
    // =====================================================================
    function test_Challenge_DoublesAndCaps() external {
        bytes32 disputeId = _opened();
        _propose(disputeId, keeper, 0, 0); // currentBond = 20M

        // Expected geometric series, clamped at MAX_BOND on the step that would exceed it.
        uint256[6] memory expected = [
            uint256(40_000_000), // 20 -> 40
            80_000_000, // 40 -> 80
            160_000_000, // 80 -> 160
            320_000_000, // 160 -> 320
            MAX_BOND, // 320 -> 640 clamp 500
            MAX_BOND // 500 -> 1000 clamp 500 (ceiling is sticky)
        ];

        uint256 accumulated = INITIAL_BOND;
        uint8 ruling = 0;
        for (uint256 i = 0; i < 6; i++) {
            ruling = ruling == 0 ? 1 : 0; // alternate so "different outcome" holds
            address who = (i % 2 == 0) ? rando : keeper;
            uint256 bondToPost = expected[i];
            _challenge(disputeId, who, ruling, 0, bondToPost);
            accumulated += bondToPost;

            assertEq(_currentBondOf(disputeId), expected[i], "currentBond wrong at step");
            assertEq(_accumulatedOf(disputeId), accumulated, "accumulated wrong at step");
        }
        // Ceiling reached and sticky across the last two challenges.
        assertEq(_currentBondOf(disputeId), MAX_BOND, "bond must rest at ceiling");
    }

    // =====================================================================
    // §11: test_Challenge_RequiresDifferent — extends BondEscalation.t.sol's plain
    //      same-ruling case with the ruling-2 same-split sub-case (the OTHER half of
    //      the isDifferent predicate: a split with an identical splitBps is NOT different).
    // =====================================================================
    function test_Challenge_RequiresDifferent_SameSplitBpsRejected() external {
        bytes32 disputeId = _opened();
        _propose(disputeId, keeper, 2, 5000); // ruling 2 @ 50/50

        // Same ruling (2) AND same splitBps (5000) → not different → revert.
        vm.startPrank(rando);
        usdc.approve(address(bondEscalation), INITIAL_BOND * 2);
        vm.expectRevert("Must propose different outcome");
        bondEscalation.challenge(disputeId, 2, 5000);
        vm.stopPrank();
    }

    /// @notice ruling 2 with a DIFFERENT splitBps IS accepted (positive control for the predicate).
    function test_Challenge_RequiresDifferent_DifferentSplitBpsAccepted() external {
        bytes32 disputeId = _opened();
        _propose(disputeId, keeper, 2, 5000);

        _challenge(disputeId, rando, 2, 6000, INITIAL_BOND * 2); // same ruling, different split → OK
        assertEq(_splitBpsOf(disputeId), 6000, "split should update");
        assertEq(_currentRulingOf(disputeId), 2, "ruling stays 2");
    }

    // =====================================================================
    // §11: test_Challenge_UpdatesLastProposerForRuling — direction tracking.
    //      lastProposerForRuling[disputeId][ruling] must record the LAST proposer of
    //      EACH direction independently (this is the map UMA resolution reads, INV-12).
    // =====================================================================
    function test_Challenge_UpdatesLastProposerForRuling() external {
        bytes32 disputeId = _opened();

        // keeper proposes ruling 0.
        _propose(disputeId, keeper, 0, 0);
        assertEq(bondEscalation.lastProposerForRuling(disputeId, 0), keeper, "ruling0 -> keeper");

        // rando challenges ruling 1.
        _challenge(disputeId, rando, 1, 0, INITIAL_BOND * 2);
        assertEq(bondEscalation.lastProposerForRuling(disputeId, 1), rando, "ruling1 -> rando");
        // ruling 0 mapping untouched by a ruling-1 challenge.
        assertEq(bondEscalation.lastProposerForRuling(disputeId, 0), keeper, "ruling0 still keeper");

        // keeper challenges back to ruling 0 — overwrites the ruling-0 slot to keeper (still keeper),
        // then a DIFFERENT actor (provider) re-challenges ruling 0 is impossible (must differ), so
        // bounce to ruling 1 via provider, proving the ruling-1 slot is reassignable.
        _challenge(disputeId, keeper, 0, 0, INITIAL_BOND * 4);
        assertEq(bondEscalation.lastProposerForRuling(disputeId, 0), keeper, "ruling0 -> keeper(re)");

        _challenge(disputeId, provider, 1, 0, INITIAL_BOND * 8);
        assertEq(bondEscalation.lastProposerForRuling(disputeId, 1), provider, "ruling1 -> provider(re)");
        // ruling 0 still points at keeper (last ruling-0 proposer), never reset by ruling-1 churn.
        assertEq(bondEscalation.lastProposerForRuling(disputeId, 0), keeper, "ruling0 stable");
    }

    // =====================================================================
    // §7.9: finalization bounty — deducted BEFORE the winner payout.
    //      BondEscalation.t.sol asserts the bounty amount; this asserts the ORDERING
    //      invariant directly: winner receives exactly (pool - bounty), and the contract
    //      nets to zero, proving the bounty came off the top before the winner push.
    // =====================================================================
    function test_Finalize_BountyDeductedBeforeWinner() external {
        bytes32 disputeId = _opened();
        _propose(disputeId, keeper, 0, 0); // pool = 20M, ruling 0 → keeper wins

        uint256 pool = INITIAL_BOND;
        uint256 bounty = (pool * BOUNTY_BPS) / 10000; // 2M
        uint256 winnerPayout = pool - bounty; // 18M

        vm.warp(block.timestamp + LIVENESS + 1);

        uint256 finalizerBefore = usdc.balanceOf(rando);
        uint256 winnerBefore = usdc.balanceOf(keeper);

        // Event ordering: finalize emits DisputeFinalized with the bounty AFTER deduction.
        vm.expectEmit(true, true, true, true, address(bondEscalation));
        emit DisputeFinalized(disputeId, 0, keeper, rando, bounty);

        vm.prank(rando);
        bondEscalation.finalize(disputeId);

        assertEq(usdc.balanceOf(rando) - finalizerBefore, bounty, "bounty must be paid off the top");
        assertEq(usdc.balanceOf(keeper) - winnerBefore, winnerPayout, "winner gets pool MINUS bounty");
        assertEq(usdc.balanceOf(address(bondEscalation)), 0, "no dust left after winner-takes-all");
        // accumulatedBonds zeroed on the winner-takes-all path.
        assertEq(_accumulatedOf(disputeId), 0, "accumulated must be zeroed");
    }

    /// @notice Bounty is paid to msg.sender (the FINALIZER), not the winner, even when the finalizer
    ///         is a third party that posted no bond. (§7.9: `USDC.safeTransfer(msg.sender, bounty)`.)
    function test_Finalize_BountyPaidToMsgSender_FinalizerNotWinner() external {
        bytes32 disputeId = _opened();
        _propose(disputeId, keeper, 1, 0); // ruling 1 → keeper is the winner

        uint256 pool = INITIAL_BOND;
        uint256 bounty = (pool * BOUNTY_BPS) / 10000;

        // A neutral EOA (never a depositor) finalizes and pockets the bounty.
        address finalizer = address(0xF1);
        vm.warp(block.timestamp + LIVENESS + 1);

        uint256 finalizerBefore = usdc.balanceOf(finalizer);
        uint256 winnerBefore = usdc.balanceOf(keeper);

        vm.prank(finalizer);
        bondEscalation.finalize(disputeId);

        assertEq(usdc.balanceOf(finalizer) - finalizerBefore, bounty, "bounty to finalizer (msg.sender)");
        assertEq(usdc.balanceOf(keeper) - winnerBefore, pool - bounty, "winner unaffected by who finalized");
    }

    /// @notice Bounty floor / clamp at the MINIMUM possible pool ($1 = MIN_ESCALATION_BOND).
    ///         Smallest single-proposal pool = MIN_ESCALATION_BOND = 1e6 (the bond floor), so the
    ///         10% bounty = 1e5 == MIN_FINALIZATION_BOUNTY exactly: the floor binds at equality and
    ///         is NEVER below the pool, so the winner still receives pool - bounty > 0. This pins the
    ///         §7.9 floor boundary (the `bounty < MIN` raise is a no-op here, the `bounty > pool`
    ///         clamp is unreachable since MIN_BOUNTY*10 == MIN_ESCALATION_BOND) and proves the floor
    ///         never inverts the payout.
    function test_Finalize_BountyFloor_SmallPool() external {
        // Tiny escrow ($0.05 == kernel MIN_TRANSACTION_AMOUNT) → _calculateInitialBond floors at
        // MIN_ESCALATION_BOND (1e6): 50_000 * 200 / 10000 = 1000 < 1e6 → bond = 1e6.
        bytes32 disputeId = _openedWithEscrow(50_000, "tiny-bounty-floor"); // $0.05 escrow
        _propose(disputeId, keeper, 0, 0);
        assertEq(_accumulatedOf(disputeId), MIN_BOND, "pool must be the $1 bond floor");

        uint256 pool = MIN_BOND; // 1e6
        uint256 rawBounty = (pool * BOUNTY_BPS) / 10000; // 1e5
        uint256 bounty = rawBounty < MIN_BOUNTY ? MIN_BOUNTY : rawBounty; // == MIN_BOUNTY (equality)
        assertEq(bounty, MIN_BOUNTY, "floored bounty must equal the $0.10 floor at min pool");
        assertLt(bounty, pool, "floor must never exceed the pool (winner keeps a positive payout)");

        // Tiny escrow → liveness tier is 1h (escrow < 50e6).
        vm.warp(block.timestamp + 1 hours + 1);

        uint256 finalizerBefore = usdc.balanceOf(rando);
        uint256 winnerBefore = usdc.balanceOf(keeper);
        vm.prank(rando);
        bondEscalation.finalize(disputeId);

        assertEq(usdc.balanceOf(rando) - finalizerBefore, bounty, "floored bounty paid");
        assertEq(usdc.balanceOf(keeper) - winnerBefore, pool - bounty, "winner gets the positive remainder");
        assertEq(usdc.balanceOf(address(bondEscalation)), 0, "contract drained");
    }

    /// @notice Bounty clamp `if (bounty > accumulatedBonds) bounty = accumulatedBonds`. From the
    ///         public surface the minimum pool (1e6) already exceeds MIN_BOUNTY (1e5), so the
    ///         clamp branch cannot trigger via proposeDirectly. We still pin the OBSERVABLE clamp
    ///         invariant on the split path: the bounty deducted can never exceed the pool, so the
    ///         post-bounty distributable pool is always >= 0 and depositors are never over-promised.
    function test_Finalize_BountyClampedToPool_SplitNeverOverPays() external {
        bytes32 disputeId = _opened();
        _propose(disputeId, keeper, 2, 5000); // split, pool = 20M

        uint256 pool = INITIAL_BOND;
        uint256 bounty = (pool * BOUNTY_BPS) / 10000;
        // clamp invariant: bounty <= pool (here 2M <= 20M).
        assertLe(bounty, pool, "bounty can never exceed the pool");

        vm.warp(block.timestamp + LIVENESS + 1);
        vm.prank(address(0xF1));
        bondEscalation.finalize(disputeId);

        // §7.9 snapshot: originalPool is the GROSS pool (set BEFORE the bounty deduction), while
        // accumulatedBonds is the POST-bounty numerator. For the sole depositor (deposit == grossPool):
        //   share = deposit * accumulatedBonds / originalPool = grossPool * (pool-bounty) / grossPool
        //         = pool - bounty (exact, no rounding) — never more than the pool (clamp holds).
        assertEq(_accumulatedOf(disputeId), pool - bounty, "frozen numerator = post-bounty pool");
        assertEq(_originalPoolOf(disputeId), pool, "snapshot divisor = GROSS pool (pre-bounty)");

        uint256 keeperBefore = usdc.balanceOf(keeper);
        vm.prank(keeper);
        bondEscalation.claimEscalationRefund(disputeId);
        assertEq(usdc.balanceOf(keeper) - keeperBefore, pool - bounty, "sole depositor claims exactly post-bounty pool");
    }

    // =====================================================================
    // §7.13 _livenessForEscrow boundaries — exact < vs <= behavior at the three
    //       thresholds (50e6, 500e6, 5e9). The map uses strict `<`, so the boundary
    //       value itself falls into the HIGHER tier. BondEscalation.t.sol only ever
    //       exercises the single 1e9 (4h) tier — these pin all four buckets + edges.
    // =====================================================================
    function test_LivenessTiers_Boundaries() external {
        // Below 50e6 → 1h. (49_999_999 is < 50e6.)
        _assertLiveness(49_999_999, 1 hours, "just under 50M -> 1h");
        // Exactly 50e6 → NOT < 50e6 → 2h tier.
        _assertLiveness(50_000_000, 2 hours, "exactly 50M -> 2h (strict <)");
        // Just under 500e6 → 2h.
        _assertLiveness(499_999_999, 2 hours, "just under 500M -> 2h");
        // Exactly 500e6 → 4h tier.
        _assertLiveness(500_000_000, 4 hours, "exactly 500M -> 4h (strict <)");
        // Just under 5e9 → 4h.
        _assertLiveness(4_999_999_999, 4 hours, "just under 5B -> 4h");
        // Exactly 5e9 → 8h tier.
        _assertLiveness(5_000_000_000, 8 hours, "exactly 5B -> 8h (strict <)");
        // Well above 5e9 → 8h.
        _assertLiveness(10_000_000_000, 8 hours, "above 5B -> 8h");
    }

    // =====================================================================
    // §4.9 governance — swap-and-pop with MULTIPLE pending indices, ClearsPending,
    //      CancelFixed, RejectsBadSlot / zero. The adversarial file tests the OVERLAP
    //      re-checks; this pins the array-bookkeeping + admin-guard surface.
    // =====================================================================

    /// @notice Queue THREE rotating additions, execute the MIDDLE one, and assert swap-and-pop:
    ///         the last pending element is moved into the executed slot, length shrinks by 1, and
    ///         BOTH parallel arrays (additions + unlock times) stay in lockstep. Then execute the
    ///         remaining two and confirm all land in the live pool.
    function test_Governance_RotatingSwapAndPop_MultiplePending() external {
        address a = makeAddr("rotA");
        address b = makeAddr("rotB");
        address c = makeAddr("rotC");

        vm.startPrank(admin);
        bondEscalation.proposeRotatingPoolAddition(a); // index 0
        bondEscalation.proposeRotatingPoolAddition(b); // index 1
        bondEscalation.proposeRotatingPoolAddition(c); // index 2
        vm.stopPrank();
        assertEq(bondEscalation.pendingRotatingAdditionsLength(), 3, "3 pending queued");

        vm.warp(block.timestamp + 2 days + 1);

        uint256 poolLenBefore = bondEscalation.rotatingPoolLength();

        // Execute the MIDDLE index (1 = b). Swap-and-pop moves c (last) into slot 1.
        bondEscalation.executeRotatingPoolAddition(1);
        assertEq(bondEscalation.rotatingPoolLength(), poolLenBefore + 1, "b should be live");
        assertEq(bondEscalation.pendingRotatingAdditionsLength(), 2, "pending shrinks to 2");
        // Slot 0 untouched (a), slot 1 now holds c (swapped in from the tail).
        assertEq(bondEscalation.pendingRotatingAdditions(0), a, "slot0 still a");
        assertEq(bondEscalation.pendingRotatingAdditions(1), c, "slot1 swapped to c");

        // Execute the two survivors (order: slot 1 = c, then slot 0 = a, each via swap-and-pop).
        bondEscalation.executeRotatingPoolAddition(1); // c
        bondEscalation.executeRotatingPoolAddition(0); // a
        assertEq(bondEscalation.pendingRotatingAdditionsLength(), 0, "all pending cleared");
        assertEq(bondEscalation.rotatingPoolLength(), poolLenBefore + 3, "all three now live");

        // All three are present in the live pool (order-agnostic).
        assertTrue(_poolContains(a) && _poolContains(b) && _poolContains(c), "a,b,c all in live pool");
    }

    /// @notice executeFixedEvaluatorUpdate CLEARS the pending slot + unlock time (no stale re-exec).
    function test_Governance_ExecuteFixedClearsPending() external {
        address x = makeAddr("newFixed");
        vm.prank(admin);
        bondEscalation.proposeFixedEvaluatorUpdate(0, x);

        vm.warp(block.timestamp + 2 days + 1);
        bondEscalation.executeFixedEvaluatorUpdate(0);
        assertEq(bondEscalation.fixedEvaluators(0), x, "slot 0 updated");
        assertEq(bondEscalation.pendingFixedEvaluators(0), address(0), "pending cleared");
        assertEq(bondEscalation.fixedEvaluatorUnlockTime(0), 0, "unlock time cleared");

        // Re-execution is rejected (nothing pending) — proves the clear actually took.
        vm.expectRevert("No pending update");
        bondEscalation.executeFixedEvaluatorUpdate(0);
    }

    /// @notice cancelFixedEvaluatorUpdate wipes a queued update so it can never execute.
    function test_Governance_CancelFixed() external {
        address x = makeAddr("cancelMe");
        vm.prank(admin);
        bondEscalation.proposeFixedEvaluatorUpdate(1, x);
        assertEq(bondEscalation.pendingFixedEvaluators(1), x, "queued");

        vm.prank(admin);
        bondEscalation.cancelFixedEvaluatorUpdate(1);
        assertEq(bondEscalation.pendingFixedEvaluators(1), address(0), "cancelled -> cleared");
        assertEq(bondEscalation.fixedEvaluatorUnlockTime(1), 0, "unlock cleared");

        // Even after the timelock window, a cancelled update cannot execute.
        vm.warp(block.timestamp + 2 days + 1);
        vm.expectRevert("No pending update");
        bondEscalation.executeFixedEvaluatorUpdate(1);
        // The original fixed evaluator is intact.
        assertEq(bondEscalation.fixedEvaluators(1), fixed1, "slot 1 unchanged");
    }

    /// @notice proposeFixedEvaluatorUpdate rejects an out-of-range slot and the zero address.
    function test_Governance_ProposeFixed_RejectsBadSlotAndZero() external {
        vm.prank(admin);
        vm.expectRevert("Invalid slot");
        bondEscalation.proposeFixedEvaluatorUpdate(2, makeAddr("x")); // slot must be < 2

        vm.prank(admin);
        vm.expectRevert("Zero address");
        bondEscalation.proposeFixedEvaluatorUpdate(0, address(0));
    }

    /// @notice executeFixedEvaluatorUpdate rejects a bad slot, and propose rejects a zero rotating add.
    function test_Governance_ExecuteFixed_RejectsBadSlot_AndProposeRotatingZero() external {
        vm.expectRevert("Invalid slot");
        bondEscalation.executeFixedEvaluatorUpdate(2);

        vm.prank(admin);
        vm.expectRevert("Zero address");
        bondEscalation.proposeRotatingPoolAddition(address(0));
    }

    /// @notice executeRotatingPoolAddition rejects an out-of-range index (empty queue).
    function test_Governance_ExecuteRotating_RejectsBadIndex() external {
        vm.expectRevert("Invalid index");
        bondEscalation.executeRotatingPoolAddition(0); // nothing pending
    }

    /// @notice Non-admin cannot drive any governance PROPOSE / cancel / removal path.
    function test_Governance_OnlyAdmin() external {
        vm.startPrank(rando);
        vm.expectRevert("Only admin");
        bondEscalation.proposeFixedEvaluatorUpdate(0, makeAddr("x"));
        vm.expectRevert("Only admin");
        bondEscalation.cancelFixedEvaluatorUpdate(0);
        vm.expectRevert("Only admin");
        bondEscalation.proposeRotatingPoolAddition(makeAddr("y"));
        vm.expectRevert("Only admin");
        bondEscalation.removeFromRotatingPool(0);
        vm.expectRevert("Only admin");
        bondEscalation.pause();
        vm.expectRevert("Only admin");
        bondEscalation.unpause();
        vm.stopPrank();
    }

    // =====================================================================
    // §7.10 split refund — proportional, sums to the post-bounty pool, deposits→0,
    //       no double-claim, dust <= sub-cent. BondEscalation.t.sol covers a 2-party
    //       50/60 split; this adds a 3-party UNEVEN split (the integer-division dust
    //       case) and explicitly proves the no-double-claim + deposits-zeroed guards.
    // =====================================================================
    function test_SplitRefund_ProportionalAndNoDoubleClaim() external {
        bytes32 disputeId = _opened();

        // Three depositors with distinct deposits → integer division leaves dust.
        // keeper  proposes ruling 2 @ 50/50  → 20M
        // rando   challenges ruling 2 @ 60/40 → 40M
        // provider challenges ruling 2 @ 30/70 → 80M
        _propose(disputeId, keeper, 2, 5000);
        _challenge(disputeId, rando, 2, 6000, INITIAL_BOND * 2);
        _challenge(disputeId, provider, 2, 3000, INITIAL_BOND * 4);

        uint256 grossPool = INITIAL_BOND + INITIAL_BOND * 2 + INITIAL_BOND * 4; // 140M
        uint256 bounty = (grossPool * BOUNTY_BPS) / 10000; // 14M
        uint256 postBountyPool = grossPool - bounty; // 126M

        vm.warp(block.timestamp + LIVENESS + 1);
        vm.prank(address(0xF1));
        bondEscalation.finalize(disputeId);

        assertEq(_accumulatedOf(disputeId), postBountyPool, "frozen numerator = post-bounty pool");
        assertEq(_originalPoolOf(disputeId), grossPool, "snapshot divisor = GROSS pool (pre-bounty)");

        // Contract formula (§7.10): share = deposits[a] * accumulatedBonds / originalPool, where at
        // finalize originalPool == accumulatedBonds == postBountyPool (frozen) and Σ deposits[a] ==
        // grossPool. So each share scales the GROSS deposit down by postBountyPool/grossPool... but the
        // EXACT on-chain arithmetic is deposit * acc / orig, which we replicate verbatim below to avoid
        // any off-by-rounding mismatch with the integer division the contract performs.
        uint256 acc = _accumulatedOf(disputeId);
        uint256 orig = _originalPoolOf(disputeId);

        uint256 dep0 = bondEscalation.deposits(disputeId, keeper);
        uint256 dep1 = bondEscalation.deposits(disputeId, rando);
        uint256 dep2 = bondEscalation.deposits(disputeId, provider);
        assertEq(dep0, INITIAL_BOND, "keeper deposit");
        assertEq(dep1, INITIAL_BOND * 2, "rando deposit");
        assertEq(dep2, INITIAL_BOND * 4, "provider deposit");

        uint256 share0 = (dep0 * acc) / orig;
        uint256 share1 = (dep1 * acc) / orig;
        uint256 share2 = (dep2 * acc) / orig;

        uint256 k0 = usdc.balanceOf(keeper);
        uint256 k1 = usdc.balanceOf(rando);
        uint256 k2 = usdc.balanceOf(provider);

        vm.prank(keeper);
        bondEscalation.claimEscalationRefund(disputeId);
        vm.prank(rando);
        bondEscalation.claimEscalationRefund(disputeId);
        vm.prank(provider);
        bondEscalation.claimEscalationRefund(disputeId);

        assertEq(usdc.balanceOf(keeper) - k0, share0, "keeper share proportional");
        assertEq(usdc.balanceOf(rando) - k1, share1, "rando share proportional");
        assertEq(usdc.balanceOf(provider) - k2, share2, "provider share proportional");

        // deposits[] zeroed for every claimant (no re-claim possible).
        assertEq(bondEscalation.deposits(disputeId, keeper), 0, "keeper deposit zeroed");
        assertEq(bondEscalation.deposits(disputeId, rando), 0, "rando deposit zeroed");
        assertEq(bondEscalation.deposits(disputeId, provider), 0, "provider deposit zeroed");

        // Σ payouts == post-bounty pool minus integer-division dust; dust is sub-cent ($0.01 = 1e4).
        uint256 totalPaid = share0 + share1 + share2;
        assertLe(totalPaid, postBountyPool, "payouts never exceed the post-bounty pool (solvency)");
        uint256 dust = postBountyPool - totalPaid;
        assertLe(dust, 10_000, "rounding dust must stay sub-cent ($0.01)");

        // No double-claim: a second claim reverts (deposit already zeroed).
        vm.prank(keeper);
        vm.expectRevert("Nothing to claim");
        bondEscalation.claimEscalationRefund(disputeId);
    }

    /// @notice claimEscalationRefund is winner-takes-all-gated: a non-split (ruling 0) resolution
    ///         cannot be claimed via the split path (§7.10 require "Not a split - winner takes all").
    function test_SplitRefund_RejectedOnWinnerTakesAll() external {
        bytes32 disputeId = _opened();
        _propose(disputeId, keeper, 0, 0); // ruling 0 → winner-takes-all
        vm.warp(block.timestamp + LIVENESS + 1);
        vm.prank(rando);
        bondEscalation.finalize(disputeId);

        vm.prank(keeper);
        vm.expectRevert("Not a split - winner takes all");
        bondEscalation.claimEscalationRefund(disputeId);
    }

    /// @notice claimEscalationRefund reverts before resolution (cannot claim a live bond game).
    function test_SplitRefund_RevertsBeforeResolved() external {
        bytes32 disputeId = _opened();
        _propose(disputeId, keeper, 2, 5000);
        vm.prank(keeper);
        vm.expectRevert("Not resolved");
        bondEscalation.claimEscalationRefund(disputeId);
    }

    // =====================================================================
    // §11 row: test_Finalize_SyncsExternal — finalize() self-sync early-return branch.
    //   (Distinct from the syncExternalResolution() function: this is the
    //    `if (txn.state != DISPUTED)` block INSIDE finalize() — BondEscalation.sol §7.9 —
    //    that a keeper hits when the kernel was ALREADY resolved out of DISPUTED by an admin
    //    INV-6 override BEFORE the keeper's finalize lands. The keeper's finalize must sync
    //    locally and RETURN WITHOUT calling compositeMediator.resolve — never double-resolve.)
    // =====================================================================

    /// @notice §11 "Handles admin-resolved disputes": a dispute whose kernel tx the admin already moved
    ///         DISPUTED -> CANCELLED (INV-6 override) must, on a post-liveness finalize(), take the
    ///         self-sync early-return: NO revert, resolved==true, ruling forced to 2 / splitBps 5000,
    ///         ExternalResolutionSynced emitted, and — critically — the mediator is NOT called a second
    ///         time (no kernel re-transition). Tier-1 bonds stay claimable via the split path.
    function test_Finalize_SyncsExternal() external {
        bytes32 disputeId = _opened();
        bytes32 txId = _txIdOf(disputeId);

        // Two depositors stake the Tier-1 bond game so there is a real pool to keep claimable.
        _propose(disputeId, keeper, 0, 0); // ruling 0, 20M
        _challenge(disputeId, rando, 1, 0, INITIAL_BOND * 2); // ruling 1, 40M
        uint256 grossPool = INITIAL_BOND + INITIAL_BOND * 2; // 60M

        // Admin uses the always-available INV-6 override to resolve the KERNEL out of DISPUTED
        // (DISPUTED -> CANCELLED) WITHOUT touching BondEscalation. d.resolved is still false here.
        uint256 remaining = _remaining(txId);
        bytes memory proof = abi.encode(remaining / 2, remaining - remaining / 2); // 64-byte CANCELLED proof
        vm.prank(admin);
        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, proof);
        assertEq(
            uint8(kernel.getTransaction(txId).state),
            uint8(IACTPKernel.State.CANCELLED),
            "precondition: kernel already CANCELLED by admin"
        );

        // Warp past liveness so finalize()'s `block.timestamp > d.livenessEnd` guard passes.
        vm.warp(block.timestamp + LIVENESS + 1);

        // Snapshot the kernel's CANCELLED state-entry timestamp so we can prove the mediator did NOT
        // re-transition (a second resolve would revert "Invalid transition" CANCELLED->SETTLED anyway,
        // but we ALSO pin that finalize itself does not revert and emits the sync event).
        bytes32 expectedTxId = txId;
        vm.expectEmit(true, true, false, true, address(bondEscalation));
        emit ExternalResolutionSynced(disputeId, expectedTxId, uint8(IACTPKernel.State.CANCELLED));

        // (a) finalize MUST NOT revert (no double-resolve via the mediator).
        address keeperFinalizer = address(0xF1);
        uint256 finalizerBefore = usdc.balanceOf(keeperFinalizer);
        vm.prank(keeperFinalizer);
        bondEscalation.finalize(disputeId);

        // (b) resolved==true, ruling forced to 2 (split), splitBps 5000 — the self-sync footprint.
        assertTrue(_resolvedOf(disputeId), "self-sync must mark resolved");
        assertEq(_currentRulingOf(disputeId), 2, "self-sync forces ruling 2 (split)");
        assertEq(_splitBpsOf(disputeId), 5000, "self-sync forces 50/50 split");

        // (c) originalPool snapshotted to the (gross) pool; NO bounty was taken on the sync path
        //     (the early return runs BEFORE the bounty deduction), so accumulatedBonds is untouched.
        assertEq(_originalPoolOf(disputeId), grossPool, "originalPool snapshot = full accumulatedBonds");
        assertEq(_accumulatedOf(disputeId), grossPool, "no bounty deducted on the sync early-return");
        assertEq(usdc.balanceOf(keeperFinalizer) - finalizerBefore, 0, "no bounty paid on the sync path");
        assertFalse(_winnerPaidOf(disputeId), "no winner pushed on the sync path");

        // (d) The mediator was NOT called again: kernel state is still CANCELLED (a second resolve would
        //     have attempted CANCELLED->SETTLED and reverted). State unchanged == no double-resolution.
        assertEq(
            uint8(kernel.getTransaction(txId).state),
            uint8(IACTPKernel.State.CANCELLED),
            "kernel must remain CANCELLED - mediator not re-invoked"
        );

        // (e) Tier-1 bonds remain claimable via the split path (no stranded pool). Both depositors get
        //     their full (no-bounty) proportional share back.
        uint256 keeperBefore = usdc.balanceOf(keeper);
        uint256 randoBefore = usdc.balanceOf(rando);
        vm.prank(keeper);
        bondEscalation.claimEscalationRefund(disputeId);
        vm.prank(rando);
        bondEscalation.claimEscalationRefund(disputeId);
        // share = deposit * accumulatedBonds / originalPool; here accumulatedBonds == originalPool ==
        // grossPool, so each depositor recovers EXACTLY their deposit.
        assertEq(usdc.balanceOf(keeper) - keeperBefore, INITIAL_BOND, "keeper recovers full deposit");
        assertEq(usdc.balanceOf(rando) - randoBefore, INITIAL_BOND * 2, "rando recovers full deposit");
    }

    /// @notice Companion edge: the SAME self-sync early return in finalize() when the admin moved the
    ///         kernel DISPUTED -> SETTLED (provider-favored admin resolution) rather than CANCELLED.
    ///         finalize must still sync locally (ruling 2 / 5000), emit with the SETTLED state code, and
    ///         not re-call the mediator. Pins that the branch keys off "!= DISPUTED", not a specific state.
    function test_Finalize_SyncsExternal_AdminSettled() external {
        bytes32 disputeId = _opened();
        bytes32 txId = _txIdOf(disputeId);
        _propose(disputeId, keeper, 0, 0);

        uint256 remaining = _remaining(txId);
        // 96-byte SETTLED proof: provider wins the remaining escrow (providerAtFault = false).
        bytes memory proof = abi.encode(uint256(0), remaining, false);
        vm.prank(admin);
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, proof);

        vm.warp(block.timestamp + LIVENESS + 1);

        vm.expectEmit(true, true, false, true, address(bondEscalation));
        emit ExternalResolutionSynced(disputeId, txId, uint8(IACTPKernel.State.SETTLED));

        vm.prank(address(0xF1));
        bondEscalation.finalize(disputeId); // must not revert

        assertTrue(_resolvedOf(disputeId), "synced");
        assertEq(_currentRulingOf(disputeId), 2, "forced split on sync");
        assertEq(
            uint8(kernel.getTransaction(txId).state),
            uint8(IACTPKernel.State.SETTLED),
            "kernel stays SETTLED - mediator not re-invoked"
        );
    }

    // =====================================================================
    // INV-22 / §11 row: test_Split_EmitsDisputeSplitRecorded — END-TO-END through the
    //   THREE BondEscalation split paths the spec enumerates ("finalize, stale, AND UMA
    //   no-winner"), each asserting the trace fires from the REAL CompositeMediator chokepoint
    //   (not just the direct mediator unit test). Anti-griefing (§3.4) depends on the trace
    //   surfacing for forceResolveStale and UMA-no-winner splits specifically.
    // =====================================================================

    /// @notice Path 1 — finalize() split: a Tier-1 ruling-2 finalize routes through
    ///         compositeMediator.resolve(txId, 2, splitBps) which MUST emit DisputeSplitRecorded.
    function test_Split_EmitsDisputeSplitRecorded_FinalizePath() external {
        bytes32 disputeId = _opened();
        bytes32 txId = _txIdOf(disputeId);
        _propose(disputeId, keeper, 2, 5000); // split @ 50/50

        vm.warp(block.timestamp + LIVENESS + 1);

        // The split trace fires from the mediator with the kernel's requester/provider for this tx.
        vm.expectEmit(true, true, true, true, address(compositeMediator));
        emit DisputeSplitRecorded(txId, requester, provider, 5000);

        vm.prank(address(0xF1));
        bondEscalation.finalize(disputeId);
    }

    /// @notice Path 2 — forceResolveStale() split: the 30-day stale recovery forces a 50/50 split via
    ///         compositeMediator.resolve(txId, 2, 5000) — the trace MUST fire on this path too.
    function test_Split_EmitsDisputeSplitRecorded_StalePath() external {
        bytes32 disputeId = _opened();
        bytes32 txId = _txIdOf(disputeId);
        _propose(disputeId, keeper, 0, 0); // a winner-takes-all proposal that goes stale

        vm.warp(block.timestamp + 30 days + 1);

        vm.expectEmit(true, true, true, true, address(compositeMediator));
        emit DisputeSplitRecorded(txId, requester, provider, 5000);

        bondEscalation.forceResolveStale(disputeId);
    }

    /// @notice Path 3 — UMA no-winner fallback split: a UMA resolution whose winning direction had NO
    ///         Tier-1 proposer falls back to a 50/50 split, routing through
    ///         compositeMediator.resolve(txId, 2, 5000) — the trace MUST fire on the UMA path too.
    function test_Split_EmitsDisputeSplitRecorded_UMANoWinnerPath() external {
        bytes32 disputeId = _opened();
        bytes32 txId = _txIdOf(disputeId);
        // Drive to the $500 ceiling such that ruling 1 is NEVER proposed (only ruling 0 / ruling 2),
        // so a UMA "FALSE" (ruling 1) result has no lastProposerForRuling[1] → no-winner fallback.
        _escalateBondToCeilingNeverRuling1(disputeId);

        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), UMA_BOND);
        bondEscalation.escalateToUMA(disputeId, "QmEvidenceCID");
        vm.stopPrank();

        bytes32 assertionId = bondEscalation.disputeToAssertion(disputeId);

        vm.expectEmit(true, true, true, true, address(compositeMediator));
        emit DisputeSplitRecorded(txId, requester, provider, 5000);

        // FALSE → ruling 1 → no proposer for that direction → 50/50 split fallback.
        oov3.mockResolve(assertionId, false);
        assertEq(_splitBpsOf(disputeId), 5000, "UMA no-winner fell back to 50/50");
        assertFalse(_winnerPaidOf(disputeId), "no winner paid on the fallback");
    }

    // =====================================================================
    // Tier-0 stale/sync ZERO-POOL edge: a dispute openDispute'd but NEVER proposed, then
    //   forceResolveStale'd / syncExternalResolution'd. originalPool == 0 and accumulatedBonds == 0.
    //   claimEscalationRefund divides by originalPool (§7.10 line `* accumulatedBonds / d.originalPool`)
    //   but is guarded by require(deposited > 0). Pin that ANY claim reverts "Nothing to claim"
    //   (the guard fires FIRST) — NOT a division Panic(0x12). Proves the safe ordering.
    // =====================================================================

    /// @notice forceResolveStale on a never-proposed (tier 0) dispute: resolves to a zero-pool split.
    function test_ZeroPool_ForceResolveStale_ClaimRevertsNotPanic() external {
        bytes32 disputeId = _opened(); // opened, NEVER proposed → tier 0, accumulatedBonds 0
        bytes32 txId = _txIdOf(disputeId);
        assertEq(_tierOf(disputeId), 0, "precondition: tier 0 (never proposed)");

        vm.warp(block.timestamp + 30 days + 1);
        bondEscalation.forceResolveStale(disputeId);

        assertTrue(_resolvedOf(disputeId), "stale resolves the empty dispute");
        assertEq(_currentRulingOf(disputeId), 2, "forced split");
        assertEq(_splitBpsOf(disputeId), 5000, "50/50 split");
        assertEq(_originalPoolOf(disputeId), 0, "originalPool snapshot == 0 (no deposits)");
        assertEq(_accumulatedOf(disputeId), 0, "accumulatedBonds == 0");
        assertEq(
            uint8(kernel.getTransaction(txId).state), uint8(IACTPKernel.State.CANCELLED), "kernel CANCELLED"
        );

        // Any address claiming hits require(deposited > 0) FIRST → "Nothing to claim", NOT a
        // division-by-zero Panic(0x12). The guard short-circuits before `/ d.originalPool`.
        vm.prank(keeper);
        vm.expectRevert("Nothing to claim");
        bondEscalation.claimEscalationRefund(disputeId);

        vm.prank(rando);
        vm.expectRevert("Nothing to claim");
        bondEscalation.claimEscalationRefund(disputeId);
    }

    /// @notice syncExternalResolution variant of the zero-pool edge: openDispute, admin resolves the
    ///         kernel out of DISPUTED, sync (no propose) → originalPool 0, claim reverts "Nothing to claim".
    function test_ZeroPool_SyncExternal_ClaimRevertsNotPanic() external {
        bytes32 disputeId = _opened(); // tier 0, never proposed
        bytes32 txId = _txIdOf(disputeId);

        // Admin INV-6 override moves the kernel out of DISPUTED.
        uint256 remaining = _remaining(txId);
        bytes memory proof = abi.encode(remaining / 2, remaining - remaining / 2);
        vm.prank(admin);
        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, proof);

        // sync (no propose ever happened → accumulatedBonds 0 → originalPool snapshot 0).
        bondEscalation.syncExternalResolution(disputeId);
        assertTrue(_resolvedOf(disputeId), "synced");
        assertEq(_originalPoolOf(disputeId), 0, "originalPool == 0 on a never-proposed sync");

        vm.prank(keeper);
        vm.expectRevert("Nothing to claim");
        bondEscalation.claimEscalationRefund(disputeId);
    }

    // =====================================================================
    // INV-21 (on-chain half): an AI ruling has NO finality privilege a direct proposal lacks.
    //   submitAIRuling and proposeDirectly share the SAME challengeable Tier-1 path. Pin the
    //   equivalence: a dispute opened via submitAIRuling can be challenged, finalized, and resolved
    //   with IDENTICAL semantics to one opened via proposeDirectly — no privileged finality.
    //   (Off-chain screening / structured-output halves of INV-21 remain P3-5, out of Phase-1 scope.)
    // =====================================================================
    function test_AIRuling_NoPrivilegedFinality_EquivalentToDirect() external {
        // Branch A: dispute opened via proposeDirectly (ruling 0).
        bytes32 dA = _opened();
        _propose(dA, keeper, 0, 0);
        assertEq(_tierOf(dA), 1, "direct proposal enters tier 1");

        // Branch B: dispute opened via submitAIRuling (ruling 0), 2/3 signed.
        bytes32 dB = _opened();
        AIRuling memory r = _ruling(dB, 0, 0);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signRuling(r, fixed0Pk);
        sigs[1] = _signRuling(r, fixed1Pk);
        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), INITIAL_BOND);
        bondEscalation.submitAIRuling(dB, r, sigs);
        vm.stopPrank();
        assertEq(_tierOf(dB), 1, "AI ruling enters the SAME tier-1 path (no privileged finality)");

        // Both are equally CHALLENGEABLE: rando challenges each with a different outcome, same bond.
        _challenge(dA, rando, 1, 0, INITIAL_BOND * 2);
        _challenge(dB, rando, 1, 0, INITIAL_BOND * 2);
        assertEq(_currentRulingOf(dA), 1, "direct dispute accepted the challenge");
        assertEq(_currentRulingOf(dB), 1, "AI dispute accepted the IDENTICAL challenge");
        assertEq(_currentBondOf(dA), INITIAL_BOND * 2, "same post-challenge bond (direct)");
        assertEq(_currentBondOf(dB), INITIAL_BOND * 2, "same post-challenge bond (AI) - no privilege");

        // Both finalize with IDENTICAL semantics after the same liveness: ruling 1 → winner-takes-all,
        // last proposer (rando) is paid, kernel SETTLED. The AI-opened dispute behaves exactly the same.
        vm.warp(block.timestamp + LIVENESS + 1);
        vm.prank(address(0xF1));
        bondEscalation.finalize(dA);
        vm.prank(address(0xF1));
        bondEscalation.finalize(dB);

        assertEq(_currentRulingOf(dA), 1, "direct final ruling");
        assertEq(_currentRulingOf(dB), 1, "AI final ruling - identical");
        assertTrue(_winnerPaidOf(dA), "direct winner paid");
        assertTrue(_winnerPaidOf(dB), "AI winner paid - same finalize semantics, no privileged finality");
        assertEq(
            uint8(kernel.getTransaction(_txIdOf(dA)).state),
            uint8(kernel.getTransaction(_txIdOf(dB)).state),
            "both resolve to the SAME kernel state (SETTLED) - AI ruling has no extra finality"
        );
    }

    // =====================================================================
    // INV-7: three pools are completely separate — entry-bond (EscrowVault), Tier-1
    //   accumulatedBonds (BondEscalation), UMA bond (OOV3). Pin that BondEscalation Tier-1 lifecycle
    //   actions (propose/challenge/finalize/claim) NEVER touch the EscrowVault entry-bond pool: it
    //   stays exactly as the kernel set it at DISPUTED, and only changes via the SINGLE
    //   compositeMediator.resolve at resolution (the kernel CANCELLED transition returns it to the
    //   disputer). This is the cross-pool non-comingling assertion the invariant suite does not make.
    // =====================================================================
    function test_INV7_ThreePoolsSeparate_Tier1LifecycleDoesNotTouchEntryBond() external {
        bytes32 disputeId = _opened();
        bytes32 txId = _txIdOf(disputeId);
        // escrowId == txId in this harness (linkEscrow(txId, escrow, txId)).
        uint256 entryBondAtOpen = escrow.bondBalance(txId);
        assertGt(entryBondAtOpen, 0, "kernel deposited an entry bond at DISPUTED");

        // Tier-1 propose: BondEscalation pulls its OWN bond into accumulatedBonds. The EscrowVault
        // entry-bond pool is UNTOUCHED (separate pool, separate token custody accounting).
        _propose(disputeId, keeper, 0, 0);
        assertEq(_accumulatedOf(disputeId), INITIAL_BOND, "Tier-1 pool credited");
        assertEq(escrow.bondBalance(txId), entryBondAtOpen, "propose must NOT touch entry bond");

        // Tier-1 challenge: grows accumulatedBonds; entry bond still untouched.
        _challenge(disputeId, rando, 1, 0, INITIAL_BOND * 2);
        assertEq(_accumulatedOf(disputeId), INITIAL_BOND * 3, "Tier-1 pool grew on challenge");
        assertEq(escrow.bondBalance(txId), entryBondAtOpen, "challenge must NOT touch entry bond");

        // finalize (ruling 1 → winner-takes-all): Tier-1 pool is pushed to the winner and the SINGLE
        // mediator.resolve enacts the kernel CANCELLED/SETTLED transition. Only NOW may the entry-bond
        // pool change (the kernel returns it to the disputer on its CANCELLED/SETTLED handler).
        vm.warp(block.timestamp + LIVENESS + 1);
        vm.prank(address(0xF1));
        bondEscalation.finalize(disputeId);

        // ruling 1 → SETTLED. The kernel released the entry bond during its transition (entry-bond pool
        // is now zero), proving the ONLY mutation of that pool happened at the mediator resolution, never
        // during the Tier-1 game. The Tier-1 pool was pushed to the winner (accumulatedBonds == 0).
        assertEq(_accumulatedOf(disputeId), 0, "Tier-1 pool pushed to winner");
        assertEq(escrow.bondBalance(txId), 0, "entry bond released ONLY at mediator resolution");
        assertEq(uint8(kernel.getTransaction(txId).state), uint8(IACTPKernel.State.SETTLED), "kernel SETTLED");
    }

    // =====================================================================
    // Admin surface is NON-EXTRACTIVE (positive control for invariant_NoAdminWithdraw, which is a
    //   regression tripwire rather than a proof). Exercise EVERY admin-only selector against a live
    //   Tier-1 pool and assert the contract's USDC balance is unchanged — there is NO fund-extraction
    //   path on the admin surface (pause/unpause + evaluator governance are the only admin functions).
    // =====================================================================
    function test_AdminSurface_NonExtractive_AllSelectors() external {
        bytes32 disputeId = _opened();
        _propose(disputeId, keeper, 0, 0);
        _challenge(disputeId, rando, 1, 0, INITIAL_BOND * 2);

        uint256 contractUsdcBefore = usdc.balanceOf(address(bondEscalation));
        uint256 adminUsdcBefore = usdc.balanceOf(admin);
        assertGt(contractUsdcBefore, 0, "contract holds a live Tier-1 pool");

        // Call every admin-only selector. None may move USDC.
        vm.startPrank(admin);
        bondEscalation.pause();
        bondEscalation.unpause();

        // Evaluator governance (timelocked additions / immediate removals / cancels). Use fresh addrs.
        (address newFixed, ) = makeAddrAndKey("newFixed");
        (address newRot, ) = makeAddrAndKey("newRot");
        bondEscalation.proposeFixedEvaluatorUpdate(0, newFixed);
        bondEscalation.cancelFixedEvaluatorUpdate(0);
        bondEscalation.proposeRotatingPoolAddition(newRot);
        // Add a second rotating member so we can exercise removeFromRotatingPool (min size 1 guard).
        (address newRot2, ) = makeAddrAndKey("newRot2");
        bondEscalation.proposeRotatingPoolAddition(newRot2);
        vm.stopPrank();

        // Execute the timelocked additions after the delay (executeRotatingPoolAddition is permissionless).
        vm.warp(block.timestamp + 2 days + 1);
        bondEscalation.executeRotatingPoolAddition(0);
        bondEscalation.executeRotatingPoolAddition(0);

        vm.startPrank(admin);
        bondEscalation.removeFromRotatingPool(bondEscalation.rotatingPoolLength() - 1);
        vm.stopPrank();

        // No admin selector moved a single wei of USDC: the contract pool and admin balance are flat.
        assertEq(usdc.balanceOf(address(bondEscalation)), contractUsdcBefore, "admin surface moved contract USDC");
        assertEq(usdc.balanceOf(admin), adminUsdcBefore, "admin extracted USDC");
    }

    /// @notice INV-18: the rotating pool cannot shrink below 1 — removing the last member reverts.
    ///         Closes the P5-1 coverage FLAG (the default DisputeTestBase pool has exactly one member).
    function test_Governance_RemoveLast_RevertsMinSizeOne() external {
        assertEq(bondEscalation.rotatingPoolLength(), 1, "default pool has one rotating member");
        vm.expectRevert("Pool minimum is 1");
        bondEscalation.removeFromRotatingPool(0);
    }

    // =====================================================================
    // §7.14 / INV-9 — full pausable matrix (BOTH directions).
    //   (a) All FIVE pausable fns revert "Paused".
    //   (b) All FOUR recovery fns succeed WHILE paused.
    // BondEscalation.t.sol checks one pausable + one recovery fn; this is the complete grid.
    // =====================================================================

    /// @notice (a) Every pausable entrypoint reverts under pause: openDispute, proposeDirectly,
    ///         submitAIRuling, challenge, escalateToUMA.
    function test_Pausable_RevertWhenPaused_AllFive() external {
        // Pre-stage: a Tier-1 dispute (for challenge/escalate) created BEFORE pausing.
        bytes32 d1 = _opened();
        _propose(d1, keeper, 0, 0);

        // A fresh DISPUTED tx whose openDispute we will attempt under pause.
        bytes32 freshTxId = _createDisputedSalt("paused-open");

        // A separate opened-but-unproposed dispute for proposeDirectly / submitAIRuling under pause.
        bytes32 d2 = _openedSalt("paused-propose");

        vm.prank(admin);
        bondEscalation.pause();
        assertTrue(bondEscalation.paused(), "must be paused");

        // 1) openDispute
        vm.expectRevert("Paused");
        bondEscalation.openDispute(freshTxId);

        // 2) proposeDirectly
        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), INITIAL_BOND);
        vm.expectRevert("Paused");
        bondEscalation.proposeDirectly(d2, 0, 0);
        vm.stopPrank();

        // 3) submitAIRuling
        AIRuling memory r = _ruling(d2, 0, 0);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signRuling(r, fixed0Pk);
        sigs[1] = _signRuling(r, fixed1Pk);
        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), INITIAL_BOND);
        vm.expectRevert("Paused");
        bondEscalation.submitAIRuling(d2, r, sigs);
        vm.stopPrank();

        // 4) challenge (on the Tier-1 d1)
        vm.startPrank(rando);
        usdc.approve(address(bondEscalation), INITIAL_BOND * 2);
        vm.expectRevert("Paused");
        bondEscalation.challenge(d1, 1, 0);
        vm.stopPrank();

        // 5) escalateToUMA (on d1 — guard order: whenNotPaused runs before the ceiling check,
        //    so "Paused" fires first even though the bond ceiling isn't reached).
        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), UMA_BOND);
        vm.expectRevert("Paused");
        bondEscalation.escalateToUMA(d1, "QmEvidence");
        vm.stopPrank();
    }

    /// @notice (b) Recovery fns work WHILE the BondEscalation contract is paused (INV-9):
    ///         finalize, claimEscalationRefund, forceResolveStale, syncExternalResolution.
    function test_Pausable_RecoveryFnsSucceedWhilePaused() external {
        // --- finalize + claimEscalationRefund under pause (split path) ---
        bytes32 dSplit = _opened();
        _propose(dSplit, keeper, 2, 5000);
        _challenge(dSplit, rando, 2, 6000, INITIAL_BOND * 2);

        // --- forceResolveStale under pause ---
        bytes32 dStale = _openedSalt("stale");
        _propose(dStale, keeper, 0, 0);

        // --- syncExternalResolution under pause (admin moved kernel out of DISPUTED) ---
        bytes32 dSync = _openedSalt("sync");
        _propose(dSync, keeper, 0, 0);
        bytes32 syncTxId = _txIdOf(dSync);
        // Admin resolves the kernel directly (INV-6 override) WITHOUT touching BondEscalation.
        uint256 rem = _remaining(syncTxId);
        bytes memory proof = abi.encode(rem / 2, rem - rem / 2);
        vm.prank(admin);
        kernel.transitionState(syncTxId, IACTPKernel.State.CANCELLED, proof);

        // Finalize dSplit BEFORE pausing (its liveness path routes through the kernel/mediator).
        vm.warp(block.timestamp + LIVENESS + 1);
        vm.prank(address(0xF1));
        bondEscalation.finalize(dSplit);
        assertTrue(_resolvedOf(dSplit), "dSplit resolved");

        // Now pause the BondEscalation contract.
        vm.prank(admin);
        bondEscalation.pause();
        assertTrue(bondEscalation.paused(), "paused for recovery test");

        // 1) claimEscalationRefund — succeeds while paused.
        uint256 keeperBefore = usdc.balanceOf(keeper);
        vm.prank(keeper);
        bondEscalation.claimEscalationRefund(dSplit);
        assertGt(usdc.balanceOf(keeper), keeperBefore, "claimEscalationRefund must work while paused");

        // 2) forceResolveStale — succeeds while paused (advance past the 30-day stale clock).
        vm.warp(block.timestamp + 30 days + 1);
        bondEscalation.forceResolveStale(dStale);
        assertTrue(_resolvedOf(dStale), "forceResolveStale must work while paused");

        // 3) syncExternalResolution — succeeds while paused.
        bondEscalation.syncExternalResolution(dSync);
        assertTrue(_resolvedOf(dSync), "syncExternalResolution must work while paused");

        // 4) finalize — also callable while paused. Because openDispute + proposeDirectly are
        //    themselves pausable, the Tier-1 state must be staged BEFORE the pause; the helper does an
        //    unpause/stage/re-pause cycle and then finalizes under pause.
        _assertFinalizeWorksUnderPause();
    }

    // =====================================================================
    // §9 sub-state guards — illegal transitions the happy-path tests never attempt.
    // =====================================================================

    /// @notice double openDispute on the SAME txId reverts "Already opened" (idempotency guard).
    ///         (BondEscalation.t.sol has this; we ALSO assert the disputeId is deterministic and the
    ///         second call cannot mutate disputedAt — the §9 UNINITIALIZED→OPENED edge is one-way.)
    function test_Guard_DoubleOpenDispute_DeterministicAndOneWay() external {
        bytes32 txId = _createDisputedSalt("double-open");
        bytes32 expected = keccak256(abi.encode("ACTP_DISPUTE_V1", txId));
        bytes32 d = bondEscalation.openDispute(txId);
        assertEq(d, expected, "disputeId deterministic");
        uint64 firstDisputedAt = _disputedAtOf(d);

        vm.warp(block.timestamp + 1000);
        vm.expectRevert("Already opened");
        bondEscalation.openDispute(txId);
        assertEq(_disputedAtOf(d), firstDisputedAt, "disputedAt must be immutable (INV-5)");
    }

    /// @notice proposeDirectly after the dispute already advanced past tier 0 reverts
    ///         "Already has proposal" (§9 OPENED→PROPOSED is one-shot).
    function test_Guard_ProposeAfterTierAdvanced() external {
        bytes32 disputeId = _opened();
        _propose(disputeId, keeper, 0, 0); // tier -> 1

        vm.startPrank(rando);
        usdc.approve(address(bondEscalation), INITIAL_BOND);
        vm.expectRevert("Already has proposal");
        bondEscalation.proposeDirectly(disputeId, 1, 0);
        vm.stopPrank();
    }

    /// @notice submitAIRuling after the dispute is already in Tier 1 reverts "Already escalated"
    ///         (an AI ruling can only ENTER from tier 0; it cannot override a live bond game).
    function test_Guard_SubmitAIRulingAfterTier1() external {
        bytes32 disputeId = _opened();
        _propose(disputeId, keeper, 0, 0); // tier -> 1

        AIRuling memory r = _ruling(disputeId, 1, 0);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signRuling(r, fixed0Pk);
        sigs[1] = _signRuling(r, fixed1Pk);

        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), INITIAL_BOND);
        vm.expectRevert("Already escalated");
        bondEscalation.submitAIRuling(disputeId, r, sigs);
        vm.stopPrank();
    }

    /// @notice challenge after resolution reverts. A finalized (winner-takes-all) dispute is no
    ///         longer tier 1, so a late challenge hits "Already resolved" (§9 RESOLVED is terminal).
    function test_Guard_ChallengeAfterResolved() external {
        bytes32 disputeId = _opened();
        _propose(disputeId, keeper, 0, 0);
        vm.warp(block.timestamp + LIVENESS + 1);
        vm.prank(rando);
        bondEscalation.finalize(disputeId);
        assertTrue(_resolvedOf(disputeId), "resolved");

        vm.startPrank(provider);
        usdc.approve(address(bondEscalation), INITIAL_BOND * 2);
        vm.expectRevert("Already resolved");
        bondEscalation.challenge(disputeId, 1, 0);
        vm.stopPrank();
    }

    /// @notice challenge after liveness expired (but pre-finalize) reverts "Liveness expired"
    ///         (the §9 CHALLENGED loop closes once liveness lapses; the only exit is finalize()).
    function test_Guard_ChallengeAfterLivenessExpired() external {
        bytes32 disputeId = _opened();
        _propose(disputeId, keeper, 0, 0);
        vm.warp(block.timestamp + LIVENESS + 1); // liveness lapsed, not yet finalized

        vm.startPrank(rando);
        usdc.approve(address(bondEscalation), INITIAL_BOND * 2);
        vm.expectRevert("Liveness expired");
        bondEscalation.challenge(disputeId, 1, 0);
        vm.stopPrank();
    }

    /// @notice finalize before liveness ends reverts "Liveness active" (cannot short-circuit the
    ///         challenge window). BondEscalation.t.sol has the basic case; we additionally prove it
    ///         holds at the EXACT livenessEnd boundary (finalize requires strict `>`).
    function test_Guard_FinalizeBeforeLiveness_BoundaryStrict() external {
        bytes32 disputeId = _opened();
        _propose(disputeId, keeper, 0, 0);
        uint64 end = _livenessEndOf(disputeId);

        // Exactly AT livenessEnd: `block.timestamp > livenessEnd` is false → revert.
        vm.warp(end);
        vm.expectRevert("Liveness active");
        bondEscalation.finalize(disputeId);

        // One second past: succeeds.
        vm.warp(uint256(end) + 1);
        vm.prank(rando);
        bondEscalation.finalize(disputeId);
        assertTrue(_resolvedOf(disputeId), "finalize succeeds 1s past liveness");
    }

    /// @notice finalize twice reverts "Already resolved" (terminal RESOLVED guard).
    function test_Guard_DoubleFinalize() external {
        bytes32 disputeId = _opened();
        _propose(disputeId, keeper, 0, 0);
        vm.warp(block.timestamp + LIVENESS + 1);
        vm.prank(rando);
        bondEscalation.finalize(disputeId);

        vm.expectRevert("Already resolved");
        bondEscalation.finalize(disputeId);
    }

    /// @notice finalize on a tier-0 (opened, never proposed) dispute reverts "Not in Tier 1".
    function test_Guard_FinalizeTier0() external {
        bytes32 disputeId = _opened();
        vm.warp(block.timestamp + LIVENESS + 1);
        vm.expectRevert("Not in Tier 1");
        bondEscalation.finalize(disputeId);
    }

    /// @notice escalateToUMA before the bond ceiling reverts (§9 ESCALATED requires the $500 cap).
    ///         BondEscalation.t.sol covers below-ceiling + empty-CID; we add the liveness-expired guard
    ///         (§9: at the ceiling but after liveness, the exit is finalize(), not UMA).
    function test_Guard_EscalateToUMA_LivenessExpired() external {
        bytes32 disputeId = _opened();
        _escalateBondToCeilingLocal(disputeId);
        // Let the ceiling-reset liveness lapse.
        vm.warp(block.timestamp + LIVENESS + 1);

        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), UMA_BOND);
        vm.expectRevert("Liveness expired - use finalize()");
        bondEscalation.escalateToUMA(disputeId, "QmEvidence");
        vm.stopPrank();
    }

    /// @notice escalateToUMA twice reverts "Already escalated" (the assertion mapping is one-shot;
    ///         tier is 2 after the first call so the tier guard fires first → "Not in Tier 1").
    function test_Guard_DoubleEscalateToUMA() external {
        bytes32 disputeId = _opened();
        _escalateBondToCeilingLocal(disputeId);
        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), UMA_BOND);
        bondEscalation.escalateToUMA(disputeId, "QmEvidence");
        // Second escalate: tier is now 2 → "Not in Tier 1" guard fires.
        usdc.approve(address(bondEscalation), UMA_BOND);
        vm.expectRevert("Not in Tier 1");
        bondEscalation.escalateToUMA(disputeId, "QmEvidence");
        vm.stopPrank();
    }

    /// @notice operations on an UNOPENED disputeId revert "Dispute not opened" across the surface.
    function test_Guard_UnopenedDispute() external {
        bytes32 ghost = keccak256("never-opened");

        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), INITIAL_BOND);
        vm.expectRevert("Dispute not opened");
        bondEscalation.proposeDirectly(ghost, 0, 0);
        vm.stopPrank();

        vm.expectRevert("Dispute not opened");
        bondEscalation.challenge(ghost, 0, 0);

        vm.expectRevert("Dispute not opened");
        bondEscalation.finalize(ghost);

        vm.expectRevert("Dispute not opened");
        bondEscalation.syncExternalResolution(ghost);
    }

    /// @notice proposeDirectly validates splitBps coupling: a non-split ruling with splitBps != 0
    ///         reverts (§7.6 "splitBps only for splits"), and an out-of-range splitBps reverts.
    function test_Guard_ProposeSplitBpsValidation() external {
        bytes32 disputeId = _opened();
        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), INITIAL_BOND);
        vm.expectRevert("splitBps only for splits");
        bondEscalation.proposeDirectly(disputeId, 0, 5000); // ruling 0 cannot carry a split
        vm.stopPrank();

        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), INITIAL_BOND);
        vm.expectRevert("Invalid splitBps");
        bondEscalation.proposeDirectly(disputeId, 2, 10001); // split > 100%
        vm.stopPrank();
    }

    // =====================================================================
    // Internal helpers
    // =====================================================================

    /// @dev Liveness assertion at a chosen escrow amount: open + propose, then read livenessEnd.
    function _assertLiveness(uint256 escrowAmount, uint64 expected, string memory tag) internal {
        bytes32 d = _openedWithEscrow(escrowAmount, tag);
        uint64 t0 = uint64(block.timestamp);
        // Bond floor still applies; proposer must approve max(percent, MIN_BOND).
        uint256 bond = (escrowAmount * 200) / 10000;
        if (bond <= MIN_BOND) bond = MIN_BOND;
        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), bond);
        bondEscalation.proposeDirectly(d, 0, 0);
        vm.stopPrank();
        assertEq(_livenessEndOf(d), t0 + expected, tag);
    }

    /// @dev Stage a Tier-1 dispute BEFORE a pause, pause, then prove finalize works under pause.
    function _assertFinalizeWorksUnderPause() internal {
        // unpause to stage, then re-pause.
        vm.prank(admin);
        bondEscalation.unpause();

        bytes32 d = _openedSalt("finalize-under-pause");
        _propose(d, keeper, 0, 0);

        vm.prank(admin);
        bondEscalation.pause();
        assertTrue(bondEscalation.paused(), "re-paused");

        vm.warp(block.timestamp + LIVENESS + 1);
        vm.prank(rando);
        bondEscalation.finalize(d); // must NOT revert under pause (INV-9)
        assertTrue(_resolvedOf(d), "finalize must work while paused (INV-9)");
    }

    /// @dev True iff `who` is currently a member of the live rotating pool.
    function _poolContains(address who) internal view returns (bool) {
        uint256 n = bondEscalation.rotatingPoolLength();
        for (uint256 i = 0; i < n; i++) {
            if (bondEscalation.rotatingPool(i) == who) return true;
        }
        return false;
    }

    /// @dev Propose helper (default-amount escrow): approve the $20 initial bond, then propose.
    function _propose(bytes32 disputeId, address who, uint8 ruling, uint16 splitBps) internal {
        vm.startPrank(who);
        usdc.approve(address(bondEscalation), INITIAL_BOND);
        bondEscalation.proposeDirectly(disputeId, ruling, splitBps);
        vm.stopPrank();
    }

    /// @dev Challenge helper with an explicit bond approval amount.
    function _challenge(bytes32 disputeId, address who, uint8 ruling, uint16 splitBps, uint256 bond) internal {
        vm.startPrank(who);
        usdc.approve(address(bondEscalation), bond);
        bondEscalation.challenge(disputeId, ruling, splitBps);
        vm.stopPrank();
    }

    /// @dev Drive the default-escrow dispute to the $500 bond ceiling (keeper ends as ruling-0 last
    ///      proposer, alternating 0/1). Mirrors BondEscalation.t.sol's helper but local to this file.
    function _escalateBondToCeilingLocal(bytes32 disputeId) internal {
        _propose(disputeId, keeper, 0, 0); // 20M, ruling 0
        uint256 bond = INITIAL_BOND;
        uint8 ruling = 0;
        for (uint256 i = 0; i < 6; i++) {
            ruling = ruling == 0 ? 1 : 0;
            bond = bond * 2;
            if (bond > MAX_BOND) bond = MAX_BOND;
            address who = (i % 2 == 0) ? rando : keeper;
            _challenge(disputeId, who, ruling, 0, bond);
        }
        require(_currentBondOf(disputeId) == MAX_BOND, "ceiling not reached");
        require(_lastProposerOf(disputeId) == keeper, "keeper should be last proposer");
    }

    /// @dev Drive to the $500 ceiling using ONLY rulings 0 and 2 (never ruling 1), so a UMA FALSE
    ///      result (ruling 1) has no `lastProposerForRuling[1]` → the no-winner split fallback fires.
    ///      keeper ends as the last ruling-0 proposer (the escalator direction).
    function _escalateBondToCeilingNeverRuling1(bytes32 disputeId) internal {
        _propose(disputeId, keeper, 0, 0); // 20M, ruling 0
        uint256 bond = INITIAL_BOND;
        uint8 ruling = 0;
        for (uint256 i = 0; i < 6; i++) {
            ruling = ruling == 0 ? 2 : 0; // alternate 0 <-> 2 (ruling 1 NEVER proposed)
            uint16 split = ruling == 2 ? uint16(5000 + i * 100) : 0; // distinct split each step
            bond = bond * 2;
            if (bond > MAX_BOND) bond = MAX_BOND;
            address who = (i % 2 == 0) ? rando : keeper;
            _challenge(disputeId, who, ruling, split, bond);
        }
        require(_currentBondOf(disputeId) == MAX_BOND, "ceiling not reached");
        require(_lastProposerOf(disputeId) == keeper, "keeper should be last ruling-0 proposer");
        require(bondEscalation.lastProposerForRuling(disputeId, 1) == address(0), "ruling 1 must have NO proposer");
    }

    /// @dev Open a fresh dispute on the canonical 1e9 escrow.
    function _opened() internal returns (bytes32 disputeId) {
        bytes32 txId = _createDisputed();
        disputeId = bondEscalation.openDispute(txId);
    }

    /// @dev Open a fresh dispute with a distinct service salt (independent txId, canonical amount).
    function _openedSalt(string memory salt) internal returns (bytes32 disputeId) {
        bytes32 txId = _createDisputedSalt(salt);
        disputeId = bondEscalation.openDispute(txId);
    }

    /// @dev Open a fresh dispute at a chosen escrow amount (for bounty-floor + liveness boundaries).
    function _openedWithEscrow(uint256 amount, string memory salt) internal returns (bytes32 disputeId) {
        bytes32 txId = _createDisputedWithAmount(amount, salt);
        disputeId = bondEscalation.openDispute(txId);
    }

    /// @dev A DISPUTED tx with a distinct service hash (independent txId), canonical amount.
    function _createDisputedSalt(string memory salt) internal returns (bytes32 txId) {
        return _createDisputedWithAmount(TRANSACTION_AMOUNT, salt);
    }

    /// @dev Drive a fresh tx of `amount` (distinct service salt) all the way to DISPUTED.
    ///      Mirrors DisputeTestBase._createDisputed() but parameterized on amount + service hash.
    function _createDisputedWithAmount(uint256 amount, string memory salt) internal returns (bytes32 txId) {
        bytes32 svc = keccak256(abi.encodePacked("service-", salt));
        vm.prank(requester);
        txId = kernel.createTransaction(
            provider, requester, amount, block.timestamp + 30 days, 2 days, svc, 0, 0
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
        if (bond < 1_000_000) bond = 1_000_000; // kernel MIN_DISPUTE_BOND
        vm.startPrank(requester);
        usdc.approve(address(escrow), bond);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");
        vm.stopPrank();
    }

    // ----- typed accessors over the disputes 13-tuple -----
    function _txIdOf(bytes32 disputeId) internal view returns (bytes32 t) {
        (t,,,,,,,,,,,,) = bondEscalation.disputes(disputeId);
    }

    function _currentRulingOf(bytes32 disputeId) internal view returns (uint8 r) {
        (, r,,,,,,,,,,,) = bondEscalation.disputes(disputeId);
    }

    function _splitBpsOf(bytes32 disputeId) internal view returns (uint16 s) {
        (,, s,,,,,,,,,,) = bondEscalation.disputes(disputeId);
    }

    function _currentBondOf(bytes32 disputeId) internal view returns (uint256 b) {
        (,,, b,,,,,,,,,) = bondEscalation.disputes(disputeId);
    }

    function _accumulatedOf(bytes32 disputeId) internal view returns (uint256 a) {
        (,,,, a,,,,,,,,) = bondEscalation.disputes(disputeId);
    }

    function _livenessEndOf(bytes32 disputeId) internal view returns (uint64 l) {
        (,,,,, l,,,,,,,) = bondEscalation.disputes(disputeId);
    }

    function _disputedAtOf(bytes32 disputeId) internal view returns (uint64 d) {
        (,,,,,, d,,,,,,) = bondEscalation.disputes(disputeId);
    }

    function _lastProposerOf(bytes32 disputeId) internal view returns (address p) {
        (,,,,,,, p,,,,,) = bondEscalation.disputes(disputeId);
    }

    function _resolvedOf(bytes32 disputeId) internal view returns (bool r) {
        (,,,,,,,,, r,,,) = bondEscalation.disputes(disputeId);
    }

    function _originalPoolOf(bytes32 disputeId) internal view returns (uint256 o) {
        (,,,,,,,,,,, o,) = bondEscalation.disputes(disputeId);
    }

    function _tierOf(bytes32 disputeId) internal view returns (uint8 t) {
        (,,,,,,,, t,,,,) = bondEscalation.disputes(disputeId);
    }

    function _winnerPaidOf(bytes32 disputeId) internal view returns (bool w) {
        (,,,,,,,,,, w,,) = bondEscalation.disputes(disputeId);
    }
}
