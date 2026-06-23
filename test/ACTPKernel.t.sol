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
    uint256 constant RECOVERY_GRACE = 1 days; // short grace so warps are practical (mainnet uses 7 days)

    function setUp() external {
        usdc = new MockUSDC();
        kernel = new ACTPKernel(address(this), address(this), feeCollector, address(0), address(usdc), RECOVERY_GRACE);
        escrow = new EscrowVault(address(usdc), address(kernel));
        
        // Approve escrow vault (admin is the test contract)
        kernel.approveEscrowVault(address(escrow), true);

        usdc.mint(requester, 1_000_000_000); // seed requester
    }

    // Helpers --------------------------------------------------------------

    function _createBaseTx() internal returns (bytes32 txId) {
        vm.prank(requester);
        txId = kernel.createTransaction(provider, requester, ONE_USDC, block.timestamp + 7 days, 2 days, keccak256("service"), 0, 0);
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
        uint256 bpsFee = (amount * kernel.platformFeeBps()) / kernel.MAX_BPS();
        fee = bpsFee > kernel.MIN_FEE() ? bpsFee : kernel.MIN_FEE();
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
        bytes32 txId1 = kernel.createTransaction(provider, requester, ONE_USDC, block.timestamp + 7 days, 2 days, keccak256("service"), 0, 0);

        // Create second transaction with SAME inputs - should succeed with DIFFERENT txId
        vm.prank(requester);
        bytes32 txId2 = kernel.createTransaction(provider, requester, ONE_USDC, block.timestamp + 7 days, 2 days, keccak256("service"), 0, 0);

        // Verify both transactions exist with different IDs
        assertTrue(txId1 != txId2, "Nonce should produce different IDs");

        IACTPKernel.TransactionView memory tx1 = kernel.getTransaction(txId1);
        IACTPKernel.TransactionView memory tx2 = kernel.getTransaction(txId2);
        assertEq(tx1.amount, ONE_USDC);
        assertEq(tx2.amount, ONE_USDC);
    }

    function testCreateTransaction_WithAgentId() external {
        uint256 testAgentId = 12345;

        vm.prank(requester);
        bytes32 txId = kernel.createTransaction(
            provider, requester, ONE_USDC,
            block.timestamp + 7 days, 2 days,
            keccak256("service"), testAgentId, 0
        );

        IACTPKernel.TransactionView memory txView = kernel.getTransaction(txId);
        assertEq(txView.agentId, testAgentId, "agentId should be stored");
    }

    function testCreateTransaction_WithZeroAgentId() external {
        vm.prank(requester);
        bytes32 txId = kernel.createTransaction(
            provider, requester, ONE_USDC,
            block.timestamp + 7 days, 2 days,
            keccak256("service"), 0, 0
        );

        IACTPKernel.TransactionView memory txView = kernel.getTransaction(txId);
        assertEq(txView.agentId, 0, "agentId should be zero when not provided");
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

        vm.startPrank(requester);
        usdc.approve(address(escrow), type(uint256).max);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");
        vm.stopPrank();

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
        bytes32 txId = kernel.createTransaction(provider, requester, ONE_USDC, block.timestamp + 1 days, 2 days, keccak256("service"), 0, 0);

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

    // [H-4 FIX] Requester CANNOT cancel from IN_PROGRESS state
    // This test verifies the security fix is working
    function testRequesterCannotCancelFromInProgress() external {
        bytes32 txId = _createBaseTx();
        _quote(txId);
        bytes32 escrowId = keccak256("escrowPenalty");
        _commit(txId, escrowId, ONE_USDC);
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");

        // [H-4 FIX] Requester should NOT be able to cancel after work started
        vm.prank(requester);
        vm.expectRevert(bytes("Cannot cancel after work started"));
        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, "");
    }

    // [H-4 FIX] Provider CAN still cancel from IN_PROGRESS (voluntary refund)
    function testProviderCanCancelFromInProgress() external {
        bytes32 txId = _createBaseTx();
        _quote(txId);
        bytes32 escrowId = keccak256("escrowPenalty");
        _commit(txId, escrowId, ONE_USDC);
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");

        // Provider should be able to cancel (voluntary refund to requester)
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, "");

        // Full refund to requester (no penalty for provider-initiated cancel)
        assertEq(usdc.balanceOf(requester), INITIAL_BALANCE);
    }

    function testDisputeResolutionCustomSplit() external {
        bytes32 txId = _createBaseTx();
        _quote(txId);
        bytes32 escrowId = keccak256("escrowSplit");
        _commit(txId, escrowId, ONE_USDC);
        _deliver(txId, 1 days);

        vm.startPrank(requester);
        usdc.approve(address(escrow), type(uint256).max);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");
        vm.stopPrank();

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

        vm.startPrank(requester);
        usdc.approve(address(escrow), type(uint256).max);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");
        vm.stopPrank();

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

        vm.startPrank(requester);
        usdc.approve(address(escrow), type(uint256).max);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");
        vm.stopPrank();

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
        uint256 TEN_USDC = 10 * ONE_USDC; // Use 10 USDC so 1% = 100K > MIN_FEE = 50K

        // Create transaction with original fee (1%)
        vm.prank(requester);
        bytes32 txId = kernel.createTransaction(provider, requester, TEN_USDC, block.timestamp + 1 days, 2 days, keccak256("aip5test1fee"), 0, 0);
        bytes32 escrowId = keccak256("aip5test1");
        _commit(txId, escrowId, TEN_USDC);
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

        // Expected: 1% fee on 10 USDC = 0.10 USDC (100K > MIN_FEE 50K)
        uint256 bpsFee = (TEN_USDC * originalFee) / 10000;
        uint256 expectedFee = bpsFee > kernel.MIN_FEE() ? bpsFee : kernel.MIN_FEE();
        uint256 expectedProviderAmount = TEN_USDC - expectedFee;

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
        bytes32 txId2 = kernel.createTransaction(provider, requester, ONE_USDC, block.timestamp + 1 days, 2 days, bytes32(uint256(1)), 0, 0);

        // Verify first transaction locked original fee
        IACTPKernel.TransactionView memory txView1 = kernel.getTransaction(txId1);
        assertEq(txView1.platformFeeBpsLocked, originalFee, "First tx should have 1% locked");

        // Verify second transaction locked new fee
        IACTPKernel.TransactionView memory txView2 = kernel.getTransaction(txId2);
        assertEq(txView2.platformFeeBpsLocked, newFee, "Second tx should have 2% locked");
    }

    function testAIP5_SettlementUsesLockedFee() external {
        uint256 TEN_USDC = 10 * ONE_USDC; // Use 10 USDC so 1% = 100K > MIN_FEE = 50K

        // Create transaction with 1% fee
        vm.prank(requester);
        bytes32 txId = kernel.createTransaction(provider, requester, TEN_USDC, block.timestamp + 1 days, 2 days, keccak256("aip5settlement-svc"), 0, 0);
        uint16 lockedFee = kernel.platformFeeBps(); // 100 bps = 1%

        bytes32 escrowId = keccak256("aip5settlement");
        _commit(txId, escrowId, TEN_USDC);
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
        uint256 bpsFee = (TEN_USDC * lockedFee) / 10000; // 1% of 10 USDC = 100K
        uint256 expectedFee = bpsFee > kernel.MIN_FEE() ? bpsFee : kernel.MIN_FEE();
        uint256 expectedProviderAmount = TEN_USDC - expectedFee;

        assertEq(usdc.balanceOf(provider), expectedProviderAmount, "Provider should get amount with 1% fee deducted");
        assertEq(usdc.balanceOf(feeCollector), expectedFee, "Fee should be 1%, not 5%");

        // Verify fee collector got 1% (0.10 USDC = 100K), not 5% (0.50 USDC = 500K)
        assertEq(usdc.balanceOf(feeCollector), TEN_USDC / 100, "Fee collector should receive exactly 1% (0.10 USDC)");
    }

    function testAIP5_MilestoneReleaseUsesLockedFee() external {
        uint256 TEN_USDC = 10 * ONE_USDC; // Use 10 USDC so 1% > MIN_FEE

        // Create transaction with 1% fee
        vm.prank(requester);
        bytes32 txId = kernel.createTransaction(provider, requester, TEN_USDC, block.timestamp + 1 days, 2 days, keccak256("aip5milestone-svc"), 0, 0);
        uint16 lockedFee = kernel.platformFeeBps(); // 100 bps = 1%

        bytes32 escrowId = keccak256("aip5milestone");
        _commit(txId, escrowId, TEN_USDC);

        // Transition to IN_PROGRESS (required for milestone release)
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");

        // Change fee to 3%
        kernel.scheduleEconomicParams(300, kernel.requesterPenaltyBps());
        vm.warp(block.timestamp + 2 days + 1);
        kernel.executeEconomicParamsUpdate();

        // Release 50% milestone (5 USDC — 1% = 50K = MIN_FEE, so bpsFee == MIN_FEE)
        uint256 milestoneAmount = TEN_USDC / 2;
        vm.prank(requester);
        kernel.releaseMilestone(txId, milestoneAmount);

        // Should use locked 1% fee on milestone, not current 3%
        uint256 bpsFee = (milestoneAmount * lockedFee) / 10000; // 1% of 5 USDC = 50K
        uint256 expectedFee = bpsFee > kernel.MIN_FEE() ? bpsFee : kernel.MIN_FEE();
        uint256 expectedProviderAmount = milestoneAmount - expectedFee;

        assertEq(usdc.balanceOf(provider), expectedProviderAmount, "Milestone should use 1% locked fee");
        assertEq(usdc.balanceOf(feeCollector), expectedFee, "Milestone fee should be 1%, not 3%");
    }

    // === ACCEPT QUOTE TESTS ===

    function _acceptQuote(bytes32 txId, uint256 newAmount) internal {
        vm.prank(requester);
        kernel.acceptQuote(txId, newAmount);
    }

    function testAcceptQuote_basic() external {
        bytes32 txId = _createBaseTx();
        _quote(txId);

        uint256 newAmount = 2 * ONE_USDC;
        _acceptQuote(txId, newAmount);

        IACTPKernel.TransactionView memory txView = kernel.getTransaction(txId);
        assertEq(txView.amount, newAmount, "Amount should be updated");
        assertGt(txView.updatedAt, 0, "updatedAt should be set");
    }

    function testAcceptQuote_thenLinkEscrow() external {
        bytes32 txId = _createBaseTx();
        _quote(txId);

        uint256 newAmount = 5 * ONE_USDC;
        _acceptQuote(txId, newAmount);

        // Fund requester extra for increased amount
        usdc.mint(requester, 10 * ONE_USDC);

        bytes32 escrowId = keccak256("escrowAcceptQuote");
        _commit(txId, escrowId, newAmount);

        IACTPKernel.TransactionView memory txView = kernel.getTransaction(txId);
        assertEq(uint8(txView.state), uint8(IACTPKernel.State.COMMITTED), "Should be COMMITTED");
        assertEq(txView.amount, newAmount, "Committed amount should match accepted quote");

        // Verify escrow holds the new amount
        (bool isActive, uint256 escrowAmount) = escrow.verifyEscrow(
            escrowId, requester, provider, newAmount
        );
        assertTrue(isActive, "Escrow should be active");
        assertEq(escrowAmount, newAmount, "Escrow should hold new amount");
    }

    function testAcceptQuote_multipleRounds() external {
        bytes32 txId = _createBaseTx();
        _quote(txId);

        _acceptQuote(txId, 2 * ONE_USDC);
        _acceptQuote(txId, 3 * ONE_USDC);

        IACTPKernel.TransactionView memory txView = kernel.getTransaction(txId);
        assertEq(txView.amount, 3 * ONE_USDC, "Last accepted amount should stick");
    }

    function testAcceptQuote_revertsNotQuoted() external {
        bytes32 txId = _createBaseTx(); // INITIATED state

        vm.prank(requester);
        vm.expectRevert(bytes("Not quoted"));
        kernel.acceptQuote(txId, 2 * ONE_USDC);
    }

    function testAcceptQuote_revertsNotRequester() external {
        bytes32 txId = _createBaseTx();
        _quote(txId);

        vm.prank(provider);
        vm.expectRevert(bytes("Only requester"));
        kernel.acceptQuote(txId, 2 * ONE_USDC);
    }

    function testAcceptQuote_revertsBelowMinimum() external {
        bytes32 txId = _createBaseTx();
        _quote(txId);

        vm.prank(requester);
        vm.expectRevert(bytes("Below minimum"));
        kernel.acceptQuote(txId, 0);
    }

    function testAcceptQuote_revertsAboveMaximum() external {
        bytes32 txId = _createBaseTx();
        _quote(txId);

        vm.prank(requester);
        vm.expectRevert(bytes("Above maximum"));
        kernel.acceptQuote(txId, 1_000_000_001e6);
    }

    function testAcceptQuote_revertsExpired() external {
        bytes32 txId = _createBaseTx();
        _quote(txId);

        vm.warp(block.timestamp + 8 days); // past 7-day deadline

        vm.prank(requester);
        vm.expectRevert(bytes("Expired"));
        kernel.acceptQuote(txId, 2 * ONE_USDC);
    }

    function testAcceptQuote_feeBpsRelocked() external {
        bytes32 txId = _createBaseTx();
        uint16 originalFee = kernel.platformFeeBps(); // 100 bps = 1%

        _quote(txId);

        // Change fee to 2% via timelock
        uint16 newFee = 200;
        kernel.scheduleEconomicParams(newFee, kernel.requesterPenaltyBps());
        vm.warp(block.timestamp + 2 days + 1);
        kernel.executeEconomicParamsUpdate();
        assertEq(kernel.platformFeeBps(), newFee, "Platform fee should be 2%");

        // acceptQuote should re-lock to current 2%
        _acceptQuote(txId, 2 * ONE_USDC);

        IACTPKernel.TransactionView memory txView = kernel.getTransaction(txId);
        assertEq(txView.platformFeeBpsLocked, newFee, "Fee should be re-locked to 2%");
        assertTrue(txView.platformFeeBpsLocked != originalFee, "Should differ from original 1%");
    }

    // ========================================================================
    // F-6: Stalled IN_PROGRESS recovery (recoverStalledInProgress)
    // ========================================================================

    // Helper: create -> quote -> commit -> IN_PROGRESS with an explicit deadline.
    // Returns to IN_PROGRESS with escrow holding `amount`.
    function _toInProgress(bytes32 svc, uint256 deadline, uint256 amount) internal returns (bytes32 txId) {
        vm.prank(requester);
        txId = kernel.createTransaction(provider, requester, amount, deadline, 2 days, svc, 0, 0);
        _quote(txId);
        _commit(txId, svc, amount);
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");
    }

    // --- Happy path: full refund of vault.remaining, permissionless, escrow inactive ---
    function testF6_RecoverHappyPath_FullRefund_Permissionless() external {
        uint256 deadline = block.timestamp + 1 days;
        bytes32 txId = _toInProgress(keccak256("f6happy"), deadline, ONE_USDC);

        // Move past deadline + recoveryGrace
        vm.warp(deadline + RECOVERY_GRACE + 1);

        // Permissionless: a random third party triggers recovery
        address anyone = address(0xCAFE);
        vm.prank(anyone);
        kernel.recoverStalledInProgress(txId);

        IACTPKernel.TransactionView memory v = kernel.getTransaction(txId);
        assertEq(uint8(v.state), uint8(IACTPKernel.State.CANCELLED), "state CANCELLED");

        // Full refund: requester whole again, provider got nothing
        assertEq(usdc.balanceOf(requester), INITIAL_BALANCE, "requester fully refunded");
        assertEq(usdc.balanceOf(provider), 0, "provider gets 0");
        assertEq(usdc.balanceOf(feeCollector), 0, "no fee on recovery");

        // Escrow drained / inactive
        assertEq(escrow.remaining(keccak256("f6happy")), 0, "escrow remaining 0");
    }

    // --- H-4 non-reopening: requester STILL cannot cancel from IN_PROGRESS via transitionState ---
    function testF6_H4Unchanged_RequesterCannotCancelFromInProgress() external {
        uint256 deadline = block.timestamp + 1 days;
        bytes32 txId = _toInProgress(keccak256("f6h4"), deadline, ONE_USDC);

        // Even AFTER deadline+grace, the cancellation path (transitionState) stays blocked.
        vm.warp(deadline + RECOVERY_GRACE + 1);
        vm.prank(requester);
        vm.expectRevert(bytes("Cannot cancel after work started"));
        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, "");
    }

    // --- Too-early revert: before deadline + recoveryGrace ---
    function testF6_RecoverRevertsBeforeGrace() external {
        uint256 deadline = block.timestamp + 1 days;
        bytes32 txId = _toInProgress(keccak256("f6early"), deadline, ONE_USDC);

        // 1 second before the window opens
        vm.warp(deadline + RECOVERY_GRACE - 1);
        vm.expectRevert(bytes("Recovery not yet available"));
        kernel.recoverStalledInProgress(txId);
    }

    // --- Too-early revert: fuzz variant over the entire pre-grace interval ---
    function testFuzzF6_RecoverRevertsBeforeGrace(uint256 elapsed) external {
        uint256 deadline = block.timestamp + 1 days;
        bytes32 txId = _toInProgress(keccak256("f6earlyfuzz"), deadline, ONE_USDC);

        // Any instant strictly before deadline + recoveryGrace must revert.
        // Bound to [0, deadline + RECOVERY_GRACE - 1].
        uint256 target = bound(elapsed, block.timestamp, deadline + RECOVERY_GRACE - 1);
        vm.warp(target);
        vm.expectRevert(bytes("Recovery not yet available"));
        kernel.recoverStalledInProgress(txId);
    }

    // --- Wrong-state revert: not IN_PROGRESS (still COMMITTED) ---
    function testF6_RecoverRevertsWrongState() external {
        bytes32 txId = _createBaseTx();
        _quote(txId);
        bytes32 escrowId = keccak256("f6wrongstate");
        _commit(txId, escrowId, ONE_USDC); // COMMITTED, not IN_PROGRESS

        vm.warp(block.timestamp + 30 days); // well past any window
        vm.expectRevert(bytes("Not in progress"));
        kernel.recoverStalledInProgress(txId);
    }

    // F-6 no-dispute-escape: recovery must reject a DISPUTED tx, locking the invariant that a
    // transaction in dispute can never be drained via the liveness backstop. (Adversarial LOW.)
    function testF6_RecoverRevertsFromDisputed() external {
        bytes32 txId = _createBaseTx();
        _quote(txId);
        _commit(txId, keccak256("f6disp"), ONE_USDC);
        _deliver(txId, 1 days);

        vm.startPrank(requester);
        usdc.approve(address(escrow), type(uint256).max);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");
        vm.stopPrank();

        // DISPUTED is not IN_PROGRESS — recovery reverts on the state guard regardless of time.
        vm.warp(block.timestamp + 365 days);
        vm.expectRevert(bytes("Not in progress"));
        kernel.recoverStalledInProgress(txId);
    }

    // --- MIN_DEADLINE createTransaction revert ---
    function testF6_CreateRevertsDeadlineTooSoon() external {
        // deadline strictly less than block.timestamp + MIN_DEADLINE (1 hours)
        vm.prank(requester);
        vm.expectRevert(bytes("Deadline too soon"));
        kernel.createTransaction(
            provider, requester, ONE_USDC,
            block.timestamp + 1 hours - 1, // just under MIN_DEADLINE floor
            2 days, keccak256("f6mindeadline"), 0, 0
        );
    }

    // --- Full-refund routing: provider gets 0, no penalty branch is taken ---
    function testF6_FullRefundRouting_NoPenaltyNoFee() external {
        uint256 deadline = block.timestamp + 1 days;
        bytes32 txId = _toInProgress(keccak256("f6routing"), deadline, ONE_USDC);
        vm.warp(deadline + RECOVERY_GRACE + 1);

        kernel.recoverStalledInProgress(txId);

        // Recovery refunds 100% of remaining to the requester (no penalty skim to provider).
        assertEq(usdc.balanceOf(requester), INITIAL_BALANCE, "requester gets full remaining, no penalty");
        assertEq(usdc.balanceOf(provider), 0, "provider penalty branch NOT taken (0)");
        assertEq(usdc.balanceOf(feeCollector), 0, "no platform fee on recovery");
    }

    // --- releaseMilestone then recover: only the remainder is refunded ---
    function testF6_RecoverAfterMilestone_RefundsRemainderOnly() external {
        uint256 deadline = block.timestamp + 1 days;
        bytes32 txId = _toInProgress(keccak256("f6milestone"), deadline, ONE_USDC);

        // Requester releases a half-milestone while IN_PROGRESS
        uint256 milestoneAmount = ONE_USDC / 2;
        vm.prank(requester);
        kernel.releaseMilestone(txId, milestoneAmount);

        (uint256 providerNet, uint256 fee) = _splitAmount(milestoneAmount);
        assertEq(usdc.balanceOf(provider), providerNet, "provider keeps milestone net");
        assertEq(usdc.balanceOf(feeCollector), fee, "fee from milestone");

        // Now recover: only the un-released remainder goes back to the requester
        vm.warp(deadline + RECOVERY_GRACE + 1);
        uint256 requesterBefore = usdc.balanceOf(requester);
        kernel.recoverStalledInProgress(txId);

        uint256 expectedRemainder = ONE_USDC - milestoneAmount;
        assertEq(usdc.balanceOf(requester) - requesterBefore, expectedRemainder, "refund == leftover only");
        assertEq(escrow.remaining(keccak256("f6milestone")), 0, "escrow drained");

        IACTPKernel.TransactionView memory v = kernel.getTransaction(txId);
        assertEq(uint8(v.state), uint8(IACTPKernel.State.CANCELLED), "CANCELLED after recover");
    }

    // --- Recovery works WHILE PAUSED (no whenNotPaused on the recovery path) ---
    function testF6_RecoverWorksWhilePaused() external {
        uint256 deadline = block.timestamp + 1 days;
        bytes32 txId = _toInProgress(keccak256("f6paused"), deadline, ONE_USDC);

        vm.warp(deadline + RECOVERY_GRACE + 1);
        kernel.pause();

        // Sanity: normal transitions are frozen...
        vm.prank(provider);
        vm.expectRevert(bytes("Kernel paused"));
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(uint256(1 days)));

        // ...but fund recovery still works under pause.
        kernel.recoverStalledInProgress(txId);

        IACTPKernel.TransactionView memory v = kernel.getTransaction(txId);
        assertEq(uint8(v.state), uint8(IACTPKernel.State.CANCELLED), "recovered while paused");
        assertEq(usdc.balanceOf(requester), INITIAL_BALANCE, "refunded while paused");
    }

    // --- StalledInProgressRecovered event emitted (requester + remaining amount) ---
    function testF6_EmitsStalledInProgressRecovered() external {
        uint256 deadline = block.timestamp + 1 days;
        bytes32 txId = _toInProgress(keccak256("f6event"), deadline, ONE_USDC);
        vm.warp(deadline + RECOVERY_GRACE + 1);

        vm.expectEmit(true, true, false, true);
        emit IACTPKernel.StalledInProgressRecovered(txId, requester, ONE_USDC);
        kernel.recoverStalledInProgress(txId);
    }

    // --- Option A: provider CAN deliver DURING the grace window and be paid ---
    function testF6_OptionA_ProviderDeliversDuringGrace_GetsPaid() external {
        uint256 deadline = block.timestamp + 1 days;
        bytes32 txId = _toInProgress(keccak256("f6grace"), deadline, ONE_USDC);

        // After the deadline but before deadline+recoveryGrace: delivery still allowed.
        vm.warp(deadline + RECOVERY_GRACE - 1);
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(uint256(1 hours)));

        IACTPKernel.TransactionView memory v = kernel.getTransaction(txId);
        assertEq(uint8(v.state), uint8(IACTPKernel.State.DELIVERED), "delivered during grace");

        // Settle after dispute window -> provider paid
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, "");

        (uint256 providerNet, ) = _splitAmount(ONE_USDC);
        assertEq(usdc.balanceOf(provider), providerNet, "provider paid after grace-window delivery");
    }

    // --- Option A boundary: delivery blocked at the exact deadline+recoveryGrace instant (strict <) ---
    function testF6_OptionA_DeliveryBlockedAtGraceBoundary() external {
        uint256 deadline = block.timestamp + 1 days;
        bytes32 txId = _toInProgress(keccak256("f6boundary"), deadline, ONE_USDC);

        // At exactly deadline + recoveryGrace: delivery is rejected (strict < gate),
        // and recovery is simultaneously available (>=) — mutually exclusive boundary.
        vm.warp(deadline + RECOVERY_GRACE);

        vm.prank(provider);
        vm.expectRevert(bytes("Delivery grace expired"));
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(uint256(1 hours)));

        // Recovery succeeds at the same instant.
        kernel.recoverStalledInProgress(txId);
        IACTPKernel.TransactionView memory v = kernel.getTransaction(txId);
        assertEq(uint8(v.state), uint8(IACTPKernel.State.CANCELLED), "recovery available at boundary");
    }

    // --- Reputation: recovery marks the provider AT FAULT (providerAtFault == true) ---
    function testF6_Reputation_MarksProviderAtFault() external {
        // Wire a recording registry via the timelocked update flow.
        RecordingAgentRegistry reg = new RecordingAgentRegistry();
        kernel.scheduleAgentRegistryUpdate(address(reg));
        vm.warp(block.timestamp + kernel.ECONOMIC_PARAM_DELAY());
        kernel.executeAgentRegistryUpdate();
        assertEq(address(kernel.agentRegistry()), address(reg), "registry wired");

        uint256 deadline = block.timestamp + 1 days;
        bytes32 txId = _toInProgress(keccak256("f6rep"), deadline, ONE_USDC);

        vm.warp(deadline + RECOVERY_GRACE + 1);
        kernel.recoverStalledInProgress(txId);

        // Reputation mark fired with provider at fault (non-delivery).
        assertTrue(reg.called(), "reputation updateReputationOnSettlement called");
        assertEq(reg.lastAgent(), provider, "marked the provider");
        assertEq(reg.lastTxId(), txId, "txId passed through");
        assertEq(reg.lastAmount(), ONE_USDC, "amount passed through");
        assertTrue(reg.lastProviderAtFault(), "providerAtFault == true");

        // reputationProcessedBy guard set to the current registry (idempotency).
        assertEq(kernel.reputationProcessedBy(txId), address(reg), "reputationProcessedBy set");
    }

}

// ============================================================================
// F-6: Recording mock registry — captures the providerAtFault bool the kernel
// passes to updateReputationOnSettlement so the recovery reputation-mark can be
// asserted (TransactionView does not expose wasDisputed).
// ============================================================================
contract RecordingAgentRegistry {
    bool public called;
    address public lastAgent;
    bytes32 public lastTxId;
    uint256 public lastAmount;
    bool public lastProviderAtFault;

    function updateReputationOnSettlement(
        address agentAddress,
        bytes32 txId,
        uint256 txAmount,
        bool wasDisputed
    ) external {
        called = true;
        lastAgent = agentAddress;
        lastTxId = txId;
        lastAmount = txAmount;
        lastProviderAtFault = wasDisputed; // AIP-14 semantics: true == provider at fault
    }
}
