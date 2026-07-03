// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DeployDisputeSystem} from "../script/DeployDisputeSystem.s.sol";

contract DeployDisputeSystemHarness is DeployDisputeSystem {
    function preflightWithRotating(address[] calldata rotatingPool)
        external
        view
        returns (uint256 rotatingLen)
    {
        Cfg memory c;
        c.network = "base-sepolia";
        c.isMainnet = false;
        c.kernel = address(this);
        c.usdc = address(0x444b4e1A65949AB2ac75979D5d0166Eb7A248Ccb);
        c.admin = address(this);
        c.fixedEvaluators[0] = address(0x1001);
        c.fixedEvaluators[1] = address(0x1002);
        c.rotatingPool = rotatingPool;
        _preflight(c);
        return c.rotatingPool.length;
    }

    function broadcastingContext() external view returns (bool) {
        return _isBroadcasting();
    }

    /// @dev Exercises the DEPLOY_MOCK_OOV3 preflight guard: the mock is a TESTNET-ONLY
    ///      convenience and must hard-revert when combined with base-mainnet.
    function preflightWithMockOOV3(bool isMainnet, bool deployMock) external view {
        Cfg memory c;
        c.network = isMainnet ? "base-mainnet" : "base-sepolia";
        c.isMainnet = isMainnet;
        c.deployMockOOV3 = deployMock;
        c.kernel = address(this); // a contract, so the code-length sanity check passes
        c.usdc = address(0x444b4e1A65949AB2ac75979D5d0166Eb7A248Ccb);
        c.admin = address(this); // a contract, so the mainnet Safe check passes
        c.fixedEvaluators[0] = address(0x1001);
        c.fixedEvaluators[1] = address(0x1002);
        address[] memory rotatingPool = new address[](3);
        rotatingPool[0] = address(0x2001);
        rotatingPool[1] = address(0x2002);
        rotatingPool[2] = address(0x2003);
        c.rotatingPool = rotatingPool;
        _preflight(c);
    }
}

contract DeployDisputeSystemScriptTest is Test {
    DeployDisputeSystemHarness internal harness;

    function setUp() public {
        harness = new DeployDisputeSystemHarness();
    }

    function testPreflightAcceptsThreeMemberRotatingList() public {
        address[] memory rotatingPool = new address[](3);
        rotatingPool[0] = address(0x2001);
        rotatingPool[1] = address(0x2002);
        rotatingPool[2] = address(0x2003);

        assertEq(harness.preflightWithRotating(rotatingPool), 3);
    }

    function testPreflightRejectsSingleRotatingMember() public {
        address[] memory rotatingPool = new address[](1);
        rotatingPool[0] = address(0x2001);

        vm.expectRevert("P4-4: rotating pool must be >= 3");
        harness.preflightWithRotating(rotatingPool);
    }

    function testPreflightRejectsDuplicateRotatingMember() public {
        address[] memory rotatingPool = new address[](3);
        rotatingPool[0] = address(0x2001);
        rotatingPool[1] = address(0x2002);
        rotatingPool[2] = address(0x2001);

        vm.expectRevert("Duplicate rotating evaluator");
        harness.preflightWithRotating(rotatingPool);
    }

    function testBroadcastingContextUsesFoundryContextNotEnv() public view {
        assertFalse(harness.broadcastingContext());
    }

    function testPreflightRejectsMockOOV3OnMainnet() public {
        vm.expectRevert("DEPLOY_MOCK_OOV3 is testnet-only (mainnet must use the canonical UMA OOV3)");
        harness.preflightWithMockOOV3(true, true);
    }

    function testPreflightAcceptsMockOOV3OnSepolia() public view {
        harness.preflightWithMockOOV3(false, true);
    }

    function testPreflightAcceptsMainnetWithoutMockOOV3() public view {
        harness.preflightWithMockOOV3(true, false);
    }
}
