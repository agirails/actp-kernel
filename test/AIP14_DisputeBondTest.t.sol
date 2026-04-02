// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ACTPKernel.sol";
import "../src/tokens/MockUSDC.sol";
import "../src/escrow/EscrowVault.sol";

/**
 * @title AIP14_DisputeBondTest
 * @notice Comprehensive tests for AIP-14: Fair Dispute Resolution
 *
 * Tests cover:
 * - Dispute bond deposit + distribution
 * - Outcome-based reputation (providerAtFault)
 * - Bond return on cancellation
 * - Legacy proof backwards compatibility
 * - Event emissions (DisputeOpened, DisputeResolved)
 * - Bond accounting separation from escrow
 * - Edge cases (min bond, insufficient USDC, etc.)
 */
contract AIP14_DisputeBondTest is Test {
    ACTPKernel kernel;
    MockUSDC usdc;
    EscrowVault escrow;

    address admin = address(this);
    address pauser = address(0xFA053);
    address requester = address(0x1);
    address provider = address(0x2);
    address mediator = address(0x3);
    address feeCollector = address(0xFEE);

    uint256 constant ONE_USDC = 1_000_000;
    uint256 constant TRANSACTION_AMOUNT = 1_000 * ONE_USDC; // $1000

    // Mirror events for testing (test contracts don't inherit from IACTPKernel)
    event DisputeOpened(bytes32 indexed transactionId, address indexed initiator, uint256 bondAmount, uint256 timestamp);
    event DisputeResolved(
        bytes32 indexed transactionId,
        bytes32 indexed disputeId,
        address indexed initiator,
        bool providerAtFault,
        uint256 bondAmount,
        uint256 timestamp
    );

    function setUp() external {
        usdc = new MockUSDC();
        kernel = new ACTPKernel(admin, pauser, feeCollector, address(0), address(usdc));
        escrow = new EscrowVault(address(usdc), address(kernel));
        kernel.approveEscrowVault(address(escrow), true);
        kernel.approveMediator(mediator, true);

        usdc.mint(requester, 100_000 * ONE_USDC); // $100K
        usdc.mint(provider, 100_000 * ONE_USDC);  // $100K for provider bonds
    }

    // ============================================
    // DISPUTE BOND BASICS
    // ============================================

    function testDisputeBond_RequesterPays() external {
        bytes32 txId = _createDeliveredTransaction();

        uint256 expectedBond = (TRANSACTION_AMOUNT * kernel.disputeBondBps()) / kernel.MAX_BPS();
        uint256 requesterBalBefore = usdc.balanceOf(requester);

        // Requester must approve vault for bond
        vm.startPrank(requester);
        usdc.approve(address(escrow), expectedBond);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");
        vm.stopPrank();

        // Bond deducted from requester
        assertEq(usdc.balanceOf(requester), requesterBalBefore - expectedBond);

        // Bond tracked in vault
        assertEq(escrow.bondBalance(txId), expectedBond);

        // Transaction stores bond info
        IACTPKernel.TransactionView memory txn = kernel.getTransaction(txId);
        assertEq(txn.disputeInitiator, requester);
        assertEq(txn.disputeBond, expectedBond);
    }

    function testDisputeBond_ProviderPays() external {
        bytes32 txId = _createDeliveredTransaction();

        uint256 expectedBond = (TRANSACTION_AMOUNT * kernel.disputeBondBps()) / kernel.MAX_BPS();
        uint256 providerBalBefore = usdc.balanceOf(provider);

        // Provider disputes
        vm.startPrank(provider);
        usdc.approve(address(escrow), expectedBond);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");
        vm.stopPrank();

        assertEq(usdc.balanceOf(provider), providerBalBefore - expectedBond);
        assertEq(escrow.bondBalance(txId), expectedBond);

        IACTPKernel.TransactionView memory txn = kernel.getTransaction(txId);
        assertEq(txn.disputeInitiator, provider);
    }

    function testDisputeBond_MinBondClamp() external {
        // Create a small transaction where 5% < MIN_DISPUTE_BOND
        // MIN_DISPUTE_BOND = $1 = 1_000_000
        // 5% of $10 = $0.50 < $1 → should clamp to $1
        uint256 smallAmount = 10 * ONE_USDC; // $10
        bytes32 txId = _createDeliveredTransactionWithAmount(smallAmount);

        uint256 expectedBond = kernel.MIN_DISPUTE_BOND(); // $1 (clamped)
        assertTrue(expectedBond > (smallAmount * kernel.disputeBondBps()) / kernel.MAX_BPS());

        vm.startPrank(requester);
        usdc.approve(address(escrow), expectedBond);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");
        vm.stopPrank();

        assertEq(escrow.bondBalance(txId), expectedBond);
    }

    function testDisputeBond_InsufficientApprovalReverts() external {
        bytes32 txId = _createDeliveredTransaction();

        // Requester approves less than bond amount
        vm.startPrank(requester);
        usdc.approve(address(escrow), 1); // Way too little
        vm.expectRevert(); // SafeERC20 will revert
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");
        vm.stopPrank();
    }

    function testDisputeBond_InsufficientBalanceReverts() external {
        bytes32 txId = _createDeliveredTransaction();

        uint256 expectedBond = (TRANSACTION_AMOUNT * kernel.disputeBondBps()) / kernel.MAX_BPS();

        // Create a poor requester with no USDC left for bond
        // The requester already spent TRANSACTION_AMOUNT on escrow
        // Let's drain their remaining balance
        uint256 remaining = usdc.balanceOf(requester);
        vm.prank(requester);
        usdc.transfer(address(0xDEAD), remaining);

        vm.startPrank(requester);
        usdc.approve(address(escrow), expectedBond);
        vm.expectRevert(); // SafeERC20 will revert
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");
        vm.stopPrank();
    }

    // ============================================
    // ESCROW ACCOUNTING SEPARATION
    // ============================================

    function testBondDoesNotAffectEscrowRemaining() external {
        bytes32 txId = _createDeliveredTransaction();

        uint256 remainingBefore = escrow.remaining(txId);
        assertEq(remainingBefore, TRANSACTION_AMOUNT);

        // Open dispute (deposits bond)
        uint256 expectedBond = (TRANSACTION_AMOUNT * kernel.disputeBondBps()) / kernel.MAX_BPS();
        vm.startPrank(requester);
        usdc.approve(address(escrow), expectedBond);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");
        vm.stopPrank();

        // remaining() unchanged — bond is tracked separately
        assertEq(escrow.remaining(txId), TRANSACTION_AMOUNT);
        assertEq(escrow.bondBalance(txId), expectedBond);
    }

    // ============================================
    // DISPUTE RESOLUTION: PROVIDER AT FAULT
    // ============================================

    function testDisputeSettled_ProviderAtFault_BondToRequester() external {
        bytes32 txId = _createDisputedTransaction();

        uint256 bond = kernel.getTransaction(txId).disputeBond;
        uint256 requesterBalBefore = usdc.balanceOf(requester);

        // 96-byte proof: providerAtFault = true → bond to requester
        bytes memory proof = abi.encode(
            TRANSACTION_AMOUNT, // all to requester
            uint256(0),
            true                // providerAtFault
        );

        vm.warp(block.timestamp + 2 days + 1);
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, proof);

        // Requester gets escrow + bond (provider at fault)
        assertEq(usdc.balanceOf(requester), requesterBalBefore + TRANSACTION_AMOUNT + bond);
        assertEq(escrow.bondBalance(txId), 0); // Bond fully distributed
    }

    // ============================================
    // DISPUTE RESOLUTION: REQUESTER AT FAULT (FRIVOLOUS)
    // ============================================

    function testDisputeSettled_ProviderNotAtFault_BondToProvider() external {
        bytes32 txId = _createDisputedTransaction();

        uint256 bond = kernel.getTransaction(txId).disputeBond;
        uint256 providerBalBefore = usdc.balanceOf(provider);

        // 96-byte proof: providerAtFault = false (frivolous dispute)
        bytes memory proof = abi.encode(
            uint256(0),
            TRANSACTION_AMOUNT, // all to provider
            false               // providerAtFault = false
        );

        vm.warp(block.timestamp + 2 days + 1);
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, proof);

        uint256 expectedFee = _calculateFee(TRANSACTION_AMOUNT);
        // Provider gets escrow (minus fee) + bond
        assertEq(usdc.balanceOf(provider), providerBalBefore + TRANSACTION_AMOUNT - expectedFee + bond);
        assertEq(escrow.bondBalance(txId), 0);
    }

    function testDisputeSettled_ProviderDisputes_ProviderAtFault_BondToRequester() external {
        // Provider opens dispute, resolver finds provider at fault → bond goes to requester
        bytes32 txId = _createDeliveredTransaction();

        uint256 expectedBond = (TRANSACTION_AMOUNT * kernel.disputeBondBps()) / kernel.MAX_BPS();

        // Provider disputes
        vm.startPrank(provider);
        usdc.approve(address(escrow), expectedBond);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");
        vm.stopPrank();

        uint256 requesterBalBefore = usdc.balanceOf(requester);

        // Resolve: provider at fault → requester wins, gets escrow + bond
        bytes memory proof = abi.encode(
            TRANSACTION_AMOUNT,  // all to requester
            uint256(0),
            true                 // providerAtFault = true → bond to requester
        );

        vm.warp(block.timestamp + 2 days + 1);
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, proof);

        // Requester gets escrow + provider's forfeited bond
        assertEq(usdc.balanceOf(requester), requesterBalBefore + TRANSACTION_AMOUNT + expectedBond);
    }

    function testDisputeSettled_ProviderDisputes_ProviderNotAtFault_BondToProvider() external {
        // Provider opens dispute, resolver finds provider NOT at fault → bond back to provider
        bytes32 txId = _createDeliveredTransaction();

        uint256 expectedBond = (TRANSACTION_AMOUNT * kernel.disputeBondBps()) / kernel.MAX_BPS();

        // Provider disputes
        vm.startPrank(provider);
        usdc.approve(address(escrow), expectedBond);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");
        vm.stopPrank();

        uint256 providerBalBefore = usdc.balanceOf(provider);

        // Resolve: provider NOT at fault → provider wins, gets escrow + bond back
        bytes memory proof = abi.encode(
            uint256(0),
            TRANSACTION_AMOUNT,  // all to provider
            false                // providerAtFault = false → bond to provider
        );

        vm.warp(block.timestamp + 2 days + 1);
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, proof);

        uint256 expectedFee = _calculateFee(TRANSACTION_AMOUNT);
        // Provider gets escrow (minus fee) + bond returned
        assertEq(usdc.balanceOf(provider), providerBalBefore + TRANSACTION_AMOUNT - expectedFee + expectedBond);
    }

    // ============================================
    // SPLIT RESOLUTION
    // ============================================

    function testDisputeSettled_SplitResolution_BondToProvider() external {
        bytes32 txId = _createDisputedTransaction();

        uint256 bond = kernel.getTransaction(txId).disputeBond;
        uint256 requesterBalBefore = usdc.balanceOf(requester);
        uint256 providerBalBefore = usdc.balanceOf(provider);

        // Split: 50/50, providerAtFault = false → provider wins bond
        bytes memory proof = abi.encode(
            uint256(500 * ONE_USDC),
            uint256(500 * ONE_USDC),
            false
        );

        vm.warp(block.timestamp + 2 days + 1);
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, proof);

        // Requester gets 500 USDC refund only (bond forfeited)
        assertEq(usdc.balanceOf(requester), requesterBalBefore + 500 * ONE_USDC);
        // Provider gets 500 USDC (minus fee) + bond
        uint256 expectedFee = _calculateFee(500 * ONE_USDC);
        assertEq(usdc.balanceOf(provider), providerBalBefore + 500 * ONE_USDC - expectedFee + bond);
    }

    // ============================================
    // DISPUTED → CANCELLED: BOND RETURNED
    // ============================================

    function testDisputeCancelled_BondReturnedToDisputer() external {
        bytes32 txId = _createDisputedTransaction();

        uint256 bond = kernel.getTransaction(txId).disputeBond;
        uint256 requesterBalBefore = usdc.balanceOf(requester);

        // Cancel with full resolution (DISPUTED → CANCELLED)
        bytes memory proof = abi.encode(
            TRANSACTION_AMOUNT,
            uint256(0),
            address(0),
            uint256(0)
        );

        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, proof);

        // Requester gets escrow refund + bond returned
        assertEq(usdc.balanceOf(requester), requesterBalBefore + TRANSACTION_AMOUNT + bond);
        assertEq(escrow.bondBalance(txId), 0);
    }

    function testDisputeCancelled_NoResolution_BondReturned() external {
        bytes32 txId = _createDisputedTransaction();

        uint256 bond = kernel.getTransaction(txId).disputeBond;
        uint256 requesterBalBefore = usdc.balanceOf(requester);

        // Cancel with no resolution proof (admin decides to dismiss)
        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, "");

        // Requester gets escrow refund (full, via _refundRequester) + bond returned
        assertEq(usdc.balanceOf(requester), requesterBalBefore + TRANSACTION_AMOUNT + bond);
    }

    // ============================================
    // LEGACY PROOF BACKWARDS COMPATIBILITY
    // ============================================

    function testLegacy64ByteProof_DefaultsProviderAtFault() external {
        bytes32 txId = _createDisputedTransaction();

        uint256 bond = kernel.getTransaction(txId).disputeBond;
        uint256 requesterBalBefore = usdc.balanceOf(requester);

        // Legacy 64-byte proof (no providerAtFault field)
        bytes memory proof = abi.encode(
            TRANSACTION_AMOUNT,
            uint256(0)
        );

        vm.warp(block.timestamp + 2 days + 1);
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, proof);

        // Legacy defaults to providerAtFault = true → bond returned to disputer
        assertEq(usdc.balanceOf(requester), requesterBalBefore + TRANSACTION_AMOUNT + bond);
    }

    function testLegacy128ByteProof_DefaultsProviderAtFault() external {
        bytes32 txId = _createDisputedTransaction();

        uint256 bond = kernel.getTransaction(txId).disputeBond;
        uint256 requesterBalBefore = usdc.balanceOf(requester);

        // Legacy 128-byte proof with mediator
        vm.warp(block.timestamp + 2 days + 1);

        bytes memory proof = abi.encode(
            uint256(800 * ONE_USDC),
            uint256(100 * ONE_USDC),
            mediator,
            uint256(100 * ONE_USDC)
        );

        kernel.transitionState(txId, IACTPKernel.State.SETTLED, proof);

        // Legacy defaults to providerAtFault = true → bond returned to disputer
        assertEq(usdc.balanceOf(requester), requesterBalBefore + 800 * ONE_USDC + bond);
    }

    // ============================================
    // 160-BYTE PROOF (WITH MEDIATOR + FAULT)
    // ============================================

    function testAIP14_160ByteProof_WithMediator() external {
        bytes32 txId = _createDisputedTransaction();

        uint256 bond = kernel.getTransaction(txId).disputeBond;

        vm.warp(block.timestamp + 2 days + 1);

        uint256 requesterBalBefore = usdc.balanceOf(requester);
        uint256 providerBalBefore = usdc.balanceOf(provider);
        uint256 mediatorBalBefore = usdc.balanceOf(mediator);

        // 160-byte proof: with mediator, providerAtFault = true
        bytes memory proof = abi.encode(
            uint256(400 * ONE_USDC),
            uint256(500 * ONE_USDC),
            mediator,
            uint256(100 * ONE_USDC),
            true // providerAtFault
        );

        kernel.transitionState(txId, IACTPKernel.State.SETTLED, proof);

        assertEq(usdc.balanceOf(requester), requesterBalBefore + 400 * ONE_USDC + bond);
        uint256 providerFee = _calculateFee(500 * ONE_USDC);
        assertEq(usdc.balanceOf(provider), providerBalBefore + 500 * ONE_USDC - providerFee);
        assertEq(usdc.balanceOf(mediator), mediatorBalBefore + 100 * ONE_USDC);
    }

    // ============================================
    // EVENT EMISSIONS
    // ============================================

    function testEmit_DisputeOpened() external {
        bytes32 txId = _createDeliveredTransaction();

        uint256 expectedBond = (TRANSACTION_AMOUNT * kernel.disputeBondBps()) / kernel.MAX_BPS();

        vm.startPrank(requester);
        usdc.approve(address(escrow), expectedBond);

        vm.expectEmit(true, true, false, true);
        emit DisputeOpened(txId, requester, expectedBond, block.timestamp);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");
        vm.stopPrank();
    }

    function testEmit_DisputeResolved_OnSettlement() external {
        bytes32 txId = _createDisputedTransaction();
        uint256 bond = kernel.getTransaction(txId).disputeBond;

        bytes memory proof = abi.encode(
            TRANSACTION_AMOUNT,
            uint256(0),
            true
        );

        vm.warp(block.timestamp + 2 days + 1);

        vm.expectEmit(true, true, true, true);
        emit DisputeResolved(txId, bytes32(0), requester, true, bond, block.timestamp);
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, proof);
    }

    function testEmit_DisputeResolved_OnCancellation() external {
        bytes32 txId = _createDisputedTransaction();
        uint256 bond = kernel.getTransaction(txId).disputeBond;

        bytes memory proof = abi.encode(
            TRANSACTION_AMOUNT,
            uint256(0),
            address(0),
            uint256(0)
        );

        vm.expectEmit(true, true, true, true);
        emit DisputeResolved(txId, bytes32(0), requester, false, bond, block.timestamp);
        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, proof);
    }

    // ============================================
    // BOND BALANCE ZERO AFTER RESOLUTION
    // ============================================

    function testBondBalanceZeroAfterSettlement() external {
        bytes32 txId = _createDisputedTransaction();

        assertTrue(escrow.bondBalance(txId) > 0);

        bytes memory proof = abi.encode(
            TRANSACTION_AMOUNT,
            uint256(0),
            true
        );

        vm.warp(block.timestamp + 2 days + 1);
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, proof);

        assertEq(escrow.bondBalance(txId), 0, "Bond must be zero after resolution");
    }

    function testBondBalanceZeroAfterCancellation() external {
        bytes32 txId = _createDisputedTransaction();

        assertTrue(escrow.bondBalance(txId) > 0);

        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, "");

        assertEq(escrow.bondBalance(txId), 0, "Bond must be zero after cancellation");
    }

    // ============================================
    // ADMIN: UPDATE DISPUTE BOND BPS
    // ============================================

    function testUpdateDisputeBondBps() external {
        assertEq(kernel.disputeBondBps(), 500); // Default 5%

        kernel.updateDisputeBondBps(1000); // Change to 10%
        assertEq(kernel.disputeBondBps(), 1000);
    }

    function testUpdateDisputeBondBps_ExceedsCapReverts() external {
        vm.expectRevert("Exceeds max bond cap");
        kernel.updateDisputeBondBps(2001); // > MAX_DISPUTE_BOND_BPS (2000)
    }

    function testUpdateDisputeBondBps_OnlyAdmin() external {
        vm.prank(address(0x999));
        vm.expectRevert("Not admin");
        kernel.updateDisputeBondBps(1000);
    }

    // ============================================
    // REQUESTER AGENT ID
    // ============================================

    function testRequesterAgentIdStored() external {
        uint256 reqAgentId = 42;

        vm.prank(requester);
        bytes32 txId = kernel.createTransaction(
            provider, requester, TRANSACTION_AMOUNT,
            block.timestamp + 30 days, 2 days,
            keccak256("service"), 0, reqAgentId
        );

        IACTPKernel.TransactionView memory txn = kernel.getTransaction(txId);
        assertEq(txn.requesterAgentId, reqAgentId);
    }

    function testRequesterAgentIdDefaultZero() external {
        vm.prank(requester);
        bytes32 txId = kernel.createTransaction(
            provider, requester, TRANSACTION_AMOUNT,
            block.timestamp + 30 days, 2 days,
            keccak256("service"), 0, 0
        );

        IACTPKernel.TransactionView memory txn = kernel.getTransaction(txId);
        assertEq(txn.requesterAgentId, 0);
    }

    // ============================================
    // GAS BENCHMARKS
    // ============================================

    function testGas_OpenDisputeWithBond() external {
        bytes32 txId = _createDeliveredTransaction();

        uint256 expectedBond = (TRANSACTION_AMOUNT * kernel.disputeBondBps()) / kernel.MAX_BPS();

        vm.startPrank(requester);
        usdc.approve(address(escrow), expectedBond);

        uint256 gasBefore = gasleft();
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();

        // Gas should be reasonable (< 200K)
        assertTrue(gasUsed < 200_000, "Dispute opening gas too high");
    }

    function testGas_ResolveDisputeWithBond() external {
        bytes32 txId = _createDisputedTransaction();

        bytes memory proof = abi.encode(
            TRANSACTION_AMOUNT,
            uint256(0),
            true
        );

        vm.warp(block.timestamp + 2 days + 1);

        uint256 gasBefore = gasleft();
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, proof);
        uint256 gasUsed = gasBefore - gasleft();

        // Gas should be reasonable (< 250K)
        assertTrue(gasUsed < 250_000, "Dispute resolution gas too high");
    }

    // ============================================
    // REGRESSION: BOND NOT LOCKED WHEN ESCROW REMAINING IS 0
    // Uses vm.store to set releasedAmount = amount, making remaining() == 0
    // ============================================

    /// @dev Drain escrow via vm.store: set releasedAmount = amount so remaining() == 0
    ///      escrows mapping is slot 0 (OZ v5 ReentrancyGuard uses ERC-7201 namespaced storage).
    ///      EscrowData struct: requester(+0), provider(+1), amount(+2), releasedAmount(+3), active(+4)
    function _drainEscrowViaStore(bytes32 escrowId) internal {
        // Mapping base slot: keccak256(escrowId . uint256(0))
        bytes32 baseSlot = keccak256(abi.encode(escrowId, uint256(0)));
        // releasedAmount is at offset +3
        bytes32 releasedSlot = bytes32(uint256(baseSlot) + 3);
        // Set releasedAmount = amount (TRANSACTION_AMOUNT)
        vm.store(address(escrow), releasedSlot, bytes32(TRANSACTION_AMOUNT));
        // Verify
        assertEq(escrow.remaining(escrowId), 0, "Escrow should be drained");
    }

    /// @notice [M-2 AUDIT FIX] Empty proof settlement now reverts — explicit resolution required
    function testBondDistributed_WhenEscrowRemainingZero_Settlement_RevertsWithoutProof() external {
        bytes32 txId = _createDisputedTransaction();

        uint256 bond = kernel.getTransaction(txId).disputeBond;
        assertTrue(bond > 0, "Bond should exist");

        // Drain escrow (simulate milestone payouts)
        _drainEscrowViaStore(txId);

        // [M-2 FIX] No-resolution settle now reverts
        vm.warp(block.timestamp + 2 days + 1);
        vm.expectRevert("Dispute resolution requires explicit proof");
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, "");
    }

    /// @notice Bond returned on cancellation even when escrow remaining == 0
    function testBondDistributed_WhenEscrowRemainingZero_Cancellation() external {
        bytes32 txId = _createDisputedTransaction();

        uint256 bond = kernel.getTransaction(txId).disputeBond;

        // Drain escrow
        _drainEscrowViaStore(txId);

        uint256 requesterBalBefore = usdc.balanceOf(requester);

        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, "");

        assertEq(escrow.bondBalance(txId), 0, "Bond must not remain locked on cancel");
        // Requester gets bond only (escrow was already drained)
        assertEq(usdc.balanceOf(requester), requesterBalBefore + bond);
    }

    /// @notice [M-2 AUDIT FIX] No-resolution settlement now reverts — explicit proof required
    function testSettlement_ZeroRemaining_NoResolution_RevertsWithoutProof() external {
        bytes32 txId = _createDisputedTransaction();

        uint256 bond = kernel.getTransaction(txId).disputeBond;
        assertTrue(bond > 0, "Bond should exist");

        // Drain escrow
        _drainEscrowViaStore(txId);

        vm.warp(block.timestamp + 2 days + 1);
        // [M-2 FIX] Empty proof now reverts instead of defaulting to provider
        vm.expectRevert("Dispute resolution requires explicit proof");
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, "");
    }

    // ============================================
    // HELPER FUNCTIONS
    // ============================================

    function _createDeliveredTransaction() internal returns (bytes32 txId) {
        return _createDeliveredTransactionWithAmount(TRANSACTION_AMOUNT);
    }

    function _createDeliveredTransactionWithAmount(uint256 amount) internal returns (bytes32 txId) {
        vm.prank(requester);
        txId = kernel.createTransaction(
            provider, requester, amount,
            block.timestamp + 30 days, 2 days,
            keccak256("service"), 0, 0
        );

        // Link escrow
        vm.startPrank(requester);
        usdc.approve(address(escrow), amount);
        kernel.linkEscrow(txId, address(escrow), txId);
        vm.stopPrank();

        // Progress to DELIVERED
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(10 days));
    }

    function _createDisputedTransaction() internal returns (bytes32 txId) {
        txId = _createDeliveredTransaction();

        uint256 expectedBond = (TRANSACTION_AMOUNT * kernel.disputeBondBps()) / kernel.MAX_BPS();

        vm.startPrank(requester);
        usdc.approve(address(escrow), expectedBond);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");
        vm.stopPrank();

        // Verify state
        IACTPKernel.TransactionView memory txn = kernel.getTransaction(txId);
        assertEq(uint8(txn.state), uint8(IACTPKernel.State.DISPUTED));
        assertEq(txn.disputeInitiator, requester);
        assertTrue(txn.disputeBond > 0);
    }

    function _calculateFee(uint256 amount) internal view returns (uint256) {
        uint256 bpsFee = (amount * kernel.platformFeeBps()) / kernel.MAX_BPS();
        return bpsFee > kernel.MIN_FEE() ? bpsFee : kernel.MIN_FEE();
    }
}
