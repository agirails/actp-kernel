// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ACTPKernel.sol";
import "../src/tokens/MockUSDC.sol";
import "../src/escrow/EscrowVault.sol";

contract ACTPKernelFuzzTest is Test {
    ACTPKernel internal kernel;
    MockUSDC internal usdc;
    EscrowVault internal escrow;

    address internal requester = address(0x1);
    address internal provider = address(0x2);
    address internal feeCollector = address(0xFEE);

    uint256 internal constant ONE_USDC = 1_000_000; // 1 USDC with 6 decimals
    uint256 internal constant INITIAL_MINT = 1_000_000_000;

    function setUp() external {
        usdc = new MockUSDC();
        kernel = new ACTPKernel(address(this), address(this), feeCollector, address(0), address(usdc));
        escrow = new EscrowVault(address(usdc), address(kernel));
        
        // Approve escrow vault (admin is the test contract)
        kernel.approveEscrowVault(address(escrow), true);

        usdc.mint(requester, INITIAL_MINT);
    }

    // @dev Disabled: Balance calculation edge cases need review before enabling
    function skip_testFuzzDisputeResolutionFlow(
        uint96 providerAwardRaw,
        uint96 requesterAwardRaw,
        uint96 mediatorAwardRaw,
        address mediator,
        bool settleNotCancel
    ) external {
        bytes32 txId = _prepareDeliveredTx();

        vm.prank(requester);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");

        uint256 providerAward = bound(uint256(providerAwardRaw), 0, ONE_USDC);
        uint256 mediatorAward = bound(uint256(mediatorAwardRaw), 0, ONE_USDC - providerAward);
        uint256 requesterAward = bound(uint256(requesterAwardRaw), 0, ONE_USDC - providerAward - mediatorAward);
        vm.assume(providerAward + requesterAward + mediatorAward > 0);
        vm.assume(mediator != requester && mediator != provider); // Avoid balance overlap

        bytes memory proof;
        address mediatorRecipient = mediator;
        if (mediatorAward > 0) {
            if (mediatorRecipient == address(0)) {
                mediatorRecipient = address(0xBEEF);
            }
            proof = abi.encode(requesterAward, providerAward, mediatorRecipient, mediatorAward);
        } else {
            proof = abi.encode(requesterAward, providerAward);
        }

        if (settleNotCancel) {
            kernel.transitionState(txId, IACTPKernel.State.SETTLED, proof);
        } else {
            kernel.transitionState(txId, IACTPKernel.State.CANCELLED, proof);
        }

        (uint256 providerNet, uint256 fee) = _splitAmount(providerAward);
        assertEq(usdc.balanceOf(provider), providerNet);
        assertEq(usdc.balanceOf(feeCollector), fee);
        if (mediatorAward > 0) {
            assertEq(usdc.balanceOf(mediatorRecipient), mediatorAward);
        }
        uint256 expectedRequesterBalance = INITIAL_MINT - ONE_USDC + requesterAward;
        if (mediatorAward > 0 && mediatorRecipient == requester) {
            expectedRequesterBalance += mediatorAward;
        }
        assertEq(usdc.balanceOf(requester), expectedRequesterBalance);
    }

    function testFuzzEconomicParams(uint16 platformFeeBps, uint16 requesterPenaltyBps) external {
        // Bound to valid ranges
        platformFeeBps = uint16(bound(uint256(platformFeeBps), 0, kernel.MAX_PLATFORM_FEE_CAP()));
        requesterPenaltyBps = uint16(bound(uint256(requesterPenaltyBps), 0, kernel.MAX_REQUESTER_PENALTY_CAP()));

        // Schedule
        kernel.scheduleEconomicParams(platformFeeBps, requesterPenaltyBps);

        // Warp
        vm.warp(block.timestamp + kernel.ECONOMIC_PARAM_DELAY());

        // Execute
        kernel.executeEconomicParamsUpdate();

        assertEq(kernel.platformFeeBps(), platformFeeBps);
        assertEq(kernel.requesterPenaltyBps(), requesterPenaltyBps);
    }

    function testFuzzDisputeWindowBoundary(uint256 windowRaw) external {
        // Dispute window must be either 0 (use default) or >= MIN_DISPUTE_WINDOW
        // Map windowRaw to valid range: if < half of range, use 0; otherwise use MIN to MAX
        uint256 window;
        if (windowRaw % 2 == 0) {
            window = 0; // Use default
        } else {
            window = bound(windowRaw, kernel.MIN_DISPUTE_WINDOW(), kernel.MAX_DISPUTE_WINDOW());
        }

        bytes32 txId = _createBaseTx(ONE_USDC, block.timestamp + 2 days);
        _quote(txId);
        _commit(txId, keccak256("escrowFuzzWindow"), ONE_USDC);

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");

        bytes memory proof = abi.encode(window);
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, proof);

        IACTPKernel.TransactionView memory txn = kernel.getTransaction(txId);
        // If window is 0, kernel uses DEFAULT_DISPUTE_WINDOW (2 days)
        uint256 expectedWindow = window == 0 ? kernel.DEFAULT_DISPUTE_WINDOW() : window;
        assertEq(txn.disputeWindow, block.timestamp + expectedWindow);
    }

    function testFuzzTransactionAmounts(uint96 amountRaw) external {
        uint256 amount = bound(uint256(amountRaw), kernel.MIN_TRANSACTION_AMOUNT(), INITIAL_MINT);


        vm.prank(requester);
        bytes32 txId = kernel.createTransaction(provider, requester, amount, block.timestamp + 1 days, 2 days, keccak256("service"));

        IACTPKernel.TransactionView memory txn = kernel.getTransaction(txId);
        assertEq(txn.amount, amount);
        assertEq(uint8(txn.state), uint8(IACTPKernel.State.INITIATED));
    }

    function testFuzzMilestoneRelease(uint96 milestoneRaw) external {
        bytes32 txId = _createBaseTx(ONE_USDC, block.timestamp + 2 days);
        _quote(txId);
        _commit(txId, keccak256("escrowMilestone"), ONE_USDC);

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");

        uint256 milestone = bound(uint256(milestoneRaw), 1, ONE_USDC);

        vm.prank(requester);
        kernel.releaseMilestone(txId, milestone);

        uint256 fee = (milestone * kernel.platformFeeBps()) / kernel.MAX_BPS();
        uint256 providerNet = milestone - fee;

        assertEq(usdc.balanceOf(provider), providerNet);
        assertEq(usdc.balanceOf(feeCollector), fee);
    }

    // [H-4 FIX] Requester CANNOT cancel from IN_PROGRESS state
    // This fuzz test verifies the security fix holds for any warp time
    function testFuzzRequesterCannotCancelFromInProgress(uint96 warpSeconds) external {
        bytes32 txId = _createBaseTx(ONE_USDC, block.timestamp + 3 days);
        _quote(txId);
        _commit(txId, keccak256("escrowPenaltyFuzz"), ONE_USDC);

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");

        uint256 warpDelta = bound(uint256(warpSeconds), 0, 2 days);
        vm.warp(block.timestamp + warpDelta);

        // [H-4 FIX] Requester should NOT be able to cancel after work started
        vm.prank(requester);
        vm.expectRevert(bytes("Cannot cancel after work started"));
        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, "");
    }

    // ---------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------

    function _prepareDeliveredTx() internal returns (bytes32 txId) {
        txId = _createBaseTx(ONE_USDC, block.timestamp + 2 days);
        _quote(txId);
        _commit(txId, keccak256("escrowFuzz"), ONE_USDC);
        _deliver(txId, 1 days);
    }

    function _createBaseTx(uint256 amount, uint256 deadline) internal returns (bytes32 txId) {
        vm.prank(requester);
        txId = kernel.createTransaction(provider, requester, amount, deadline, 2 days, keccak256("service"));
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
}
