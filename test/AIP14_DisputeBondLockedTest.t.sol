// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ACTPKernel.sol";
import "../src/tokens/MockUSDC.sol";
import "../src/escrow/EscrowVault.sol";

/**
 * @title AIP14_DisputeBondLockedTest
 * @notice INV-30: Dispute bond rate must be locked at transaction creation.
 *
 * The `disputeBondBps` storage variable is admin-settable via updateDisputeBondBps()
 * without timelock. Without per-transaction locking, an admin could change the rate
 * between createTransaction() and transitionState(DISPUTED) and silently alter the
 * bond a user is required to post relative to the rate at creation time.
 *
 * This test suite verifies the INV-30 fix: every transaction carries
 * `disputeBondBpsLocked`, set at creation, and used at dispute open instead of the
 * live state variable.
 *
 * Companion to AIP14_DisputeBondTest.t.sol. See verification plan v2.1 §6 INV-30.
 */
contract AIP14_DisputeBondLockedTest is Test {
    ACTPKernel kernel;
    MockUSDC usdc;
    EscrowVault escrow;

    address admin = address(this);
    address pauser = address(0xFA053);
    address requester = address(0x1);
    address provider = address(0x2);
    address feeCollector = address(0xFEE);

    uint256 constant ONE_USDC = 1_000_000;
    uint256 constant TRANSACTION_AMOUNT = 1_000 * ONE_USDC; // $1000

    function setUp() external {
        usdc = new MockUSDC();
        kernel = new ACTPKernel(admin, pauser, feeCollector, address(0), address(usdc), 1 hours);
        escrow = new EscrowVault(address(usdc), address(kernel));
        kernel.approveEscrowVault(address(escrow), true);

        usdc.mint(requester, 100_000 * ONE_USDC);
        usdc.mint(provider, 100_000 * ONE_USDC);
    }

    // ============================================
    // INV-30: Lock-at-creation correctness
    // ============================================

    /// @notice Admin changes disputeBondBps between create and dispute; bond must use creation-time rate.
    function testDisputeBond_UsesLockedRateNotLiveRate() external {
        // Capture rate at creation (default 500 bps = 5%)
        uint16 creationRate = kernel.disputeBondBps();
        assertEq(creationRate, 500, "Default disputeBondBps should be 500 bps");

        bytes32 txId = _createDeliveredTransaction();

        // Verify the locked rate matches the live rate at creation time
        IACTPKernel.TransactionView memory txnAtCreation = kernel.getTransaction(txId);
        assertEq(
            txnAtCreation.disputeBondBpsLocked,
            creationRate,
            "Locked rate should match disputeBondBps at create time"
        );

        // Admin raises rate to MAX (2000 bps = 20%) — 4× the creation rate
        uint16 newRate = kernel.MAX_DISPUTE_BOND_BPS();
        kernel.updateDisputeBondBps(newRate);
        assertEq(kernel.disputeBondBps(), newRate, "Live rate should now be 2000");

        // Compute bond requester is required to post
        uint256 expectedBondAtCreationRate = (TRANSACTION_AMOUNT * creationRate) / kernel.MAX_BPS();
        uint256 wrongBondAtLiveRate = (TRANSACTION_AMOUNT * newRate) / kernel.MAX_BPS();
        assertTrue(
            expectedBondAtCreationRate < wrongBondAtLiveRate,
            "Sanity: creation rate yields smaller bond than post-change live rate"
        );

        // Open dispute with the bond requester actually approved at creation time
        vm.startPrank(requester);
        usdc.approve(address(escrow), expectedBondAtCreationRate);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");
        vm.stopPrank();

        // Bond posted must equal the rate-at-creation, not the live (raised) rate
        IACTPKernel.TransactionView memory txnAfterDispute = kernel.getTransaction(txId);
        assertEq(
            txnAfterDispute.disputeBond,
            expectedBondAtCreationRate,
            "Bond must use rate locked at creation, not live disputeBondBps"
        );
        assertEq(escrow.bondBalance(txId), expectedBondAtCreationRate, "Vault bond balance must match creation rate");
    }

    /// @notice MIN_DISPUTE_BOND floor applies even when locked rate is high.
    /// @dev Guards against the corner where locked rate × amount is below the $1 floor.
    function testDisputeBond_MinFloorAppliesUnderLockedRate() external {
        // Small transaction where locked-rate bond would be below MIN_DISPUTE_BOND
        // 5% of $10 = $0.50 < $1 MIN_DISPUTE_BOND
        uint256 smallAmount = 10 * ONE_USDC; // $10
        bytes32 txId = _createDeliveredTransactionWithAmount(smallAmount);

        IACTPKernel.TransactionView memory txn = kernel.getTransaction(txId);
        uint256 rateComputed = (smallAmount * txn.disputeBondBpsLocked) / kernel.MAX_BPS();
        uint256 floor = kernel.MIN_DISPUTE_BOND();
        assertTrue(rateComputed < floor, "Sanity: rate-computed bond is below floor");

        // Open dispute with floor-sized bond approval
        vm.startPrank(requester);
        usdc.approve(address(escrow), floor);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");
        vm.stopPrank();

        IACTPKernel.TransactionView memory txnAfter = kernel.getTransaction(txId);
        assertEq(txnAfter.disputeBond, floor, "Bond must clamp to MIN_DISPUTE_BOND when locked rate yields less");
    }

    /// @notice Getter must not drift when admin changes live rate post-creation.
    /// @dev Initial-exposure read is already covered by testDisputeBond_UsesLockedRateNotLiveRate.
    function testDisputeBond_LockedRateDoesNotDriftOnLiveRateChange() external {
        uint16 creationRate = kernel.disputeBondBps();
        bytes32 txId = _createDeliveredTransaction();

        // Admin changes live rate; getter must continue returning the locked value
        kernel.updateDisputeBondBps(1000);
        IACTPKernel.TransactionView memory txnAfter = kernel.getTransaction(txId);
        assertEq(
            txnAfter.disputeBondBpsLocked,
            creationRate,
            "Locked rate must not drift when admin changes live rate"
        );
    }

    /// @notice Regression guard: acceptQuote re-locks platformFeeBpsLocked (AIP-5 §5.5 carve-out)
    ///         but MUST NOT touch disputeBondBpsLocked. A future change that adds symmetric
    ///         re-lock for the bond rate would break user expectations advertised at create time.
    function testDisputeBond_AcceptQuoteDoesNotRelockBondRate() external {
        // Create at default rate (500 bps); we then move to QUOTED so acceptQuote is callable.
        uint16 creationRate = kernel.disputeBondBps();
        bytes32 txId = _createQuotedTransaction();

        IACTPKernel.TransactionView memory txnAtQuote = kernel.getTransaction(txId);
        assertEq(txnAtQuote.disputeBondBpsLocked, creationRate, "Sanity: locked at creation");

        // Admin raises live disputeBondBps between QUOTED and acceptQuote
        uint16 newRate = kernel.MAX_DISPUTE_BOND_BPS();
        kernel.updateDisputeBondBps(newRate);

        // Requester accepts quote (renegotiates amount). This re-locks platformFee per AIP-5 §5.5
        // carve-out but MUST leave disputeBondBpsLocked untouched.
        uint256 newAmount = TRANSACTION_AMOUNT * 2;
        vm.prank(requester);
        kernel.acceptQuote(txId, newAmount);

        IACTPKernel.TransactionView memory txnAfterAccept = kernel.getTransaction(txId);
        assertEq(
            txnAfterAccept.disputeBondBpsLocked,
            creationRate,
            "acceptQuote must NOT re-lock disputeBondBpsLocked (creation-only lock)"
        );

        // Carry through to DISPUTED and assert the bond posted uses creation rate, not live rate.
        _progressQuotedToDelivered(txId, newAmount);
        uint256 expectedBondAtCreationRate = (newAmount * creationRate) / kernel.MAX_BPS();
        vm.startPrank(requester);
        usdc.approve(address(escrow), expectedBondAtCreationRate);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");
        vm.stopPrank();

        IACTPKernel.TransactionView memory txnAfterDispute = kernel.getTransaction(txId);
        assertEq(
            txnAfterDispute.disputeBond,
            expectedBondAtCreationRate,
            "Bond posted at dispute must reflect creation-time rate, not live or acceptQuote-time rate"
        );
    }

    // ============================================
    // HELPER FUNCTIONS (mirror AIP14_DisputeBondTest)
    // ============================================

    /// @dev Create tx and move to QUOTED so acceptQuote is callable.
    function _createQuotedTransaction() internal returns (bytes32 txId) {
        vm.prank(requester);
        txId = kernel.createTransaction(
            provider, requester, TRANSACTION_AMOUNT,
            block.timestamp + 30 days, 2 days,
            keccak256("service"), 0, 0
        );

        // Provider posts a quote (proof.length == 32 to store hash)
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.QUOTED, abi.encode(keccak256("quote")));
    }

    /// @dev Continue a QUOTED+accepted tx through link/in-progress/delivered.
    function _progressQuotedToDelivered(bytes32 txId, uint256 amount) internal {
        vm.startPrank(requester);
        usdc.approve(address(escrow), amount);
        kernel.linkEscrow(txId, address(escrow), txId);
        vm.stopPrank();

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(10 days));
    }

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

        vm.startPrank(requester);
        usdc.approve(address(escrow), amount);
        kernel.linkEscrow(txId, address(escrow), txId);
        vm.stopPrank();

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(10 days));
    }
}
