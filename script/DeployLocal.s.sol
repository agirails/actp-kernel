// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/ACTPKernel.sol";
import "../src/escrow/EscrowVault.sol";
import "../src/tokens/MockUSDC.sol";

/**
 * @title DeployLocal
 * @notice Deploy ACTP contracts to local Anvil testnet
 *
 * Usage:
 *   PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
 *   forge script script/DeployLocal.s.sol --rpc-url http://localhost:8545 --broadcast
 *
 * Note: The key above is Anvil's default account #0 - safe for local testing only!
 */
contract DeployLocal is Script {
    function run() external {
        // Load private key from environment (use Anvil default for local testing)
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy MockUSDC
        console.log("Deploying MockUSDC...");
        MockUSDC usdc = new MockUSDC();
        console.log("MockUSDC deployed at:", address(usdc));

        // 2. Deploy ACTPKernel
        console.log("\nDeploying ACTPKernel...");
        ACTPKernel kernel = new ACTPKernel(
            address(this), // admin (deployer)
            address(this), // pauser (same as admin)
            address(this), // fee recipient
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

        // 5. Mint test USDC to test accounts
        console.log("\nMinting test USDC...");
        address testAccount1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8; // Anvil account 1
        address testAccount2 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC; // Anvil account 2
        
        usdc.mint(testAccount1, 1000000 * 10**6); // 1M USDC
        usdc.mint(testAccount2, 1000000 * 10**6); // 1M USDC
        console.log("Minted 1M USDC to test accounts");

        vm.stopBroadcast();

        // Print summary
        console.log("\n=== Deployment Summary ===");
        console.log("ACTPKernel:  ", address(kernel));
        console.log("EscrowVault: ", address(escrow));
        console.log("MockUSDC:    ", address(usdc));
        console.log("Admin:       ", kernel.admin());
        console.log("FeeRecipient:", kernel.feeRecipient());
        console.log("\nTest Accounts:");
        console.log("Account 1:   ", testAccount1, " (Balance: 1M USDC)");
        console.log("Account 2:   ", testAccount2, " (Balance: 1M USDC)");
    }
}


