// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/ACTPKernel.sol";

/**
 * @title ApproveCompositeMediator
 * @notice AIP-14b P4-3 — register the CompositeMediator CONTRACT as an approved kernel
 *         resolver, which starts the 2-day MEDIATOR_APPROVAL_DELAY timelock.
 *
 * @dev WHAT THIS DOES (and does NOT do):
 *   - Calls `ACTPKernel.approveMediator(compositeMediator, true)`.
 *   - The argument is the **CompositeMediator contract address** — NOT any evaluator EOA.
 *     The evaluators sign AI rulings inside BondEscalation; the kernel only ever recognizes
 *     the CompositeMediator as a resolver (AIP-14b §6 / P0-3 / INV-13). Approving an
 *     evaluator here would be a bug — the kernel resolver set is {admin} ∪ {timelocked mediators}.
 *   - This call ONLY *starts* the 2-day timelock. The mediator cannot resolve a DISPUTED
 *     transaction until `block.timestamp >= mediatorApprovedAt[composite]`. See the runbook
 *     `docs/AIP14B-MEDIATOR-APPROVAL-RUNBOOK.md` for the calendar gate.
 *
 * @dev SOURCE OF ADDRESSES (never hardcode broadcast literals):
 *   - Kernel + CompositeMediator are read from env (written back into
 *     `deployments/aip14b.json` by P4-1/P4-2). On Sepolia the kernel defaults to the
 *     current ground-truth kernel if KERNEL_ADDRESS is unset; on the G3 v2 redeploy
 *     (P4-2) set KERNEL_ADDRESS to the v2 address explicitly.
 *
 * ============================================================================
 * SEPOLIA (testnet) — broadcast directly with the deployer/admin key:
 * ============================================================================
 *   COMPOSITE_MEDIATOR_ADDRESS=0x... \
 *   KERNEL_ADDRESS=0x469CBADbACFFE096270594F0a31f0EEC53753411 \
 *   forge script script/ApproveCompositeMediator.s.sol \
 *     --rpc-url $BASE_SEPOLIA_RPC \
 *     --broadcast
 *
 *   Required env:
 *     - PRIVATE_KEY                 Deployer/admin key (must equal kernel.admin())
 *     - COMPOSITE_MEDIATOR_ADDRESS  CompositeMediator from P4-1 write-back
 *     - KERNEL_ADDRESS              (optional on Sepolia; defaults to ground-truth kernel)
 *
 * ============================================================================
 * MAINNET — admin is the Gnosis Safe (2-of-3). DO NOT broadcast with a key.
 * ============================================================================
 *   Run WITHOUT --broadcast to emit the Safe-submittable calldata, then have the
 *   Safe operator build + sign the transaction (kernel.admin() == Safe):
 *
 *   COMPOSITE_MEDIATOR_ADDRESS=0x... \
 *   KERNEL_ADDRESS=$MAINNET_KERNEL_V2 \
 *   forge script script/ApproveCompositeMediator.s.sol --rpc-url $BASE_MAINNET_RPC
 *
 *   The script prints:
 *     to:        <kernel address>
 *     value:     0
 *     data:      approveMediator(compositeMediator, true) ABI-encoded calldata
 *   No private key is read or used on the mainnet path.
 */
contract ApproveCompositeMediator is Script {
    // Ground-truth Base Sepolia kernel (current pre-v2 wiring target; overridable by env).
    // On the G3/P4-2 v2 redeploy, pass KERNEL_ADDRESS explicitly.
    address constant SEPOLIA_KERNEL_DEFAULT = 0x469CBADbACFFE096270594F0a31f0EEC53753411;

    function run() external {
        address kernelAddr = vm.envOr("KERNEL_ADDRESS", SEPOLIA_KERNEL_DEFAULT);
        address composite = vm.envAddress("COMPOSITE_MEDIATOR_ADDRESS");

        require(kernelAddr != address(0), "KERNEL_ADDRESS=0");
        require(composite != address(0), "COMPOSITE_MEDIATOR_ADDRESS=0");
        require(composite != kernelAddr, "composite == kernel (wrong address)");

        ACTPKernel kernel = ACTPKernel(kernelAddr);

        // Build the exact calldata for approveMediator(composite, true).
        bytes memory data = abi.encodeWithSelector(
            ACTPKernel.approveMediator.selector,
            composite,
            true
        );

        console.log("============================================");
        console.log("  AIP-14b P4-3: approveMediator(composite)");
        console.log("============================================");
        console.log("Kernel:            ", kernelAddr);
        console.log("CompositeMediator: ", composite);
        console.log("MEDIATOR_APPROVAL_DELAY (sec):", kernel.MEDIATOR_APPROVAL_DELAY());
        console.log("");

        // Pre-flight read-only sanity checks (no state change).
        // _isApprovedResolver requires approvedMediators==true AND mediatorApprovedAt!=0
        // AND now >= mediatorApprovedAt. After this call, mediatorApprovedAt becomes
        // now + 2 days, so the mediator is NOT yet a live resolver (timelock pending).
        bool alreadyApproved = kernel.approvedMediators(composite);
        uint256 priorApprovedAt = kernel.mediatorApprovedAt(composite);
        uint256 priorRevokedAt = kernel.mediatorRevokedAt(composite);

        console.log("Pre-call state:");
        console.log("  approvedMediators[composite]:", alreadyApproved);
        console.log("  mediatorApprovedAt[composite]:", priorApprovedAt);
        console.log("  mediatorRevokedAt[composite]:", priorRevokedAt);
        console.log("");

        // C-1 guard surfacing: if the mediator was previously revoked, re-approval is
        // blocked until revokedAt + 2 days. Warn loudly so the operator does not assume
        // a fresh timelock when in fact the call will revert "Cannot bypass timelock...".
        if (priorRevokedAt != 0) {
            uint256 reApproveAt = priorRevokedAt + kernel.MEDIATOR_APPROVAL_DELAY();
            console.log("WARNING: mediator was REVOKED. C-1 cooldown applies.");
            console.log("  Earliest re-approval (unix):", reApproveAt);
            require(
                block.timestamp >= reApproveAt,
                "C-1: revoke->re-approve 2-day penalty not elapsed (would revert)"
            );
        }

        if (alreadyApproved) {
            console.log("NOTE: already approved. approveMediator is idempotent and will");
            console.log("      NOT reset mediatorApprovedAt (timelock not restarted).");
        }

        // ---------------------------------------------------------------
        // Mainnet (Safe) path: emit calldata only, never broadcast.
        // Selected when no PRIVATE_KEY is present in env.
        // ---------------------------------------------------------------
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", uint256(0));

        if (deployerKey == 0) {
            console.log("=== SAFE-SUBMITTABLE CALLDATA (no key; do NOT broadcast) ===");
            console.log("to:    ", kernelAddr);
            console.log("value: 0");
            console.log("data:  ");
            console.logBytes(data);
            console.log("");
            console.log("Admin (must equal Safe):", kernel.admin());
            console.log("Build + sign this tx in the Gnosis Safe (2-of-3).");
            console.log("After execution: wait 2 days (MEDIATOR_APPROVAL_DELAY) before");
            console.log("the first mediator-routed DISPUTED resolution. See runbook.");
            return;
        }

        // ---------------------------------------------------------------
        // Testnet path: broadcast with the deployer/admin key.
        // ---------------------------------------------------------------
        address sender = vm.addr(deployerKey);
        console.log("Broadcasting as:", sender);
        require(sender == kernel.admin(), "sender != kernel.admin() (onlyAdmin)");

        vm.startBroadcast(deployerKey);
        kernel.approveMediator(composite, true);
        vm.stopBroadcast();

        // Post-call verification (read-only).
        bool nowApproved = kernel.approvedMediators(composite);
        uint256 nowApprovedAt = kernel.mediatorApprovedAt(composite);
        require(nowApproved, "approveMediator did not set approvedMediators=true");
        require(nowApprovedAt != 0, "mediatorApprovedAt unexpectedly 0");

        console.log("");
        console.log("=== APPROVED (timelock STARTED) ===");
        console.log("approvedMediators[composite]:", nowApproved);
        console.log("mediatorApprovedAt[composite] (unix):", nowApprovedAt);
        console.log("now (unix):                          ", block.timestamp);
        console.log("Resolver-eligible at (unix):         ", nowApprovedAt);
        console.log("");
        console.log("TIMELOCK PENDING: a CompositeMediator-routed DISPUTED resolution");
        console.log("will revert 'Mediator approval pending' until the +2-day gate.");
        console.log("See docs/AIP14B-MEDIATOR-APPROVAL-RUNBOOK.md for the calendar gate.");
    }
}
