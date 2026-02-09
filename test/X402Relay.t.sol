// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/relay/X402Relay.sol";
import "../src/tokens/MockUSDC.sol";

contract X402RelayTest is Test {
    // Mirror events from X402Relay for expectEmit
    event X402Payment(
        address indexed from,
        address indexed provider,
        uint256 providerAmount,
        uint256 fee,
        bytes32 serviceId
    );
    event FeeRecipientUpdated(
        address indexed oldRecipient,
        address indexed newRecipient
    );
    event PlatformFeeBpsUpdated(uint16 oldBps, uint16 newBps);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);

    X402Relay relay;
    MockUSDC usdc;

    address requester = address(0x1);
    address provider = address(0x2);
    address treasury = address(0xFEE);
    address admin = address(this);

    uint256 constant ONE_USDC = 1_000_000;
    uint256 constant MIN_FEE = 50_000; // $0.05

    function setUp() external {
        usdc = new MockUSDC();
        relay = new X402Relay(address(usdc), treasury, 100, admin); // 1% fee

        usdc.mint(requester, 1_000_000 * ONE_USDC);
    }

    // ========================================================================
    // payWithFee — happy paths
    // ========================================================================

    function test_payWithFee_basicSplit() external {
        uint256 gross = 100 * ONE_USDC; // $100
        uint256 expectedFee = 1 * ONE_USDC; // 1% = $1
        uint256 expectedNet = 99 * ONE_USDC;

        vm.startPrank(requester);
        usdc.approve(address(relay), gross);
        uint256 fee = relay.payWithFee(provider, gross, keccak256("svc-1"));
        vm.stopPrank();

        assertEq(fee, expectedFee, "Fee should be 1%");
        assertEq(usdc.balanceOf(provider), expectedNet, "Provider gets 99%");
        assertEq(usdc.balanceOf(treasury), expectedFee, "Treasury gets 1%");
    }

    function test_payWithFee_minimumFeeEnforced() external {
        // $1 payment: 1% = $0.01, but MIN_FEE = $0.05
        uint256 gross = 1 * ONE_USDC;
        uint256 expectedFee = MIN_FEE; // $0.05 minimum
        uint256 expectedNet = gross - expectedFee;

        vm.startPrank(requester);
        usdc.approve(address(relay), gross);
        uint256 fee = relay.payWithFee(provider, gross, bytes32(0));
        vm.stopPrank();

        assertEq(fee, expectedFee, "Fee should be MIN_FEE");
        assertEq(usdc.balanceOf(provider), expectedNet, "Provider gets gross - MIN_FEE");
        assertEq(usdc.balanceOf(treasury), expectedFee, "Treasury gets MIN_FEE");
    }

    function test_payWithFee_exactMinimumThreshold() external {
        // At $5: 1% = $0.05 = MIN_FEE (exactly at threshold)
        uint256 gross = 5 * ONE_USDC;
        uint256 bpsFee = (gross * 100) / 10_000; // 50_000
        assertEq(bpsFee, MIN_FEE, "1% of $5 == MIN_FEE");

        vm.startPrank(requester);
        usdc.approve(address(relay), gross);
        uint256 fee = relay.payWithFee(provider, gross, bytes32(0));
        vm.stopPrank();

        assertEq(fee, MIN_FEE, "Fee should be MIN_FEE (equal)");
    }

    function test_payWithFee_zeroFee() external {
        // When platformFeeBps = 0, MIN_FEE still applies
        X402Relay zeroFeeRelay = new X402Relay(address(usdc), treasury, 0, admin);
        uint256 gross = 10 * ONE_USDC;

        vm.startPrank(requester);
        usdc.approve(address(zeroFeeRelay), gross);
        uint256 fee = zeroFeeRelay.payWithFee(provider, gross, bytes32(0));
        vm.stopPrank();

        assertEq(fee, MIN_FEE, "MIN_FEE enforced even when bps=0");
    }

    function test_payWithFee_maxFee() external {
        // 5% cap
        X402Relay maxFeeRelay = new X402Relay(address(usdc), treasury, 500, admin);
        uint256 gross = 100 * ONE_USDC;
        uint256 expectedFee = 5 * ONE_USDC; // 5%
        uint256 expectedNet = 95 * ONE_USDC;

        vm.startPrank(requester);
        usdc.approve(address(maxFeeRelay), gross);
        uint256 fee = maxFeeRelay.payWithFee(provider, gross, bytes32(0));
        vm.stopPrank();

        assertEq(fee, expectedFee, "Fee should be 5%");
        assertEq(usdc.balanceOf(provider), expectedNet);
    }

    function test_payWithFee_emitsEvent() external {
        uint256 gross = 10 * ONE_USDC;
        uint256 expectedFee = (gross * 100) / 10_000; // 100_000
        uint256 expectedNet = gross - expectedFee;
        bytes32 svcId = keccak256("test-service");

        vm.startPrank(requester);
        usdc.approve(address(relay), gross);

        vm.expectEmit(true, true, false, true);
        emit X402Payment(requester, provider, expectedNet, expectedFee, svcId);

        relay.payWithFee(provider, gross, svcId);
        vm.stopPrank();
    }

    // ========================================================================
    // payWithFee — reverts
    // ========================================================================

    function test_payWithFee_revertsZeroProvider() external {
        vm.startPrank(requester);
        usdc.approve(address(relay), ONE_USDC);
        vm.expectRevert("Zero provider");
        relay.payWithFee(address(0), ONE_USDC, bytes32(0));
        vm.stopPrank();
    }

    function test_payWithFee_revertsBelowMinimum() external {
        uint256 dust = MIN_FEE - 1; // $0.049999
        vm.startPrank(requester);
        usdc.approve(address(relay), dust);
        vm.expectRevert("Amount below minimum");
        relay.payWithFee(provider, dust, bytes32(0));
        vm.stopPrank();
    }

    function test_payWithFee_revertsInsufficientAllowance() external {
        vm.startPrank(requester);
        // No approval
        vm.expectRevert();
        relay.payWithFee(provider, 10 * ONE_USDC, bytes32(0));
        vm.stopPrank();
    }

    function test_payWithFee_revertsInsufficientBalance() external {
        address broke = address(0xBEEF);
        vm.startPrank(broke);
        usdc.approve(address(relay), 10 * ONE_USDC);
        vm.expectRevert();
        relay.payWithFee(provider, 10 * ONE_USDC, bytes32(0));
        vm.stopPrank();
    }

    // ========================================================================
    // Constructor — reverts
    // ========================================================================

    function test_constructor_revertsExceedsFeeCap() external {
        vm.expectRevert("Fee exceeds cap");
        new X402Relay(address(usdc), treasury, 501, admin);
    }

    function test_constructor_revertsZeroUSDC() external {
        vm.expectRevert("Zero USDC");
        new X402Relay(address(0), treasury, 100, admin);
    }

    function test_constructor_revertsZeroFeeRecipient() external {
        vm.expectRevert("Zero feeRecipient");
        new X402Relay(address(usdc), address(0), 100, admin);
    }

    function test_constructor_revertsZeroAdmin() external {
        vm.expectRevert("Zero admin");
        new X402Relay(address(usdc), treasury, 100, address(0));
    }

    // ========================================================================
    // Admin — setFeeRecipient
    // ========================================================================

    function test_setFeeRecipient_onlyAdmin() external {
        vm.prank(requester); // not admin
        vm.expectRevert("Not admin");
        relay.setFeeRecipient(address(0x999));
    }

    function test_setFeeRecipient_works() external {
        address newTreasury = address(0x999);

        vm.expectEmit(true, true, false, false);
        emit FeeRecipientUpdated(treasury, newTreasury);

        relay.setFeeRecipient(newTreasury);
        assertEq(relay.feeRecipient(), newTreasury);
    }

    function test_setFeeRecipient_revertsZero() external {
        vm.expectRevert("Zero feeRecipient");
        relay.setFeeRecipient(address(0));
    }

    // ========================================================================
    // Admin — setPlatformFeeBps
    // ========================================================================

    function test_setPlatformFeeBps_onlyAdmin() external {
        vm.prank(requester);
        vm.expectRevert("Not admin");
        relay.setPlatformFeeBps(200);
    }

    function test_setPlatformFeeBps_works() external {
        vm.expectEmit(false, false, false, true);
        emit PlatformFeeBpsUpdated(100, 200);

        relay.setPlatformFeeBps(200);
        assertEq(relay.platformFeeBps(), 200);
    }

    function test_setPlatformFeeBps_exceedsCap() external {
        vm.expectRevert("Fee exceeds cap");
        relay.setPlatformFeeBps(501);
    }

    function test_setPlatformFeeBps_atCap() external {
        relay.setPlatformFeeBps(500);
        assertEq(relay.platformFeeBps(), 500);
    }

    // ========================================================================
    // Admin — transferAdmin
    // ========================================================================

    function test_transferAdmin_onlyAdmin() external {
        vm.prank(requester);
        vm.expectRevert("Not admin");
        relay.transferAdmin(address(0x999));
    }

    function test_transferAdmin_works() external {
        address newAdmin = address(0x999);

        vm.expectEmit(true, true, false, false);
        emit AdminTransferred(admin, newAdmin);

        relay.transferAdmin(newAdmin);
        assertEq(relay.admin(), newAdmin);
    }

    function test_transferAdmin_revertsZero() external {
        vm.expectRevert("Zero admin");
        relay.transferAdmin(address(0));
    }

    // ========================================================================
    // View — calculateFee
    // ========================================================================

    function test_calculateFee_preview() external view {
        // $100 → 1% = $1
        assertEq(relay.calculateFee(100 * ONE_USDC), 1 * ONE_USDC);
        // $1 → MIN_FEE = $0.05
        assertEq(relay.calculateFee(1 * ONE_USDC), MIN_FEE);
        // $5 → 1% = $0.05 = MIN_FEE
        assertEq(relay.calculateFee(5 * ONE_USDC), MIN_FEE);
    }

    function test_calculateFee_revertsBelowMinimum() external {
        vm.expectRevert("Amount below minimum");
        relay.calculateFee(MIN_FEE - 1);
    }
}
