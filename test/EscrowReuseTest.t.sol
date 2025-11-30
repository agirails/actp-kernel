// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ACTPKernel.sol";
import "../src/tokens/MockUSDC.sol";
import "../src/escrow/EscrowVault.sol";

/**
 * @title EscrowReuseTest
 * @notice Test to verify BLOCKER-1 fix: Escrow ID reuse attack is prevented
 */
contract EscrowReuseTest is Test {
    ACTPKernel kernel;
    MockUSDC usdc;
    EscrowVault escrow;

    address admin = address(this);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address attacker = address(0xBAD);
    address feeCollector = address(0xFEE);

    uint256 constant ONE_USDC = 1_000_000;

    function setUp() external {
        kernel = new ACTPKernel(admin, admin, feeCollector);
        usdc = new MockUSDC();
        escrow = new EscrowVault(address(usdc), address(kernel));
        kernel.approveEscrowVault(address(escrow), true);

        // Fund users
        usdc.mint(alice, 10_000_000);
        usdc.mint(attacker, 10_000_000);
    }

    /**
     * @notice M-1 FIX: Verify that escrow IDs CAN be reused after settlement
     * This is now ALLOWED because we delete escrow data after completion
     */
    function testEscrowIdCanBeReusedAfterSettle() external {
        bytes32 sharedEscrowId = keccak256("shared_escrow_id");

        // ==================== TX1: Normal transaction lifecycle ====================
        // Alice creates transaction
        vm.prank(alice);
        bytes32 tx1 = kernel.createTransaction(bob, alice, ONE_USDC, block.timestamp + 7 days, 2 days, keccak256("service1"));

        // Bob quotes
        vm.prank(bob);
        kernel.transitionState(tx1, IACTPKernel.State.QUOTED, "");

        // Alice commits escrow
        vm.startPrank(alice);
        usdc.approve(address(escrow), ONE_USDC);
        kernel.linkEscrow(tx1, address(escrow), sharedEscrowId);
        vm.stopPrank();

        // Bob delivers
        vm.prank(bob);
        kernel.transitionState(tx1, IACTPKernel.State.IN_PROGRESS, "");
        vm.prank(bob);
        kernel.transitionState(tx1, IACTPKernel.State.DELIVERED, abi.encode(1 hours));

        // Alice settles (or wait for dispute window)
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(bob);
        kernel.transitionState(tx1, IACTPKernel.State.SETTLED, "");

        // Verify TX1 is complete and escrow is inactive
        IACTPKernel.TransactionView memory tx1View = kernel.getTransaction(tx1);
        assertEq(uint8(tx1View.state), uint8(IACTPKernel.State.SETTLED));
        assertEq(escrow.remaining(sharedEscrowId), 0); // All funds disbursed

        // ==================== TX2: User can now reuse escrowId ====================
        // Attacker creates transaction (attacker is now requester)
        vm.prank(attacker);
        bytes32 tx2 = kernel.createTransaction(bob, attacker, ONE_USDC, block.timestamp + 7 days, 2 days, keccak256("service2"));

        // User links with SAME escrowId - NOW ALLOWED after previous deletion
        vm.startPrank(attacker);
        usdc.approve(address(escrow), ONE_USDC);
        kernel.linkEscrow(tx2, address(escrow), sharedEscrowId); // ✅ NOW WORKS!
        vm.stopPrank();

        // Verify new escrow is active
        assertEq(escrow.remaining(sharedEscrowId), ONE_USDC);
    }

    /**
     * @notice Verify that escrow IDs CAN be reused after CANCELLED state
     */
    function testEscrowIdCanBeReusedAfterCancel() external {
        bytes32 sharedEscrowId = keccak256("cancelled_escrow");

        // TX1: Create and cancel
        vm.prank(alice);
        bytes32 tx1 = kernel.createTransaction(bob, alice, ONE_USDC, block.timestamp + 1 days, 2 days, keccak256("service"));

        vm.prank(bob);
        kernel.transitionState(tx1, IACTPKernel.State.QUOTED, "");

        vm.startPrank(alice);
        usdc.approve(address(escrow), ONE_USDC);
        kernel.linkEscrow(tx1, address(escrow), sharedEscrowId);
        vm.stopPrank();

        // Cancel after deadline
        vm.warp(block.timestamp + 2 days);
        vm.prank(alice);
        kernel.transitionState(tx1, IACTPKernel.State.CANCELLED, "");

        // Verify funds returned and escrow deleted
        assertEq(escrow.remaining(sharedEscrowId), 0);

        // TX2: Reuse escrowId - NOW ALLOWED
        vm.prank(attacker);
        bytes32 tx2 = kernel.createTransaction(bob, attacker, ONE_USDC, block.timestamp + 7 days, 2 days, keccak256("service2"));

        vm.startPrank(attacker);
        usdc.approve(address(escrow), ONE_USDC);
        kernel.linkEscrow(tx2, address(escrow), sharedEscrowId); // ✅ NOW WORKS!
        vm.stopPrank();

        // Verify new escrow is active
        assertGt(escrow.remaining(sharedEscrowId), 0);
    }

    /**
     * @notice Verify that ACTIVE transactions cannot share the same escrowId
     * (but same ID can be reused after first transaction completes)
     */
    function testActiveTransactionsCannotShareEscrowId() external {
        bytes32 escrowId = keccak256("unique_escrow");

        // TX1: Alice creates transaction
        vm.prank(alice);
        bytes32 tx1 = kernel.createTransaction(bob, alice, ONE_USDC, block.timestamp + 7 days, 2 days, keccak256("service1"));

        vm.startPrank(alice);
        usdc.approve(address(escrow), ONE_USDC);
        kernel.linkEscrow(tx1, address(escrow), escrowId);
        vm.stopPrank();

        // TX2: Alice tries to create another transaction with SAME escrowId - SHOULD FAIL
        vm.prank(alice);
        bytes32 tx2 = kernel.createTransaction(bob, alice, ONE_USDC, block.timestamp + 7 days, 2 days, keccak256("service2"));

        vm.startPrank(alice);
        usdc.approve(address(escrow), ONE_USDC);
        vm.expectRevert("Escrow exists");
        kernel.linkEscrow(tx2, address(escrow), escrowId); // ❌ BLOCKED!
        vm.stopPrank();
    }

    /**
     * @notice Verify that unique escrowIds work correctly (baseline test)
     */
    function testUniqueEscrowIdsWorkCorrectly() external {
        // TX1: Alice creates transaction with escrowId1
        bytes32 escrowId1 = keccak256("escrow1");

        vm.prank(alice);
        bytes32 tx1 = kernel.createTransaction(bob, alice, ONE_USDC, block.timestamp + 7 days, 2 days, keccak256("service1"));

        vm.startPrank(alice);
        usdc.approve(address(escrow), ONE_USDC);
        kernel.linkEscrow(tx1, address(escrow), escrowId1); // ✅ SUCCESS
        vm.stopPrank();

        // TX2: Alice creates transaction with DIFFERENT escrowId2
        bytes32 escrowId2 = keccak256("escrow2"); // DIFFERENT ID

        vm.prank(alice);
        bytes32 tx2 = kernel.createTransaction(bob, alice, ONE_USDC, block.timestamp + 7 days, 2 days, keccak256("service2"));

        vm.startPrank(alice);
        usdc.approve(address(escrow), ONE_USDC);
        kernel.linkEscrow(tx2, address(escrow), escrowId2); // ✅ SUCCESS (different ID)
        vm.stopPrank();

        // Both escrows should be active
        assertGt(escrow.remaining(escrowId1), 0);
        assertGt(escrow.remaining(escrowId2), 0);
    }

    /**
     * @notice Fuzz test: Verify escrowIds CAN be reused after completion
     */
    function testFuzzEscrowIdReusableAfterCompletion(bytes32 escrowId) external {
        // Skip zero escrowId (would fail amount > 0 check anyway)
        vm.assume(escrowId != bytes32(0));

        // TX1: Create and settle
        vm.prank(alice);
        bytes32 tx1 = kernel.createTransaction(bob, alice, ONE_USDC, block.timestamp + 7 days, 2 days, keccak256("service"));

        vm.startPrank(alice);
        usdc.approve(address(escrow), ONE_USDC);
        kernel.linkEscrow(tx1, address(escrow), escrowId);
        vm.stopPrank();

        vm.prank(bob);
        kernel.transitionState(tx1, IACTPKernel.State.IN_PROGRESS, "");
        vm.prank(bob);
        kernel.transitionState(tx1, IACTPKernel.State.DELIVERED, abi.encode(0));

        vm.prank(alice);
        kernel.transitionState(tx1, IACTPKernel.State.SETTLED, "");

        // Verify escrow is deleted (amount reset to 0)
        assertEq(escrow.remaining(escrowId), 0);

        // TX2: Reuse the SAME escrowId - NOW ALLOWED
        vm.prank(attacker);
        bytes32 tx2 = kernel.createTransaction(bob, attacker, ONE_USDC, block.timestamp + 7 days, 2 days, keccak256("service2"));

        vm.startPrank(attacker);
        usdc.approve(address(escrow), ONE_USDC);
        kernel.linkEscrow(tx2, address(escrow), escrowId); // ✅ NOW WORKS!
        vm.stopPrank();

        // Verify new escrow is active with new funds
        assertEq(escrow.remaining(escrowId), ONE_USDC);
    }
}
