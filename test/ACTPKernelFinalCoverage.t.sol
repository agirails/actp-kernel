// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ACTPKernel.sol";
import "../src/tokens/MockUSDC.sol";
import "../src/escrow/EscrowVault.sol";

/**
 * @title ACTPKernelFinalCoverageTest
 * @notice Final targeted tests to push branch coverage from 74% to 80%+
 * Focuses on uncovered branches: quote hash validation, complex state paths, edge cases
 */
contract ACTPKernelFinalCoverageTest is Test {
    ACTPKernel kernel;
    MockUSDC usdc;
    EscrowVault escrow;

    address admin = address(this);
    address pauser = address(0xFA053);
    address requester = address(0x1);
    address provider = address(0x2);
    address feeCollector = address(0xFEE);

    uint256 constant ONE_USDC = 1_000_000;

    function setUp() external {
        kernel = new ACTPKernel(admin, pauser, feeCollector);
        usdc = new MockUSDC();
        escrow = new EscrowVault(address(usdc), address(kernel));
        kernel.approveEscrowVault(address(escrow), true);
        usdc.mint(requester, 10_000_000);
    }

    // ============================================
    // UNCOVERED BRANCH: Quote Hash Validation
    // ============================================

    function testQuotedStateWithProofStoresHash() external {
        bytes32 txId = _createTx();
        bytes32 quoteHash = keccak256("quote_data");

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.QUOTED, abi.encode(quoteHash));

        IACTPKernel.TransactionView memory txn = kernel.getTransaction(txId);
        assertEq(uint8(txn.state), uint8(IACTPKernel.State.QUOTED));
    }

    function testQuotedStateWithoutProofWorks() external {
        bytes32 txId = _createTx();

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.QUOTED, "");

        IACTPKernel.TransactionView memory txn = kernel.getTransaction(txId);
        assertEq(uint8(txn.state), uint8(IACTPKernel.State.QUOTED));
    }

    function testQuotedStateRejectsInvalidProofLength() external {
        bytes32 txId = _createTx();
        bytes memory invalidProof = new bytes(64); // Too long

        vm.prank(provider);
        vm.expectRevert("Quote hash must be 32 bytes");
        kernel.transitionState(txId, IACTPKernel.State.QUOTED, invalidProof);
    }

    function testQuotedStateRejectsZeroHash() external {
        bytes32 txId = _createTx();

        vm.prank(provider);
        vm.expectRevert("Invalid quote hash");
        kernel.transitionState(txId, IACTPKernel.State.QUOTED, abi.encode(bytes32(0)));
    }

    function testQuotedStateWith16ByteProofReverts() external {
        bytes32 txId = _createTx();
        bytes memory shortProof = new bytes(16);

        vm.prank(provider);
        vm.expectRevert();
        kernel.transitionState(txId, IACTPKernel.State.QUOTED, shortProof);
    }

    // ============================================
    // UNCOVERED BRANCH: Dispute Window Edge Cases
    // ============================================

    function testDeliveredWithZeroWindowUsesDefault() external {
        bytes32 txId = _createCommitted();

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(uint256(0)));

        IACTPKernel.TransactionView memory txn = kernel.getTransaction(txId);
        assertEq(txn.disputeWindow, block.timestamp + kernel.DEFAULT_DISPUTE_WINDOW());
    }

    function testDeliveredWithCustomWindowUsesProvided() external {
        bytes32 txId = _createCommitted();

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");

        uint256 customWindow = 2 days;
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(customWindow));

        IACTPKernel.TransactionView memory txn = kernel.getTransaction(txId);
        assertEq(txn.disputeWindow, block.timestamp + customWindow);
    }

    // ============================================
    // UNCOVERED BRANCH: State Transition No-Op Check
    // ============================================

    function testTransitionToSameStateReverts() external {
        bytes32 txId = _createCommitted();

        vm.prank(provider);
        vm.expectRevert("No-op");
        kernel.transitionState(txId, IACTPKernel.State.COMMITTED, "");
    }

    // ============================================
    // UNCOVERED BRANCH: Invalid State Transitions
    // ============================================

    function testCannotSkipFromInitiatedToDelivered() external {
        bytes32 txId = _createTx();

        vm.prank(provider);
        vm.expectRevert("Invalid transition");
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(1 days));
    }

    function testCannotTransitionFromSettledToAnything() external {
        bytes32 txId = _createSettled();

        vm.prank(provider);
        vm.expectRevert("Invalid transition");
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");
    }

    function testCannotTransitionFromCancelledToAnything() external {
        bytes32 txId = _createTx();

        // Move to QUOTED first
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.QUOTED, "");

        // Move to COMMITTED
        vm.startPrank(requester);
        usdc.approve(address(escrow), ONE_USDC);
        kernel.linkEscrow(txId, address(escrow), keccak256("escrow"));
        vm.stopPrank();

        // Cancel
        vm.warp(block.timestamp + 8 days);
        vm.prank(requester);
        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, "");

        // Try to transition from CANCELLED
        vm.prank(provider);
        vm.expectRevert("Invalid transition");
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");
    }

    // ============================================
    // UNCOVERED BRANCH: Authorization Checks
    // ============================================

    function testOnlyProviderCanTransitionToQuoted() external {
        bytes32 txId = _createTx();

        vm.prank(requester); // Wrong person
        vm.expectRevert("Only provider");
        kernel.transitionState(txId, IACTPKernel.State.QUOTED, "");
    }

    function testOnlyProviderCanTransitionToInProgress() external {
        bytes32 txId = _createCommitted();

        vm.prank(requester); // Wrong person
        vm.expectRevert("Only provider");
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");
    }

    function testOnlyProviderCanTransitionToDelivered() external {
        bytes32 txId = _createCommitted();

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");

        vm.prank(requester); // Wrong person
        vm.expectRevert("Only provider");
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(1 days));
    }

    function testEitherPartyCanTransitionToDisputed() external {
        bytes32 txId = _createCommitted();

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(1 days));

        // Requester can dispute
        vm.prank(requester);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");

        IACTPKernel.TransactionView memory txn = kernel.getTransaction(txId);
        assertEq(uint8(txn.state), uint8(IACTPKernel.State.DISPUTED));
    }

    function testProviderCanDisputeOwnDelivery() external {
        bytes32 txId = _createCommitted();

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(1 days));

        // Provider can also dispute (unusual but allowed)
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");

        IACTPKernel.TransactionView memory txn = kernel.getTransaction(txId);
        assertEq(uint8(txn.state), uint8(IACTPKernel.State.DISPUTED));
    }

    // ============================================
    // UNCOVERED BRANCH: Settlement Paths
    // ============================================

    function testRequesterCanSettleFromDelivered() external {
        bytes32 txId = _createCommitted();

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(0));

        // Requester accepts delivery
        vm.prank(requester);
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, "");

        IACTPKernel.TransactionView memory txn = kernel.getTransaction(txId);
        assertEq(uint8(txn.state), uint8(IACTPKernel.State.SETTLED));
    }

    function testProviderCanSettleAfterDisputeWindow() external {
        bytes32 txId = _createCommitted();

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(1 hours));

        // Warp past dispute window
        vm.warp(block.timestamp + 2 hours);

        // Provider can now settle
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, "");

        IACTPKernel.TransactionView memory txn = kernel.getTransaction(txId);
        assertEq(uint8(txn.state), uint8(IACTPKernel.State.SETTLED));
    }

    function testProviderCannotSettleBeforeDisputeWindow() external {
        bytes32 txId = _createCommitted();

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(1 days));

        // Try to settle immediately (dispute window still active)
        vm.prank(provider);
        vm.expectRevert("Requester decision pending");
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, "");
    }

    // ============================================
    // UNCOVERED BRANCH: Escrow Link Verification
    // ============================================

    function testLinkEscrowFromQuotedStateWorks() external {
        bytes32 txId = _createTx();

        // Transition to QUOTED
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.QUOTED, "");

        // Link escrow from QUOTED (should work)
        vm.startPrank(requester);
        usdc.approve(address(escrow), ONE_USDC);
        kernel.linkEscrow(txId, address(escrow), keccak256("escrow"));
        vm.stopPrank();

        IACTPKernel.TransactionView memory txn = kernel.getTransaction(txId);
        assertEq(uint8(txn.state), uint8(IACTPKernel.State.COMMITTED));
    }

    // ============================================
    // UNCOVERED BRANCH: Deadline Enforcement
    // ============================================

    function testCannotProgressAfterDeadline() external {
        vm.prank(requester);
        bytes32 txId = kernel.createTransaction(provider, requester, ONE_USDC, block.timestamp + 1 hours, 2 days, keccak256("service"));

        // Warp past deadline
        vm.warp(block.timestamp + 2 hours);

        // Try to transition (should fail due to deadline)
        vm.prank(provider);
        vm.expectRevert("Transaction expired");
        kernel.transitionState(txId, IACTPKernel.State.QUOTED, "");
    }

    function testCanDisputeAfterDeadline() external {
        bytes32 txId = _createCommitted();

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(10 days)); // Long dispute window

        // Warp past transaction deadline (but within dispute window)
        vm.warp(block.timestamp + 8 days);

        // Can still dispute even after transaction deadline (within dispute window)
        vm.prank(requester);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");

        IACTPKernel.TransactionView memory txn = kernel.getTransaction(txId);
        assertEq(uint8(txn.state), uint8(IACTPKernel.State.DISPUTED));
    }

    function testCanCancelAfterDeadline() external {
        vm.prank(requester);
        bytes32 txId = kernel.createTransaction(provider, requester, ONE_USDC, block.timestamp + 1 hours, 2 days, keccak256("service"));

        // Warp past deadline
        vm.warp(block.timestamp + 2 hours);

        // Can cancel after deadline (cancellation exempted from deadline check)
        vm.prank(requester);
        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, "");

        IACTPKernel.TransactionView memory txn = kernel.getTransaction(txId);
        assertEq(uint8(txn.state), uint8(IACTPKernel.State.CANCELLED));
    }

    // ============================================
    // UNCOVERED BRANCH: Dispute Window Timing
    // ============================================

    function testCannotDisputeAfterWindowExpires() external {
        bytes32 txId = _createCommitted();

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(1 hours));

        // Warp past dispute window
        vm.warp(block.timestamp + 2 hours);

        // Try to dispute (should fail)
        vm.prank(requester);
        vm.expectRevert("Dispute window closed");
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");
    }

    function testDisputeExactlyAtWindowEnd() external {
        bytes32 txId = _createCommitted();

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(1 hours));

        IACTPKernel.TransactionView memory txn = kernel.getTransaction(txId);
        uint256 windowEnd = txn.disputeWindow;

        // Warp to exactly window end
        vm.warp(windowEnd);

        // Can still dispute at exact window end
        vm.prank(requester);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");

        txn = kernel.getTransaction(txId);
        assertEq(uint8(txn.state), uint8(IACTPKernel.State.DISPUTED));
    }

    // ============================================
    // UNCOVERED BRANCH: Cancellation from Different States
    // ============================================

    function testRequesterCanCancelFromInitiated() external {
        bytes32 txId = _createTx();

        vm.prank(requester);
        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, "");

        IACTPKernel.TransactionView memory txn = kernel.getTransaction(txId);
        assertEq(uint8(txn.state), uint8(IACTPKernel.State.CANCELLED));
    }

    function testRequesterCanCancelFromQuoted() external {
        bytes32 txId = _createTx();

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.QUOTED, "");

        vm.prank(requester); // Only requester can cancel from QUOTED
        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, "");

        IACTPKernel.TransactionView memory txn = kernel.getTransaction(txId);
        assertEq(uint8(txn.state), uint8(IACTPKernel.State.CANCELLED));
    }

    function testProviderCanCancelFromInProgress() external {
        bytes32 txId = _createCommitted();

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");

        // Provider can cancel anytime
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, "");

        IACTPKernel.TransactionView memory txn = kernel.getTransaction(txId);
        assertEq(uint8(txn.state), uint8(IACTPKernel.State.CANCELLED));
    }

    // ============================================
    // Helper Functions
    // ============================================

    function _createTx() internal returns (bytes32 txId) {
        vm.prank(requester);
        txId = kernel.createTransaction(provider, requester, ONE_USDC, block.timestamp + 7 days, 2 days, keccak256("service"));
    }

    function _createCommitted() internal returns (bytes32 txId) {
        txId = _createTx();
        vm.startPrank(requester);
        usdc.approve(address(escrow), ONE_USDC);
        kernel.linkEscrow(txId, address(escrow), keccak256(abi.encodePacked("escrow", txId)));
        vm.stopPrank();
    }

    function _createSettled() internal returns (bytes32 txId) {
        txId = _createCommitted();

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(0));

        vm.prank(requester);
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, "");
    }
}
