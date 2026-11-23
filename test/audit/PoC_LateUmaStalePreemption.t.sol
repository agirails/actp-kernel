// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../helpers/DisputeTestBase.sol";

/// @notice H-01/F19 regression (Codex audit 2026-07-16). A dispute can be kept in Tier-1 past the
///         absolute 60-day mark by alternating challenges, then escalated to UMA. Before the fix,
///         `forceResolveStale` (anchored on disputedAt+60d) could pre-empt the fresh assertion
///         IMMEDIATELY and force a 50/50, discarding the real UMA verdict. After the fix the Tier-2
///         backstop is anchored on `escalatedAt + UMA_LIVENESS + TIER2_STALE_GRACE`, so the fresh
///         assertion always gets its full window and a real verdict settles winner-takes-all.
contract PoC_LateUmaStalePreemption is DisputeTestBase {
    uint256 private constant TIER1_LIVENESS = 4 hours;
    uint64 private constant UMA_LIVENESS = 7200; // mirror BondEscalation.UMA_LIVENESS
    uint256 private constant TIER2_GRACE = 30 days; // mirror BondEscalation.TIER2_STALE_GRACE

    function setUp() external {
        _setUpStack();
    }

    /// Drive to Tier-1, hold liveness past day-60 with 361 alternating challenges, escalate to UMA.
    function _lateEscalate()
        internal
        returns (bytes32 txId, bytes32 disputeId, bytes32 assertionId, uint64 escalatedAt)
    {
        txId = _createDisputed();
        disputeId = bondEscalation.openDispute(txId);

        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), type(uint256).max);
        bondEscalation.proposeDirectly(disputeId, 0, 0); // last ruling-0 proposer = keeper
        vm.stopPrank();

        vm.prank(rando);
        usdc.approve(address(bondEscalation), type(uint256).max);

        uint256 challengeTime = block.timestamp;
        for (uint256 i; i < 361; ++i) {
            challengeTime += TIER1_LIVENESS;
            vm.warp(challengeTime);
            if (i % 2 == 0) {
                vm.prank(rando);
                bondEscalation.challenge(disputeId, 1, 0);
            } else {
                vm.prank(keeper);
                bondEscalation.challenge(disputeId, 0, 0);
            }
        }

        (,,,,,, uint64 disputedAt,, uint8 tierBefore,,,,,) = bondEscalation.disputes(disputeId);
        assertEq(tierBefore, 1, "must remain Tier 1 before escalation");
        assertGt(block.timestamp, uint256(disputedAt) + 60 days, "absolute stale threshold not crossed");

        vm.prank(keeper);
        bondEscalation.escalateToUMA(disputeId, "QmLateEvidence", "QmLateReasoning");
        assertionId = bondEscalation.disputeToAssertion(disputeId);
        assertTrue(assertionId != bytes32(0), "UMA assertion not created");

        (,,,,,,,, uint8 tierAfter, bool resolvedBefore,,,, uint64 escAt) = bondEscalation.disputes(disputeId);
        escalatedAt = escAt;
        assertEq(tierAfter, 2, "must enter Tier 2");
        assertFalse(resolvedBefore, "fresh assertion unexpectedly resolved");
        assertEq(uint256(escalatedAt), block.timestamp, "escalatedAt must be set at escalation");
    }

    /// FIX: forceResolveStale REVERTS on the fresh assertion; a real UMA verdict then settles
    /// winner-takes-all (kernel SETTLED, not the 50/50 CANCELLED the stale path forced).
    function test_H01_FreshUMAAssertion_NotPreempted_RealVerdictSettles() external {
        (bytes32 txId, bytes32 disputeId, bytes32 assertionId, uint64 escalatedAt) = _lateEscalate();

        // (1) Immediately after escalation: the backstop is CLOSED (pre-fix this succeeded).
        vm.expectRevert("UMA pending: settle assertion first");
        bondEscalation.forceResolveStale(disputeId);

        // (2) Exactly at the re-anchored boundary: still CLOSED (strict >).
        vm.warp(uint256(escalatedAt) + UMA_LIVENESS + TIER2_GRACE);
        vm.expectRevert("UMA pending: settle assertion first");
        bondEscalation.forceResolveStale(disputeId);

        // (3) The genuine UMA verdict arrives via the permissionless settle path
        //     (TRUE = provider delivered = ruling 0; winner = last ruling-0 proposer = keeper).
        oov3.mockArmResult(assertionId, true);
        uint256 keeperBefore = usdc.balanceOf(keeper);
        bondEscalation.settleUMAAssertion(disputeId);

        assertEq(
            uint8(kernel.getTransaction(txId).state),
            uint8(IACTPKernel.State.SETTLED),
            "real UMA verdict must settle winner-takes-all, not 50/50"
        );

        (, uint8 ruling, uint16 splitBps,,,,,,, bool resolved,,,,) = bondEscalation.disputes(disputeId);
        assertTrue(resolved, "dispute resolved by UMA");
        assertEq(ruling, 0, "ruling must reflect UMA TRUE (provider delivered)");
        assertEq(splitBps, 0, "winner-takes-all, not a 50/50 split");
        assertGt(usdc.balanceOf(keeper), keeperBefore, "Tier-1 pool paid to genuine winner");
    }

    /// The legitimate recovery path is preserved: a genuinely hung assertion (callback never runs)
    /// is still force-resolvable to 50/50 AFTER escalatedAt + UMA_LIVENESS + grace.
    function test_H01_HungAssertion_StaleBackstopStillWorks() external {
        (bytes32 txId, bytes32 disputeId,, uint64 escalatedAt) = _lateEscalate();

        vm.warp(uint256(escalatedAt) + UMA_LIVENESS + TIER2_GRACE + 1); // grace elapsed, no settle
        bondEscalation.forceResolveStale(disputeId);

        assertEq(
            uint8(kernel.getTransaction(txId).state),
            uint8(IACTPKernel.State.CANCELLED),
            "hung-assertion backstop must still 50/50 after the re-anchored grace"
        );
        (,, uint16 splitBps,,,,,,, bool resolved,,,,) = bondEscalation.disputes(disputeId);
        assertTrue(resolved, "backstop latches resolved");
        assertEq(splitBps, 5000, "50/50 recovery split");
    }
}
