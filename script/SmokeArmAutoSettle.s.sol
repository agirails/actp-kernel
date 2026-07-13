// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/ACTPKernel.sol";
import "../src/interfaces/IACTPKernel.sol";
import "../src/tokens/MockUSDC.sol";
import "../src/escrow/EscrowVault.sol";

/**
 * Arm a transaction for the permissionless auto-settle test on Sepolia.
 *
 * Creates → QUOTES → COMMITTED → IN_PROGRESS → DELIVERED with dispute
 * window = 1 hour (kernel minimum). After 1 h has elapsed, anyone (even a
 * non-participant) can call settle on it via the follow-up script.
 *
 * Prints the txId + window expiry so the return trip knows what to settle.
 */
contract SmokeArmAutoSettle is Script {
    address constant KERNEL = 0xE83cba71C445B4f658D88E4F179FccB9E1454F97;
    address constant VAULT = 0x0DAbBF59C40C1804488a84237C87971b2a7f5f5f;
    address constant USDC = 0x444b4e1A65949AB2ac75979D5d0166Eb7A248Ccb;

    function run() external {
        uint256 reqPk = vm.envUint("PRIVATE_KEY");
        uint256 provPk = vm.envUint("PROVIDER_PRIVATE_KEY");
        address requester = vm.addr(reqPk);
        address provider = vm.addr(provPk);

        ACTPKernel kernel = ACTPKernel(KERNEL);
        MockUSDC usdc = MockUSDC(USDC);

        uint256 amount = 1_000_000;
        uint256 disputeWindow = 1 hours;

        vm.startBroadcast(reqPk);
        usdc.mint(requester, amount);
        bytes32 txId = kernel.createTransaction(
            provider, requester, amount, block.timestamp + 7 days, disputeWindow,
            keccak256("smoke-autosettle"), bytes32(0), 0, 0
        );
        vm.stopBroadcast();

        vm.startBroadcast(provPk);
        kernel.transitionState(txId, IACTPKernel.State.QUOTED, "");
        vm.stopBroadcast();

        vm.startBroadcast(reqPk);
        usdc.approve(VAULT, amount);
        bytes32 escrowId = keccak256(abi.encode(txId, "as-esc"));
        kernel.linkEscrow(txId, VAULT, escrowId);
        vm.stopBroadcast();

        vm.startBroadcast(provPk);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(disputeWindow, keccak256("result")));
        vm.stopBroadcast();

        IACTPKernel.TransactionView memory v = kernel.getTransaction(txId);
        require(uint8(v.state) == uint8(IACTPKernel.State.DELIVERED), "not DELIVERED");

        console2.log("=== AUTO-SETTLE ARMED ===");
        console2.log("txId:");
        console2.logBytes32(txId);
        console2.log("disputeWindow (s):", v.disputeWindow);
        console2.log("Eligible for permissionless settle at unix:", v.disputeWindow + 1);
    }
}
