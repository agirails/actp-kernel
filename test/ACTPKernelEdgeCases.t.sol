// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ACTPKernel.sol";
import "../src/tokens/MockUSDC.sol";
import "../src/escrow/EscrowVault.sol";

/**
 * @title ACTPKernelEdgeCasesTest
 * @notice Comprehensive edge case tests to increase branch coverage to 80%+
 */
contract ACTPKernelEdgeCasesTest is Test {
    ACTPKernel kernel;
    MockUSDC usdc;
    EscrowVault escrow;

    address admin = address(this);
    address requester = address(0x1);
    address provider = address(0x2);
    address feeCollector = address(0xFEE);

    uint256 constant ONE_USDC = 1_000_000;

    function setUp() external {
        kernel = new ACTPKernel(admin, admin, feeCollector);
        usdc = new MockUSDC();
        escrow = new EscrowVault(address(usdc), address(kernel));
        kernel.approveEscrowVault(address(escrow), true);
        usdc.mint(requester, 10_000_000);
    }

    // ============================================
    // EDGE CASE TESTS: Amount Boundaries
    // ============================================

    function testMinTransactionAmountAccepted() external {
        bytes32 txId = keccak256("min_amount");
        uint256 minAmount = kernel.MIN_TRANSACTION_AMOUNT();

        vm.prank(requester);
        kernel.createTransaction(txId, provider, minAmount, keccak256("service"), block.timestamp + 7 days);

        IACTPKernel.TransactionView memory txn = kernel.getTransaction(txId);
        assertEq(txn.amount, minAmount);
    }

    function testBelowMinTransactionAmountReverts() external {
        bytes32 txId = keccak256("below_min");
        uint256 belowMin = kernel.MIN_TRANSACTION_AMOUNT() - 1;

        vm.prank(requester);
        vm.expectRevert("Amount below minimum");
        kernel.createTransaction(txId, provider, belowMin, keccak256("service"), block.timestamp + 7 days);
    }

    function testMaxTransactionAmountAccepted() external {
        bytes32 txId = keccak256("max_amount");
        uint256 maxAmount = kernel.MAX_TRANSACTION_AMOUNT();

        usdc.mint(requester, maxAmount); // Mint enough

        vm.prank(requester);
        kernel.createTransaction(txId, provider, maxAmount, keccak256("service"), block.timestamp + 7 days);

        IACTPKernel.TransactionView memory txn = kernel.getTransaction(txId);
        assertEq(txn.amount, maxAmount);
    }

    function testAboveMaxTransactionAmountReverts() external {
        bytes32 txId = keccak256("above_max");
        uint256 aboveMax = kernel.MAX_TRANSACTION_AMOUNT() + 1;

        vm.prank(requester);
        vm.expectRevert("Amount exceeds maximum");
        kernel.createTransaction(txId, provider, aboveMax, keccak256("service"), block.timestamp + 7 days);
    }

    // ============================================
    // EDGE CASE TESTS: Deadline Boundaries
    // ============================================

    function testDeadlineExactly1YearAccepted() external {
        bytes32 txId = keccak256("1year_deadline");
        uint256 deadline = block.timestamp + kernel.MAX_DEADLINE();

        vm.prank(requester);
        kernel.createTransaction(txId, provider, ONE_USDC, keccak256("service"), deadline);

        IACTPKernel.TransactionView memory txn = kernel.getTransaction(txId);
        assertEq(txn.deadline, deadline);
    }

    function testDeadlineOver1YearReverts() external {
        bytes32 txId = keccak256("over_1year");
        uint256 deadline = block.timestamp + kernel.MAX_DEADLINE() + 1;

        vm.prank(requester);
        vm.expectRevert("Deadline too far");
        kernel.createTransaction(txId, provider, ONE_USDC, keccak256("service"), deadline);
    }

    function testDeadlineInPastReverts() external {
        bytes32 txId = keccak256("past_deadline");
        uint256 deadline = block.timestamp - 1;

        vm.prank(requester);
        vm.expectRevert("Deadline in past");
        kernel.createTransaction(txId, provider, ONE_USDC, keccak256("service"), deadline);
    }

    // ============================================
    // EDGE CASE TESTS: Provider Cancel Scenarios
    // ============================================

    function testProviderCanCancelFromCommittedImmediately() external {
        bytes32 txId = _createAndCommit();

        // Provider cancels immediately (no deadline wait)
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, "");

        IACTPKernel.TransactionView memory txn = kernel.getTransaction(txId);
        assertEq(uint8(txn.state), uint8(IACTPKernel.State.CANCELLED));

        // Requester gets full refund
        assertEq(usdc.balanceOf(requester), 10_000_000);
    }

    function testProviderCanCancelFromInProgressImmediately() external {
        bytes32 txId = _createAndCommit();

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");

        // Provider cancels from IN_PROGRESS (voluntary)
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, "");

        IACTPKernel.TransactionView memory txn = kernel.getTransaction(txId);
        assertEq(uint8(txn.state), uint8(IACTPKernel.State.CANCELLED));
    }

    function testRequesterCannotCancelFromCommittedBeforeDeadline() external {
        bytes32 txId = _createAndCommit();

        // Requester tries to cancel before deadline
        vm.prank(requester);
        vm.expectRevert("Deadline not reached");
        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, "");
    }

    function testRequesterCanCancelFromCommittedAfterDeadline() external {
        bytes32 txId = keccak256("short_deadline");
        vm.prank(requester);
        kernel.createTransaction(txId, provider, ONE_USDC, keccak256("service"), block.timestamp + 1 days);

        vm.startPrank(requester);
        usdc.approve(address(escrow), ONE_USDC);
        kernel.linkEscrow(txId, address(escrow), keccak256("escrow"));
        vm.stopPrank();

        // Warp past deadline
        vm.warp(block.timestamp + 2 days);

        // Requester can now cancel
        vm.prank(requester);
        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, "");

        IACTPKernel.TransactionView memory txn = kernel.getTransaction(txId);
        assertEq(uint8(txn.state), uint8(IACTPKernel.State.CANCELLED));
    }

    // ============================================
    // EDGE CASE TESTS: Dispute Window Boundaries
    // ============================================

    function testDisputeWindowExactlyAtMinimum() external {
        bytes32 txId = _createAndCommit();

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");

        uint256 minWindow = kernel.MIN_DISPUTE_WINDOW();
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(minWindow));

        IACTPKernel.TransactionView memory txn = kernel.getTransaction(txId);
        assertEq(txn.disputeWindow, block.timestamp + minWindow);
    }

    function testDisputeWindowBelowMinimumReverts() external {
        bytes32 txId = _createAndCommit();

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");

        uint256 belowMin = kernel.MIN_DISPUTE_WINDOW() - 1;
        vm.prank(provider);
        vm.expectRevert("Dispute window too short");
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(belowMin));
    }

    function testDisputeWindowZeroUsesDefault() external {
        bytes32 txId = _createAndCommit();

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(0));

        IACTPKernel.TransactionView memory txn = kernel.getTransaction(txId);
        assertEq(txn.disputeWindow, block.timestamp + kernel.DEFAULT_DISPUTE_WINDOW());
    }

    // ============================================
    // EDGE CASE TESTS: Milestone Release
    // ============================================

    function testMilestoneReleaseExactRemaining() external {
        bytes32 txId = _createAndCommit();

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");

        // Release EXACT remaining amount
        vm.prank(requester);
        kernel.releaseMilestone(txId, ONE_USDC);

        // Should succeed - escrow fully depleted
        assertEq(escrow.remaining(keccak256("escrow")), 0);
    }

    function testMilestoneReleaseOneWeiOverReverts() external {
        bytes32 txId = _createAndCommit();

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");

        // Try to release 1 wei more than available
        vm.prank(requester);
        vm.expectRevert("Insufficient escrow");
        kernel.releaseMilestone(txId, ONE_USDC + 1);
    }

    function testMilestoneReleaseZeroReverts() external {
        bytes32 txId = _createAndCommit();

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");

        vm.prank(requester);
        vm.expectRevert("Amount zero");
        kernel.releaseMilestone(txId, 0);
    }

    function testMilestoneReleaseFromWrongStateReverts() external {
        bytes32 txId = _createAndCommit();

        // Try from COMMITTED (not IN_PROGRESS)
        vm.prank(requester);
        vm.expectRevert("Not in progress");
        kernel.releaseMilestone(txId, ONE_USDC / 2);
    }

    function testMultipleMilestoneReleases() external {
        bytes32 txId = _createAndCommit();

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");

        // Release 25%
        vm.prank(requester);
        kernel.releaseMilestone(txId, ONE_USDC / 4);

        // Release another 25%
        vm.prank(requester);
        kernel.releaseMilestone(txId, ONE_USDC / 4);

        // Release remaining 50%
        vm.prank(requester);
        kernel.releaseMilestone(txId, ONE_USDC / 2);

        // Escrow should be fully depleted
        assertEq(escrow.remaining(keccak256("escrow")), 0);
    }

    // ============================================
    // EDGE CASE TESTS: Economic Parameters
    // ============================================

    function testEconomicParamScheduleAtMaxCap() external {
        uint16 maxFee = uint16(kernel.MAX_PLATFORM_FEE_CAP());
        uint16 maxPenalty = uint16(kernel.MAX_REQUESTER_PENALTY_CAP());

        kernel.scheduleEconomicParams(maxFee, maxPenalty);

        (uint16 pendingFee, uint16 pendingPenalty, , bool active) = kernel.getPendingEconomicParams();
        assertTrue(active);
        assertEq(pendingFee, maxFee);
        assertEq(pendingPenalty, maxPenalty);
    }

    function testEconomicParamZeroFeeAllowed() external {
        kernel.scheduleEconomicParams(0, 500);

        (uint16 pendingFee, , , bool active) = kernel.getPendingEconomicParams();
        assertTrue(active);
        assertEq(pendingFee, 0);
    }

    function testEconomicParamZeroPenaltyAllowed() external {
        kernel.scheduleEconomicParams(100, 0);

        (, uint16 pendingPenalty, , bool active) = kernel.getPendingEconomicParams();
        assertTrue(active);
        assertEq(pendingPenalty, 0);
    }

    // ============================================
    // EDGE CASE TESTS: Dispute Resolution Splits
    // ============================================

    function testDisputeResolutionFullRefundToRequester() external {
        bytes32 txId = _createCommitDeliver();

        vm.prank(requester);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");

        // Admin awards 100% to requester
        bytes memory resolution = abi.encode(ONE_USDC, 0); // requester gets all, provider gets 0
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, resolution);

        assertEq(usdc.balanceOf(requester), 10_000_000); // Full refund
        assertEq(usdc.balanceOf(provider), 0);
    }

    function testDisputeResolutionFullPayoutToProvider() external {
        bytes32 txId = _createCommitDeliver();

        vm.prank(requester);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");

        // Admin awards 100% to provider (minus fee)
        bytes memory resolution = abi.encode(0, ONE_USDC); // requester gets 0, provider gets all
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, resolution);

        uint256 fee = (ONE_USDC * kernel.platformFeeBps()) / kernel.MAX_BPS();
        assertEq(usdc.balanceOf(provider), ONE_USDC - fee);
        assertEq(usdc.balanceOf(requester), 10_000_000 - ONE_USDC);
    }

    function testDisputeResolutionWithMediatorMaxFee() external {
        bytes32 txId = _createCommitDeliver();

        vm.prank(requester);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");

        address mediator = address(0x99);
        kernel.approveMediator(mediator, true);
        vm.warp(block.timestamp + 2 days + 1);

        // Mediator gets MAX fee (10% of transaction amount)
        uint256 maxMediatorFee = (ONE_USDC * kernel.MAX_MEDIATOR_FEE_BPS()) / kernel.MAX_BPS();
        uint256 providerAward = ONE_USDC / 2;
        uint256 requesterAward = ONE_USDC - providerAward - maxMediatorFee;

        bytes memory resolution = abi.encode(requesterAward, providerAward, mediator, maxMediatorFee);
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, resolution);

        assertEq(usdc.balanceOf(mediator), maxMediatorFee);
    }

    function testDisputeResolutionMediatorOverMaxReverts() external {
        bytes32 txId = _createCommitDeliver();

        vm.prank(requester);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");

        address mediator = address(0x99);
        kernel.approveMediator(mediator, true);
        vm.warp(block.timestamp + 2 days + 1);

        // Try to give mediator MORE than 10%
        // H-2 FIX: Must distribute exactly ONE_USDC to reach mediator check
        uint256 overMaxFee = (ONE_USDC * kernel.MAX_MEDIATOR_FEE_BPS()) / kernel.MAX_BPS() + 1;
        uint256 providerAmount = ONE_USDC / 2;
        uint256 requesterAmount = ONE_USDC - providerAmount - overMaxFee;
        bytes memory resolution = abi.encode(requesterAmount, providerAmount, mediator, overMaxFee);

        vm.expectRevert("Mediator fee exceeds maximum");
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, resolution);
    }

    // ============================================
    // Helper Functions
    // ============================================

    function _createAndCommit() internal returns (bytes32 txId) {
        txId = keccak256(abi.encodePacked("tx", block.timestamp));
        vm.prank(requester);
        kernel.createTransaction(txId, provider, ONE_USDC, keccak256("service"), block.timestamp + 7 days);

        vm.startPrank(requester);
        usdc.approve(address(escrow), ONE_USDC);
        kernel.linkEscrow(txId, address(escrow), keccak256("escrow"));
        vm.stopPrank();
    }

    function _createCommitDeliver() internal returns (bytes32 txId) {
        txId = _createAndCommit();

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(1 days));
    }
}
