// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ACTPKernel.sol";
import "../src/tokens/MockUSDC.sol";
import "../src/escrow/EscrowVault.sol";

/**
 * @title ACTPKernelBranchCoverageTest
 * @notice Targeted tests to achieve 80%+ branch coverage
 * Focuses on uncovered branches in admin functions, emergency scenarios, and complex paths
 */
contract ACTPKernelBranchCoverageTest is Test {
    ACTPKernel kernel;
    MockUSDC usdc;
    EscrowVault escrow;

    address admin = address(this);
    address newAdmin = address(0xAD111);
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
        // C-4 FIX: No longer minting to kernel - kernel never holds funds
    }

    // ============================================
    // BRANCH COVERAGE: Admin Transfer
    // ============================================

    function testAdminTransferRejectsZeroAddress() external {
        vm.expectRevert("Zero admin");
        kernel.transferAdmin(address(0));
    }

    function testAdminTransferRejectsNonAdmin() external {
        vm.prank(address(0xBAD));
        vm.expectRevert("Not admin");
        kernel.transferAdmin(newAdmin);
    }

    function testAdminTransferUpdatesPendingAdmin() external {
        kernel.transferAdmin(newAdmin);
        assertEq(kernel.pendingAdmin(), newAdmin);
        assertEq(kernel.admin(), admin); // Not yet transferred
    }

    function testAcceptAdminRejectsNonPending() external {
        kernel.transferAdmin(newAdmin);

        vm.prank(address(0xBAD));
        vm.expectRevert("Not pending admin");
        kernel.acceptAdmin();
    }

    function testAcceptAdminTransfersRole() external {
        kernel.transferAdmin(newAdmin);

        vm.prank(newAdmin);
        kernel.acceptAdmin();

        assertEq(kernel.admin(), newAdmin);
        assertEq(kernel.pendingAdmin(), address(0));
    }

    // ============================================
    // BRANCH COVERAGE: Pauser Management
    // ============================================

    function testUpdatePauserRejectsZeroAddress() external {
        vm.expectRevert("Zero pauser");
        kernel.updatePauser(address(0));
    }

    function testUpdatePauserRejectsNonAdmin() external {
        vm.prank(address(0xBAD));
        vm.expectRevert("Not admin");
        kernel.updatePauser(address(0x999));
    }

    function testUpdatePauserChangesRole() external {
        address newPauser = address(0x999);
        kernel.updatePauser(newPauser);
        assertEq(kernel.pauser(), newPauser);
    }

    // ============================================
    // BRANCH COVERAGE: Fee Recipient Management
    // ============================================

    function testUpdateFeeRecipientRejectsZeroAddress() external {
        vm.expectRevert("Zero recipient");
        kernel.updateFeeRecipient(address(0));
    }

    function testUpdateFeeRecipientRejectsNonAdmin() external {
        vm.prank(address(0xBAD));
        vm.expectRevert("Not admin");
        kernel.updateFeeRecipient(address(0x888));
    }

    function testUpdateFeeRecipientChangesRecipient() external {
        address newRecipient = address(0x888);
        kernel.updateFeeRecipient(newRecipient);
        assertEq(kernel.feeRecipient(), newRecipient);
    }

    // ============================================
    // BRANCH COVERAGE: Pause/Unpause
    // ============================================

    function testPauseRejectsNonPauser() external {
        vm.prank(address(0xBAD));
        vm.expectRevert("Not pauser");
        kernel.pause();
    }

    function testPauseByPauser() external {
        vm.prank(pauser);
        kernel.pause();
        assertTrue(kernel.paused());
    }

    function testPauseByAdmin() external {
        kernel.pause();
        assertTrue(kernel.paused());
    }

    function testUnpauseRejectsNonAdmin() external {
        kernel.pause();

        vm.prank(address(0xBAD));
        vm.expectRevert("Not pauser");
        kernel.unpause();
    }

    function testUnpauseByAdmin() external {
        kernel.pause();
        kernel.unpause();
        assertFalse(kernel.paused());
    }

    function testPausedTransactionCreationReverts() external {
        kernel.pause();

        bytes32 txId = keccak256("paused_tx");
        vm.prank(requester);
        vm.expectRevert("Kernel paused");
        kernel.createTransaction(txId, provider, ONE_USDC, keccak256("service"), block.timestamp + 7 days);
    }

    function testPausedLinkEscrowReverts() external {
        bytes32 txId = _createTx();

        kernel.pause();

        vm.startPrank(requester);
        usdc.approve(address(escrow), ONE_USDC);
        vm.expectRevert("Kernel paused");
        kernel.linkEscrow(txId, address(escrow), keccak256("escrow"));
        vm.stopPrank();
    }

    // ============================================
    // C-4 FIX: Emergency Withdraw tests removed
    // Kernel never holds funds by design - all funds go to EscrowVault
    // Platform fees go directly to feeRecipient
    // Emergency withdraw was unnecessary and created attack surface
    // ============================================

    // ============================================
    // BRANCH COVERAGE: Escrow Vault Approval
    // ============================================

    function testApproveEscrowVaultRejectsNonAdmin() external {
        vm.prank(address(0xBAD));
        vm.expectRevert("Not admin");
        kernel.approveEscrowVault(address(0x123), true);
    }

    function testApproveEscrowVaultSetsApproval() external {
        address vault = address(0x123);
        kernel.approveEscrowVault(vault, true);
        assertTrue(kernel.approvedEscrowVaults(vault));
    }

    function testRevokeEscrowVaultClearsApproval() external {
        address vault = address(0x123);
        kernel.approveEscrowVault(vault, true);
        kernel.approveEscrowVault(vault, false);
        assertFalse(kernel.approvedEscrowVaults(vault));
    }

    // ============================================
    // BRANCH COVERAGE: Mediator Approval
    // ============================================

    function testApproveMediatorRejectsZeroAddress() external {
        vm.expectRevert("Zero mediator");
        kernel.approveMediator(address(0), true);
    }

    function testApproveMediatorRejectsNonAdmin() external {
        vm.prank(address(0xBAD));
        vm.expectRevert("Not admin");
        kernel.approveMediator(address(0x99), true);
    }

    function testApproveMediatorSetsTimelock() external {
        address mediator = address(0x99);
        kernel.approveMediator(mediator, true);

        assertTrue(kernel.approvedMediators(mediator));
        assertGt(kernel.mediatorApprovedAt(mediator), block.timestamp);
    }

    function testRevokeMediatorClearsTimelock() external {
        address mediator = address(0x99);
        kernel.approveMediator(mediator, true);
        assertGt(kernel.mediatorApprovedAt(mediator), 0);

        kernel.approveMediator(mediator, false);

        assertFalse(kernel.approvedMediators(mediator));
        assertEq(kernel.mediatorApprovedAt(mediator), 0); // M-2 FIX: Timelock DELETED
    }

    function testReapproveMediatorResetsTimelock() external {
        address mediator = address(0x99);
        kernel.approveMediator(mediator, true);
        uint256 timelockFirst = kernel.mediatorApprovedAt(mediator);

        // Disapprove (timelock deleted)
        kernel.approveMediator(mediator, false);
        assertEq(kernel.mediatorApprovedAt(mediator), 0);

        // Re-approve (new timelock set)
        vm.warp(block.timestamp + 1 days); // Time passes
        kernel.approveMediator(mediator, true);
        uint256 timelockSecond = kernel.mediatorApprovedAt(mediator);

        assertGt(timelockSecond, timelockFirst); // M-2 FIX: Timelock RESET
    }

    // ============================================
    // BRANCH COVERAGE: Economic Parameters
    // ============================================

    function testScheduleEconomicParamsRejectsNonAdmin() external {
        vm.prank(address(0xBAD));
        vm.expectRevert("Not admin");
        kernel.scheduleEconomicParams(200, 600);
    }

    function testScheduleEconomicParamsRejectsIfActive() external {
        kernel.scheduleEconomicParams(200, 600);

        vm.expectRevert("Pending update exists - cancel first");
        kernel.scheduleEconomicParams(300, 700);
    }

    function testCancelEconomicParamsRejectsNonAdmin() external {
        kernel.scheduleEconomicParams(200, 600);

        vm.prank(address(0xBAD));
        vm.expectRevert("Not admin");
        kernel.cancelEconomicParamsUpdate();
    }

    function testExecuteEconomicParamsRejectsInactive() external {
        vm.expectRevert("No pending");
        kernel.executeEconomicParamsUpdate();
    }

    function testExecuteEconomicParamsRejectsTooEarly() external {
        kernel.scheduleEconomicParams(200, 600);

        vm.expectRevert("Too early");
        kernel.executeEconomicParamsUpdate();
    }

    function testExecuteEconomicParamsAfterDelay() external {
        kernel.scheduleEconomicParams(200, 600);

        vm.warp(block.timestamp + kernel.ECONOMIC_PARAM_DELAY());
        kernel.executeEconomicParamsUpdate();

        assertEq(kernel.platformFeeBps(), 200);
        assertEq(kernel.requesterPenaltyBps(), 600);
    }

    // ============================================
    // BRANCH COVERAGE: Transaction Creation Validation
    // ============================================

    function testCreateTransactionRejectsZeroProvider() external {
        bytes32 txId = keccak256("zero_provider");
        vm.prank(requester);
        vm.expectRevert("Zero provider");
        kernel.createTransaction(txId, address(0), ONE_USDC, keccak256("service"), block.timestamp + 7 days);
    }

    function testCreateTransactionRejectsSelfTransaction() external {
        bytes32 txId = keccak256("self_tx");
        vm.prank(requester);
        vm.expectRevert("Self-transaction not allowed");
        kernel.createTransaction(txId, requester, ONE_USDC, keccak256("service"), block.timestamp + 7 days);
    }

    function testCreateTransactionRejectsDuplicateId() external {
        bytes32 txId = keccak256("duplicate");
        vm.prank(requester);
        kernel.createTransaction(txId, provider, ONE_USDC, keccak256("service"), block.timestamp + 7 days);

        vm.prank(requester);
        vm.expectRevert("Tx exists");
        kernel.createTransaction(txId, provider, ONE_USDC, keccak256("service"), block.timestamp + 7 days);
    }

    // ============================================
    // BRANCH COVERAGE: Link Escrow Validation
    // ============================================

    function testLinkEscrowRejectsWrongState() external {
        bytes32 txId = _createTx();

        // Move to IN_PROGRESS (wrong state)
        vm.prank(requester);
        usdc.approve(address(escrow), ONE_USDC);
        vm.prank(requester);
        kernel.linkEscrow(txId, address(escrow), keccak256("escrow1"));

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");

        // Try to link again from wrong state
        vm.startPrank(requester);
        usdc.approve(address(escrow), ONE_USDC);
        vm.expectRevert("Invalid state for linking escrow");
        kernel.linkEscrow(txId, address(escrow), keccak256("escrow2"));
        vm.stopPrank();
    }

    function testLinkEscrowRejectsNonRequester() external {
        bytes32 txId = _createTx();

        vm.startPrank(provider); // Wrong person
        usdc.approve(address(escrow), ONE_USDC);
        vm.expectRevert("Only requester");
        kernel.linkEscrow(txId, address(escrow), keccak256("escrow"));
        vm.stopPrank();
    }

    function testLinkEscrowRejectsUnapprovedVault() external {
        bytes32 txId = _createTx();

        EscrowVault unapprovedVault = new EscrowVault(address(usdc), address(kernel));

        vm.startPrank(requester);
        usdc.approve(address(unapprovedVault), ONE_USDC);
        vm.expectRevert("Escrow not approved");
        kernel.linkEscrow(txId, address(unapprovedVault), keccak256("escrow"));
        vm.stopPrank();
    }

    function testLinkEscrowRejectsAfterDeadline() external {
        bytes32 txId = keccak256("short_deadline");
        vm.prank(requester);
        kernel.createTransaction(txId, provider, ONE_USDC, keccak256("service"), block.timestamp + 1 hours);

        // Warp past deadline
        vm.warp(block.timestamp + 2 hours);

        vm.startPrank(requester);
        usdc.approve(address(escrow), ONE_USDC);
        vm.expectRevert("Transaction expired");
        kernel.linkEscrow(txId, address(escrow), keccak256("escrow"));
        vm.stopPrank();
    }

    // ============================================
    // BRANCH COVERAGE: Milestone Release Validation
    // ============================================

    function testMilestoneReleaseRejectsNonRequester() external {
        bytes32 txId = _createCommittedTx();

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");

        vm.prank(provider); // Wrong person
        vm.expectRevert("Only requester");
        kernel.releaseMilestone(txId, ONE_USDC / 2);
    }

    // ============================================
    // BRANCH COVERAGE: Attestation Validation
    // ============================================

    function testAnchorAttestationRejectsNonProvider() external {
        bytes32 txId = _createSettledTx();

        vm.prank(address(0xBAD));
        vm.expectRevert("Not participant");
        kernel.anchorAttestation(txId, keccak256("attestation"));
    }

    function testAnchorAttestationRejectsWrongState() external {
        bytes32 txId = _createTx();

        vm.prank(provider);
        vm.expectRevert("Only settled");
        kernel.anchorAttestation(txId, keccak256("attestation"));
    }

    function testAnchorAttestationRejectsZeroUID() external {
        bytes32 txId = _createSettledTx();

        vm.prank(provider);
        vm.expectRevert("Attestation missing");
        kernel.anchorAttestation(txId, bytes32(0));
    }

    // ============================================
    // Helper Functions
    // ============================================

    function _createTx() internal returns (bytes32 txId) {
        txId = keccak256(abi.encodePacked("tx", block.timestamp, block.prevrandao));
        vm.prank(requester);
        kernel.createTransaction(txId, provider, ONE_USDC, keccak256("service"), block.timestamp + 7 days);
    }

    function _createCommittedTx() internal returns (bytes32 txId) {
        txId = _createTx();
        vm.startPrank(requester);
        usdc.approve(address(escrow), ONE_USDC);
        kernel.linkEscrow(txId, address(escrow), keccak256(abi.encodePacked("escrow", txId)));
        vm.stopPrank();
    }

    function _createSettledTx() internal returns (bytes32 txId) {
        txId = _createCommittedTx();

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(0));

        vm.prank(requester);
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, "");
    }
}
