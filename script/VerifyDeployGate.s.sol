// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {ACTPKernel} from "../src/ACTPKernel.sol";
import {BondEscalation} from "../src/BondEscalation.sol";

/**
 * @title VerifyDeployGate
 * @notice The AIP-14c deploy gate: verifies a LIVE kernel-v2 + BondEscalation deployment
 *         is (1) the right LOGICAL version, (2) wired to the right collaborators, and
 *         (3) running EXACTLY the audited bytecode — before it is trusted / a mainnet
 *         mediator timelock is armed.
 *
 * WHY codehash is capture-then-enforce (not a hardcoded constant): both contracts bake
 * IMMUTABLES into their runtime bytecode (kernel `recoveryGrace`; Bond kernel/USDC/
 * mediator/UMA_OOV3/cached domain), so the runtime codehash is DEPLOYMENT-SPECIFIC. The
 * flow is therefore:
 *   RECORD  — run right after the audited reference deploy (env pins unset / zero). The
 *             script LOGS the two codehashes; the auditor signs off on THOSE exact hashes.
 *   ENFORCE — thereafter, pass the signed hashes as env pins; the script REVERTS unless the
 *             live code still hashes to them (catches a post-audit swap or wrong-immutable
 *             redeploy). `kernelVersion()` is the constant logical-identity check in both modes.
 *
 * Env:
 *   DISPUTE_KERNEL              (address, required) — the live ACTPKernel v2
 *   DISPUTE_BOND               (address, required) — the live BondEscalation
 *   EXPECTED_USDC              (address, optional) — asserts Bond.USDC() when set
 *   EXPECTED_MEDIATOR          (address, optional) — asserts Bond.compositeMediator() when set
 *   EXPECTED_OOV3              (address, optional) — asserts Bond.UMA_OOV3() when set
 *   EXPECTED_KERNEL_CODEHASH   (bytes32, optional) — ENFORCE kernel codehash when non-zero
 *   EXPECTED_BOND_CODEHASH     (bytes32, optional) — ENFORCE bond codehash when non-zero
 *
 * Run (record):  DISPUTE_KERNEL=0x.. DISPUTE_BOND=0x.. forge script script/VerifyDeployGate.s.sol --rpc-url $RPC
 * Run (enforce): + EXPECTED_KERNEL_CODEHASH=0x.. EXPECTED_BOND_CODEHASH=0x..
 */
contract VerifyDeployGate is Script {
    /// @dev Frozen kernel identity (AIP14C-ABI-FREEZE.md). keccak256("ACTP_KERNEL_V2_AIP14C_REV2").
    bytes32 internal constant KERNEL_VERSION_V2 =
        0x6237ef5c6bfb5df789df4b1707183342f5ab5c813a9b570f3283a32ddc6f9be1;

    /// @dev EIP-712 domain typehash the Bond commits to (matches BondEscalation.DOMAIN_TYPEHASH).
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    function run() external view {
        address kernelAddr = vm.envAddress("DISPUTE_KERNEL");
        address bondAddr = vm.envAddress("DISPUTE_BOND");
        require(kernelAddr.code.length > 0, "GATE: kernel has no code");
        require(bondAddr.code.length > 0, "GATE: bond has no code");

        console2.log("=== AIP-14c Deploy Gate ===");
        console2.log("chainid  ", block.chainid);
        console2.log("kernel   ", kernelAddr);
        console2.log("bond     ", bondAddr);

        // (1) LOGICAL IDENTITY — the constant, network-independent check.
        bytes32 kv = ACTPKernel(kernelAddr).kernelVersion();
        _assertBytes32("kernelVersion", kv, KERNEL_VERSION_V2);

        // (2) WIRING — the Bond must point at THIS kernel, and (when pinned) the right token/
        //     mediator/oracle. Catches a Bond wired to a stale kernel or wrong USDC.
        BondEscalation bond = BondEscalation(bondAddr);
        require(address(bond.kernel()) == kernelAddr, "GATE: bond.kernel() != DISPUTE_KERNEL");
        console2.log("OK  bond.kernel() == kernel");

        _assertOptionalAddr("bond.USDC()", address(bond.USDC()), "EXPECTED_USDC");
        _assertOptionalAddr("bond.compositeMediator()", address(bond.compositeMediator()), "EXPECTED_MEDIATOR");
        _assertOptionalAddr("bond.UMA_OOV3()", bond.UMA_OOV3(), "EXPECTED_OOV3");

        // (2b) DOMAIN SEPARATOR — recompute for (chainid, bond) and require the live getter
        //      matches. Proves the evaluator-signature domain is bound to THIS deployment
        //      (a wrong chain/address here would silently reject every ruling on-chain).
        bytes32 expectedDomain = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("ACTPDisputeEvaluator"), keccak256("1"), block.chainid, bondAddr)
        );
        _assertBytes32("bond.DOMAIN_SEPARATOR()", bond.DOMAIN_SEPARATOR(), expectedDomain);

        // (3) BYTECODE — record or enforce the per-deployment runtime codehash.
        bytes32 kernelCodehash = kernelAddr.codehash;
        bytes32 bondCodehash = bondAddr.codehash;
        console2.log("kernel runtime codehash:");
        console2.logBytes32(kernelCodehash);
        console2.log("bond runtime codehash:");
        console2.logBytes32(bondCodehash);

        _codehashGate("kernel", kernelCodehash, "EXPECTED_KERNEL_CODEHASH");
        _codehashGate("bond", bondCodehash, "EXPECTED_BOND_CODEHASH");

        // (4) STORAGE ROLES + LIVENESS (Codex 2026-07-16 remediation #7). The kernel must NOT be
        //     deployed paused, and admin/pauser must be the pinned governance (the Safe) when set.
        ACTPKernel k = ACTPKernel(kernelAddr);
        require(!k.paused(), "GATE: kernel deployed paused");
        console2.log("OK  kernel not paused");
        _assertOptionalAddr("kernel.admin()", k.admin(), "EXPECTED_KERNEL_ADMIN");
        _assertOptionalAddr("kernel.pauser()", k.pauser(), "EXPECTED_KERNEL_PAUSER");

        // (5) CONSUMER FANOUT — the fee/registry/treasury sinks must be the pinned addresses, so a
        //     mis-wired feeRecipient can't divert fees and a stale registry can't drop reputation.
        _assertOptionalAddr("kernel.feeRecipient()", k.feeRecipient(), "EXPECTED_FEE_RECIPIENT");
        _assertOptionalAddr("kernel.agentRegistry()", address(k.agentRegistry()), "EXPECTED_AGENT_REGISTRY");
        _assertOptionalAddr("kernel.archiveTreasury()", k.archiveTreasury(), "EXPECTED_ARCHIVE_TREASURY");

        // (6) FEE INVARIANT — the protocol charges exactly 1% (platformFeeBps == 100). A deploy with
        //     any other value violates the economic policy (only 1% with a $0.05 minimum).
        require(k.platformFeeBps() == 100, "GATE: platformFeeBps != 100 (1%)");
        console2.log("OK  platformFeeBps == 100 (1%)");

        // (7) OFF-CHAIN OPERATOR CHECKLIST (cannot be asserted from this script — verify manually
        //     before mainnet go, per report.md remediation #7):
        //       - Safe policy: owners set, threshold (e.g. 2-of-4), no rogue modules, guard as intended.
        //       - Evaluator registry: the 2 fixed + rotating evaluator addresses on-chain match the
        //         signer keys in the dispute-evaluator secret store (boot.prod asserts this at boot).
        //       - Constructor args: implicitly pinned by the codehash gate (3) once EXPECTED_*_CODEHASH
        //         is set from the auditor-signed hashes.
        console2.log("NOTE  verify Safe policy + evaluator registry + constructor args off-chain (remediation #7)");

        console2.log("=== GATE PASSED ===");
    }

    function _assertBytes32(string memory label, bytes32 got, bytes32 want) internal pure {
        if (got != want) {
            console2.log(string.concat("GATE FAIL: ", label, " mismatch"));
            console2.logBytes32(got);
            console2.logBytes32(want);
            revert(string.concat("GATE: ", label, " mismatch"));
        }
        console2.log(string.concat("OK  ", label));
    }

    function _assertOptionalAddr(string memory label, address got, string memory envKey) internal view {
        address want = vm.envOr(envKey, address(0));
        if (want == address(0)) {
            console2.log(string.concat("skip (unset) ", label), got);
            return;
        }
        require(got == want, string.concat("GATE: ", label, " != ", envKey));
        console2.log(string.concat("OK  ", label), got);
    }

    function _codehashGate(string memory label, bytes32 live, string memory envKey) internal view {
        bytes32 pin = vm.envOr(envKey, bytes32(0));
        if (pin == bytes32(0)) {
            console2.log(string.concat("RECORD (no pin) ", label, " codehash logged above"));
            return;
        }
        if (live != pin) {
            console2.log(string.concat("GATE FAIL: ", label, " codehash != ", envKey));
            revert(string.concat("GATE: ", label, " codehash mismatch"));
        }
        console2.log(string.concat("OK  ENFORCE ", label, " codehash == pin"));
    }
}
