// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/ACTPKernel.sol";
import "../src/escrow/EscrowVault.sol";
import "../src/tokens/MockUSDC.sol";

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

        // 4. Approve EscrowVault in Kernel
        console.log("\nApproving EscrowVault...");
        kernel.approveEscrowVault(address(escrow), true);
        console.log("EscrowVault approved");

        vm.stopBroadcast();

        // Print deployment summary
        console.log("\n=== DEPLOYMENT SUMMARY ===");
        console.log("Network:     Base Sepolia (Chain ID 84532)");
        console.log("ACTPKernel:  ", address(kernel));
        console.log("EscrowVault: ", address(escrow));
        console.log("MockUSDC:    ", address(usdc));
        console.log("Admin:       ", kernel.admin());
        console.log("FeeRecipient:", kernel.feeRecipient());
        console.log("\n=== UPDATE SDK CONFIG ===");
        console.log("contracts: {");
        console.log("  actpKernel: '", vm.toString(address(kernel)), "',");
        console.log("  escrowVault: '", vm.toString(address(escrow)), "',");
        console.log("  usdc: '", vm.toString(address(usdc)), "'");
        console.log("}");
    }
}
