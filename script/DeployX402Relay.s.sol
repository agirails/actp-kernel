// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/relay/X402Relay.sol";

/**
 * @title DeployX402Relay
 * @notice Deploy X402Relay contract for atomic x402 fee splitting.
 *
 * Usage (Sepolia):
 *   forge script script/DeployX402Relay.s.sol \
 *     --rpc-url $BASE_SEPOLIA_RPC \
 *     --broadcast \
 *     --verify \
 *     --etherscan-api-key $BASESCAN_API_KEY
 *
 * Usage (Mainnet):
 *   USDC_ADDRESS=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 \
 *   forge script script/DeployX402Relay.s.sol \
 *     --rpc-url $BASE_MAINNET_RPC \
 *     --broadcast \
 *     --verify \
 *     --etherscan-api-key $BASESCAN_API_KEY
 *
 * Required env vars:
 *   - PRIVATE_KEY: Deployer private key
 *   - TREASURY_ADDRESS: Fee recipient (optional, defaults to deployer)
 *   - USDC_ADDRESS: USDC contract (optional, defaults to Base Sepolia MockUSDC)
 */
contract DeployX402Relay is Script {
    // Base Sepolia MockUSDC (default)
    address constant SEPOLIA_MOCK_USDC = 0x444b4e1A65949AB2ac75979D5d0166Eb7A248Ccb;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address treasury = vm.envOr("TREASURY_ADDRESS", deployer);
        address usdcAddr = vm.envOr("USDC_ADDRESS", SEPOLIA_MOCK_USDC);
        uint16 feeBps = 100; // 1%

        console.log("=== X402Relay Deployment ===");
        console.log("Deployer:", deployer);
        console.log("USDC:", usdcAddr);
        console.log("Treasury:", treasury);
        console.log("Fee BPS:", feeBps);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        X402Relay relay = new X402Relay(usdcAddr, treasury, feeBps, deployer);

        vm.stopBroadcast();

        // Verify
        require(address(relay.usdc()) == usdcAddr, "USDC mismatch");
        require(relay.feeRecipient() == treasury, "Treasury mismatch");
        require(relay.platformFeeBps() == feeBps, "Fee mismatch");
        require(relay.admin() == deployer, "Admin mismatch");

        console.log("");
        console.log("=== Deployed ===");
        console.log("X402Relay:", address(relay));
        console.log("");
        console.log("Verification OK");
    }
}
