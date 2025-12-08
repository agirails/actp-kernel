// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/escrow/EscrowVault.sol";
import "../src/tokens/MockUSDC.sol";

/**
 * @title EscrowVaultBranchCoverageTest
 * @notice Tests to achieve 80%+ branch coverage on EscrowVault
 */
contract EscrowVaultBranchCoverageTest is Test {
    EscrowVault escrow;
    MockUSDC usdc;

    address kernel = address(0xAAAA);
    address requester = address(0x1);
    address provider = address(0x2);
    address attacker = address(0xBAD);

    uint256 constant ONE_USDC = 1_000_000;

    function setUp() external {
        usdc = new MockUSDC();
        escrow = new EscrowVault(address(usdc), kernel);
        usdc.mint(requester, 1_000_000 * ONE_USDC);

        // Approve escrow to spend requester's USDC
        vm.prank(requester);
        usdc.approve(address(escrow), type(uint256).max);
    }

    // ============================================
    // CONSTRUCTOR BRANCH TESTS
    // ============================================

    function testConstructorRejectsZeroToken() external {
        vm.expectRevert("Zero address");
        new EscrowVault(address(0), kernel);
    }

    function testConstructorRejectsZeroKernel() external {
        vm.expectRevert("Zero address");
        new EscrowVault(address(usdc), address(0));
    }

    function testConstructorRejectsBothZero() external {
        vm.expectRevert("Zero address");
        new EscrowVault(address(0), address(0));
    }

    function testConstructorRejectsTokenEqualsKernel() external {
        vm.expectRevert("Token and kernel must differ");
        new EscrowVault(address(usdc), address(usdc));
    }

    // ============================================
    // onlyKernel MODIFIER BRANCH TESTS
    // ============================================

    function testCreateEscrowRejectsNonKernel() external {
        vm.prank(attacker);
        vm.expectRevert("Only kernel");
        escrow.createEscrow(keccak256("escrow1"), requester, provider, ONE_USDC);
    }

    function testPayoutToProviderRejectsNonKernel() external {
        bytes32 escrowId = _createEscrow(ONE_USDC);

        vm.prank(attacker);
        vm.expectRevert("Only kernel");
        escrow.payoutToProvider(escrowId, ONE_USDC);
    }

    function testRefundToRequesterRejectsNonKernel() external {
        bytes32 escrowId = _createEscrow(ONE_USDC);

        vm.prank(attacker);
        vm.expectRevert("Only kernel");
        escrow.refundToRequester(escrowId, ONE_USDC);
    }

    function testPayoutRejectsNonKernel() external {
        bytes32 escrowId = _createEscrow(ONE_USDC);

        vm.prank(attacker);
        vm.expectRevert("Only kernel");
        escrow.payout(escrowId, provider, ONE_USDC);
    }

    // ============================================
    // createEscrow BRANCH TESTS
    // ============================================

    function testCreateEscrowRejectsExistingEscrow() external {
        bytes32 escrowId = _createEscrow(ONE_USDC);

        vm.prank(kernel);
        vm.expectRevert("Escrow exists");
        escrow.createEscrow(escrowId, requester, provider, ONE_USDC);
    }

    function testCreateEscrowRejectsZeroRequester() external {
        vm.prank(kernel);
        vm.expectRevert("Zero address");
        escrow.createEscrow(keccak256("new"), address(0), provider, ONE_USDC);
    }

    function testCreateEscrowRejectsZeroProvider() external {
        vm.prank(kernel);
        vm.expectRevert("Zero address");
        escrow.createEscrow(keccak256("new"), requester, address(0), ONE_USDC);
    }

    function testCreateEscrowRejectsBothZeroAddresses() external {
        vm.prank(kernel);
        vm.expectRevert("Zero address");
        escrow.createEscrow(keccak256("new"), address(0), address(0), ONE_USDC);
    }

    function testCreateEscrowRejectsZeroAmount() external {
        vm.prank(kernel);
        vm.expectRevert("Amount zero");
        escrow.createEscrow(keccak256("new"), requester, provider, 0);
    }

    function testCreateEscrowSuccess() external {
        bytes32 escrowId = keccak256("new");

        vm.prank(kernel);
        escrow.createEscrow(escrowId, requester, provider, ONE_USDC);

        assertEq(escrow.remaining(escrowId), ONE_USDC);
    }

    // ============================================
    // payoutToProvider BRANCH TESTS
    // ============================================

    function testPayoutToProviderRejectsMissingEscrow() external {
        bytes32 fakeId = keccak256("nonexistent");

        vm.prank(kernel);
        vm.expectRevert("Escrow missing");
        escrow.payoutToProvider(fakeId, ONE_USDC);
    }

    function testPayoutToProviderSuccess() external {
        bytes32 escrowId = _createEscrow(ONE_USDC);

        uint256 providerBalanceBefore = usdc.balanceOf(provider);

        vm.prank(kernel);
        escrow.payoutToProvider(escrowId, ONE_USDC);

        assertEq(usdc.balanceOf(provider), providerBalanceBefore + ONE_USDC);
    }

    // ============================================
    // refundToRequester BRANCH TESTS
    // ============================================

    function testRefundToRequesterRejectsMissingEscrow() external {
        bytes32 fakeId = keccak256("nonexistent");

        vm.prank(kernel);
        vm.expectRevert("Escrow missing");
        escrow.refundToRequester(fakeId, ONE_USDC);
    }

    function testRefundToRequesterSuccess() external {
        bytes32 escrowId = _createEscrow(ONE_USDC);

        uint256 requesterBalanceBefore = usdc.balanceOf(requester);

        vm.prank(kernel);
        escrow.refundToRequester(escrowId, ONE_USDC);

        assertEq(usdc.balanceOf(requester), requesterBalanceBefore + ONE_USDC);
    }

    // ============================================
    // payout BRANCH TESTS
    // ============================================

    function testPayoutRejectsZeroRecipient() external {
        bytes32 escrowId = _createEscrow(ONE_USDC);

        vm.prank(kernel);
        vm.expectRevert("Zero recipient");
        escrow.payout(escrowId, address(0), ONE_USDC);
    }

    function testPayoutToThirdPartySuccess() external {
        bytes32 escrowId = _createEscrow(ONE_USDC);
        address thirdParty = address(0x3);

        vm.prank(kernel);
        escrow.payout(escrowId, thirdParty, ONE_USDC);

        assertEq(usdc.balanceOf(thirdParty), ONE_USDC);
    }

    // ============================================
    // _disburse BRANCH TESTS
    // ============================================

    function testDisburseRejectsInactiveEscrow() external {
        bytes32 escrowId = _createEscrow(ONE_USDC);

        // Fully disburse to make inactive
        vm.prank(kernel);
        escrow.payoutToProvider(escrowId, ONE_USDC);

        // Now try to disburse again
        vm.prank(kernel);
        vm.expectRevert("Escrow missing"); // provider is now address(0) after delete
        escrow.payoutToProvider(escrowId, ONE_USDC);
    }

    function testDisburseRejectsZeroAmount() external {
        bytes32 escrowId = _createEscrow(ONE_USDC);

        vm.prank(kernel);
        vm.expectRevert("Amount zero");
        escrow.payoutToProvider(escrowId, 0);
    }

    function testDisburseRejectsInsufficientEscrow() external {
        bytes32 escrowId = _createEscrow(ONE_USDC);

        vm.prank(kernel);
        vm.expectRevert("Insufficient escrow");
        escrow.payoutToProvider(escrowId, ONE_USDC + 1);
    }

    function testDisbursePartialThenFull() external {
        bytes32 escrowId = _createEscrow(100 * ONE_USDC);

        // Partial payout
        vm.prank(kernel);
        escrow.payoutToProvider(escrowId, 30 * ONE_USDC);

        assertEq(escrow.remaining(escrowId), 70 * ONE_USDC);

        // Remaining payout - should complete escrow
        vm.prank(kernel);
        escrow.payoutToProvider(escrowId, 70 * ONE_USDC);

        assertEq(escrow.remaining(escrowId), 0);
    }

    function testDisburseCompletesAndDeletesEscrow() external {
        bytes32 escrowId = _createEscrow(ONE_USDC);

        vm.prank(kernel);
        escrow.payoutToProvider(escrowId, ONE_USDC);

        // Escrow should be deleted - remaining returns 0
        assertEq(escrow.remaining(escrowId), 0);

        // Verify escrow data is cleared
        (address storedRequester, address storedProvider, uint256 amount, uint256 released, bool active) = escrow.escrows(escrowId);
        assertEq(storedRequester, address(0));
        assertEq(storedProvider, address(0));
        assertEq(amount, 0);
        assertEq(released, 0);
        assertFalse(active);
    }

    // ============================================
    // verifyEscrow BRANCH TESTS
    // ============================================

    function testVerifyEscrowReturnsFalseWhenInactive() external {
        bytes32 escrowId = _createEscrow(ONE_USDC);

        // Complete the escrow
        vm.prank(kernel);
        escrow.payoutToProvider(escrowId, ONE_USDC);

        // Verify returns false for inactive
        (bool isActive, uint256 amount) = escrow.verifyEscrow(escrowId, requester, provider, ONE_USDC);
        assertFalse(isActive);
        assertEq(amount, 0);
    }

    function testVerifyEscrowReturnsFalseWhenRequesterMismatch() external {
        bytes32 escrowId = _createEscrow(ONE_USDC);

        (bool isActive, ) = escrow.verifyEscrow(escrowId, attacker, provider, ONE_USDC);
        assertFalse(isActive);
    }

    function testVerifyEscrowReturnsFalseWhenProviderMismatch() external {
        bytes32 escrowId = _createEscrow(ONE_USDC);

        (bool isActive, ) = escrow.verifyEscrow(escrowId, requester, attacker, ONE_USDC);
        assertFalse(isActive);
    }

    function testVerifyEscrowReturnsFalseWhenAmountTooHigh() external {
        bytes32 escrowId = _createEscrow(ONE_USDC);

        (bool isActive, ) = escrow.verifyEscrow(escrowId, requester, provider, ONE_USDC + 1);
        assertFalse(isActive);
    }

    function testVerifyEscrowReturnsTrueWhenValid() external {
        bytes32 escrowId = _createEscrow(ONE_USDC);

        (bool isActive, uint256 amount) = escrow.verifyEscrow(escrowId, requester, provider, ONE_USDC);
        assertTrue(isActive);
        assertEq(amount, ONE_USDC);
    }

    function testVerifyEscrowReturnsTrueWhenAmountLower() external {
        bytes32 escrowId = _createEscrow(100 * ONE_USDC);

        // Verify with lower amount should still return true
        (bool isActive, uint256 amount) = escrow.verifyEscrow(escrowId, requester, provider, 50 * ONE_USDC);
        assertTrue(isActive);
        assertEq(amount, 100 * ONE_USDC);
    }

    // ============================================
    // remaining BRANCH TESTS
    // ============================================

    function testRemainingReturnsZeroForNonexistent() external {
        bytes32 fakeId = keccak256("nonexistent");
        assertEq(escrow.remaining(fakeId), 0);
    }

    function testRemainingReturnsCorrectAfterPartialPayout() external {
        bytes32 escrowId = _createEscrow(100 * ONE_USDC);

        vm.prank(kernel);
        escrow.payoutToProvider(escrowId, 40 * ONE_USDC);

        assertEq(escrow.remaining(escrowId), 60 * ONE_USDC);
    }

    // ============================================
    // EDGE CASE TESTS
    // ============================================

    function testMultiplePayoutsToMultipleRecipients() external {
        bytes32 escrowId = _createEscrow(100 * ONE_USDC);
        address recipient1 = address(0x111);
        address recipient2 = address(0x222);

        vm.prank(kernel);
        escrow.payout(escrowId, recipient1, 30 * ONE_USDC);

        vm.prank(kernel);
        escrow.payout(escrowId, recipient2, 30 * ONE_USDC);

        vm.prank(kernel);
        escrow.payoutToProvider(escrowId, 40 * ONE_USDC);

        assertEq(usdc.balanceOf(recipient1), 30 * ONE_USDC);
        assertEq(usdc.balanceOf(recipient2), 30 * ONE_USDC);
        assertEq(usdc.balanceOf(provider), 40 * ONE_USDC);
        assertEq(escrow.remaining(escrowId), 0);
    }

    function testExactAmountPayout() external {
        bytes32 escrowId = _createEscrow(ONE_USDC);

        // Payout exact amount
        vm.prank(kernel);
        escrow.payoutToProvider(escrowId, ONE_USDC);

        // Escrow should be completed and deleted
        assertEq(escrow.remaining(escrowId), 0);
    }

    function testOneWeiOverLimitReverts() external {
        bytes32 escrowId = _createEscrow(ONE_USDC);

        vm.prank(kernel);
        vm.expectRevert("Insufficient escrow");
        escrow.payoutToProvider(escrowId, ONE_USDC + 1);
    }

    // ============================================
    // FUZZ TESTS
    // ============================================

    function testFuzzCreateAndPayout(uint96 amount) external {
        vm.assume(amount > 0);
        vm.assume(amount <= 1_000_000 * ONE_USDC);

        bytes32 escrowId = keccak256(abi.encodePacked("fuzz", amount));

        vm.prank(kernel);
        escrow.createEscrow(escrowId, requester, provider, amount);

        assertEq(escrow.remaining(escrowId), amount);

        vm.prank(kernel);
        escrow.payoutToProvider(escrowId, amount);

        assertEq(escrow.remaining(escrowId), 0);
        assertEq(usdc.balanceOf(provider), amount);
    }

    function testFuzzPartialPayouts(uint96 total, uint96 first) external {
        vm.assume(total > 0);
        vm.assume(total <= 1_000_000 * ONE_USDC);
        vm.assume(first > 0);
        vm.assume(first < total);

        bytes32 escrowId = keccak256(abi.encodePacked("fuzz_partial", total, first));

        vm.prank(kernel);
        escrow.createEscrow(escrowId, requester, provider, total);

        vm.prank(kernel);
        escrow.payoutToProvider(escrowId, first);

        uint256 remaining = total - first;
        assertEq(escrow.remaining(escrowId), remaining);

        vm.prank(kernel);
        escrow.payoutToProvider(escrowId, remaining);

        assertEq(escrow.remaining(escrowId), 0);
    }

    // ============================================
    // HELPER FUNCTIONS
    // ============================================

    function _createEscrow(uint256 amount) internal returns (bytes32 escrowId) {
        escrowId = keccak256(abi.encodePacked("escrow", block.timestamp, amount));
        vm.prank(kernel);
        escrow.createEscrow(escrowId, requester, provider, amount);
    }
}
