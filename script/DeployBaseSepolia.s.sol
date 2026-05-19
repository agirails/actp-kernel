// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/ACTPKernel.sol";
import "../src/escrow/EscrowVault.sol";
import "../src/tokens/MockUSDC.sol";
import "../src/registry/AgentRegistry.sol";
import "../src/treasury/ArchiveTreasury.sol";

/**
 * @title DeployBaseSepolia
 * @notice Deploy ACTP contracts to Base Sepolia testnet
 *
 * Usage:
 *   forge script script/DeployBaseSepolia.s.sol \
 *     --rpc-url $BASE_SEPOLIA_RPC \
 *     --broadcast \
 *     --verify \
 *     --etherscan-api-key $BASESCAN_API_KEY
 *
 * Required env vars:
 *   - PRIVATE_KEY: Deployer private key
 *   - BASE_SEPOLIA_RPC: Base Sepolia RPC URL
 *   - BASESCAN_API_KEY: Basescan API key for verification
 *   - KERNEL_ADMIN: Admin address (optional, defaults to deployer)
 *   - TREASURY_ADDRESS: Fee recipient address (optional, defaults to deployer)
 */
contract DeployBaseSepolia is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address admin = vm.envOr("KERNEL_ADMIN", deployer);
        address treasury = vm.envOr("TREASURY_ADDRESS", deployer);

        console.log("Deployer:", deployer);
        console.log("Admin:", admin);
        console.log("Treasury:", treasury);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy MockUSDC (or use existing)
        address existingUSDC = vm.envOr("MOCK_USDC_ADDRESS", address(0));
        MockUSDC usdc;

        if (existingUSDC != address(0)) {
            console.log("Using existing MockUSDC at:", existingUSDC);
            usdc = MockUSDC(existingUSDC);
        } else {
            console.log("Deploying new MockUSDC...");
            usdc = new MockUSDC();
            console.log("MockUSDC deployed at:", address(usdc));
        }

        // 2. Deploy ACTPKernel
        console.log("\nDeploying ACTPKernel...");
        ACTPKernel kernel = new ACTPKernel(
            admin,         // admin
            admin,         // pauser (same as admin)
            treasury,      // fee recipient (separate treasury wallet)
            address(0),    // agentRegistry (deploy later)
            address(usdc)  // USDC token
        );
        console.log("ACTPKernel deployed at:", address(kernel));

        // 3. Deploy EscrowVault
        console.log("\nDeploying EscrowVault...");
        EscrowVault escrow = new EscrowVault(address(usdc), address(kernel));
        console.log("EscrowVault deployed at:", address(escrow));

        // 4. Deploy AgentRegistry
        console.log("\nDeploying AgentRegistry...");
        AgentRegistry registry = new AgentRegistry(address(kernel));
        console.log("AgentRegistry deployed at:", address(registry));

        // 5. Deploy ArchiveTreasury
        console.log("\nDeploying ArchiveTreasury...");
        ArchiveTreasury archive = new ArchiveTreasury(address(usdc), address(kernel), admin);
        console.log("ArchiveTreasury deployed at:", address(archive));

        // 6. Approve EscrowVault in Kernel
        console.log("\nApproving EscrowVault...");
        kernel.approveEscrowVault(address(escrow), true);
        console.log("EscrowVault approved");

        // 7. Set ArchiveTreasury on Kernel
        console.log("\nSetting ArchiveTreasury...");
        kernel.setArchiveTreasury(address(archive));
        console.log("ArchiveTreasury set");

        // 8. Schedule AgentRegistry update (2-day timelock starts)
        console.log("\nScheduling AgentRegistry update (2-day timelock)...");
        kernel.scheduleAgentRegistryUpdate(address(registry));
        console.log("Registry scheduled. Run executeAgentRegistryUpdate() after timelock expires.");

        // 9. Transfer ArchiveTreasury ownership to admin (if different from deployer)
        // On Sepolia admin typically == deployer, so this is a no-op when they match.
        if (admin != deployer) {
            console.log("\nTransferring ArchiveTreasury ownership to admin...");
            archive.transferOwnership(admin);
            console.log("Ownership transferred");
        }

        vm.stopBroadcast();

        // Print deployment summary
        console.log("\n=== DEPLOYMENT SUMMARY ===");
        console.log("Network:           Base Sepolia (Chain ID 84532)");
        console.log("ACTPKernel:       ", address(kernel));
        console.log("EscrowVault:      ", address(escrow));
        console.log("AgentRegistry:    ", address(registry));
        console.log("ArchiveTreasury:  ", address(archive));
        console.log("MockUSDC:         ", address(usdc));
        console.log("Admin:            ", kernel.admin());
        console.log("FeeRecipient:     ", kernel.feeRecipient());
        console.log("\n=== UPDATE SDK CONFIG ===");
        console.log("contracts: {");
        console.log("  actpKernel: '",      vm.toString(address(kernel)),   "',");
        console.log("  escrowVault: '",     vm.toString(address(escrow)),   "',");
        console.log("  agentRegistry: '",   vm.toString(address(registry)), "',");
        console.log("  archiveTreasury: '", vm.toString(address(archive)),  "',");
        console.log("  usdc: '",            vm.toString(address(usdc)),     "'");
        console.log("}");
    }
}
