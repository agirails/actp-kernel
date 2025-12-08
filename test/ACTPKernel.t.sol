// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ACTPKernel.sol";
import "../src/tokens/MockUSDC.sol";
import "../src/escrow/EscrowVault.sol";

contract ACTPKernelTest is Test {
    ACTPKernel kernel;
    MockUSDC usdc;
    EscrowVault escrow;

    address requester = address(0x1);
    address provider = address(0x2);
    address feeCollector = address(0xFEE);

    uint256 constant ONE_USDC = 1_000_000; // 1 USDC with 6 decimals
    uint256 constant INITIAL_BALANCE = 1_000_000_000;

    function setUp() external {
        usdc = new MockUSDC();
        kernel = new ACTPKernel(address(this), address(this), feeCollector, address(0), address(usdc));
        escrow = new EscrowVault(address(usdc), address(kernel));
        
        // Approve escrow vault (admin is the test contract)
        kernel.approveEscrowVault(address(escrow), true);

        usdc.mint(requester, 1_000_000_000); // seed requester
    }

    // Helpers --------------------------------------------------------------

    function _createBaseTx() internal returns (bytes32 txId) {
        vm.prank(requester);
        txId = kernel.createTransaction(provider, requester, ONE_USDC, block.timestamp + 7 days, 2 days, keccak256("service"));
    }

    function _quote(bytes32 txId) internal {
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.QUOTED, "");
    }

    function _commit(bytes32 txId, bytes32 escrowId, uint256 amount) internal {
        vm.startPrank(requester);
        usdc.approve(address(escrow), amount);
        kernel.linkEscrow(txId, address(escrow), escrowId);
        vm.stopPrank();
    }

    function _deliver(bytes32 txId, uint256 disputeWindow) internal {
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(disputeWindow));
    }

    function _splitAmount(uint256 amount) internal view returns (uint256 providerNet, uint256 fee) {
        fee = (amount * kernel.platformFeeBps()) / kernel.MAX_BPS();
        providerNet = amount - fee;
    }

    // Tests ----------------------------------------------------------------

    function testCreateAndLinkEscrow() external {
        bytes32 txId = _createBaseTx();
        _quote(txId);

        bytes32 escrowId = keccak256("escrow");
        _commit(txId, escrowId, ONE_USDC);

        IACTPKernel.TransactionView memory viewData = kernel.getTransaction(txId);
        assertEq(uint8(viewData.state), uint8(IACTPKernel.State.COMMITTED));
        assertEq(viewData.escrowContract, address(escrow));
    }

    function testNonceBasedIdPreventsCollision() external {
        // With nonce-based ID generation, identical parameters produce DIFFERENT txIds
        // Create first transaction
        vm.prank(requester);
        bytes32 txId1 = kernel.createTransaction(provider, requester, ONE_USDC, block.timestamp + 7 days, 2 days, keccak256("service"));

        // Create second transaction with SAME inputs - should succeed with DIFFERENT txId
        vm.prank(requester);
        bytes32 txId2 = kernel.createTransaction(provider, requester, ONE_USDC, block.timestamp + 7 days, 2 days, keccak256("service"));

        // Verify both transactions exist with different IDs
        assertTrue(txId1 != txId2, "Nonce should produce different IDs");

        IACTPKernel.TransactionView memory tx1 = kernel.getTransaction(txId1);
        IACTPKernel.TransactionView memory tx2 = kernel.getTransaction(txId2);
        assertEq(tx1.amount, ONE_USDC);
        assertEq(tx2.amount, ONE_USDC);
    }

    function testUnauthorizedTransitionReverts() external {
        bytes32 txId = _createBaseTx();

        vm.prank(address(0x999));
        vm.expectRevert(bytes("Only provider"));
        kernel.transitionState(txId, IACTPKernel.State.QUOTED, "");
    }

    function testDisputeFlowResolves() external {
        bytes32 txId = _createBaseTx();
        _quote(txId);

        bytes32 escrowId = keccak256("escrow2");
        _commit(txId, escrowId, ONE_USDC);
        _deliver(txId, 1 days);

        vm.prank(requester);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");

        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, "");
        IACTPKernel.TransactionView memory viewData = kernel.getTransaction(txId);
        assertEq(uint8(viewData.state), uint8(IACTPKernel.State.CANCELLED));
        assertEq(usdc.balanceOf(requester), 1_000_000_000); // refunded
    }

    function testAutoSettleAfterDisputeWindow() external {
        bytes32 txId = _createBaseTx();
        _quote(txId);
        bytes32 escrowId = keccak256("escrow3");
        _commit(txId, escrowId, ONE_USDC);
        _deliver(txId, 6 hours);

        vm.warp(block.timestamp + 6 hours + 1 seconds);
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, "");

        (uint256 providerNet, ) = _splitAmount(ONE_USDC);
        assertEq(usdc.balanceOf(provider), providerNet);
    }

    function testCancelBeforeDeadlineFailsUntilExpired() external {
        // Use a short deadline (1 day) for this test to check cancel behavior
        vm.prank(requester);
        bytes32 txId = kernel.createTransaction(provider, requester, ONE_USDC, block.timestamp + 1 days, 2 days, keccak256("service"));

        _quote(txId);
        bytes32 escrowId = keccak256("escrow4");
        _commit(txId, escrowId, ONE_USDC);

        vm.prank(requester);
        vm.expectRevert(bytes("Deadline not reached"));
        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, "");

        vm.warp(block.timestamp + 2 days);
        vm.prank(requester);
        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, "");
    }

    function testAttestationAnchoring() external {
        bytes32 txId = _createBaseTx();
        _quote(txId);
        bytes32 escrowId = keccak256("escrow5");
        _commit(txId, escrowId, ONE_USDC);
        _deliver(txId, 0);

        vm.prank(requester);
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, "");

        bytes32 attUid = keccak256("att");
        vm.prank(provider);
        kernel.anchorAttestation(txId, attUid);

        IACTPKernel.TransactionView memory viewData = kernel.getTransaction(txId);
        assertEq(viewData.attestationUID, attUid);
    }

    function testPausePreventsTransitions() external {
        bytes32 txId = _createBaseTx();
        kernel.pause();

        vm.expectRevert(bytes("Kernel paused"));
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.QUOTED, "");
    }

    function testPauseRevertsIfAlreadyPaused() external {
        kernel.pause();
        vm.expectRevert(bytes("Already paused"));
        kernel.pause();
    }

    function testUnpauseRevertsIfNotPaused() external {
        vm.expectRevert(bytes("Not paused"));
        kernel.unpause();
    }

    function testSettleTransfersFundsToProvider() external {
        bytes32 txId = _createBaseTx();
        _quote(txId);
        bytes32 escrowId = keccak256("escrow6");
        _commit(txId, escrowId, ONE_USDC);
        _deliver(txId, 0);

        vm.prank(requester);
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, "");
        (uint256 providerNet, ) = _splitAmount(ONE_USDC);
        assertEq(usdc.balanceOf(provider), providerNet);
    }

    function testMilestoneReleasePaysProviderAndFee() external {
        bytes32 txId = _createBaseTx();
        _quote(txId);
        bytes32 escrowId = keccak256("escrowMilestone");
        _commit(txId, escrowId, ONE_USDC);

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");

        uint256 milestoneAmount = ONE_USDC / 2;
        vm.prank(requester);
        kernel.releaseMilestone(txId, milestoneAmount);

        (uint256 providerNet, uint256 fee) = _splitAmount(milestoneAmount);
        assertEq(usdc.balanceOf(provider), providerNet);
        assertEq(usdc.balanceOf(feeCollector), fee);
    }

    function testMilestoneReleaseCannotExceedRemaining() external {
        bytes32 txId = _createBaseTx();
        _quote(txId);
        bytes32 escrowId = keccak256("escrowMilestoneOverflow");
        _commit(txId, escrowId, ONE_USDC);

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");

        vm.prank(requester);
        vm.expectRevert(bytes("Insufficient escrow"));
        kernel.releaseMilestone(txId, ONE_USDC + 1);
    }

    function testRequesterCancellationPenaltyDistribution() external {
        bytes32 txId = _createBaseTx();
        _quote(txId);
        bytes32 escrowId = keccak256("escrowPenalty");
        _commit(txId, escrowId, ONE_USDC);
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");

        vm.prank(requester);
        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, "");

        uint256 penaltyGross = (ONE_USDC * kernel.requesterPenaltyBps()) / kernel.MAX_BPS();
        (uint256 providerNet, uint256 fee) = _splitAmount(penaltyGross);
        uint256 expectedRequesterBalance = INITIAL_BALANCE - ONE_USDC + (ONE_USDC - penaltyGross);

        assertEq(usdc.balanceOf(provider), providerNet);
        assertEq(usdc.balanceOf(feeCollector), fee);
        assertEq(usdc.balanceOf(requester), expectedRequesterBalance);
    }

    function testDisputeResolutionCustomSplit() external {
        bytes32 txId = _createBaseTx();
        _quote(txId);
        bytes32 escrowId = keccak256("escrowSplit");
        _commit(txId, escrowId, ONE_USDC);
        _deliver(txId, 1 days);

        vm.prank(requester);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");

        uint256 requesterAward = ONE_USDC / 4;
        uint256 providerAward = ONE_USDC - requesterAward;
        bytes memory resolution = abi.encode(requesterAward, providerAward);

        kernel.transitionState(txId, IACTPKernel.State.SETTLED, resolution);

        (uint256 providerNet, uint256 fee) = _splitAmount(providerAward);
        assertEq(usdc.balanceOf(provider), providerNet);
        assertEq(usdc.balanceOf(feeCollector), fee);
        uint256 expectedRequesterBalance = INITIAL_BALANCE - ONE_USDC + requesterAward;
        assertEq(usdc.balanceOf(requester), expectedRequesterBalance);
    }

    function testDisputeResolutionWithMediatorPayout() external {
        bytes32 txId = _createBaseTx();
        _quote(txId);
        bytes32 escrowId = keccak256("escrowMediator");
        _commit(txId, escrowId, ONE_USDC);
        _deliver(txId, 1 days);

        vm.prank(requester);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");

        uint256 mediatorAward = ONE_USDC / 10;
        uint256 providerAward = ONE_USDC / 2;
        uint256 requesterAward = ONE_USDC - providerAward - mediatorAward;
        address mediator = address(0x99);

        // Approve mediator and wait for time-lock
        kernel.approveMediator(mediator, true);
        vm.warp(block.timestamp + 2 days + 1);

        bytes memory resolution = abi.encode(requesterAward, providerAward, mediator, mediatorAward);

        kernel.transitionState(txId, IACTPKernel.State.SETTLED, resolution);

        (uint256 providerNet, uint256 fee) = _splitAmount(providerAward);
        assertEq(usdc.balanceOf(provider), providerNet);
        assertEq(usdc.balanceOf(feeCollector), fee);
        assertEq(usdc.balanceOf(mediator), mediatorAward);
        uint256 expectedRequesterBalance = INITIAL_BALANCE - ONE_USDC + requesterAward;
        assertEq(usdc.balanceOf(requester), expectedRequesterBalance);
    }

    function testDisputeCancellationResolutionRefunds() external {
        bytes32 txId = _createBaseTx();
        _quote(txId);
        bytes32 escrowId = keccak256("escrowCancelSplit");
        _commit(txId, escrowId, ONE_USDC);
        _deliver(txId, 1 days);

        vm.prank(requester);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");

        uint256 requesterAward = ONE_USDC * 3 / 4;
        uint256 providerAward = ONE_USDC - requesterAward;
        bytes memory resolution = abi.encode(requesterAward, providerAward);

        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, resolution);

        (uint256 providerNet, uint256 fee) = _splitAmount(providerAward);
        assertEq(usdc.balanceOf(provider), providerNet);
        assertEq(usdc.balanceOf(feeCollector), fee);
        uint256 expectedRequesterBalance = INITIAL_BALANCE - ONE_USDC + requesterAward;
        assertEq(usdc.balanceOf(requester), expectedRequesterBalance);
    }

    function testScheduleEconomicParamsAndExecute() external {
        uint16 newFee = 150;
        uint16 newPenalty = 700;

        vm.prank(address(this));
        kernel.scheduleEconomicParams(newFee, newPenalty);

        (uint16 pendingFee, uint16 pendingPenalty, uint256 executeAfter, bool active) = kernel.getPendingEconomicParams();
        assertTrue(active);
        assertEq(pendingFee, newFee);
        assertEq(pendingPenalty, newPenalty);

        vm.expectRevert();
        kernel.executeEconomicParamsUpdate();

        vm.warp(executeAfter);
        kernel.executeEconomicParamsUpdate();

        assertEq(kernel.platformFeeBps(), newFee);
        assertEq(kernel.requesterPenaltyBps(), newPenalty);

        (, , , bool activeAfter) = kernel.getPendingEconomicParams();
        assertFalse(activeAfter);
    }

    function testEconomicParamScheduleRequiresAdmin() external {
        vm.prank(provider);
        vm.expectRevert();
        kernel.scheduleEconomicParams(200, 600);
    }

    function testCancelEconomicParamUpdate() external {
        vm.prank(address(this));
        kernel.scheduleEconomicParams(200, 600);

        vm.prank(address(this));
        kernel.cancelEconomicParamsUpdate();

        (, , , bool active) = kernel.getPendingEconomicParams();
        assertFalse(active);
    }

    function testEconomicParamCapsEnforced() external {
        uint16 currentPenalty = kernel.requesterPenaltyBps();
        uint16 currentFee = kernel.platformFeeBps();
        
        uint16 invalidFee = uint16(kernel.MAX_PLATFORM_FEE_CAP() + 1);
        vm.expectRevert("Fee cap");
        kernel.scheduleEconomicParams(invalidFee, currentPenalty);

        uint16 invalidPenalty = uint16(kernel.MAX_REQUESTER_PENALTY_CAP() + 1);
        vm.expectRevert("Penalty cap");
        kernel.scheduleEconomicParams(currentFee, invalidPenalty);
    }

    function testEconomicParamCannotBypassTimelock() external {
        // Schedule first update
        kernel.scheduleEconomicParams(200, 600);

        // Try to schedule another while first is pending (should revert)
        vm.expectRevert("Pending update exists - cancel first");
        kernel.scheduleEconomicParams(300, 700);

        // Cancel first, then new schedule should work
        kernel.cancelEconomicParamsUpdate();
        kernel.scheduleEconomicParams(300, 700);

        (uint16 pendingFee, uint16 pendingPenalty, , bool active) = kernel.getPendingEconomicParams();
        assertTrue(active);
        assertEq(pendingFee, 300);
        assertEq(pendingPenalty, 700);
    }

    // ========================================
    // AIP-5: Platform Fee Lock Tests
    // ========================================

    function testAIP5_FeeLockedAtCreation() external {
        uint16 originalFee = kernel.platformFeeBps();

        // Create transaction with original fee
        bytes32 txId = _createBaseTx();

        // Verify transaction locked the current platform fee
        IACTPKernel.TransactionView memory txView = kernel.getTransaction(txId);
        assertEq(txView.platformFeeBpsLocked, originalFee, "Fee should be locked at creation");
    }

    function testAIP5_FeeChangeDoesNotAffectExisting() external {
        uint16 originalFee = kernel.platformFeeBps(); // 100 bps = 1%

        // Create transaction with original fee (1%)
        bytes32 txId = _createBaseTx();
        bytes32 escrowId = keccak256("aip5test1");
        _commit(txId, escrowId, ONE_USDC);
        _deliver(txId, 1 days);

        // Change platform fee to 2%
        uint16 newFee = 200;
        kernel.scheduleEconomicParams(newFee, kernel.requesterPenaltyBps());
        vm.warp(block.timestamp + 2 days + 1);
        kernel.executeEconomicParamsUpdate();

        assertEq(kernel.platformFeeBps(), newFee, "Fee should be updated to 2%");

        // Verify transaction still has original locked fee
        IACTPKernel.TransactionView memory txView = kernel.getTransaction(txId);
        assertEq(txView.platformFeeBpsLocked, originalFee, "Locked fee should remain 1%");

        // Settle and verify 1% fee is used (not 2%)
        vm.warp(block.timestamp + 2 days);
        vm.prank(requester);
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, "");

        // Expected: 1% fee on 1 USDC = 0.01 USDC
        uint256 expectedFee = (ONE_USDC * originalFee) / 10000;
        uint256 expectedProviderAmount = ONE_USDC - expectedFee;

        assertEq(usdc.balanceOf(provider), expectedProviderAmount, "Provider should get 99% (1% original fee)");
        assertEq(usdc.balanceOf(feeCollector), expectedFee, "Fee collector should get 1% original fee");
    }

    function testAIP5_NewTransactionsUseNewFee() external {
        uint16 originalFee = kernel.platformFeeBps(); // 100 bps = 1%

        // Create first transaction with original fee
        bytes32 txId1 = _createBaseTx();

        // Change platform fee to 2%
        uint16 newFee = 200;
        kernel.scheduleEconomicParams(newFee, kernel.requesterPenaltyBps());
        vm.warp(block.timestamp + 2 days + 1);
        kernel.executeEconomicParamsUpdate();

        // Create second transaction with new fee
        vm.prank(requester);
        bytes32 txId2 = kernel.createTransaction(provider, requester, ONE_USDC, block.timestamp + 1 days, 2 days, bytes32(uint256(1)));

        // Verify first transaction locked original fee
        IACTPKernel.TransactionView memory txView1 = kernel.getTransaction(txId1);
        assertEq(txView1.platformFeeBpsLocked, originalFee, "First tx should have 1% locked");

        // Verify second transaction locked new fee
        IACTPKernel.TransactionView memory txView2 = kernel.getTransaction(txId2);
        assertEq(txView2.platformFeeBpsLocked, newFee, "Second tx should have 2% locked");
    }

    function testAIP5_SettlementUsesLockedFee() external {
        // Create transaction with 1% fee
        bytes32 txId = _createBaseTx();
        uint16 lockedFee = kernel.platformFeeBps(); // 100 bps = 1%

        bytes32 escrowId = keccak256("aip5settlement");
        _commit(txId, escrowId, ONE_USDC);
        _deliver(txId, 1 days);

        // Change fee to 5% (max)
        kernel.scheduleEconomicParams(500, kernel.requesterPenaltyBps());
        vm.warp(block.timestamp + 2 days + 1);
        kernel.executeEconomicParamsUpdate();

        // Settle transaction
        vm.warp(block.timestamp + 2 days);
        vm.prank(requester);
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, "");

        // Should use locked 1% fee, not current 5%
        uint256 expectedFee = (ONE_USDC * lockedFee) / 10000; // 1% of 1 USDC
        uint256 expectedProviderAmount = ONE_USDC - expectedFee;

        assertEq(usdc.balanceOf(provider), expectedProviderAmount, "Provider should get amount with 1% fee deducted");
        assertEq(usdc.balanceOf(feeCollector), expectedFee, "Fee should be 1%, not 5%");

        // Verify fee collector got 1% (0.01 USDC), not 5% (0.05 USDC)
        assertEq(usdc.balanceOf(feeCollector), ONE_USDC / 100, "Fee collector should receive exactly 1% (0.01 USDC)");
    }

    function testAIP5_MilestoneReleaseUsesLockedFee() external {
        // Create transaction with 1% fee
        bytes32 txId = _createBaseTx();
        uint16 lockedFee = kernel.platformFeeBps(); // 100 bps = 1%

        bytes32 escrowId = keccak256("aip5milestone");
        _commit(txId, escrowId, ONE_USDC);

        // Transition to IN_PROGRESS (required for milestone release)
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");

        // Change fee to 3%
        kernel.scheduleEconomicParams(300, kernel.requesterPenaltyBps());
        vm.warp(block.timestamp + 2 days + 1);
        kernel.executeEconomicParamsUpdate();

        // Release 50% milestone
        uint256 milestoneAmount = ONE_USDC / 2;
        vm.prank(requester);
        kernel.releaseMilestone(txId, milestoneAmount);

        // Should use locked 1% fee on milestone, not current 3%
        uint256 expectedFee = (milestoneAmount * lockedFee) / 10000; // 1% of 0.5 USDC
        uint256 expectedProviderAmount = milestoneAmount - expectedFee;

        assertEq(usdc.balanceOf(provider), expectedProviderAmount, "Milestone should use 1% locked fee");
        assertEq(usdc.balanceOf(feeCollector), expectedFee, "Milestone fee should be 1%, not 3%");
    }
}
