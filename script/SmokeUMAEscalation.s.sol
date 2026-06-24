// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {ACTPKernel} from "../src/ACTPKernel.sol";
import {EscrowVault} from "../src/escrow/EscrowVault.sol";
import {CompositeMediator} from "../src/CompositeMediator.sol";
import {BondEscalation} from "../src/BondEscalation.sol";
import {IACTPKernel} from "../src/interfaces/IACTPKernel.sol";
import {ICompositeMediator} from "../src/interfaces/ICompositeMediator.sol";
import {IOptimisticOracleV3} from "../src/interfaces/IOptimisticOracleV3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title SmokeUMAEscalation
 * @notice READ-ONLY-ish smoke of the AIP-14b Tier-2 UMA path against the REAL Base-mainnet
 *         OptimisticOracleV3 (0x2aBf…500c) on a Base-MAINNET FORK. NO BROADCAST — this script
 *         deploys an ephemeral dispute stack on the fork and walks escalateToUMA → resolved
 *         callback end-to-end so an operator can eyeball that the live OOV3 ABI (assertTruth 9-arg,
 *         identifier, bond floor, settle/callback) is wire-compatible BEFORE any mainnet broadcast.
 *
 * WHY A FORK: Base Sepolia has no UMA OOV3 (G2 probe 2026-06-21, deployments/aip14b.json). The live
 *             oracle exists only on Base mainnet, so Tier-2 is smoked against a mainnet fork.
 *
 * Usage (NO --broadcast — fork-only dry run; the script never sends a real tx):
 *
 *     export BASE_MAINNET_RPC=https://YOUR_BASE_MAINNET_GATEWAY
 *     forge script script/SmokeUMAEscalation.s.sol --fork-url $BASE_MAINNET_RPC -vvv
 *
 * If BASE_MAINNET_RPC is unset/placeholder the script logs a SKIP and returns cleanly (no revert),
 * mirroring the fork-required guard in test/E2E_UMA_Fork.t.sol. All fund movement uses Foundry
 * cheats (deal/prank/warp) — there are NO private keys and NO real transactions in this file.
 */
contract SmokeUMAEscalation is Script, StdCheats {
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // Circle USDC (Base)
    address internal constant UMA_OOV3 = 0x2aBf1Bd76655de80eDB3086114315Eec75AF500c; // canonical OOV3
    bytes32 internal constant ASSERT_TRUTH = bytes32("ASSERT_TRUTH");

    uint256 internal constant UMA_BOND = 500_000_000; // $500 (BondEscalation.UMA_BOND)
    uint64 internal constant UMA_LIVENESS = 7200; // 2h (BondEscalation.UMA_LIVENESS)
    uint256 internal constant MAX_BOND = 500_000_000; // Tier-1 $500 ceiling
    uint256 internal constant INITIAL_BOND = 20_000_000; // $20 first Tier-1 bond
    uint256 internal constant ESCROW_AMOUNT = 1_000_000_000; // $1,000 escrow

    // Deterministic smoke actors (cheatcode-funded; NOT keys).
    address internal admin; // set to address(this) in run() (CompositeMediator deployer == admin)
    address internal requester = address(0xA001);
    address internal provider = address(0xB002);
    address internal keeper = address(0x3);
    address internal rando = address(0xBAD);

    function run() external {
        // ---- fork-required guard: clean SKIP when RPC is unset/placeholder ----
        string memory rpc = vm.envOr("BASE_MAINNET_RPC", string(""));
        if (!_rpcConfigured(rpc)) {
            console2.log("SKIP: BASE_MAINNET_RPC not configured - UMA fork smoke requires a Base-mainnet RPC.");
            console2.log("      Set BASE_MAINNET_RPC and re-run: forge script script/SmokeUMAEscalation.s.sol --fork-url $BASE_MAINNET_RPC");
            return;
        }
        if (UMA_OOV3.code.length == 0) {
            // Defensive: if the script is somehow run on a chain WITHOUT OOV3 code, skip rather than revert.
            console2.log("SKIP: no OOV3 code at 0x2aBf...500c on this chain - run against a Base-mainnet fork.");
            return;
        }

        admin = address(this);

        console2.log("============================================");
        console2.log("   SMOKE: AIP-14b Tier-2 UMA (real OOV3, fork)");
        console2.log("============================================");

        // ---- deploy ephemeral dispute stack on the fork (umaOOV3=0 → real OOV3) ----
        ACTPKernel kernel = new ACTPKernel(admin, admin, address(0xFEE), address(0), USDC, 7 days);
        EscrowVault escrow = new EscrowVault(USDC, address(kernel));
        kernel.approveEscrowVault(address(escrow), true);

        CompositeMediator mediator = new CompositeMediator(IACTPKernel(address(kernel)));
        address[2] memory fixedEvaluators = [makeAddrLite("fixed0"), makeAddrLite("fixed1")];
        address[] memory rotatingPool = new address[](1);
        rotatingPool[0] = makeAddrLite("rotating0");
        BondEscalation bondEscalation = new BondEscalation(
            IACTPKernel(address(kernel)),
            IERC20(USDC),
            ICompositeMediator(address(mediator)),
            admin,
            fixedEvaluators,
            rotatingPool,
            address(0) // production default → resolves DEFAULT_UMA_OOV3 (real Base OOV3)
        );
        mediator.initialize(address(bondEscalation));
        kernel.approveMediator(address(mediator), true);
        vm.warp(block.timestamp + 2 days + 1);

        require(bondEscalation.UMA_OOV3() == UMA_OOV3, "BondEscalation must target canonical OOV3");
        console2.log("BondEscalation:", address(bondEscalation));
        console2.log("UMA_OOV3 (resolved):", bondEscalation.UMA_OOV3());

        // ---- live oracle sanity (G2 recon, on-chain) ----
        IOptimisticOracleV3 oov3 = IOptimisticOracleV3(UMA_OOV3);
        bytes32 id = oov3.defaultIdentifier();
        uint256 minBond = oov3.getMinimumBond(USDC);
        console2.log("OOV3.defaultIdentifier() == ASSERT_TRUTH:", id == ASSERT_TRUTH);
        console2.log("OOV3.getMinimumBond(USDC):", minBond);
        require(id == ASSERT_TRUTH, "identifier drift: not ASSERT_TRUTH");
        require(UMA_BOND >= minBond, "UMA_BOND below live min bond - escalateToUMA would revert (RISK R6)");
        if (minBond == UMA_BOND) {
            console2.log("NOTE: UMA_BOND is EXACTLY at the min-bond floor (zero margin) - RISK R6 / OPS P5-4 drift alert.");
        }

        // ---- fund actors with real USDC via cheatcode ----
        deal(USDC, requester, 5_000_000 * 1e6);
        deal(USDC, keeper, 5_000_000 * 1e6);
        deal(USDC, rando, 5_000_000 * 1e6);

        // ---- drive a fresh tx to DISPUTED, open + walk Tier-1 to the $500 ceiling ----
        bytes32 txId = _createDisputed(kernel, escrow);
        bytes32 disputeId = bondEscalation.openDispute(txId);
        _escalateBondToCeiling(bondEscalation, disputeId);
        console2.log("Tier-1 ceiling reached ($500). Escalating to UMA...");

        // ---- escalateToUMA against the real OOV3 ----
        uint256 keeperBefore = IERC20(USDC).balanceOf(keeper);
        uint256 oov3Before = IERC20(USDC).balanceOf(UMA_OOV3);
        vm.startPrank(keeper);
        IERC20(USDC).approve(address(bondEscalation), UMA_BOND);
        bondEscalation.escalateToUMA(disputeId, "QmEvidenceBundleCID12345");
        vm.stopPrank();

        bytes32 assertionId = bondEscalation.disputeToAssertion(disputeId);
        require(assertionId != bytes32(0), "real assertTruth returned zero assertionId");
        console2.log("assertTruth OK - assertionId:");
        console2.logBytes32(assertionId);
        require(
            IERC20(USDC).balanceOf(UMA_OOV3) == oov3Before + UMA_BOND, "OOV3 did not custody the $500 bond"
        );
        console2.log("OOV3 custodied $500 bond. Escalator paid:", keeperBefore - IERC20(USDC).balanceOf(keeper));

        // ---- warp past real 2h liveness, settle (undisputed → TRUE), resolved callback fires ----
        vm.warp(block.timestamp + uint256(UMA_LIVENESS) + 1);
        vm.prank(keeper);
        bondEscalation.settleUMAAssertion(disputeId);

        IACTPKernel.TransactionView memory v = kernel.getTransaction(txId);
        require(uint8(v.state) == uint8(IACTPKernel.State.SETTLED), "kernel tx not SETTLED after resolved callback");
        console2.log("Resolved callback (msg.sender==OOV3) fired. Kernel tx SETTLED (ruling 0 = provider delivered).");
        console2.log("Asserter (keeper) USDC after settle:", IERC20(USDC).balanceOf(keeper));

        console2.log("============================================");
        console2.log("   UMA TIER-2 SMOKE: PASS (real OOV3, fork)");
        console2.log("============================================");
        console2.log("DISPUTED-callback path + post-DVM distribution: see test/E2E_UMA_Fork.t.sol");
        console2.log("and the P1-7 MockOOV3 suite (authoritative for post-DVM resolution math).");
    }

    // ---------------------------------------------------------------------
    // Helpers (cheatcode-driven; no broadcast, no keys)
    // ---------------------------------------------------------------------
    function _rpcConfigured(string memory rpc) internal pure returns (bool) {
        bytes memory b = bytes(rpc);
        if (b.length == 0) return false;
        if (
            keccak256(b) == keccak256(bytes("https://YOUR_BASE_MAINNET_GATEWAY"))
                || keccak256(b) == keccak256(bytes("YOUR_BASE_MAINNET_GATEWAY"))
        ) return false;
        return true;
    }

    /// @dev Deterministic address from a label (script-local; avoids importing Test's makeAddr).
    function makeAddrLite(string memory label) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked("ACTP_SMOKE_EVALUATOR", label)))));
    }

    function _createDisputed(ACTPKernel kernel, EscrowVault escrow) internal returns (bytes32 txId) {
        vm.prank(requester);
        txId = kernel.createTransaction(
            provider, requester, ESCROW_AMOUNT, block.timestamp + 30 days, 2 days, keccak256("uma-smoke-svc"), 0, 0
        );
        vm.startPrank(requester);
        IERC20(USDC).approve(address(escrow), ESCROW_AMOUNT);
        kernel.linkEscrow(txId, address(escrow), txId);
        vm.stopPrank();

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(10 days));

        uint256 bond = (ESCROW_AMOUNT * kernel.disputeBondBps()) / kernel.MAX_BPS();
        if (bond < kernel.MIN_DISPUTE_BOND()) bond = kernel.MIN_DISPUTE_BOND();
        vm.startPrank(requester);
        IERC20(USDC).approve(address(escrow), bond);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");
        vm.stopPrank();
    }

    function _escalateBondToCeiling(BondEscalation bondEscalation, bytes32 disputeId) internal {
        vm.startPrank(keeper);
        IERC20(USDC).approve(address(bondEscalation), INITIAL_BOND);
        bondEscalation.proposeDirectly(disputeId, 0, 0);
        vm.stopPrank();

        uint256 bond = INITIAL_BOND;
        uint8 ruling = 0;
        for (uint256 i = 0; i < 6; i++) {
            ruling = ruling == 0 ? 1 : 0;
            bond = bond * 2;
            if (bond > MAX_BOND) bond = MAX_BOND;
            address who = (i % 2 == 0) ? rando : keeper;
            vm.startPrank(who);
            IERC20(USDC).approve(address(bondEscalation), bond);
            bondEscalation.challenge(disputeId, ruling, 0);
            vm.stopPrank();
        }
    }
}
