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
}
