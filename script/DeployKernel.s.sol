// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/ACTPKernel.sol";

contract DeployKernel is Script {
    function run() external {
        address admin = vm.envAddress("KERNEL_ADMIN");
        address pauser = vm.envOr("KERNEL_PAUSER", admin);
        address feeRecipient = vm.envOr("KERNEL_FEE_RECIPIENT", admin);

        vm.startBroadcast();
        ACTPKernel kernel = new ACTPKernel(admin, pauser, feeRecipient);
        vm.stopBroadcast();

        console2.log("ACTP Kernel deployed:", address(kernel));
    }
}
