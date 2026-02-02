// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/identity/AGIRAILSIdentityRegistry.sol";

/**
 * @title DeployIdentityRegistry
 * @notice Deploy AGIRAILSIdentityRegistry (ERC-1056 compatible DID registry) to Base Sepolia
 *
 * Usage:
 *   source .env && forge script script/DeployIdentityRegistry.s.sol \
 *     --rpc-url $BASE_SEPOLIA_RPC --broadcast --verify
 *
 * This deploys AGIRAILS-owned ERC-1056 compatible DID registry as specified in AIP-7 Section 2.2.
 * The contract is permissionless - any address can be an identity owner by default.
 */
contract DeployIdentityRegistry is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        console.log("Deploying AGIRAILSIdentityRegistry...");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);

        AGIRAILSIdentityRegistry registry = new AGIRAILSIdentityRegistry();

        console.log("AGIRAILSIdentityRegistry deployed at:", address(registry));

        // Verify deployment by checking identityOwner returns self
        address testIdentity = deployer;
        address owner = registry.identityOwner(testIdentity);
        require(owner == testIdentity, "Self-ownership check failed");
        console.log("Self-ownership check passed for:", testIdentity);

        vm.stopBroadcast();

        // Print summary
        console.log("\n=== Deployment Summary ===");
        console.log("AGIRAILSIdentityRegistry:", address(registry));
        console.log("Chain ID:                ", block.chainid);
        console.log("\nUpdate deployments/base-sepolia.json with this address.");
    }
}
