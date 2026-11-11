// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {ACTPKernel} from "../src/ACTPKernel.sol";
import {BondEscalation} from "../src/BondEscalation.sol";
import {CompositeMediator} from "../src/CompositeMediator.sol";
import {FeeSplitVault} from "../src/escrow/FeeSplitVault.sol";
import {IACTPKernel} from "../src/interfaces/IACTPKernel.sol";

/**
 * @title VerifyFeeSplitGate
 * @notice The FeeSplitVault deploy gate. It accepts a stack, not a contract: the triple
 *         supported kernel + FeeSplitVault + resolver stack (CompositeMediator, BondEscalation).
 *
 *         What it requires:
 *         (1) Supported kernel. The kernel exposes `escrowPrincipal`, `retryPlatformFee` and
 *             `resolveDisputeWhilePaused`. The mainnet v1 kernel has none of them and the July
 *             2026 Sepolia v2 kernel lacks the first two; both are unsupported. A compatible view
 *             layout does not make a stack compatible.
 *         (2) Resolver wiring, checked and not only recorded. A mediator that was never
 *             initialized, or initialized to another BondEscalation, has the same runtime codehash
 *             as a correct one and rejects every resolution, so the storage is read:
 *             mediator.kernel, mediator.bondEscalation, bond.kernel, bond.compositeMediator,
 *             bond.USDC, and the kernel's approval of the mediator with its activation delay
 *             elapsed. BondEscalation itself is not a kernel resolver: it reaches the kernel only
 *             through the mediator.
 *         (3) Vault. Bound to this kernel and its token, cap 1000 bps, empty while not yet
 *             approved, and its own decoding of the kernel view equals the kernel view field by
 *             field on a real transaction.
 *         (4) Bytecode. Runtime codehashes of kernel, mediator, bond and vault: RECORD when the
 *             pin is unset, ENFORCE when set (pattern of VerifyDeployGate).
 *
 * Env:
 *   FEE_SPLIT_KERNEL, FEE_SPLIT_VAULT, COMPOSITE_MEDIATOR, BOND_ESCALATION   (addresses, required)
 *   PROBE_TX                                                                 (bytes32, required)
 *   EXPECTED_KERNEL_CODEHASH, EXPECTED_MEDIATOR_CODEHASH, EXPECTED_BOND_CODEHASH,
 *   EXPECTED_FEE_SPLIT_CODEHASH                                              (bytes32, optional)
 *
 * Run (record):  FEE_SPLIT_KERNEL=0x.. FEE_SPLIT_VAULT=0x.. COMPOSITE_MEDIATOR=0x.. BOND_ESCALATION=0x.. \
 *                PROBE_TX=0x.. forge script script/VerifyFeeSplitGate.s.sol --rpc-url $RPC
 * Run (enforce): + the four EXPECTED_*_CODEHASH pins
 */
contract VerifyFeeSplitGate is Script {
    struct Inputs {
        address kernel;
        address vault;
        address mediator;
        address bond;
        bytes32 probeTx;
        bytes32 kernelCodehash; // zero = record
        bytes32 mediatorCodehash;
        bytes32 bondCodehash;
        bytes32 vaultCodehash;
    }

    function run() external view {
        Inputs memory i = Inputs({
            kernel: vm.envAddress("FEE_SPLIT_KERNEL"),
            vault: vm.envAddress("FEE_SPLIT_VAULT"),
            mediator: vm.envAddress("COMPOSITE_MEDIATOR"),
            bond: vm.envAddress("BOND_ESCALATION"),
            probeTx: vm.envBytes32("PROBE_TX"),
            kernelCodehash: vm.envOr("EXPECTED_KERNEL_CODEHASH", bytes32(0)),
            mediatorCodehash: vm.envOr("EXPECTED_MEDIATOR_CODEHASH", bytes32(0)),
            bondCodehash: vm.envOr("EXPECTED_BOND_CODEHASH", bytes32(0)),
            vaultCodehash: vm.envOr("EXPECTED_FEE_SPLIT_CODEHASH", bytes32(0))
        });
        verify(i);
    }

    /// @notice Reverts with a distinct "GATE: ..." message for each failed requirement.
    function verify(Inputs memory i) public view {
        console2.log("=== FeeSplitVault Deploy Gate ===");
        console2.log("chainid  ", block.chainid);
        console2.log("kernel   ", i.kernel);
        console2.log("vault    ", i.vault);
        console2.log("mediator ", i.mediator);
        console2.log("bond     ", i.bond);
        require(i.kernel.code.length > 0, "GATE: kernel has no code");
        require(i.vault.code.length > 0, "GATE: vault has no code");
        require(i.mediator.code.length > 0, "GATE: mediator has no code");
        require(i.bond.code.length > 0, "GATE: bond has no code");

        _kernel(i);
        _resolvers(i);
        _vault(i);

        _codehash("kernel", i.kernel.codehash, i.kernelCodehash);
        _codehash("mediator", i.mediator.codehash, i.mediatorCodehash);
        _codehash("bond", i.bond.codehash, i.bondCodehash);
        _codehash("vault", i.vault.codehash, i.vaultCodehash);
        console2.log("=== GATE PASSED ===");
    }

    // (1) Supported kernel.
    function _kernel(Inputs memory i) internal view {
        bytes memory code = i.kernel.code;
        require(_hasSelector(code, ACTPKernel.escrowPrincipal.selector), "GATE: kernel lacks escrowPrincipal");
        require(_hasSelector(code, ACTPKernel.retryPlatformFee.selector), "GATE: kernel lacks retryPlatformFee");
        require(
            _hasSelector(code, ACTPKernel.resolveDisputeWhilePaused.selector),
            "GATE: kernel lacks resolveDisputeWhilePaused"
        );
        require(ACTPKernel(i.kernel).feeRecipient() != address(0), "GATE: kernel.feeRecipient() is zero");
        console2.log("OK  supported kernel: escrowPrincipal, retryPlatformFee, resolveDisputeWhilePaused");
    }

    // (2) Resolver wiring.
    function _resolvers(Inputs memory i) internal view {
        ACTPKernel kernel = ACTPKernel(i.kernel);
        CompositeMediator mediator = CompositeMediator(i.mediator);
        BondEscalation bond = BondEscalation(i.bond);

        require(address(mediator.kernel()) == i.kernel, "GATE: mediator.kernel() != kernel");
        address wired = mediator.bondEscalation();
        require(wired != address(0), "GATE: mediator is not initialized");
        require(wired == i.bond, "GATE: mediator.bondEscalation() != bond");
        require(address(bond.kernel()) == i.kernel, "GATE: bond.kernel() != kernel");
        require(address(bond.compositeMediator()) == i.mediator, "GATE: bond.compositeMediator() != mediator");
        require(address(bond.USDC()) == address(kernel.USDC()), "GATE: bond.USDC() != kernel.USDC()");

        require(kernel.approvedMediators(i.mediator), "GATE: mediator is not an approved kernel resolver");
        uint256 approvedAt = kernel.mediatorApprovedAt(i.mediator);
        require(approvedAt != 0, "GATE: mediator approval has no activation time");
        require(block.timestamp >= approvedAt, "GATE: mediator approval is inside its activation delay");
        console2.log("OK  resolver wiring: mediator <-> bond <-> kernel, mediator approved and active");
    }

    // (3) Vault.
    function _vault(Inputs memory i) internal view {
        ACTPKernel kernel = ACTPKernel(i.kernel);
        FeeSplitVault vault = FeeSplitVault(i.vault);
        require(vault.kernel() == i.kernel, "GATE: vault.kernel() != kernel");
        require(address(vault.token()) == address(kernel.USDC()), "GATE: vault.token() != kernel.USDC()");
        require(vault.MAX_INTEGRATOR_BPS() == 1000, "GATE: MAX_INTEGRATOR_BPS != 1000");

        bool approved = kernel.approvedEscrowVaults(i.vault);
        console2.log(approved ? "RECORD  kernel.approvedEscrowVaults(vault) = true" : "RECORD  kernel.approvedEscrowVaults(vault) = false");
        // A vault the kernel has not approved can hold nothing.
        if (!approved) require(vault.totalLocked() == 0, "GATE: unapproved vault is not empty");

        IACTPKernel.TransactionView memory t = kernel.getTransaction(i.probeTx); // reverts on an unknown id
        (bool ok, address requester, address provider, uint256 amount, address escrowContract, bytes32 escrowId, uint16 p)
        = vault.kernelViewProbe(i.probeTx);
        require(ok, "GATE: kernelViewProbe failed on the probe transaction");
        require(
            requester == t.requester && provider == t.provider && amount == t.amount
                && escrowContract == t.escrowContract && escrowId == t.escrowId && p == t.platformFeeBpsLocked,
            "GATE: kernelViewProbe != kernel.getTransaction"
        );
        console2.log("OK  vault bound to kernel and token, cap 1000, kernel view decoded field by field");
    }

    function _hasSelector(bytes memory code, bytes4 selector) internal pure returns (bool) {
        for (uint256 k = 0; k + 4 <= code.length; k++) {
            if (bytes4(bytes.concat(code[k], code[k + 1], code[k + 2], code[k + 3])) == selector) return true;
        }
        return false;
    }

    function _codehash(string memory label, bytes32 live, bytes32 pin) internal pure {
        console2.log(string.concat(label, " runtime codehash:"));
        console2.logBytes32(live);
        if (pin == bytes32(0)) {
            console2.log(string.concat("RECORD (no pin) ", label));
            return;
        }
        require(live == pin, string.concat("GATE: ", label, " codehash mismatch"));
        console2.log(string.concat("OK  ENFORCE ", label, " codehash == pin"));
    }
}
