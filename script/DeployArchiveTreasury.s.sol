// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/treasury/ArchiveTreasury.sol";

/**
 * @title DeployArchiveTreasury
 * @notice Deploy ArchiveTreasury to Base Sepolia
 *
 * Usage:
 *   source .env && forge script script/DeployArchiveTreasury.s.sol \
 *     --rpc-url $BASE_SEPOLIA_RPC --broadcast --verify
 *
 * This deploys the Archive Treasury as specified in AIP-7 Section 4.
 * The treasury receives 0.1% of protocol fees for permanent Arweave storage.
 */
contract DeployArchiveTreasury is Script {
    // Base Sepolia deployed contract addresses (from deployments/base-sepolia.json)
    address constant MOCK_USDC = 0x444b4e1A65949AB2ac75979D5d0166Eb7A248Ccb;
    address constant ACTP_KERNEL = 0xE83cba71C445B4f658D88E4F179FccB9E1454F97;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        console.log("Deploying ArchiveTreasury...");
        console.log("Deployer (owner):", deployer);
        console.log("USDC:            ", MOCK_USDC);
        console.log("ACTPKernel:      ", ACTP_KERNEL);
        console.log("Uploader:        ", deployer); // Deployer is initial uploader

        ArchiveTreasury treasury = new ArchiveTreasury(
            MOCK_USDC,      // _usdc
            ACTP_KERNEL,    // _kernel
            deployer        // _uploader (deployer initially, can be changed later)
        );

        console.log("ArchiveTreasury deployed at:", address(treasury));

        // Verify deployment
        require(treasury.uploader() == deployer, "Uploader check failed");
        require(address(treasury.USDC()) == MOCK_USDC, "USDC check failed");
        require(address(treasury.kernel()) == ACTP_KERNEL, "Kernel check failed");
        console.log("Deployment verification passed");

        vm.stopBroadcast();

        // Print summary
        console.log("\n=== Deployment Summary ===");
        console.log("ArchiveTreasury: ", address(treasury));
        console.log("Owner:           ", deployer);
        console.log("Uploader:        ", deployer);
        console.log("USDC:            ", MOCK_USDC);
        console.log("ACTPKernel:      ", ACTP_KERNEL);
        console.log("Max Daily Withdrawal: $1000 USDC");
        console.log("\nUpdate deployments/base-sepolia.json with this address.");
        console.log("\nNOTE: To change uploader later, owner calls setUploader(newAddress)");
    }
}
