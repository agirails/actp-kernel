// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.20;

import "forge-std/Script.sol";

/**
 * @title RegisterConfigSnapshotSchema
 * @notice Registers the ConfigSnapshot EAS schema for AGIRAILS.md config versioning
 * @dev Schema: "bytes32 configHash, string configCID, address agent, uint256 version"
 *
 * Usage:
 *   source .env && forge script script/RegisterConfigSnapshotSchema.s.sol \
 *     --rpc-url $BASE_SEPOLIA_RPC --broadcast --verify
 *
 * After deployment, record the schema UID in sdk-js/src/config/networks.ts
 */

interface ISchemaRegistry {
    function register(string calldata schema, address resolver, bool revocable) external returns (bytes32);
}

contract RegisterConfigSnapshotSchema is Script {
    // EAS SchemaRegistry (same on all Base chains)
    address constant SCHEMA_REGISTRY = 0x4200000000000000000000000000000000000020;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        ISchemaRegistry schemaRegistry = ISchemaRegistry(SCHEMA_REGISTRY);

        // Register ConfigSnapshot schema
        // - configHash: keccak256 of canonical AGIRAILS.md
        // - configCID: IPFS CID pointing to the config file
        // - agent: address of the agent that published
        // - version: incrementing version number
        bytes32 schemaUID = schemaRegistry.register(
            "bytes32 configHash, string configCID, address agent, uint256 version",
            address(0), // No resolver (permissionless attestation)
            true        // Revocable (allows config unpublish)
        );

        vm.stopBroadcast();

        console.log("=== ConfigSnapshot Schema Registered ===");
        console.log("Schema UID:");
        console.logBytes32(schemaUID);
        console.log("");
        console.log("Add to sdk-js/src/config/networks.ts:");
        console.log("  configSnapshotSchemaUID: '<schema_uid_here>'");
    }
}
