// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {ACTPKernel} from "../src/ACTPKernel.sol";
import {EscrowVault} from "../src/escrow/EscrowVault.sol";
import {AgentRegistry} from "../src/registry/AgentRegistry.sol";
import {ArchiveTreasury} from "../src/treasury/ArchiveTreasury.sol";

/**
 * @title DeployKernelV2
 * @notice P4-2 — AIP-14b kernel redeploy + NEW EscrowVault + re-point fan-out helper.
 *
 *  WHY A REDEPLOY (per AIP14B-DECISIONS.md G3): ACTPKernel is non-upgradeable
 *  (no proxy, plain `new ACTPKernel(...)`). EscrowVault.kernel, AgentRegistry.actpKernel
 *  and ArchiveTreasury.kernel are all `immutable` — a new kernel forces a fresh vault,
 *  registry and (optionally) archive treasury. This script deploys the v2 kernel + a NEW
 *  EscrowVault and calls approveEscrowVault(newVault). Without that approval,
 *  _payoutProviderAmount / _refundRequester / _payoutMediator all revert "Vault not approved"
 *  (src/ACTPKernel.sol L1049 / L1145 / L1156) — even an admin dispute resolution cannot
 *  pay out. The full off-chain/on-chain re-point checklist lives in docs/AIP14B-KERNEL-UPGRADE.md.
 *
 *  THIS SCRIPT DOES NOT BROADCAST BY ITSELF in CI. It mirrors the patterns in
 *  DeployBaseSepolia.s.sol / DeployBaseMainnet.s.sol. Addresses are read from env
 *  (and, for mainnet, written back to deployments/aip14b.json by the operator) —
 *  no hardcoded broadcast literals except the known immutable USDC on mainnet.
 *
 *  -------------------------------------------------------------------------
 *  USAGE
 *  -------------------------------------------------------------------------
 *  Testnet (Base Sepolia — admin == deployer EOA, atomic wiring in-script):
 *
 *    forge script script/DeployKernelV2.s.sol \
 *      --rpc-url $BASE_SEPOLIA_RPC --broadcast --verify \
 *      --etherscan-api-key $BASESCAN_API_KEY
 *
 *  Mainnet (admin == Gnosis Safe 2-of-3 — script deploys contracts only and
 *  PRINTS Safe-submittable calldata; the post-deploy wiring txns are built/
 *  signed in the Safe, NEVER as a raw key broadcast):
 *
 *    forge script script/DeployKernelV2.s.sol \
 *      --rpc-url https://mainnet.base.org --broadcast --verify \
 *      --etherscan-api-key $BASESCAN_API_KEY --slow
 *
 *  -------------------------------------------------------------------------
 *  REQUIRED ENV
 *  -------------------------------------------------------------------------
 *   - PRIVATE_KEY          Deployer key (hot wallet, deploy-only — never the admin key on mainnet)
 *   - KERNEL_ADMIN         v2 admin. Mainnet = Gnosis Safe; testnet = deployer EOA.
 *   - USDC_ADDRESS         USDC token. Mainnet auto-uses the Circle constant if unset.
 *
 *  OPTIONAL ENV
 *   - KERNEL_PAUSER        Defaults to KERNEL_ADMIN (G1: pauser is NOT a resolver).
 *   - KERNEL_FEE_RECIPIENT / TREASURY_ADDRESS  Fee recipient. Defaults to KERNEL_ADMIN.
 *   - RECOVERY_GRACE       F-6 grace seconds. Mainnet 7 days (604800), testnet 1 hour (3600).
 *                          Must be >= MIN_RECOVERY_GRACE (1 hour) or the constructor reverts.
 *   - DEPLOY_ARCHIVE       "true" to also deploy a fresh ArchiveTreasury bound to the v2 kernel.
 *   - ARCHIVE_UPLOADER     Archive anchor authority (defaults to KERNEL_ADMIN).
 *   - DEPLOY_REGISTRY      "true" to also deploy a fresh AgentRegistry bound to the v2 kernel
 *                          and start the 2-day scheduleAgentRegistryUpdate timelock.
 */
contract DeployKernelV2 is Script {
    // Known immutable: Base Mainnet USDC (Circle official). The ONLY hardcoded literal allowed.
    address constant USDC_MAINNET = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    uint256 constant BASE_MAINNET_CHAIN_ID = 8453;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address admin = vm.envOr("KERNEL_ADMIN", deployer);
        address pauser = vm.envOr("KERNEL_PAUSER", admin);

        // Fee recipient: KERNEL_FEE_RECIPIENT > TREASURY_ADDRESS > admin (matches existing scripts).
        address feeRecipient = vm.envOr("KERNEL_FEE_RECIPIENT", vm.envOr("TREASURY_ADDRESS", admin));

        bool isMainnet = block.chainid == BASE_MAINNET_CHAIN_ID;

        // USDC: mainnet defaults to the Circle constant; testnet must supply MockUSDC via env.
        address usdc = vm.envOr("USDC_ADDRESS", isMainnet ? USDC_MAINNET : address(0));
        require(usdc != address(0), "USDC_ADDRESS required (MockUSDC on testnet)");

        // recoveryGrace: explicit RECOVERY_GRACE wins; else 7 days mainnet / 1 hour testnet.
        uint256 recoveryGrace = vm.envOr("RECOVERY_GRACE", isMainnet ? uint256(7 days) : uint256(1 hours));

        bool deployArchive = vm.envOr("DEPLOY_ARCHIVE", false);
        bool deployRegistry = vm.envOr("DEPLOY_REGISTRY", false);
        address archiveUploader = vm.envOr("ARCHIVE_UPLOADER", admin);

        console.log("============================================");
        console.log("   AIP-14b P4-2: KERNEL V2 REDEPLOY");
        console.log("============================================");
        console.log("");
        console.log("Chain ID:        ", block.chainid);
        console.log("Mainnet:         ", isMainnet);
        console.log("Deployer:        ", deployer);
        console.log("Admin (v2):      ", admin);
        console.log("Pauser:          ", pauser);
        console.log("FeeRecipient:    ", feeRecipient);
        console.log("USDC:            ", usdc);
        console.log("recoveryGrace:   ", recoveryGrace);
        console.log("Deploy archive:  ", deployArchive);
        console.log("Deploy registry: ", deployRegistry);
        console.log("");

        // On mainnet the admin MUST be a contract (Gnosis Safe). Catch an EOA mistake early.
        if (isMainnet) {
            require(admin.code.length > 0, "Mainnet admin must be a contract (Gnosis Safe)");
        }

        bool adminIsDeployer = (admin == deployer);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy v2 ACTPKernel (6-arg F-6 constructor; agentRegistry wired later via timelock).
        console.log("1. Deploying ACTPKernel v2...");
        ACTPKernel kernel = new ACTPKernel(
            admin,          // admin
            pauser,         // pauser (G1: NOT part of the resolver set)
            feeRecipient,   // fee recipient
            address(0),     // agentRegistry (set later via scheduleAgentRegistryUpdate timelock)
            usdc,           // USDC token
            recoveryGrace   // recoveryGrace (F-6)
        );
        console.log("   ACTPKernel v2:", address(kernel));

        // Sanity-check constructor wiring (cheap, fail-fast).
        require(kernel.admin() == admin, "Admin mismatch");
        require(kernel.pauser() == pauser, "Pauser mismatch");
        require(kernel.feeRecipient() == feeRecipient, "FeeRecipient mismatch");
        require(address(kernel.USDC()) == usdc, "USDC mismatch");
        require(kernel.platformFeeBps() == 100, "Fee should be 1%");
        require(kernel.recoveryGrace() == recoveryGrace, "recoveryGrace mismatch");
        console.log("   Kernel v2 configuration verified");

        // 2. Deploy a NEW EscrowVault bound to the v2 kernel (vault.kernel is immutable).
        console.log("");
        console.log("2. Deploying NEW EscrowVault v2...");
        EscrowVault vault = new EscrowVault(usdc, address(kernel));
        console.log("   EscrowVault v2:", address(vault));
        require(address(vault.token()) == usdc, "Vault USDC mismatch");
        require(vault.kernel() == address(kernel), "Vault kernel mismatch");
        console.log("   Vault v2 configuration verified");

        // 3. Optional: fresh AgentRegistry (actpKernel is immutable → cannot re-point the old one).
        AgentRegistry registry;
        if (deployRegistry) {
            console.log("");
            console.log("3. Deploying NEW AgentRegistry v2...");
            registry = new AgentRegistry(address(kernel));
            console.log("   AgentRegistry v2:", address(registry));
            require(registry.actpKernel() == address(kernel), "Registry kernel mismatch");
            console.log("   Registry v2 configuration verified");
        }

        // 4. Optional: fresh ArchiveTreasury (kernel is immutable → cannot re-point the old one).
        ArchiveTreasury archive;
        if (deployArchive) {
            console.log("");
            console.log("4. Deploying NEW ArchiveTreasury v2...");
            archive = new ArchiveTreasury(usdc, address(kernel), archiveUploader);
            console.log("   ArchiveTreasury v2:", address(archive));
            require(address(archive.USDC()) == usdc, "Archive USDC mismatch");
            require(address(archive.kernel()) == address(kernel), "Archive kernel mismatch");
            require(archive.uploader() == archiveUploader, "Archive uploader mismatch");
            console.log("   Archive v2 configuration verified");
        }

        // 5. POST-DEPLOY WIRING.
        //    CRITICAL invariant: approveEscrowVault(newVault) MUST execute or the v2 kernel can
        //    never pay out / refund / pay a mediator. When admin == deployer (testnet) we wire it
        //    atomically in-broadcast. When admin is the Safe (mainnet) we CANNOT call onlyAdmin
        //    functions from the deployer key — we emit Safe-submittable calldata instead.
        if (adminIsDeployer) {
            console.log("");
            console.log("5. Wiring v2 (admin == deployer, atomic)...");

            kernel.approveEscrowVault(address(vault), true);
            require(kernel.approvedEscrowVaults(address(vault)), "Vault approval failed");
            console.log("   approveEscrowVault(newVault, true) -> OK");

            if (deployArchive) {
                kernel.setArchiveTreasury(address(archive));
                console.log("   setArchiveTreasury(newArchive) -> OK");
                // Hand archive ownership to admin if deployer != admin (no-op when equal).
                if (archive.owner() != admin) {
                    archive.transferOwnership(admin);
                    console.log("   archive.transferOwnership(admin) -> OK");
                }
            }

            if (deployRegistry) {
                kernel.scheduleAgentRegistryUpdate(address(registry));
                console.log("   scheduleAgentRegistryUpdate(newRegistry) -> scheduled (2-day timelock)");
                console.log("   Run executeAgentRegistryUpdate() after the timelock expires.");
            }
        } else {
            console.log("");
            console.log("5. Admin is a Safe/multisig (mainnet) - wiring is Safe-submitted.");
            console.log("   See the calldata block below; NO onlyAdmin call is broadcast here.");
        }

        vm.stopBroadcast();

        // ----------------------------------------------------------------
        // Summary + write-back hints (operator updates deployments/aip14b.json
        // base-mainnet.* / base-sepolia.* — these are NOT auto-written to avoid
        // touching the file on a dry run).
        // ----------------------------------------------------------------
        console.log("");
        console.log("============================================");
        console.log("        KERNEL V2 DEPLOYMENT COMPLETE");
        console.log("============================================");
        console.log("Write these back to deployments/aip14b.json (.networks.*) and .env:");
        console.log("  MAINNET_KERNEL_V2 / kernelV2 :", address(kernel));
        console.log("  MAINNET_VAULT_V2  / vaultV2  :", address(vault));
        if (deployRegistry) console.log("  agentRegistryV2            :", address(registry));
        if (deployArchive)  console.log("  archiveTreasuryV2          :", address(archive));
        console.log("");

        if (!adminIsDeployer) {
            // Safe-submittable calldata (admin == Gnosis Safe). NO private keys anywhere.
            console.log("============================================");
            console.log("    SAFE TRANSACTIONS (admin = Gnosis Safe)");
            console.log("============================================");
            console.log("");
            console.log("TX 1 (MANDATORY): approve the new vault");
            console.log("  to:       ", address(kernel));
            console.log("  selector: approveEscrowVault(address,bool)");
            console.log("  args:     [", address(vault), ", true ]");
            console.log("  calldata: ", vm.toString(abi.encodeWithSelector(ACTPKernel.approveEscrowVault.selector, address(vault), true)));
            console.log("");
            if (deployArchive) {
                console.log("TX 2: set the new archive treasury");
                console.log("  to:       ", address(kernel));
                console.log("  selector: setArchiveTreasury(address)");
                console.log("  calldata: ", vm.toString(abi.encodeWithSelector(ACTPKernel.setArchiveTreasury.selector, address(archive))));
                console.log("");
                console.log("TX 3 (CRITICAL): transfer archive ownership to the Safe");
                console.log("  to:       ", address(archive));
                console.log("  selector: transferOwnership(address)");
                console.log("  calldata: ", vm.toString(abi.encodeWithSignature("transferOwnership(address)", admin)));
                console.log("");
            }
            if (deployRegistry) {
                console.log("TX 4: schedule the new AgentRegistry (2-day timelock)");
                console.log("  to:       ", address(kernel));
                console.log("  selector: scheduleAgentRegistryUpdate(address)");
                console.log("  calldata: ", vm.toString(abi.encodeWithSelector(ACTPKernel.scheduleAgentRegistryUpdate.selector, address(registry))));
                console.log("  note:     after the 2-day delay, anyone may call executeAgentRegistryUpdate()");
                console.log("");
            }
            console.log("Then run the dispute-system deploy (DeployDisputeSystem.s.sol) with");
            console.log("MAINNET_KERNEL_V2 / MAINNET_VAULT_V2 set to the addresses above, and");
            console.log("Safe-submit approveMediator(CompositeMediator,true) (2-day mediator timelock).");
        }
        console.log("");
        console.log("FULL RE-POINT CHECKLIST: docs/AIP14B-KERNEL-UPGRADE.md");
    }
}
