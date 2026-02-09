// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {ACTPKernel} from "../src/ACTPKernel.sol";
import {EscrowVault} from "../src/escrow/EscrowVault.sol";
import {AgentRegistry} from "../src/registry/AgentRegistry.sol";
// Note: ArchiveTreasury has its own IACTPKernel interface, import with alias to avoid collision
import {ArchiveTreasury} from "../src/treasury/ArchiveTreasury.sol";

/**
 * @title DeployBaseMainnet
 * @notice Deploy ACTP contracts to Base Mainnet
 *
 * PREREQUISITES:
 *   1. Gnosis Safe created on Base Mainnet
 *   2. Safe funded with 0.1 ETH for post-deployment config
 *   3. Deployer wallet funded with 0.05 ETH
 *
 * Usage:
 *   # Dry run (simulation)
 *   forge script script/DeployBaseMainnet.s.sol \
 *     --rpc-url https://mainnet.base.org
 *
 *   # Actual deployment
 *   forge script script/DeployBaseMainnet.s.sol \
 *     --rpc-url https://mainnet.base.org \
 *     --broadcast \
 *     --verify \
 *     --etherscan-api-key $BASESCAN_API_KEY \
 *     --slow
 *
 * Required env vars:
 *   - PRIVATE_KEY: Deployer private key (hot wallet, only for deployment)
 *   - KERNEL_ADMIN: Gnosis Safe address (will be admin)
 *   - TREASURY_ADDRESS: Fee recipient (can be same Safe)
 *   - BASESCAN_API_KEY: For contract verification
 *
 * Optional env vars:
 *   - ARCHIVE_UPLOADER: Address authorized to anchor archives (defaults to Safe)
 *
 * POST-DEPLOYMENT (via Gnosis Safe):
 *   1. approveEscrowVault(escrowAddress, true)
 *   2. setArchiveTreasury(archiveAddress)
 *   3. ArchiveTreasury.transferOwnership(safeAddress) - CRITICAL!
 *   4. scheduleAgentRegistryUpdate(registryAddress) - optional, 2-day delay
 */
contract DeployBaseMainnet is Script {
    // Base Mainnet USDC (Circle official)
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    function run() external {
        // Load configuration
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address gnosisSafe = vm.envAddress("KERNEL_ADMIN");
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        address archiveUploader = vm.envOr("ARCHIVE_UPLOADER", gnosisSafe);

        // Validation
        require(gnosisSafe != address(0), "KERNEL_ADMIN not set");
        require(treasury != address(0), "TREASURY_ADDRESS not set");
        require(gnosisSafe.code.length > 0, "KERNEL_ADMIN is not a contract (should be Gnosis Safe)");

        console.log("============================================");
        console.log("   AGIRAILS ACTP - BASE MAINNET DEPLOYMENT");
        console.log("============================================");
        console.log("");
        console.log("Network:       Base Mainnet (Chain ID 8453)");
        console.log("USDC:          ", USDC);
        console.log("");
        console.log("Deployer:      ", deployer);
        console.log("Deployer ETH:  ", deployer.balance / 1e18, "ETH");
        console.log("");
        console.log("Gnosis Safe:   ", gnosisSafe);
        console.log("Treasury:      ", treasury);
        console.log("Archive Uploader:", archiveUploader);
        console.log("");

        require(deployer.balance >= 0.005 ether, "Deployer needs at least 0.005 ETH");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy ACTPKernel
        console.log("1. Deploying ACTPKernel...");
        ACTPKernel kernel = new ACTPKernel(
            gnosisSafe,    // admin (Gnosis Safe)
            gnosisSafe,    // pauser (same Safe for security)
            treasury,      // fee recipient
            address(0),    // agentRegistry (set later via timelock)
            USDC           // USDC mainnet
        );
        console.log("   ACTPKernel deployed at:", address(kernel));

        // Verify kernel configuration
        require(kernel.admin() == gnosisSafe, "Admin mismatch");
        require(kernel.pauser() == gnosisSafe, "Pauser mismatch");
        require(kernel.feeRecipient() == treasury, "Treasury mismatch");
        require(address(kernel.USDC()) == USDC, "USDC mismatch");
        require(kernel.platformFeeBps() == 100, "Fee should be 1%");
        console.log("   Kernel configuration verified");

        // 2. Deploy EscrowVault
        console.log("");
        console.log("2. Deploying EscrowVault...");
        EscrowVault escrow = new EscrowVault(USDC, address(kernel));
        console.log("   EscrowVault deployed at:", address(escrow));

        // Verify escrow configuration
        require(address(escrow.token()) == USDC, "Escrow USDC mismatch");
        require(escrow.kernel() == address(kernel), "Escrow kernel mismatch");
        console.log("   Escrow configuration verified");

        // 3. Deploy AgentRegistry
        console.log("");
        console.log("3. Deploying AgentRegistry...");
        AgentRegistry registry = new AgentRegistry(address(kernel));
        console.log("   AgentRegistry deployed at:", address(registry));

        // Verify registry configuration
        require(registry.actpKernel() == address(kernel), "Registry kernel mismatch");
        console.log("   Registry configuration verified");

        // 4. Deploy ArchiveTreasury
        console.log("");
        console.log("4. Deploying ArchiveTreasury...");
        ArchiveTreasury archive = new ArchiveTreasury(
            USDC,
            address(kernel),
            archiveUploader
        );
        console.log("   ArchiveTreasury deployed at:", address(archive));

        // Verify archive configuration
        require(address(archive.USDC()) == USDC, "Archive USDC mismatch");
        require(address(archive.kernel()) == address(kernel), "Archive kernel mismatch");
        require(archive.uploader() == archiveUploader, "Archive uploader mismatch");
        // WARNING: owner() is deployer, NOT Safe! Must transfer after deployment.
        console.log("   Archive configuration verified");
        console.log("   WARNING: Archive owner is deployer! Transfer to Safe required.");

        vm.stopBroadcast();

        // Print deployment summary
        console.log("");
        console.log("============================================");
        console.log("          DEPLOYMENT COMPLETE");
        console.log("============================================");
        console.log("");
        console.log("Contracts deployed:");
        console.log("  ACTPKernel:      ", address(kernel));
        console.log("  EscrowVault:     ", address(escrow));
        console.log("  AgentRegistry:   ", address(registry));
        console.log("  ArchiveTreasury: ", address(archive));
        console.log("");
        console.log("============================================");
        console.log("    POST-DEPLOYMENT ACTIONS (via Safe)");
        console.log("============================================");
        console.log("");
        console.log("Transaction 1: Approve EscrowVault");
        console.log("  To:       ", address(kernel));
        console.log("  Function: approveEscrowVault(address,bool)");
        console.log("  Args:     [", address(escrow), ", true]");
        console.log("");
        console.log("Transaction 2: Set ArchiveTreasury");
        console.log("  To:       ", address(kernel));
        console.log("  Function: setArchiveTreasury(address)");
        console.log("  Args:     [", address(archive), "]");
        console.log("");
        console.log("Transaction 3: Transfer ArchiveTreasury ownership (CRITICAL!)");
        console.log("  To:       ", address(archive));
        console.log("  Function: transferOwnership(address)");
        console.log("  Args:     [", gnosisSafe, "]");
        console.log("");
        console.log("Transaction 4 (Optional): Schedule AgentRegistry");
        console.log("  To:       ", address(kernel));
        console.log("  Function: scheduleAgentRegistryUpdate(address)");
        console.log("  Args:     [", address(registry), "]");
        console.log("  Note:     2-day timelock before execution");
        console.log("");
        console.log("============================================");
        console.log("           SDK CONFIG UPDATE");
        console.log("============================================");
        console.log("");
        console.log("baseMainnet: {");
        console.log("  chainId: 8453,");
        console.log("  actpKernel: '", vm.toString(address(kernel)), "',");
        console.log("  escrowVault: '", vm.toString(address(escrow)), "',");
        console.log("  agentRegistry: '", vm.toString(address(registry)), "',");
        console.log("  archiveTreasury: '", vm.toString(address(archive)), "',");
        console.log("  usdc: '", vm.toString(USDC), "'");
        console.log("}");
        console.log("");
    }
}
