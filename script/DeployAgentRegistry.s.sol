// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/registry/AgentRegistry.sol";

/**
 * @title DeployAgentRegistry
 * @notice Deploy AgentRegistry to Base Sepolia
 *
 * Usage:
 *   source .env && forge script script/DeployAgentRegistry.s.sol \
 *     --rpc-url $BASE_SEPOLIA_RPC --broadcast --verify
 */
contract DeployAgentRegistry is Script {
    // Base Sepolia ACTPKernel address
    address constant ACTP_KERNEL = 0x0ba0b17554601b30F5406e74d2208f567C12CcFE;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        console.log("Deploying AgentRegistry...");
        console.log("ACTPKernel:", ACTP_KERNEL);

        AgentRegistry registry = new AgentRegistry(ACTP_KERNEL);

        console.log("AgentRegistry deployed at:", address(registry));
        console.log("Chain ID stored:", registry.chainId());

        vm.stopBroadcast();

        // Print summary
        console.log("\n=== Deployment Summary ===");
        console.log("AgentRegistry:", address(registry));
        console.log("ACTPKernel:   ", ACTP_KERNEL);
    }
}
