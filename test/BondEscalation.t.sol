// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/DisputeTestBase.sol";
import {AIRuling} from "../src/interfaces/DisputeTypes.sol";

/// @title BondEscalationTest — AIP-14b Tier-0/1/2 lifecycle coverage.
/// @notice Exercises the full bond-escalation game against a real ACTPKernel + EscrowVault +
///         CompositeMediator, plus the Tier-2 UMA bridge via an injected MockOOV3.
///
///         UMA testability: BondEscalation's `UMA_OOV3` was changed from a hardcoded `internal
///         constant` to a constructor-set `immutable` (defaults to the canonical Base-mainnet
///         address when the arg is zero). The base harness injects a `MockOOV3` so Tier-2
///         assertTruth bond custody + resolved/disputed callbacks are exercised end-to-end WITHOUT
///         vm.etch — the mock retains its assertion storage (needed for callback dispatch) and does
///         real bond `transferFrom`, so solvency assertions reflect on-chain reality.
contract BondEscalationTest is DisputeTestBase {
    // --- escrow / bond constants for a 1,000 USDC escrow (1e9 units) ---
    uint256 internal constant ESCROW = TRANSACTION_AMOUNT; // 1e9
    uint256 internal constant INITIAL_BOND = 20_000_000; // (1e9 * 200) / 10000 = $20
    uint64 internal constant LIVENESS = 4 hours; // escrow in [500M, 5B)
    uint256 internal constant MAX_BOND = 500_000_000; // $500 ceiling

    // Mirror events for vm.expectEmit.
    event DisputeOpened(bytes32 indexed disputeId, bytes32 indexed txId, uint256 escrowAmount, address opener);

    function setUp() external {
        _setUpStack();
    }

    // =====================================================================
    // openDispute
    // =====================================================================
    function test_OpenDispute_Succeeds() external {
        bytes32 txId = _createDisputed();
        bytes32 expectedId = keccak256(abi.encode("ACTP_DISPUTE_V1", txId));

        vm.expectEmit(true, true, false, true, address(bondEscalation));
        emit DisputeOpened(expectedId, txId, ESCROW, address(this));

        bytes32 disputeId = bondEscalation.openDispute(txId);
        assertEq(disputeId, expectedId, "disputeId mismatch");

        assertEq(_txIdOf(disputeId), txId);
        assertGt(_disputedAtOf(disputeId), 0, "disputedAt not set");
        assertEq(_tierOf(disputeId), 0, "tier should be 0");
        assertEq(_escrowAmountOf(disputeId), ESCROW, "escrow cached wrong");
    }

    function test_OpenDispute_RevertsIfAlreadyOpened() external {
        bytes32 txId = _createDisputed();
        bondEscalation.openDispute(txId);
        vm.expectRevert("Already opened");
        bondEscalation.openDispute(txId);
    }

    function test_OpenDispute_RevertsIfNotDisputed() external {
        // Create a tx but leave it pre-DISPUTED.
        vm.prank(requester);
        bytes32 txId = kernel.createTransaction(
            provider, requester, TRANSACTION_AMOUNT, block.timestamp + 30 days, 2 days, keccak256("svc2"), 0, 0
        );
        vm.expectRevert("Not in DISPUTED state");
        bondEscalation.openDispute(txId);
    }

    // =====================================================================
    // proposeDirectly + bond custody
    // =====================================================================
    function test_ProposeDirectly_BondsAndTransitionsToTier1() external {
        bytes32 disputeId = _opened();

        uint256 beforeBal = usdc.balanceOf(keeper);
        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), INITIAL_BOND);
        bondEscalation.proposeDirectly(disputeId, 0, 0);
        vm.stopPrank();

        assertEq(beforeBal - usdc.balanceOf(keeper), INITIAL_BOND, "bond not pulled");
        assertEq(usdc.balanceOf(address(bondEscalation)), INITIAL_BOND, "contract didn't custody bond");

        assertEq(_tierOf(disputeId), 1, "should be tier 1");
        assertEq(_currentBondOf(disputeId), INITIAL_BOND);
        assertEq(_accumulatedOf(disputeId), INITIAL_BOND);
        assertEq(_splitBpsOf(disputeId), 0);
        assertEq(_lastProposerOf(disputeId), keeper);
        assertEq(_livenessEndOf(disputeId), uint64(block.timestamp) + LIVENESS);
    }

    function test_ProposeDirectly_RevertsIfAlreadyProposed() external {
        bytes32 disputeId = _opened();
        _propose(disputeId, keeper, 0, 0);
        vm.startPrank(rando);
        usdc.approve(address(bondEscalation), INITIAL_BOND);
        vm.expectRevert("Already has proposal");
        bondEscalation.proposeDirectly(disputeId, 1, 0);
        vm.stopPrank();
    }

    function test_ProposeDirectly_RevertsInvalidRuling() external {
        bytes32 disputeId = _opened();
        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), INITIAL_BOND);
        vm.expectRevert("Invalid ruling");
        bondEscalation.proposeDirectly(disputeId, 3, 0);
        vm.stopPrank();
    }

    // =====================================================================
    // submitAIRuling — 2/3 valid EIP-712 sigs and variants
    // =====================================================================
    function test_SubmitAIRuling_TwoOfThreeValid_Succeeds() external {
        bytes32 disputeId = _opened();
        AIRuling memory r = _ruling(disputeId, 0, 0);

        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signRuling(r, fixed0Pk);
        sigs[1] = _signRuling(r, fixed1Pk);

        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), INITIAL_BOND);
        bondEscalation.submitAIRuling(disputeId, r, sigs);
        vm.stopPrank();

        assertEq(_tierOf(disputeId), 1, "AI ruling should enter tier 1");
        assertEq(_currentBondOf(disputeId), INITIAL_BOND);
    }

    /// @notice 2 valid (fixed0 + rotating0) + 1 unknown signer still passes (>= 2 valid).
    function test_SubmitAIRuling_OneUnknownStillPasses() external {
        bytes32 disputeId = _opened();
        AIRuling memory r = _ruling(disputeId, 0, 0);

        (, uint256 strangerPk) = makeAddrAndKey("stranger");
        bytes[] memory sigs = new bytes[](3);
        sigs[0] = _signRuling(r, fixed0Pk); // valid fixed
        sigs[1] = _signRuling(r, rotating0Pk); // valid rotating (pool len 1 → always selected)
        sigs[2] = _signRuling(r, strangerPk); // unknown — ignored

        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), INITIAL_BOND);
        bondEscalation.submitAIRuling(disputeId, r, sigs);
        vm.stopPrank();

        assertEq(_tierOf(disputeId), 1);
    }

    /// @notice A stale ruling (timestamp older than RULING_FRESHNESS) is rejected.
    function test_SubmitAIRuling_Stale_Reverts() external {
        bytes32 disputeId = _opened();
        AIRuling memory r = _ruling(disputeId, 0, 0);
        r.timestamp = uint64(block.timestamp); // sign at now

        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signRuling(r, fixed0Pk);
        sigs[1] = _signRuling(r, fixed1Pk);

        // Advance beyond RULING_FRESHNESS (1 hour).
        vm.warp(block.timestamp + 1 hours + 1);

        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), INITIAL_BOND);
        vm.expectRevert("Ruling stale");
        bondEscalation.submitAIRuling(disputeId, r, sigs);
        vm.stopPrank();
    }

    /// @notice The same signer counted twice does NOT reach the 2-valid threshold (dedup via `seen`).
    function test_SubmitAIRuling_DuplicateSignerCountsOnce_Reverts() external {
        bytes32 disputeId = _opened();
        AIRuling memory r = _ruling(disputeId, 0, 0);

        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signRuling(r, fixed0Pk);
        sigs[1] = _signRuling(r, fixed0Pk); // same signer again — counted once

        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), INITIAL_BOND);
        vm.expectRevert("Insufficient valid signatures");
        bondEscalation.submitAIRuling(disputeId, r, sigs);
        vm.stopPrank();
    }

    // =====================================================================
    // challenge — doubling, cap, requires-different
    // =====================================================================
    function test_Challenge_DoublesBond() external {
        bytes32 disputeId = _opened();
        _propose(disputeId, keeper, 0, 0); // bond 20M, ruling 0

        // Challenger flips to ruling 1, bond doubles to 40M.
        vm.startPrank(rando);
        usdc.approve(address(bondEscalation), INITIAL_BOND * 2);
        bondEscalation.challenge(disputeId, 1, 0);
        vm.stopPrank();

        assertEq(_currentBondOf(disputeId), INITIAL_BOND * 2, "bond did not double");
        assertEq(_accumulatedOf(disputeId), INITIAL_BOND + INITIAL_BOND * 2, "accumulated wrong");
        assertEq(_lastProposerOf(disputeId), rando);
        assertEq(_splitBpsOf(disputeId), 0);
    }

    function test_Challenge_RequiresDifferentOutcome() external {
        bytes32 disputeId = _opened();
        _propose(disputeId, keeper, 0, 0);

        vm.startPrank(rando);
        usdc.approve(address(bondEscalation), INITIAL_BOND * 2);
        vm.expectRevert("Must propose different outcome");
        bondEscalation.challenge(disputeId, 0, 0); // same ruling
        vm.stopPrank();
    }

    function test_Challenge_BondCapsAtMax() external {
        bytes32 disputeId = _opened();
        _escalateBondToCeiling(disputeId);

        assertEq(_currentBondOf(disputeId), MAX_BOND, "bond should be capped at MAX");
    }

    // =====================================================================
    // finalize — bounty BEFORE winner, mediator.resolve → kernel state
    // =====================================================================

    /// @notice Winner-takes-all (ruling 0): bounty to finalizer first, remaining pool to last
    ///         proposer, kernel → SETTLED.
    function test_Finalize_WinnerTakesAll_ProviderWins_Settled() external {
        bytes32 disputeId = _opened();
        bytes32 txId = _txIdOf(disputeId);
        _propose(disputeId, keeper, 0, 0); // ruling 0 → provider wins

        uint256 pool = INITIAL_BOND;
        uint256 expectedBounty = (pool * 1000) / 10000; // 10% = 2M
        uint256 expectedPayout = pool - expectedBounty;

        // Advance past liveness, finalize as rando (the finalizer/keeper getting the bounty).
        vm.warp(block.timestamp + LIVENESS + 1);

        uint256 finalizerBefore = usdc.balanceOf(rando);
        uint256 winnerBefore = usdc.balanceOf(keeper);

        vm.prank(rando);
        bondEscalation.finalize(disputeId);

        assertEq(usdc.balanceOf(rando) - finalizerBefore, expectedBounty, "bounty wrong / not first");
        assertEq(usdc.balanceOf(keeper) - winnerBefore, expectedPayout, "winner payout wrong");
        assertEq(usdc.balanceOf(address(bondEscalation)), 0, "contract should hold no bonds after");

        assertEq(uint8(kernel.getTransaction(txId).state), uint8(IACTPKernel.State.SETTLED), "kernel not SETTLED");

        assertTrue(_resolvedOf(disputeId));
        assertTrue(_winnerPaidOf(disputeId));
    }

    /// @notice ruling 1 (requester wins) also → SETTLED via the kernel.
    function test_Finalize_RequesterWins_Settled() external {
        bytes32 disputeId = _opened();
        bytes32 txId = _txIdOf(disputeId);
        _propose(disputeId, keeper, 1, 0); // ruling 1 → requester wins

        vm.warp(block.timestamp + LIVENESS + 1);
        vm.prank(rando);
        bondEscalation.finalize(disputeId);

        assertEq(uint8(kernel.getTransaction(txId).state), uint8(IACTPKernel.State.SETTLED));
    }

    /// @notice Split (ruling 2): no winner push; kernel → CANCELLED; depositors claim proportionally.
    function test_Finalize_Split_Cancelled_RefundProportional() external {
        bytes32 disputeId = _opened();
        bytes32 txId = _txIdOf(disputeId);

        // keeper proposes split (ruling 2, 50/50): bond 20M.
        _propose(disputeId, keeper, 2, 5000);
        // rando challenges with a different split (ruling 2, 60/40): bond 40M.
        vm.startPrank(rando);
        usdc.approve(address(bondEscalation), INITIAL_BOND * 2);
        bondEscalation.challenge(disputeId, 2, 6000);
        vm.stopPrank();

        uint256 pool = INITIAL_BOND + INITIAL_BOND * 2; // 60M
        uint256 bounty = (pool * 1000) / 10000; // 6M
        uint256 remainingPool = pool - bounty; // 54M

        vm.warp(block.timestamp + LIVENESS + 1);
        vm.prank(address(0xF1));
        // fund the finalizer-as-EOA path: finalize is callable by anyone, bounty goes to caller.
        bondEscalation.finalize(disputeId);

        assertEq(uint8(kernel.getTransaction(txId).state), uint8(IACTPKernel.State.CANCELLED), "kernel not CANCELLED");

        // accumulatedBonds now == remainingPool (post-bounty), originalPool snapshot == remainingPool.
        // keeper deposited 20M, rando deposited 40M → proportional split of the 54M.
        uint256 keeperBefore = usdc.balanceOf(keeper);
        uint256 randoBefore = usdc.balanceOf(rando);

        vm.prank(keeper);
        bondEscalation.claimEscalationRefund(disputeId);
        vm.prank(rando);
        bondEscalation.claimEscalationRefund(disputeId);

        uint256 keeperShare = usdc.balanceOf(keeper) - keeperBefore;
        uint256 randoShare = usdc.balanceOf(rando) - randoBefore;

        // keeper share = 20/60 of 54M = 18M; rando share = 40/60 of 54M = 36M.
        assertEq(keeperShare, (INITIAL_BOND * remainingPool) / pool, "keeper refund not proportional");
        assertEq(randoShare, (INITIAL_BOND * 2 * remainingPool) / pool, "rando refund not proportional");
        assertEq(keeperShare + randoShare, remainingPool, "refunds don't sum to pool");
    }

    function test_Finalize_RevertsIfLivenessActive() external {
        bytes32 disputeId = _opened();
        _propose(disputeId, keeper, 0, 0);
        vm.expectRevert("Liveness active");
        bondEscalation.finalize(disputeId);
    }

    // =====================================================================
    // escalateToUMA + callbacks
    // =====================================================================

    /// @notice Escalation requires the bond ceiling; UMA bond is custodied by the mock (NOT in
    ///         accumulatedBonds); tier → 2; assertion mapping recorded.
    function test_EscalateToUMA_CeilingLivenessCID_BondNotInAccumulated() external {
        bytes32 disputeId = _opened();
        _escalateBondToCeiling(disputeId);

        uint256 accumulatedBefore = _accumulatedOf(disputeId);

        // Escalator posts the UMA bond ($500).
        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), 500_000_000);
        bondEscalation.escalateToUMA(disputeId, "QmEvidenceCID");
        vm.stopPrank();

        assertEq(_tierOf(disputeId), 2, "should be tier 2");
        assertEq(_accumulatedOf(disputeId), accumulatedBefore, "UMA bond MUST NOT be added to accumulatedBonds");

        bytes32 assertionId = bondEscalation.disputeToAssertion(disputeId);
        assertTrue(assertionId != bytes32(0), "assertion not recorded");
        assertEq(bondEscalation.assertionToDispute(assertionId), disputeId, "reverse mapping wrong");

        // The mock OOV3 actually custodies the $500 bond.
        assertEq(usdc.balanceOf(address(oov3)), 500_000_000, "mock OOV3 didn't custody UMA bond");
    }

    function test_EscalateToUMA_RevertsIfBelowCeiling() external {
        bytes32 disputeId = _opened();
        _propose(disputeId, keeper, 0, 0); // bond only 20M

        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), 500_000_000);
        vm.expectRevert("Bond ceiling not reached");
        bondEscalation.escalateToUMA(disputeId, "QmEvidenceCID");
        vm.stopPrank();
    }

    function test_EscalateToUMA_RevertsWithoutCID() external {
        bytes32 disputeId = _opened();
        _escalateBondToCeiling(disputeId);
        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), 500_000_000);
        vm.expectRevert("Evidence CID required");
        bondEscalation.escalateToUMA(disputeId, "");
        vm.stopPrank();
    }

    /// @notice assertionResolvedCallback (TRUE → ruling 0 / provider wins). Winner by direction is
    ///         the escalator (set lastProposerForRuling[0] = escalator). Tier-1 pool pays the winner;
    ///         kernel → SETTLED.
    function test_UMA_ResolvedTrue_ProviderWins_Settled() external {
        bytes32 disputeId = _opened();
        bytes32 txId = _txIdOf(disputeId);
        _escalateBondToCeiling(disputeId);

        // Snapshot the accumulated tier-1 pool — the escalator becomes winner for ruling 0.
        uint256 pool = _accumulatedOf(disputeId);

        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), 500_000_000);
        bondEscalation.escalateToUMA(disputeId, "QmEvidenceCID");
        vm.stopPrank();

        bytes32 assertionId = bondEscalation.disputeToAssertion(disputeId);

        uint256 winnerBefore = usdc.balanceOf(keeper);
        // Drive the mock to resolve TRUE → fires assertionResolvedCallback AS the OOV3.
        oov3.mockResolve(assertionId, true);

        // keeper (escalator = winner for ruling 0) receives the tier-1 pool.
        assertEq(usdc.balanceOf(keeper) - winnerBefore, pool, "winner didn't receive tier-1 pool");
        assertEq(uint8(kernel.getTransaction(txId).state), uint8(IACTPKernel.State.SETTLED), "kernel not SETTLED");

        assertTrue(_resolvedOf(disputeId));
        assertTrue(_winnerPaidOf(disputeId));
        assertEq(_splitBpsOf(disputeId), 0);
    }

    /// @notice assertionResolvedCallback (FALSE → ruling 1 / requester wins). The escalator only set
    ///         the winner for ruling 0, so ruling 1 has no proposer → graceful split fallback
    ///         (CANCELLED). Proves the no-winner branch.
    function test_UMA_ResolvedFalse_NoWinnerForDirection_SplitFallback() external {
        bytes32 disputeId = _opened();
        bytes32 txId = _txIdOf(disputeId);
        // counterRuling 2 → ruling 1 is NEVER proposed, so FALSE (ruling 1) has no tier-1 winner.
        _escalateBondToCeiling(disputeId, 2);

        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), 500_000_000);
        bondEscalation.escalateToUMA(disputeId, "QmEvidenceCID");
        vm.stopPrank();

        bytes32 assertionId = bondEscalation.disputeToAssertion(disputeId);
        oov3.mockResolve(assertionId, false); // ruling 1 → no lastProposerForRuling[1]

        // Fallback to split → kernel CANCELLED.
        assertEq(uint8(kernel.getTransaction(txId).state), uint8(IACTPKernel.State.CANCELLED), "kernel not CANCELLED");

        assertTrue(_resolvedOf(disputeId));
        assertFalse(_winnerPaidOf(disputeId), "no winner should have been paid");
        assertEq(_splitBpsOf(disputeId), 5000, "split fallback should be 50/50");
    }

    /// @notice onlyUMA guard: a non-OOV3 caller cannot fire the resolved callback.
    function test_UMA_ResolvedCallback_OnlyUMA() external {
        bytes32 disputeId = _opened();
        _escalateBondToCeiling(disputeId);
        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), 500_000_000);
        bondEscalation.escalateToUMA(disputeId, "QmEvidenceCID");
        vm.stopPrank();

        bytes32 assertionId = bondEscalation.disputeToAssertion(disputeId);
        vm.prank(rando);
        vm.expectRevert("Only UMA");
        bondEscalation.assertionResolvedCallback(assertionId, true);
    }

    /// @notice Graceful no-op: if the dispute was already resolved (stale path) before UMA's
    ///         callback arrives, the callback returns without reverting and without double-paying.
    function test_UMA_ResolvedCallback_GracefulNoOpAfterStale() external {
        bytes32 disputeId = _opened();
        _escalateBondToCeiling(disputeId);
        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), 500_000_000);
        bondEscalation.escalateToUMA(disputeId, "QmEvidenceCID");
        vm.stopPrank();

        bytes32 assertionId = bondEscalation.disputeToAssertion(disputeId);

        // Force-resolve as stale (30-day fallback) BEFORE UMA replies.
        vm.warp(block.timestamp + 30 days + 1);
        bondEscalation.forceResolveStale(disputeId);
        assertTrue(_resolvedOf(disputeId));

        // UMA's late callback must be a graceful no-op (no revert, no extra payout).
        uint256 contractBalBefore = usdc.balanceOf(address(bondEscalation));
        oov3.mockResolve(assertionId, true);
        assertEq(usdc.balanceOf(address(bondEscalation)), contractBalBefore, "stale callback paid out");
    }

    /// @notice assertionDisputedCallback: onlyUMA, emits, no state change (resolution still pending).
    function test_UMA_DisputedCallback_OnlyUMA_AndNoOp() external {
        bytes32 disputeId = _opened();
        _escalateBondToCeiling(disputeId);
        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), 500_000_000);
        bondEscalation.escalateToUMA(disputeId, "QmEvidenceCID");
        vm.stopPrank();

        bytes32 assertionId = bondEscalation.disputeToAssertion(disputeId);

        // Non-UMA caller rejected.
        vm.prank(rando);
        vm.expectRevert("Only UMA");
        bondEscalation.assertionDisputedCallback(assertionId);

        // UMA dispute callback: still tier 2, unresolved, just escalated to DVM.
        oov3.mockDispute(assertionId);
        assertEq(_tierOf(disputeId), 2, "should remain tier 2");
        assertFalse(_resolvedOf(disputeId), "dispute callback should not resolve");
    }

    // =====================================================================
    // forceResolveStale (recovery, never pausable)
    // =====================================================================
    function test_ForceResolveStale_Resolves() external {
        bytes32 disputeId = _opened();
        bytes32 txId = _txIdOf(disputeId);
        _propose(disputeId, keeper, 0, 0);

        vm.warp(block.timestamp + 30 days + 1);
        bondEscalation.forceResolveStale(disputeId);

        assertTrue(_resolvedOf(disputeId));
        assertEq(_splitBpsOf(disputeId), 5000, "stale -> 50/50 split");
        assertEq(uint8(kernel.getTransaction(txId).state), uint8(IACTPKernel.State.CANCELLED), "stale -> CANCELLED");
    }

    function test_ForceResolveStale_RevertsIfNotStale() external {
        bytes32 disputeId = _opened();
        _propose(disputeId, keeper, 0, 0);
        vm.expectRevert("Not stale");
        bondEscalation.forceResolveStale(disputeId);
    }

    // =====================================================================
    // pause gating (recovery paths stay open — INV-9)
    // =====================================================================
    function test_Pause_BlocksProposeButNotFinalize() external {
        bytes32 disputeId = _opened();
        _propose(disputeId, keeper, 0, 0);

        // Open a second (still-unproposed) dispute BEFORE pausing — openDispute is itself pausable.
        bytes32 disputeId2 = _opened2();

        vm.prank(admin);
        bondEscalation.pause();

        // A proposal (pausable path) on the second dispute is blocked while paused.
        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), INITIAL_BOND);
        vm.expectRevert("Paused");
        bondEscalation.proposeDirectly(disputeId2, 0, 0);
        vm.stopPrank();

        // finalize (recovery, INV-9) still works on the first dispute despite pause.
        vm.warp(block.timestamp + LIVENESS + 1);
        vm.prank(rando);
        bondEscalation.finalize(disputeId); // must NOT revert
        assertTrue(_resolvedOf(disputeId), "finalize must work while paused (INV-9)");
    }

    // =====================================================================
    // Internal helpers — typed accessors over the `disputes` public getter (13-tuple).
    // =====================================================================
    function _txIdOf(bytes32 disputeId) internal view returns (bytes32 t) {
        (t,,,,,,,,,,,,) = bondEscalation.disputes(disputeId);
    }

    function _tierOf(bytes32 disputeId) internal view returns (uint8 tier) {
        (,,,,,,,, tier,,,,) = bondEscalation.disputes(disputeId);
    }

    function _currentBondOf(bytes32 disputeId) internal view returns (uint256 b) {
        (,,, b,,,,,,,,,) = bondEscalation.disputes(disputeId);
    }

    function _accumulatedOf(bytes32 disputeId) internal view returns (uint256 a) {
        (,,,, a,,,,,,,,) = bondEscalation.disputes(disputeId);
    }

    function _splitBpsOf(bytes32 disputeId) internal view returns (uint16 s) {
        (,, s,,,,,,,,,,) = bondEscalation.disputes(disputeId);
    }

    function _lastProposerOf(bytes32 disputeId) internal view returns (address p) {
        (,,,,,,, p,,,,,) = bondEscalation.disputes(disputeId);
    }

    function _resolvedOf(bytes32 disputeId) internal view returns (bool r) {
        (,,,,,,,,, r,,,) = bondEscalation.disputes(disputeId);
    }

    function _winnerPaidOf(bytes32 disputeId) internal view returns (bool w) {
        (,,,,,,,,,, w,,) = bondEscalation.disputes(disputeId);
    }

    function _livenessEndOf(bytes32 disputeId) internal view returns (uint64 l) {
        (,,,,, l,,,,,,,) = bondEscalation.disputes(disputeId);
    }

    function _disputedAtOf(bytes32 disputeId) internal view returns (uint64 d) {
        (,,,,,, d,,,,,,) = bondEscalation.disputes(disputeId);
    }

    function _escrowAmountOf(bytes32 disputeId) internal view returns (uint256 e) {
        (,,,,,,,,,,,, e) = bondEscalation.disputes(disputeId);
    }

    function _opened() internal returns (bytes32 disputeId) {
        bytes32 txId = _createDisputed();
        disputeId = bondEscalation.openDispute(txId);
    }

    /// @dev A second independent dispute for pause tests (distinct service hash → distinct txId).
    function _opened2() internal returns (bytes32 disputeId) {
        vm.prank(requester);
        bytes32 txId = kernel.createTransaction(
            provider, requester, TRANSACTION_AMOUNT, block.timestamp + 30 days, 2 days, keccak256("service2"), 0, 0
        );
        vm.startPrank(requester);
        usdc.approve(address(escrow), TRANSACTION_AMOUNT);
        kernel.linkEscrow(txId, address(escrow), txId);
        vm.stopPrank();
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(10 days));
        uint256 bond = (TRANSACTION_AMOUNT * kernel.disputeBondBps()) / kernel.MAX_BPS();
        vm.startPrank(requester);
        usdc.approve(address(escrow), bond);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");
        vm.stopPrank();
        disputeId = bondEscalation.openDispute(txId);
    }

    function _propose(bytes32 disputeId, address who, uint8 ruling, uint16 splitBps) internal {
        vm.startPrank(who);
        usdc.approve(address(bondEscalation), INITIAL_BOND);
        bondEscalation.proposeDirectly(disputeId, ruling, splitBps);
        vm.stopPrank();
    }

    /// @dev Propose then challenge 6 times so currentBond reaches the $500 ceiling.
    ///      20M -> 40 -> 80 -> 160 -> 320 -> 640(cap 500) -> cap 500. Alternates ruling 0/1 to satisfy
    ///      "must be different". The escalator (keeper) ends as the last proposer for ruling 0, AND
    ///      ruling 1 has a proposer (rando) — so a UMA FALSE (ruling 1) resolution has a winner.
    function _escalateBondToCeiling(bytes32 disputeId) internal {
        _escalateBondToCeiling(disputeId, 1);
    }

    /// @dev Ceiling helper parameterized by the counter-ruling used in challenges.
    ///      counterRuling == 1 → ruling 1 has a proposer (FALSE resolution → winner exists).
    ///      counterRuling == 2 → only rulings 0 and 2 are ever proposed, so ruling 1 has NO
    ///        proposer; a UMA FALSE (ruling 1) resolution then exercises the no-winner split fallback.
    ///      Either way keeper ends as the last proposer for ruling 0 (the escalator direction).
    function _escalateBondToCeiling(bytes32 disputeId, uint8 counterRuling) internal {
        _propose(disputeId, keeper, 0, 0); // currentBond = 20M, ruling 0
        uint256 bond = INITIAL_BOND;
        uint8 ruling = 0;
        // Challenge until currentBond == MAX_BOND. After each challenge bond = min(bond*2, MAX).
        for (uint256 i = 0; i < 6; i++) {
            ruling = ruling == 0 ? counterRuling : 0;
            uint16 split = ruling == 2 ? uint16(5000 + i * 100) : 0; // distinct split each time
            bond = bond * 2;
            if (bond > MAX_BOND) bond = MAX_BOND;
            address who = (i % 2 == 0) ? rando : keeper;
            vm.startPrank(who);
            usdc.approve(address(bondEscalation), bond);
            bondEscalation.challenge(disputeId, ruling, split);
            vm.stopPrank();
        }
        // After 6 challenges ruling alternated counter,0,counter,0,counter,0 → final ruling 0, keeper.
        require(_currentBondOf(disputeId) == MAX_BOND, "ceiling not reached");
        require(_lastProposerOf(disputeId) == keeper, "keeper should be last proposer (ruling 0)");
    }
}
