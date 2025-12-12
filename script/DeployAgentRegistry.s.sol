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
    // Base Sepolia ACTPKernel address (deployed 2025-12-10)
    address constant ACTP_KERNEL = 0xD199070F8e9FB9a127F6Fe730Bc13300B4b3d962;

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
