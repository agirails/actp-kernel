// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/relay/X402Relay.sol";
import "../src/tokens/MockUSDC.sol";

/**
 * Coverage for the new `require(providerNet > 0, "Provider would receive nothing")`
 * guard in X402Relay.payWithFee.
 *
 * The existing `grossAmount >= MIN_FEE` guard (line 115) blocks anything strictly
 * below the floor, but at exactly grossAmount == MIN_FEE the percentage fee is
 * tiny ($0.0005 at 1 % bps on $0.05) so the floor takes over: fee == MIN_FEE ==
 * grossAmount → providerNet == 0. Without the new guard, the relay would silently
 * forward zero to the provider while still sending the full amount to treasury.
 */
contract X402RelayDustGuardTest is Test {
    X402Relay relay;
    MockUSDC usdc;

    address admin = address(this);
    address treasury = address(0xFEE);
    address requester = address(0x1);
    address provider = address(0x2);

    uint256 constant ONE_USDC = 1_000_000;
    uint256 constant MIN_FEE = 50_000; // $0.05 — matches X402Relay.MIN_FEE

    function setUp() external {
        usdc = new MockUSDC();
        relay = new X402Relay(address(usdc), treasury, 100, admin); // 1% fee
        usdc.mint(requester, 100 * ONE_USDC);
        vm.prank(requester);
        usdc.approve(address(relay), type(uint256).max);
    }

    function testRejectsWhenFeeFloorEatsEntirePayment() external {
        // grossAmount == MIN_FEE is the boundary: passes the >= MIN_FEE
        // upstream check, but the floor fee equals the gross → provider gets 0.
        vm.prank(requester);
        vm.expectRevert("Provider would receive nothing");
        relay.payWithFee(provider, MIN_FEE, keccak256("svc"));
    }

    function testAcceptsOneWeiAboveFloor() external {
        // At MIN_FEE + 1, fee is still floored (because 1% of MIN_FEE+1 << MIN_FEE),
        // so providerNet = 1. Smallest possible non-zero payout — must succeed.
        uint256 gross = MIN_FEE + 1;
        uint256 reqBefore = usdc.balanceOf(requester);
        uint256 provBefore = usdc.balanceOf(provider);
        uint256 treasBefore = usdc.balanceOf(treasury);

        vm.prank(requester);
        relay.payWithFee(provider, gross, keccak256("svc"));

        assertEq(usdc.balanceOf(requester), reqBefore - gross, "requester pays gross");
        assertEq(usdc.balanceOf(provider), provBefore + 1, "provider gets 1 wei");
        assertEq(usdc.balanceOf(treasury), treasBefore + MIN_FEE, "treasury gets floor fee");
    }
}
