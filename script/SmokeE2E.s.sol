// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/ACTPKernel.sol";
import "../src/interfaces/IACTPKernel.sol";
import "../src/tokens/MockUSDC.sol";
import "../src/escrow/EscrowVault.sol";

/**
 * End-to-end smoke test against the freshly redeployed Sepolia kernel.
 *
 *   INITIATED → QUOTED → COMMITTED → IN_PROGRESS → DELIVERED → SETTLED
 *
 * Proves the new kernel accepts the full state machine and the storage-layout
 * change (requesterPenaltyBpsLocked) didn't break the happy path.
 *
 * Required env:
 *   PRIVATE_KEY           — requester (funded on Sepolia, any USDC)
 *   PROVIDER_PRIVATE_KEY  — provider (treasury key works)
 */
contract SmokeE2E is Script {
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
        EscrowVault vault = EscrowVault(VAULT);

        uint256 amount = 1_000_000; // $1
        uint256 deadline = block.timestamp + 7 days;
        uint256 disputeWindow = 1 hours;  // kernel minimum; we use the participant-settle path, not the auto-settle path, so no warp needed

        console2.log("Requester:", requester);
        console2.log("Provider :", provider);

        // 1) Requester mints + approves + creates tx
        vm.startBroadcast(reqPk);
        usdc.mint(requester, amount);
        bytes32 txId = kernel.createTransaction(
            provider, requester, amount, deadline, disputeWindow,
            keccak256("smoke"), bytes32(0), 0, 0
        );
        console2.log("txId:");
        console2.logBytes32(txId);
        vm.stopBroadcast();

        // 2) Provider quotes
        vm.startBroadcast(provPk);
        kernel.transitionState(txId, IACTPKernel.State.QUOTED, "");
        vm.stopBroadcast();
        console2.log("QUOTED ok");

        // 3) Requester commits (approve vault, linkEscrow)
        vm.startBroadcast(reqPk);
        usdc.approve(address(vault), amount);
        bytes32 escrowId = keccak256(abi.encode(txId, "esc"));
        kernel.linkEscrow(txId, VAULT, escrowId);
        vm.stopBroadcast();
        console2.log("COMMITTED ok");

        // 4 & 5) Provider → IN_PROGRESS → DELIVERED
        vm.startBroadcast(provPk);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(disputeWindow, keccak256("result")));
        vm.stopBroadcast();
        console2.log("DELIVERED ok");

        // 6) Requester settles (participant path — works before window expires too)
        vm.startBroadcast(reqPk);
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, "");
        vm.stopBroadcast();
        console2.log("SETTLED ok");

        // 7) Assert final state
        IACTPKernel.TransactionView memory v = kernel.getTransaction(txId);
        require(uint8(v.state) == uint8(IACTPKernel.State.SETTLED), "Not settled");

        uint256 provBal = usdc.balanceOf(provider);
        console2.log("Provider USDC balance after settle (gwei):", provBal);
    }
}
