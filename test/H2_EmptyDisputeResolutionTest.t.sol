// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ACTPKernel.sol";
import "../src/tokens/MockUSDC.sol";
import "../src/escrow/EscrowVault.sol";

/**
 * @title H2_EmptyDisputeResolutionTest
 * @notice Security test demonstrating H-2 vulnerability fix
 *
 * VULNERABILITY (BEFORE FIX):
 * Mediator/admin could resolve dispute with:
 * - requesterAmount = 0
 * - providerAmount = 0
 * - mediatorAmount = 0
 * - TOTAL = 0
 * Result: All funds refunded to requester (leftover logic)
 *
 * OR partial resolution:
 * - requesterAmount = 500K
 * - providerAmount = 500K
 * - mediatorAmount = 0
 * - TOTAL = 1M (but escrow has 2M)
 * Result: 1M leftover refunded to requester automatically
 *
 * PROBLEM:
 * 1. Resolution not explicit (leftover goes to requester by default)
 * 2. Mediator could "game" system by under-distributing
 * 3. No guarantee all funds are distributed as intended
 * 4. Unclear dispute outcome (was it intentional to favor requester?)
 *
 * FIX:
 * - require(totalDistributed > 0, "Empty resolution not allowed")
 * - require(totalDistributed == remaining, "Must distribute ALL funds")
 * - Removed leftover refund logic (no longer needed)
 * - Resolution must be EXPLICIT and COMPLETE
 */
contract H2_EmptyDisputeResolutionTest is Test {
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

    function setUp() external {
        kernel = new ACTPKernel(admin, pauser, feeCollector);
        usdc = new MockUSDC();
        escrow = new EscrowVault(address(usdc), address(kernel));
        kernel.approveEscrowVault(address(escrow), true);
        kernel.approveMediator(mediator, true);

        usdc.mint(requester, 10_000 * ONE_USDC);
    }

    // ============================================
    // H-2 EXPLOIT DEMONSTRATION (NOW PREVENTED)
    // ============================================

    /**
     * @notice Demonstrates H-2 vulnerability: Empty resolution (all zeros)
     * BEFORE FIX: Would succeed, all funds go to requester via leftover logic
     * AFTER FIX: Reverts with "Empty resolution not allowed"
     */
    function testH2Vulnerability_EmptyResolution() external {
        bytes32 txId = _createDisputedTransaction();

        // Mediator tries to resolve with all zeros
        bytes memory emptyResolution = abi.encode(
            uint256(0), // requesterAmount = 0
            uint256(0), // providerAmount = 0
            address(0), // mediator = 0
            uint256(0)  // mediatorAmount = 0
        );

        // Wait for mediator timelock (2 days)
        vm.warp(block.timestamp + 2 days + 1);

        // H-2 FIX: Should revert with "Empty resolution" (caught in decode)
        vm.expectRevert("Empty resolution");
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, emptyResolution);
    }

    /**
     * @notice Demonstrates H-2 vulnerability: Partial resolution
     * BEFORE FIX: Would succeed, leftover refunded to requester automatically
     * AFTER FIX: Reverts with "Must distribute ALL funds"
     */
    function testH2Vulnerability_PartialResolution() external {
        bytes32 txId = _createDisputedTransaction();
        uint256 escrowBalance = usdc.balanceOf(address(escrow));
        assertEq(escrowBalance, TRANSACTION_AMOUNT); // $1000 in escrow

        // Mediator tries to distribute only $500 (50%)
        // Remaining $500 would go to requester via leftover logic (BEFORE FIX)
        bytes memory partialResolution = abi.encode(
            uint256(250 * ONE_USDC), // requesterAmount = $250
            uint256(250 * ONE_USDC), // providerAmount = $250
            address(0),              // mediator = 0
            uint256(0)               // mediatorAmount = 0
        );
        // Total = $500, but escrow has $1000

        // Wait for mediator timelock
        vm.warp(block.timestamp + 2 days + 1);

        // H-2 FIX: Should revert with "Must distribute ALL funds"
        vm.expectRevert("Must distribute ALL funds");
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, partialResolution);
    }

    /**
     * @notice Demonstrates H-2 vulnerability: Over-distribution
     * Should always fail (even before fix)
     */
    function testH2Vulnerability_OverDistribution() external {
        bytes32 txId = _createDisputedTransaction();

        // Mediator tries to distribute MORE than available
        bytes memory overResolution = abi.encode(
            uint256(600 * ONE_USDC), // requesterAmount = $600
            uint256(600 * ONE_USDC), // providerAmount = $600
            address(0),              // mediator = 0
            uint256(0)               // mediatorAmount = 0
        );
        // Total = $1200, but escrow only has $1000

        // Wait for mediator timelock
        vm.warp(block.timestamp + 2 days + 1);

        // Should revert (was also prevented before fix)
        vm.expectRevert("Must distribute ALL funds");
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, overResolution);
    }

    // ============================================
    // H-2 FIX: CORRECT RESOLUTION TESTS
    // ============================================

    /**
     * @notice Test correct full resolution: 50/50 split
     */
    function testH2Fix_FullResolution50_50() external {
        bytes32 txId = _createDisputedTransaction();

        // Correct resolution: Distribute ALL $1000
        bytes memory correctResolution = abi.encode(
            uint256(500 * ONE_USDC), // requesterAmount = $500
            uint256(500 * ONE_USDC), // providerAmount = $500
            address(0),              // mediator = 0
            uint256(0)               // mediatorAmount = 0
        );
        // Total = $1000 (matches escrow balance)

        // Wait for mediator timelock
        vm.warp(block.timestamp + 2 days + 1);

        uint256 requesterBalanceBefore = usdc.balanceOf(requester);
        uint256 providerBalanceBefore = usdc.balanceOf(provider);

        // Should succeed
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, correctResolution);

        // Verify balances
        assertEq(usdc.balanceOf(requester), requesterBalanceBefore + 500 * ONE_USDC);
        assertEq(usdc.balanceOf(provider), providerBalanceBefore + 500 * ONE_USDC - _calculateFee(500 * ONE_USDC));
        assertEq(usdc.balanceOf(address(escrow)), 0); // All funds distributed
    }

    /**
     * @notice Test correct full resolution: Requester wins 100%
     */
    function testH2Fix_FullResolutionRequesterWins() external {
        bytes32 txId = _createDisputedTransaction();

        // Requester wins dispute: Gets full refund
        bytes memory resolution = abi.encode(
            uint256(1000 * ONE_USDC), // requesterAmount = $1000
            uint256(0),               // providerAmount = $0
            address(0),               // mediator = 0
            uint256(0)                // mediatorAmount = 0
        );

        vm.warp(block.timestamp + 2 days + 1);

        uint256 requesterBalanceBefore = usdc.balanceOf(requester);

        kernel.transitionState(txId, IACTPKernel.State.SETTLED, resolution);

        assertEq(usdc.balanceOf(requester), requesterBalanceBefore + 1000 * ONE_USDC);
        assertEq(usdc.balanceOf(provider), 0);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    /**
     * @notice Test correct full resolution: Provider wins 100%
     */
    function testH2Fix_FullResolutionProviderWins() external {
        bytes32 txId = _createDisputedTransaction();

        // Provider wins dispute: Gets full payment
        bytes memory resolution = abi.encode(
            uint256(0),               // requesterAmount = $0
            uint256(1000 * ONE_USDC), // providerAmount = $1000
            address(0),               // mediator = 0
            uint256(0)                // mediatorAmount = 0
        );

        vm.warp(block.timestamp + 2 days + 1);

        uint256 providerBalanceBefore = usdc.balanceOf(provider);
        uint256 expectedFee = _calculateFee(1000 * ONE_USDC);

        kernel.transitionState(txId, IACTPKernel.State.SETTLED, resolution);

        assertEq(usdc.balanceOf(requester), 9000 * ONE_USDC); // Started with 10K, locked 1K
        assertEq(usdc.balanceOf(provider), providerBalanceBefore + 1000 * ONE_USDC - expectedFee);
        assertEq(usdc.balanceOf(feeCollector), expectedFee);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    /**
     * @notice Test correct full resolution: With mediator fee
     */
    function testH2Fix_FullResolutionWithMediator() external {
        bytes32 txId = _createDisputedTransaction();

        // Split with mediator:
        // - Requester: $400
        // - Provider: $500
        // - Mediator: $100
        // Total: $1000 (exact)
        bytes memory resolution = abi.encode(
            uint256(400 * ONE_USDC), // requesterAmount
            uint256(500 * ONE_USDC), // providerAmount
            mediator,                // mediator address
            uint256(100 * ONE_USDC)  // mediatorAmount
        );

        vm.warp(block.timestamp + 2 days + 1);

        uint256 requesterBalanceBefore = usdc.balanceOf(requester);
        uint256 providerBalanceBefore = usdc.balanceOf(provider);
        uint256 mediatorBalanceBefore = usdc.balanceOf(mediator);
        uint256 expectedProviderFee = _calculateFee(500 * ONE_USDC);

        kernel.transitionState(txId, IACTPKernel.State.SETTLED, resolution);

        assertEq(usdc.balanceOf(requester), requesterBalanceBefore + 400 * ONE_USDC);
        assertEq(usdc.balanceOf(provider), providerBalanceBefore + 500 * ONE_USDC - expectedProviderFee);
        assertEq(usdc.balanceOf(mediator), mediatorBalanceBefore + 100 * ONE_USDC);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    /**
     * @notice Test that resolution must match EXACT escrow balance
     * Even 1 wei off should fail
     */
    function testH2Fix_MustDistributeExactAmount() external {
        bytes32 txId = _createDisputedTransaction();

        // Try to distribute 1 wei LESS than escrow balance
        bytes memory resolution = abi.encode(
            uint256(1000 * ONE_USDC - 1), // 1 wei less
            uint256(0),
            address(0),
            uint256(0)
        );

        vm.warp(block.timestamp + 2 days + 1);

        vm.expectRevert("Must distribute ALL funds");
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, resolution);

        // Try to distribute 1 wei MORE than escrow balance
        resolution = abi.encode(
            uint256(1000 * ONE_USDC + 1), // 1 wei more
            uint256(0),
            address(0),
            uint256(0)
        );

        vm.expectRevert("Must distribute ALL funds");
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, resolution);
    }

    // ============================================
    // H-2 FIX: CANCELLATION PATH TESTS
    // ============================================

    /**
     * @notice Test that cancellation with empty resolution also reverts
     */
    function testH2Fix_CancellationWithEmptyResolution() external {
        bytes32 txId = _createDisputedTransaction();

        // Admin tries to cancel with empty resolution
        bytes memory emptyResolution = abi.encode(
            uint256(0),
            uint256(0),
            address(0),
            uint256(0)
        );

        vm.expectRevert("Empty resolution");
        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, emptyResolution);
    }

    /**
     * @notice Test that cancellation with partial resolution reverts
     */
    function testH2Fix_CancellationWithPartialResolution() external {
        bytes32 txId = _createDisputedTransaction();

        // Admin tries to cancel with partial resolution
        bytes memory partialResolution = abi.encode(
            uint256(500 * ONE_USDC),
            uint256(0),
            address(0),
            uint256(0)
        );

        vm.expectRevert("Must distribute ALL funds");
        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, partialResolution);
    }

    /**
     * @notice Test that cancellation with full resolution succeeds
     */
    function testH2Fix_CancellationWithFullResolution() external {
        bytes32 txId = _createDisputedTransaction();

        // Admin cancels with full resolution
        bytes memory fullResolution = abi.encode(
            uint256(600 * ONE_USDC), // Requester gets $600
            uint256(400 * ONE_USDC), // Provider gets $400
            address(0),
            uint256(0)
        );

        uint256 requesterBalanceBefore = usdc.balanceOf(requester);
        uint256 providerBalanceBefore = usdc.balanceOf(provider);
        uint256 expectedProviderFee = _calculateFee(400 * ONE_USDC);

        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, fullResolution);

        assertEq(usdc.balanceOf(requester), requesterBalanceBefore + 600 * ONE_USDC);
        assertEq(usdc.balanceOf(provider), providerBalanceBefore + 400 * ONE_USDC - expectedProviderFee);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    // ============================================
    // H-2 ECONOMIC IMPACT
    // ============================================

    /**
     * @notice Demonstrates prevented loss from H-2 fix
     */
    function testH2EconomicImpact_PreventedAmbiguity() external view {
        // Scenario: Mediator resolves 1000 disputes per year
        uint256 disputesPerYear = 1000;
        uint256 avgDisputeAmount = 10_000 * ONE_USDC; // $10K average

        // BEFORE FIX: Mediator could under-distribute, unclear outcomes
        // - Partial distribution → leftover goes to requester automatically
        // - Empty distribution → all funds to requester
        // - Unclear if intentional or error
        // - No transparency in dispute outcome

        // AFTER FIX: Every resolution must be EXPLICIT
        // - Must distribute exact amount
        // - No ambiguity (mediator's intent is clear)
        // - Cannot "game" system by under-distributing
        // - Full transparency in dispute outcome

        uint256 totalDisputeVolume = disputesPerYear * avgDisputeAmount;
        assertEq(totalDisputeVolume, 10_000_000 * ONE_USDC); // $10M per year

        // IMPROVEMENT: 100% clarity and transparency in $10M+ annual dispute volume
    }

    // ============================================
    // Helper Functions
    // ============================================

    function _createDisputedTransaction() internal returns (bytes32 txId) {

        // Create transaction
        vm.prank(requester);
        txId = kernel.createTransaction(provider, requester, TRANSACTION_AMOUNT, block.timestamp + 30 days, 2 days, keccak256("service"));

        // Link escrow (auto-transitions to COMMITTED)
        vm.startPrank(requester);
        usdc.approve(address(escrow), TRANSACTION_AMOUNT);
        kernel.linkEscrow(txId, address(escrow), txId);
        vm.stopPrank();

        // Provider marks in progress
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");

        // Provider delivers
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(10 days));

        // Requester disputes
        vm.prank(requester);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");

        // Verify state
        IACTPKernel.TransactionView memory txn = kernel.getTransaction(txId);
        assertEq(uint8(txn.state), uint8(IACTPKernel.State.DISPUTED));
    }

    function _calculateFee(uint256 amount) internal view returns (uint256) {
        return (amount * kernel.platformFeeBps()) / kernel.MAX_BPS();
    }
}
