// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {ACTPKernel} from "../src/ACTPKernel.sol";
import {IACTPKernel} from "../src/interfaces/IACTPKernel.sol";
import {DeployDisputeSystemHarness} from "./DeployDisputeSystemScript.t.sol";
import {VerifyDeployGate} from "../script/VerifyDeployGate.s.sol";

contract LegacyResolutionKernel {
    function resolveDisputeWhilePaused(bytes32, IACTPKernel.State, bytes calldata) external {}
}

contract MissingFeeRetryKernel {
    function resolveDisputeWhilePaused(bytes32, IACTPKernel.State, bytes calldata) external {}

    function escrowPrincipal(bytes32) external pure returns (uint256) {
        return 0;
    }
}

contract FeeDeployGateHarness is VerifyDeployGate {
    function checkFeeABI(address kernel) external view {
        _requireSelector(kernel, ACTPKernel.escrowPrincipal.selector);
        _requireSelector(kernel, ACTPKernel.retryPlatformFee.selector);
    }
}

contract KernelFeeABIGateTest is Test {
    DeployDisputeSystemHarness preflight;
    FeeDeployGateHarness gate;

    function setUp() public {
        preflight = new DeployDisputeSystemHarness();
        gate = new FeeDeployGateHarness();
    }

    function test_PreflightRejectsOldResolutionKernel() external {
        address legacy = address(new LegacyResolutionKernel());
        vm.expectRevert("kernel missing escrowPrincipal");
        preflight.preflightWithKernel(legacy);
    }

    function test_PreflightRejectsMissingFeeRetry() external {
        address incompleteKernel = address(new MissingFeeRetryKernel());
        vm.expectRevert("kernel missing retryPlatformFee");
        preflight.preflightWithKernel(incompleteKernel);
    }

    function test_DeployGateRejectsOldKernel() external {
        address legacy = address(new LegacyResolutionKernel());
        vm.expectRevert("GATE: kernel missing fee accounting ABI");
        gate.checkFeeABI(legacy);
    }

    function test_DeployGateAcceptsMatchingKernel() external {
        ACTPKernel kernel = new ACTPKernel(
            address(this), address(this), address(this), address(0), address(1), 1 hours
        );
        gate.checkFeeABI(address(kernel));
    }
}
