// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {ACTPKernel} from "../src/ACTPKernel.sol";
import {FeeSplitVault} from "../src/escrow/FeeSplitVault.sol";

/**
 * @title DeployFeeSplitVault
 * @notice Deploys one FeeSplitVault next to a supported kernel. Deploy only: the vault is inert
 *         until the kernel admin approves it, and it has no owner, so the deployer keeps no power.
 *
 *         The kernel's token is read from the kernel, never from the environment, so the vault
 *         cannot be bound to a different token than its kernel.
 *
 *         Approval: the script always prints the calldata of `approveEscrowVault(vault, true)`
 *         (selector 0x4a54b798) for the kernel admin. It broadcasts the approval itself only when
 *         FEE_SPLIT_APPROVE=true AND the broadcaster is the kernel admin, which is the case on
 *         Base Sepolia and on a local stack. On mainnet the admin is a Safe: the script deploys,
 *         prints the calldata, and the Safe sends it after the deploy gate recorded the codehash.
 *
 * Env:
 *   PRIVATE_KEY          deployer (any EOA)
 *   FEE_SPLIT_KERNEL     the supported kernel (candidate build; see VerifyFeeSplitGate)
 *   FEE_SPLIT_APPROVE    optional, "true" to approve in the same run when the deployer is the admin
 *
 * Run: forge script script/DeployFeeSplitVault.s.sol --rpc-url $RPC --broadcast
 */
contract DeployFeeSplitVault is Script {
    function run() external returns (FeeSplitVault vault) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        ACTPKernel kernel = ACTPKernel(vm.envAddress("FEE_SPLIT_KERNEL"));
        require(address(kernel).code.length > 0, "FEE_SPLIT_KERNEL has no code");
        address token = address(kernel.USDC());
        bool approve = vm.envOr("FEE_SPLIT_APPROVE", false);
        address admin = kernel.admin();

        vm.startBroadcast(deployerKey);
        vault = new FeeSplitVault(token, address(kernel));
        if (approve && admin == deployer) kernel.approveEscrowVault(address(vault), true);
        vm.stopBroadcast();

        require(vault.kernel() == address(kernel) && address(vault.token()) == token, "vault wiring");

        console2.log("=== FeeSplitVault ===");
        console2.log("chainid      ", block.chainid);
        console2.log("kernel       ", address(kernel));
        console2.log("token        ", token);
        console2.log("vault        ", address(vault));
        console2.log("runtime codehash:");
        console2.logBytes32(address(vault).codehash);
        console2.log("kernel admin ", admin);
        if (kernel.approvedEscrowVaults(address(vault))) {
            console2.log("approved by the deployer (kernel admin) in this run");
        } else {
            if (approve) console2.log("NOT approved: the deployer is not the kernel admin");
            console2.log("Calldata for the kernel admin, to:", address(kernel));
            console2.logBytes(abi.encodeCall(ACTPKernel.approveEscrowVault, (address(vault), true)));
            console2.log("Run VerifyFeeSplitGate (RECORD) before the admin approves.");
        }
    }
}
