// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ACTPKernel.sol";
import "../src/tokens/MockUSDC.sol";
import "../src/escrow/EscrowVault.sol";

/**
 * @title ACTPKernelSecurityTest
 * @notice Tests for security improvements:
 *         - Admin transfer (M-1)
 *         - Escrow vault whitelist (M-2)
 *         - Dispute window cap (M-3)
 */
contract ACTPKernelSecurityTest is Test {
    ACTPKernel kernel;
    MockUSDC usdc;
    EscrowVault escrow;

    address admin = address(this);
    address newAdmin = address(0xABCD);
    address requester = address(0x1);
    address provider = address(0x2);
    address feeCollector = address(0xFEE);

    uint256 constant ONE_USDC = 1_000_000;

    function setUp() external {
        kernel = new ACTPKernel(admin, admin, feeCollector);
        usdc = new MockUSDC();
        escrow = new EscrowVault(address(usdc), address(kernel));
        kernel.approveEscrowVault(address(escrow), true);
        usdc.mint(requester, 1_000_000_000);
    }

    // M-1: Admin Transfer Tests
    function testAdminTransferTwoStep() external {
        // Step 1: Current admin proposes new admin
        kernel.transferAdmin(newAdmin);
        assertEq(kernel.pendingAdmin(), newAdmin);

        // Admin should still be the same
        assertEq(kernel.admin(), admin);

        // Step 2: New admin accepts
        vm.prank(newAdmin);
        kernel.acceptAdmin();

        // Admin should now be updated
        assertEq(kernel.admin(), newAdmin);
        assertEq(kernel.pendingAdmin(), address(0));
    }

    function testAdminTransferRejectsIfNotPending() external {
        kernel.transferAdmin(newAdmin);

        // Random address tries to accept
        vm.prank(address(0xBAD));
        vm.expectRevert("Not pending admin");
        kernel.acceptAdmin();
    }

    function testAdminTransferRequiresCurrentAdmin() external {
        vm.prank(address(0xBAD));
        vm.expectRevert("Not admin");
        kernel.transferAdmin(newAdmin);
    }

    // M-2: Escrow Whitelist Tests
    function testLinkEscrowRequiresApproval() external {
        EscrowVault unapprovedEscrow = new EscrowVault(address(usdc), address(kernel));

        bytes32 txId = _createBaseTx();
        _quote(txId);

        bytes32 escrowId = keccak256("escrow");
        vm.startPrank(requester);
        usdc.approve(address(unapprovedEscrow), ONE_USDC);

        vm.expectRevert("Escrow not approved");
        kernel.linkEscrow(txId, address(unapprovedEscrow), escrowId);
        vm.stopPrank();
    }

    function testApproveEscrowVaultRequiresAdmin() external {
        address fakeEscrow = address(0xFA4E);
        
        vm.prank(address(0xBAD));
        vm.expectRevert("Not admin");
        kernel.approveEscrowVault(fakeEscrow, true);
    }

    function testApproveAndRevokeEscrowVault() external {
        address vault = address(0x123);
        
        // Approve
        kernel.approveEscrowVault(vault, true);
        assertTrue(kernel.approvedEscrowVaults(vault));

        // Revoke
        kernel.approveEscrowVault(vault, false);
        assertFalse(kernel.approvedEscrowVaults(vault));
    }

    // M-3: Dispute Window Cap Tests
    function testDisputeWindowCappedAt30Days() external {
        bytes32 txId = _createBaseTx();
        _quote(txId);
        _commit(txId, keccak256("escrow"), ONE_USDC);
        
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");

        // Try to set dispute window to 31 days (should fail)
        uint256 excessiveWindow = 31 days;
        bytes memory proof = abi.encode(excessiveWindow);

        vm.prank(provider);
        vm.expectRevert("Dispute window too long");
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, proof);
    }

    function testDisputeWindowAccepts30Days() external {
        bytes32 txId = _createBaseTx();
        _quote(txId);
        _commit(txId, keccak256("escrow"), ONE_USDC);
        
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");

        // Set dispute window to exactly 30 days (should succeed)
        uint256 maxWindow = 30 days;
        bytes memory proof = abi.encode(maxWindow);

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, proof);

        IACTPKernel.TransactionView memory txn = kernel.getTransaction(txId);
        assertEq(uint8(txn.state), uint8(IACTPKernel.State.DELIVERED));
        assertEq(txn.disputeWindow, block.timestamp + 30 days);
    }

    // C-1: Fee Exceeds Amount (edge case test)
    function testFeeCalculationNeverExceedsAmount() external {
        // This is implicitly tested by MAX_PLATFORM_FEE_CAP (5%)
        // and the require(fee <= grossAmount) check in _payoutProviderAmount
        
        bytes32 txId = _createBaseTx();
        _quote(txId);
        _commit(txId, keccak256("escrow"), ONE_USDC);
        _deliver(txId, 1 days);
        
        // Settle - fee should never exceed amount (requester settles to avoid dispute window wait)
        vm.prank(requester);
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, "");

        uint256 fee = (ONE_USDC * kernel.platformFeeBps()) / kernel.MAX_BPS();
        uint256 providerNet = ONE_USDC - fee;
        
        assertGt(providerNet, 0);
        assertLe(fee, ONE_USDC);
        assertEq(usdc.balanceOf(provider), providerNet);
        assertEq(usdc.balanceOf(feeCollector), fee);
    }

    // C-4 FIX: Emergency Withdraw tests removed
    // Kernel never holds funds by design - all funds go to EscrowVault
    // Platform fees go directly to feeRecipient (see ACTPKernel.sol line 675)
    // If tokens are accidentally sent to kernel, they are permanently lost (user error)
    // Emergency withdraw was unnecessary and created attack surface

    // Event Tests
    function testUpdatePauserEmitsEvent() external {
        address newPauser = address(0x999);
        
        vm.expectEmit(true, true, false, false);
        emit PauserUpdated(admin, newPauser);
        kernel.updatePauser(newPauser);
        
        assertEq(kernel.pauser(), newPauser);
    }

    function testUpdateFeeRecipientEmitsEvent() external {
        address newRecipient = address(0x888);
        
        vm.expectEmit(true, true, false, false);
        emit FeeRecipientUpdated(feeCollector, newRecipient);
        kernel.updateFeeRecipient(newRecipient);
        
        assertEq(kernel.feeRecipient(), newRecipient);
    }

    // Mediator Collision Tests
    function testMediatorAddressValidation() external {
        bytes32 txId = _createBaseTx();
        _quote(txId);
        _commit(txId, keccak256("escrowMediator"), ONE_USDC);
        _deliver(txId, 1 days);
        
        vm.prank(requester);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");

        // Try to submit resolution with mediatorAmount > 0 but address(0)
        bytes memory badProof = abi.encode(
            uint256(0),           // requesterAmount
            uint256(ONE_USDC/2),  // providerAmount
            address(0),           // mediator (ZERO!)
            uint256(ONE_USDC/2)   // mediatorAmount (NON-ZERO!)
        );

        vm.expectRevert("Mediator address required");
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, badProof);
    }

    function testMediatorCollisionWithProvider() external {
        bytes32 txId = _createBaseTx();
        _quote(txId);
        _commit(txId, keccak256("escrowMediatorProvider"), ONE_USDC);
        _deliver(txId, 1 days);
        
        vm.prank(requester);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");

        // Mediator is same as provider (should work but test balance accounting)
        // Mediator fee capped at 10% of transaction amount
        uint256 mediatorAward = ONE_USDC / 10;  // 10% max mediator fee
        uint256 providerAward = ONE_USDC / 3;
        // H-2 FIX: Must distribute exactly ONE_USDC
        uint256 requesterAmount = ONE_USDC - providerAward - mediatorAward;

        // Approve provider as mediator and wait for time-lock
        kernel.approveMediator(provider, true);
        vm.warp(block.timestamp + 2 days + 1);

        bytes memory proof = abi.encode(
            requesterAmount,   // requesterAmount (remaining)
            providerAward,     // providerAmount
            provider,          // mediator = provider!
            mediatorAward      // mediatorAmount
        );

        kernel.transitionState(txId, IACTPKernel.State.SETTLED, proof);

        // Provider should receive both provider award (net of fee) + mediator award
        uint256 providerFee = (providerAward * kernel.platformFeeBps()) / kernel.MAX_BPS();
        uint256 expectedBalance = (providerAward - providerFee) + mediatorAward;
        
        assertEq(usdc.balanceOf(provider), expectedBalance);
    }

    // Events (for expectEmit)
    event PauserUpdated(address indexed oldPauser, address indexed newPauser);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    // Helpers
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
}

