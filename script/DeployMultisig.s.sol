// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/ACTPKernel.sol";

/**
 * @title DeployMultisig
 * @notice Script to deploy/configure Gnosis Safe multisig as admin
 *
 * SECURITY REQUIREMENTS:
 * - 3-of-5 or 4-of-7 threshold (balance security vs operational speed)
 * - Signers from different geographic locations
 * - Signers with different roles (CEO, CTO, Legal, Advisors)
 * - Hardware wallets for all signers (Ledger, Trezor)
 * - No signers share the same location or device
 *
 * DEPLOYMENT STEPS:
 * 1. Deploy Gnosis Safe with Safe{Wallet} UI (https://app.safe.global)
 * 2. Add 5-7 signers with diversified control
 * 3. Set threshold to 3 (for 5 signers) or 4 (for 7 signers)
 * 4. Run this script to transfer ACTPKernel admin to multisig
 * 5. Wait 2 days (M-1 fix: admin transfer timelock)
 * 6. Multisig executes acceptAdmin() via Safe UI
 * 7. Verify admin transfer successful
 * 8. Test all admin functions work via multisig
 *
 * PRODUCTION CHECKLIST:
 * ☐ All signers have hardware wallets
 * ☐ All signers tested signing on testnet
 * ☐ Emergency contact info for all signers documented
 * ☐ Multisig address added to monitoring/alerting
 * ☐ Admin transfer tested on testnet first
 * ☐ Legal reviewed signer agreements
 * ☐ Signer key backup procedures documented
 *
 * USAGE:
 * # On Base Sepolia (testnet)
 * forge script script/DeployMultisig.s.sol:DeployMultisig \
 *   --rpc-url $BASE_SEPOLIA_RPC \
 *   --broadcast \
 *   --verify
 *
 * # On Base Mainnet (production)
 * forge script script/DeployMultisig.s.sol:DeployMultisig \
 *   --rpc-url $BASE_MAINNET_RPC \
 *   --broadcast \
 *   --verify \
 *   --slow # Extra safety for production
 */
contract DeployMultisig is Script {
    // ============================================
    // CONFIGURATION (UPDATE BEFORE DEPLOYMENT)
    // ============================================

    // Gnosis Safe address (deploy via https://app.safe.global first)
    address constant GNOSIS_SAFE_ADDRESS = address(0); // ⚠️ UPDATE THIS

    // ACTPKernel address (deployed contract)
    address constant ACTP_KERNEL_ADDRESS = address(0); // ⚠️ UPDATE THIS

    // Expected multisig signers (for verification)
    address constant SIGNER_1_CEO = address(0); // ⚠️ UPDATE THIS
    address constant SIGNER_2_CTO = address(0); // ⚠️ UPDATE THIS
    address constant SIGNER_3_LEGAL = address(0); // ⚠️ UPDATE THIS
    address constant SIGNER_4_ADVISOR_1 = address(0); // ⚠️ UPDATE THIS
    address constant SIGNER_5_ADVISOR_2 = address(0); // ⚠️ UPDATE THIS

    // Expected threshold (3 for 5 signers, 4 for 7 signers)
    uint256 constant EXPECTED_THRESHOLD = 3; // ⚠️ UPDATE THIS

    // ============================================
    // SCRIPT EXECUTION
    // ============================================

    function run() external {
        // Load deployer private key
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== H-1 FIX: Multisig Admin Deployment ===");
        console.log("Deployer:", deployer);
        console.log("ACTPKernel:", ACTP_KERNEL_ADDRESS);
        console.log("Gnosis Safe:", GNOSIS_SAFE_ADDRESS);
        console.log("");

        // Pre-flight checks
        _preflight();

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Transfer admin to multisig (2-step process)
        ACTPKernel kernel = ACTPKernel(ACTP_KERNEL_ADDRESS);

        console.log("Current admin:", kernel.admin());
        console.log("Transferring admin to multisig:", GNOSIS_SAFE_ADDRESS);

        kernel.transferAdmin(GNOSIS_SAFE_ADDRESS);

        console.log("Pending admin:", kernel.pendingAdmin());
        console.log("");
        console.log("=== NEXT STEPS ===");
        console.log("1. Wait 2 days (admin transfer timelock)");
        console.log("2. Go to Safe UI: https://app.safe.global");
        console.log("3. Select multisig:", GNOSIS_SAFE_ADDRESS);
        console.log("4. Create transaction: ACTPKernel.acceptAdmin()");
        console.log("5. Collect 3-of-5 signatures from signers");
        console.log("6. Execute transaction");
        console.log("7. Verify admin == multisig");
        console.log("");
        console.log("Multisig will be active in:", kernel.MEDIATOR_APPROVAL_DELAY(), "seconds (2 days)");

        vm.stopBroadcast();
    }

    // ============================================
    // PRE-FLIGHT CHECKS
    // ============================================

    function _preflight() internal view {
        console.log("=== Pre-Flight Safety Checks ===");

        // Check 1: Gnosis Safe address is not zero
        require(GNOSIS_SAFE_ADDRESS != address(0), "GNOSIS_SAFE_ADDRESS not set");
        console.log("[OK] Gnosis Safe address configured");

        // Check 2: ACTPKernel address is not zero
        require(ACTP_KERNEL_ADDRESS != address(0), "ACTP_KERNEL_ADDRESS not set");
        console.log("[OK] ACTPKernel address configured");

        // Check 3: Gnosis Safe has code (is deployed contract)
        require(GNOSIS_SAFE_ADDRESS.code.length > 0, "Gnosis Safe not deployed");
        console.log("[OK] Gnosis Safe contract exists");

        // Check 4: ACTPKernel has code (is deployed contract)
        require(ACTP_KERNEL_ADDRESS.code.length > 0, "ACTPKernel not deployed");
        console.log("[OK] ACTPKernel contract exists");

        // Check 5: Deployer is current admin
        ACTPKernel kernel = ACTPKernel(ACTP_KERNEL_ADDRESS);
        address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));
        require(kernel.admin() == deployer, "Deployer is not current admin");
        console.log("[OK] Deployer is current admin");

        // Check 6: No pending admin transfer
        require(kernel.pendingAdmin() == address(0), "Admin transfer already pending");
        console.log("[OK] No pending admin transfer");

        // Check 7: All signer addresses configured
        require(SIGNER_1_CEO != address(0), "Signer 1 (CEO) not configured");
        require(SIGNER_2_CTO != address(0), "Signer 2 (CTO) not configured");
        require(SIGNER_3_LEGAL != address(0), "Signer 3 (Legal) not configured");
        require(SIGNER_4_ADVISOR_1 != address(0), "Signer 4 (Advisor 1) not configured");
        require(SIGNER_5_ADVISOR_2 != address(0), "Signer 5 (Advisor 2) not configured");
        console.log("[OK] All 5 signers configured");

        // Check 8: Threshold is valid (3 for 5 signers)
        require(EXPECTED_THRESHOLD >= 3, "Threshold too low (min 3)");
        require(EXPECTED_THRESHOLD <= 5, "Threshold too high (max 5 for 5 signers)");
        console.log("[OK] Threshold valid:", EXPECTED_THRESHOLD);

        console.log("=== All Pre-Flight Checks Passed ===");
        console.log("");
    }
}

/**
 * GNOSIS SAFE DEPLOYMENT GUIDE
 * =============================
 *
 * Step 1: Deploy Safe via Safe{Wallet} UI
 * ----------------------------------------
 * 1. Go to https://app.safe.global
 * 2. Connect wallet (deployer)
 * 3. Select network (Base Sepolia or Base Mainnet)
 * 4. Click "Create New Safe"
 * 5. Name: "AGIRAILS ACTP Admin Multisig"
 * 6. Add signers (5 total, see agirails.io/contact for current team):
 *    - Signer 1: Protocol Lead
 *    - Signer 2: Technical Lead
 *    - Signer 3: Legal Counsel
 *    - Signer 4: Technical Advisor 1
 *    - Signer 5: Technical Advisor 2
 * 7. Set threshold: 3-of-5
 * 8. Review and deploy
 * 9. Copy Safe address
 * 10. Update GNOSIS_SAFE_ADDRESS in this script
 *
 * Step 2: Verify Safe Configuration
 * ----------------------------------
 * # Get Safe owners
 * cast call $SAFE_ADDRESS "getOwners()(address[])" --rpc-url $RPC
 *
 * # Get Safe threshold
 * cast call $SAFE_ADDRESS "getThreshold()(uint256)" --rpc-url $RPC
 *
 * # Should return: 3
 *
 * Step 3: Transfer Admin to Safe
 * -------------------------------
 * # Run this script
 * forge script script/DeployMultisig.s.sol --broadcast --rpc-url $RPC
 *
 * Step 4: Wait 2 Days (Admin Transfer Timelock)
 * ----------------------------------------------
 * # Check pending admin
 * cast call $KERNEL_ADDRESS "pendingAdmin()(address)" --rpc-url $RPC
 *
 * # Should return: $SAFE_ADDRESS
 *
 * Step 5: Accept Admin via Safe UI
 * ---------------------------------
 * 1. Go to https://app.safe.global
 * 2. Select your Safe
 * 3. Click "New Transaction"
 * 4. Select "Contract Interaction"
 * 5. Enter ACTPKernel address
 * 6. Select function: acceptAdmin()
 * 7. Click "Create"
 * 8. Collect 3 signatures from signers
 * 9. Execute transaction
 * 10. Verify success
 *
 * Step 6: Verify Admin Transfer
 * ------------------------------
 * # Check current admin
 * cast call $KERNEL_ADDRESS "admin()(address)" --rpc-url $RPC
 *
 * # Should return: $SAFE_ADDRESS
 *
 * Step 7: Test Admin Functions
 * -----------------------------
 * # Test pause (via Safe UI)
 * ACTPKernel.pause()
 *
 * # Test unpause
 * ACTPKernel.unpause()
 *
 * # Test escrow vault approval
 * ACTPKernel.approveEscrowVault(address, bool)
 *
 * EMERGENCY CONTACTS
 * ==================
 * See agirails.io/contact for current emergency contacts
 *
 * BACKUP PROCEDURES
 * =================
 * 1. All signers MUST backup recovery phrase (24 words)
 * 2. Store in fireproof safe or bank vault
 * 3. Never digital backup (no cloud, no photos)
 * 4. Test recovery on testnet before mainnet
 * 5. Document backup location (sealed envelope)
 * 6. Review backup annually
 *
 * SIGNER ROTATION POLICY
 * ======================
 * When to rotate:
 * - Signer leaves company
 * - Signer device lost/stolen
 * - Signer key potentially compromised
 * - Annual rotation (proactive security)
 *
 * How to rotate:
 * 1. Add new signer via Safe UI
 * 2. Update threshold if needed
 * 3. Remove old signer via Safe UI
 * 4. Test new configuration on testnet
 * 5. Document change in security log
 */
