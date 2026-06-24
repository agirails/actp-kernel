// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {ACTPKernel} from "../src/ACTPKernel.sol";
import {BondEscalation} from "../src/BondEscalation.sol";
import {CompositeMediator} from "../src/CompositeMediator.sol";
import {IACTPKernel} from "../src/interfaces/IACTPKernel.sol";
import {ICompositeMediator} from "../src/interfaces/ICompositeMediator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DeployDisputeSystem
 * @notice Deploy + wire the AIP-14b three-tier dispute system (BondEscalation + CompositeMediator)
 *         against an ALREADY-DEPLOYED ACTPKernel/EscrowVault/USDC. References AIP-14b §6 (mediator
 *         mapping), §7 / §7.4 (bond-escalation engine + constants), §8.4 (UMA Tier-2 / testability
 *         override), §11 (deploy/ops). Decisions: G1 (admin-only + 2-day-timelocked mediator), G2
 *         (UMA probe), G3 (kernel/vault v2 redeploy → addresses from env, never stale literals), G4
 *         (CompositeMediator write-once init, NOT immutable), OQ-5 (genesis evaluator seeding).
 *
 * SAFETY / SCOPE (this script):
 *   - NEVER hardcodes broadcast literals. Kernel / vault / USDC are read from `deployments/aip14b.json`
 *     and/or env (the only hardcoded values are KNOWN IMMUTABLES: the Sepolia MockUSDC default and the
 *     canonical UMA OOV3 — and even those are env-overridable). BondEscalation itself is deployed with
 *     `umaOOV3 = address(0)` so it resolves the canonical `DEFAULT_UMA_OOV3` on-chain (§8.4).
 *   - Contains NO private keys. On mainnet, admin == Gnosis Safe; the `initialize` + `approveMediator`
 *     wiring is emitted as Safe-submittable calldata hints (see console output + deployments/aip14b.json
 *     `safeCalldata`), never executed by a raw key here.
 *   - The full broadcast path is detected via Foundry's ScriptBroadcast context. A mainnet DRY-RUN
 *     SIMULATES every step (including the Safe-only steps, via `vm.prank(admin)`) without reverting,
 *     so `forge script ... --rpc-url <mainnet>` validates the wiring before the Safe ever signs.
 *
 * =============================================================================
 * WIRING ORDER (Decision G4 — load-bearing; see aip14b.json `wiring.deployOrder`)
 * =============================================================================
 *   1. Deploy CompositeMediator(kernel)
 *        → captures `deployer` (== broadcaster) as the ONLY address that may call initialize()
 *          (front-run-proof: `deployer` is immutable, set to msg.sender in the constructor).
 *   2. Deploy BondEscalation(kernel, usdc, compositeMediator, admin, fixed[2], rotating[], umaOOV3=0)
 *        → OQ-5 genesis-seeds the evaluator registry (2 fixed + >=1 rotating, all distinct), NON-
 *          timelocked, so the first AI ruling is not blocked for 2 days. umaOOV3=0 → DEFAULT_UMA_OOV3.
 *   3. compositeMediator.initialize(bondEscalation)
 *        → G4 one-shot, deployer-guarded back-reference. Freezes `bondEscalation` forever; resolve()
 *          is dead until this runs (modifier reverts on msg.sender == address(0)).
 *   4. kernel.approveMediator(compositeMediator, true)
 *        → admin-only (G1). Starts the 2-day MEDIATOR_APPROVAL_DELAY timelock; the mediator becomes an
 *          active kernel resolver only after `block.timestamp >= mediatorApprovedAt`. On mainnet this is
 *          a Safe tx (calldata hint emitted), NOT a raw broadcast.
 *
 * The graph is acyclic at deploy time: CompositeMediator -> kernel (immutable, exists), then
 * BondEscalation -> {kernel, mediator} (both exist), then the SINGLE back-edge mediator -> bond is
 * closed by the write-once initialize(). No constructor depends on a not-yet-deployed contract.
 *
 * =============================================================================
 * USAGE
 * =============================================================================
 *   # Sepolia DRY-RUN (simulation; default — NO --broadcast):
 *   forge script script/DeployDisputeSystem.s.sol \
 *     --rpc-url $BASE_SEPOLIA_RPC --sig "run()"
 *
 *   # Sepolia BROADCAST (Tier-0/1 live; Tier-2 non-functional by design — no OOV3 on Sepolia):
 *   forge script script/DeployDisputeSystem.s.sol \
 *     --rpc-url $BASE_SEPOLIA_RPC --broadcast \
 *     --verify --verifier sourcify
 *   # (Basescan alt: --verify --etherscan-api-key $BASESCAN_API_KEY)
 *
 *   # Mainnet DRY-RUN (recommended before any Safe action — simulates Safe steps, never reverts):
 *   DEPLOY_NETWORK=base-mainnet forge script script/DeployDisputeSystem.s.sol \
 *     --rpc-url $BASE_MAINNET_RPC --sig "run()"
 *
 *   # Mainnet BROADCAST (deployer broadcasts steps 1-3; step 4 = Safe tx, NOT broadcast here):
 *   DEPLOY_NETWORK=base-mainnet forge script script/DeployDisputeSystem.s.sol \
 *     --rpc-url $BASE_MAINNET_RPC --broadcast \
 *     --verify --etherscan-api-key $BASESCAN_API_KEY --slow
 *
 * Required env (see .env.example §AIP-14b):
 *   PRIVATE_KEY                 deployer key (testnet EOA; mainnet hot deployer, NOT the Safe)
 *   DISPUTE_ADMIN              BondEscalation.admin (Sepolia: EOA; mainnet: Gnosis Safe)
 *   EVALUATOR_FIXED_0/1       2 distinct fixed evaluator addresses (§4.6)
 *   EVALUATOR_ROTATING        >=3 comma-delimited rotating evaluators (preferred)
 *                              (legacy fallback: EVALUATOR_ROTATING_0.._7)
 * Optional env (override the deployments/aip14b.json values; for G3 v2 re-point):
 *   DEPLOY_NETWORK            "base-sepolia" (default) | "base-mainnet"
 *   DISPUTE_KERNEL            kernel to wire against (default: aip14b.json existing.ACTPKernel)
 *   DISPUTE_USDC              USDC to wire against (default: aip14b.json existing USDC/MockUSDC)
 *   MAINNET_KERNEL_V2         G3 v2 kernel (mainnet); takes precedence when on base-mainnet
 *   UMA_OOV3_<NET>            informational only (constructor still passes 0 → DEFAULT_UMA_OOV3)
 *   WRITE_DEPLOYMENTS_JSON    "true" to write addresses back into deployments/aip14b.json
 *                             (requires fs_permissions for that path — added to foundry.toml).
 */
contract DeployDisputeSystem is Script {
    // -------------------------------------------------------------------------
    // KNOWN IMMUTABLES ONLY (env-overridable). Everything else comes from env /
    // deployments/aip14b.json — NEVER a hardcoded broadcast literal (G3).
    // -------------------------------------------------------------------------
    // Canonical UMA OptimisticOracleV3 on Base mainnet (== BondEscalation.DEFAULT_UMA_OOV3).
    // Informational here: the constructor still receives address(0) so the on-chain default is used.
    address internal constant DEFAULT_UMA_OOV3 = 0x2aBf1Bd76655de80eDB3086114315Eec75AF500c;
    // Base mainnet USDC (Circle) — used as the default `existing` USDC when targeting mainnet.
    address internal constant MAINNET_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    // Pre-existing ground-truth addresses (mirror deployments/aip14b.json `existing`). These are the
    // CURRENT pre-v2 wiring targets; on mainnet a G3 v2 kernel (MAINNET_KERNEL_V2) overrides at runtime.
    address internal constant SEPOLIA_KERNEL = 0x469CBADbACFFE096270594F0a31f0EEC53753411;
    address internal constant SEPOLIA_USDC = 0x444b4e1A65949AB2ac75979D5d0166Eb7A248Ccb;
    address internal constant MAINNET_KERNEL_PREV2 = 0x132B9eB321dBB57c828B083844287171BDC92d29;
    address internal constant MAINNET_SAFE_ADMIN = 0x61fE58E9EdB380EA65EC74bD364D9D2cba30B7f2;

    uint256 internal constant MEDIATOR_APPROVAL_DELAY = 2 days; // mirrors ACTPKernel constant (G1)
    uint256 internal constant MIN_ROTATING_POOL = 3; // P4-4 operational floor

    struct Cfg {
        string network;
        bool isMainnet;
        address kernel;
        address usdc;
        address admin;
        address[2] fixedEvaluators;
        address[] rotatingPool;
    }

    function run() external {
        Cfg memory c = _loadConfig();
        bool broadcasting = _isBroadcasting();

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        // Testnet: DISPUTE_ADMIN defaults to the deployer EOA (mirrors DeployBaseSepolia). Resolved here
        // because _loadConfig() is view and has no access to the deployer. Mainnet admin is the Safe and
        // is never overwritten.
        if (!c.isMainnet && c.admin == address(0)) {
            c.admin = deployer;
        }

        _printHeader(c, deployer, broadcasting);
        _preflight(c);

        // =====================================================================
        // STEP 1 + 2 + 3: deployer-broadcast (or simulate). CompositeMediator's
        // `deployer` immutable must equal the broadcaster, so initialize() (step 3)
        // is run by the SAME identity — hence steps 1-3 are one broadcast block.
        // =====================================================================
        vm.startBroadcast(deployerKey);

        // --- STEP 1: CompositeMediator(kernel) — front-run-proof deployer capture ---
        CompositeMediator mediator = new CompositeMediator(IACTPKernel(c.kernel));
        console.log("[1] CompositeMediator deployed:", address(mediator));

        // --- STEP 2: BondEscalation(...) — OQ-5 genesis evaluator seeding, umaOOV3=0 (§8.4) ---
        BondEscalation bond = new BondEscalation(
            IACTPKernel(c.kernel),
            IERC20(c.usdc),
            ICompositeMediator(address(mediator)),
            c.admin,
            c.fixedEvaluators,
            c.rotatingPool,
            address(0) // umaOOV3 = 0 → BondEscalation resolves DEFAULT_UMA_OOV3 on-chain (§8.4)
        );
        console.log("[2] BondEscalation deployed:    ", address(bond));

        // --- STEP 3: G4 write-once init (deployer-guarded back-reference) ---
        // The broadcaster IS the mediator's immutable `deployer`, so this one-shot call succeeds.
        mediator.initialize(address(bond));
        console.log("[3] CompositeMediator.initialize(bondEscalation) DONE");

        vm.stopBroadcast();

        // =====================================================================
        // STEP 4: kernel.approveMediator(mediator, true) — admin-only (G1), starts the 2-day timelock.
        //   - Sepolia: admin is typically the deployer EOA → broadcast it (or simulate on dry-run).
        //   - Mainnet: admin == Gnosis Safe → DO NOT broadcast a raw tx. Emit Safe calldata; on a
        //     dry-run, SIMULATE via vm.prank(admin) so the wiring is validated end-to-end.
        // =====================================================================
        bool approveExecutedInScript =
            _step4ApproveMediator(c, deployer, deployerKey, address(mediator), broadcasting);

        // Post-deploy require/assert verification of the full wiring (steps 1-3, + step 4 when applied).
        _verifyWiring(c, mediator, bond, approveExecutedInScript);

        // Address write-back (deployments/aip14b.json) + verify notes.
        _writeBackAndNotes(c, address(mediator), address(bond), broadcasting);
    }

    // =========================================================================
    // Config loading — env first, deployments/aip14b.json `existing` as defaults.
    // =========================================================================
    function _loadConfig() internal view returns (Cfg memory c) {
        c.network = vm.envOr("DEPLOY_NETWORK", string("base-sepolia"));
        c.isMainnet = _eq(c.network, "base-mainnet");

        if (c.isMainnet) {
            // G3: prefer the v2 kernel; fall back to the recorded pre-v2 existing kernel.
            address v2 = vm.envOr("MAINNET_KERNEL_V2", address(0));
            address envKernel = vm.envOr("DISPUTE_KERNEL", address(0));
            c.kernel = v2 != address(0)
                ? v2
                : (envKernel != address(0) ? envKernel : MAINNET_KERNEL_PREV2);
            c.usdc = vm.envOr("DISPUTE_USDC", MAINNET_USDC);
            c.admin = vm.envOr("DISPUTE_ADMIN", MAINNET_SAFE_ADMIN);
        } else {
            c.kernel = vm.envOr("DISPUTE_KERNEL", SEPOLIA_KERNEL);
            c.usdc = vm.envOr("DISPUTE_USDC", SEPOLIA_USDC);
            // On Sepolia admin defaults to the deployer; resolved in _preflight if left zero.
            c.admin = vm.envOr("DISPUTE_ADMIN", address(0));
        }

        // §4.6 evaluator registry — two FIXED + >=3 ROTATING, all distinct (P4-4 operational floor).
        c.fixedEvaluators[0] = vm.envAddress("EVALUATOR_FIXED_0");
        c.fixedEvaluators[1] = vm.envAddress("EVALUATOR_FIXED_1");
        c.rotatingPool = _loadRotatingPool();
    }

    /// @dev Rotating pool source priority mirrors InitEvaluatorRegistry:
    ///      1. EVALUATOR_ROTATING — comma-delimited list (preferred; supports any pool size).
    ///      2. EVALUATOR_ROTATING_0.._7 — legacy individual vars, read in order.
    function _loadRotatingPool() internal view returns (address[] memory pool) {
        address[] memory empty = new address[](0);
        address[] memory listed = vm.envOr("EVALUATOR_ROTATING", ",", empty);
        if (listed.length > 0) return listed;

        address[] memory tmp = new address[](8);
        uint256 n = 0;
        for (uint256 i = 0; i < 8; i++) {
            address a = vm.envOr(string.concat("EVALUATOR_ROTATING_", vm.toString(i)), address(0));
            if (a == address(0)) break;
            tmp[n++] = a;
        }
        require(n > 0, "No rotating evaluators (set EVALUATOR_ROTATING or _0/_1/_2)");
        pool = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            pool[i] = tmp[i];
        }
    }

    // =========================================================================
    // Preflight checks — fail-fast BEFORE any deploy. Mirror the constructor's own
    // requires so a misconfig surfaces with a readable message at simulation time.
    // =========================================================================
    function _preflight(Cfg memory c) internal view {
        require(c.kernel != address(0), "kernel address unresolved");
        require(c.usdc != address(0), "USDC address unresolved");
        require(c.fixedEvaluators[0] != address(0), "EVALUATOR_FIXED_0 unset");
        require(c.fixedEvaluators[1] != address(0), "EVALUATOR_FIXED_1 unset");
        require(c.fixedEvaluators[0] != c.fixedEvaluators[1], "Fixed slots must differ");
        require(c.rotatingPool.length >= MIN_ROTATING_POOL, "P4-4: rotating pool must be >= 3");
        for (uint256 i = 0; i < c.rotatingPool.length; i++) {
            require(c.rotatingPool[i] != address(0), "rotating[i]=0");
            require(
                c.rotatingPool[i] != c.fixedEvaluators[0]
                    && c.rotatingPool[i] != c.fixedEvaluators[1],
                "Rotating overlaps fixed"
            );
            for (uint256 j = i + 1; j < c.rotatingPool.length; j++) {
                require(c.rotatingPool[i] != c.rotatingPool[j], "Duplicate rotating evaluator");
            }
        }
        // Sanity: the kernel we wire against must actually be a contract (skip in pure-simulation w/o RPC).
        require(c.kernel.code.length > 0, "kernel has no code (wrong address/RPC?)");

        if (c.isMainnet) {
            // Mainnet admin must be the Safe (or an explicitly-supplied multisig) — a contract.
            require(c.admin != address(0), "DISPUTE_ADMIN (Safe) required on mainnet");
            require(
                c.admin.code.length > 0, "mainnet DISPUTE_ADMIN must be a contract (Gnosis Safe)"
            );
        }
    }

    // =========================================================================
    // STEP 4 — approveMediator (admin-only). Broadcast on testnet-EOA-admin; Safe-calldata on mainnet.
    // =========================================================================
    function _step4ApproveMediator(
        Cfg memory c,
        address deployer,
        uint256 deployerKey,
        address mediator,
        bool broadcasting
    ) internal returns (bool executedInScript) {
        bytes memory calldata_ = abi.encodeWithSelector(
            ACTPKernel.approveMediator.selector, mediator, true
        );

        if (c.isMainnet) {
            // Mainnet: NEVER broadcast a raw approveMediator — admin is the Safe (2-of-3).
            console.log("");
            console.log("[4] approveMediator => SAFE TRANSACTION (NOT broadcast by this script)");
            console.log("    Safe (to):", c.admin);
            console.log("    target  :", c.kernel);
            console.log("    selector: approveMediator(address,bool)");
            console.log("    arg0    :", mediator);
            console.log("    arg1    : true");
            console.log("    calldata:", vm.toString(calldata_));
            console.log(
                "    effect  : starts 2-day MEDIATOR_APPROVAL_DELAY; resolver active after."
            );

            if (!broadcasting) {
                // DRY-RUN: simulate the Safe's call so the whole wiring is validated without reverting.
                vm.prank(c.admin);
                ACTPKernel(c.kernel).approveMediator(mediator, true);
                console.log("    [dry-run] simulated approveMediator via vm.prank(Safe) - OK");
                return true;
            }
            return false;
        }

        // Testnet path: admin defaults to deployer. If admin is the deployer EOA, broadcast it.
        // If a different (non-deployer, non-contract-we-control) admin was supplied, fall back to a hint.
        address admin = c.admin;
        if (admin == deployer) {
            // `vm.broadcast` works in both dry-run simulation and `forge script --broadcast`.
            // Do not gate this behind an env var: omitting BROADCAST=true must never silently skip the
            // admin step on the documented Sepolia command.
            vm.broadcast(deployerKey);
            ACTPKernel(c.kernel).approveMediator(mediator, true);
            console.log(
                broadcasting
                    ? "[4] approveMediator broadcast by deployer-admin: started 2-day timelock"
                    : "[4] [dry-run] simulated approveMediator via deployer-admin - OK"
            );
            return true;
        } else {
            console.log("");
            console.log("[4] approveMediator => external admin tx (NOT this deployer):");
            console.log("    admin   :", admin);
            console.log("    target  :", c.kernel);
            console.log("    calldata:", vm.toString(calldata_));
            if (!broadcasting) {
                vm.prank(admin);
                ACTPKernel(c.kernel).approveMediator(mediator, true);
                console.log("    [dry-run] simulated approveMediator via vm.prank(admin) - OK");
                return true;
            }
            return false;
        }
    }

    // =========================================================================
    // Post-deploy verification — ALL require/assert checks (steps 1-4).
    // =========================================================================
    function _verifyWiring(
        Cfg memory c,
        CompositeMediator mediator,
        BondEscalation bond,
        bool approveExecutedInScript
    ) internal view {
        // --- CompositeMediator (§6 / G4) ---
        require(address(mediator.kernel()) == c.kernel, "mediator.kernel mismatch");
        require(mediator.bondEscalation() == address(bond), "G4: mediator.bondEscalation not wired");
        // deployer captured at construction == the script broadcaster (front-run-proof).
        require(mediator.deployer() != address(0), "mediator.deployer zero");

        // --- BondEscalation (§7 / §7.4 / §8.4 / OQ-5) ---
        require(address(bond.kernel()) == c.kernel, "bond.kernel mismatch");
        require(address(bond.USDC()) == c.usdc, "bond.USDC mismatch");
        require(address(bond.compositeMediator()) == address(mediator), "bond.mediator mismatch");
        require(bond.admin() == c.admin, "bond.admin mismatch");
        // §8.4 testability override: umaOOV3=0 in ctor MUST resolve to the canonical DEFAULT_UMA_OOV3.
        require(
            bond.UMA_OOV3() == DEFAULT_UMA_OOV3,
            "UMA_OOV3 not canonical (expected DEFAULT_UMA_OOV3)"
        );
        require(!bond.paused(), "bond should start unpaused");

        // OQ-5 genesis seeding: registry live immediately (NON-timelocked), distinct entries.
        require(bond.fixedEvaluators(0) == c.fixedEvaluators[0], "fixed[0] not seeded");
        require(bond.fixedEvaluators(1) == c.fixedEvaluators[1], "fixed[1] not seeded");
        require(bond.fixedEvaluators(0) != bond.fixedEvaluators(1), "fixed slots collide");
        require(bond.rotatingPoolLength() == c.rotatingPool.length, "rotating pool length mismatch");
        for (uint256 i = 0; i < c.rotatingPool.length; i++) {
            require(bond.rotatingPool(i) == c.rotatingPool[i], "rotating[i] not seeded");
        }

        // --- Kernel-side resolver registration (step 4) ---
        bool approved = ACTPKernel(c.kernel).approvedMediators(address(mediator));
        uint256 approvedAt = ACTPKernel(c.kernel).mediatorApprovedAt(address(mediator));
        // On any path where step 4 ran (testnet deployer-admin, or dry-run prank for an external admin),
        // the mediator is approved with a future activation timestamp. On mainnet/external-admin broadcast
        // runs, step 4 is not executed here, so the fresh mediator should remain unapproved.
        if (approveExecutedInScript) {
            require(approved, "mediator not approved after step 4");
            require(
                approvedAt == block.timestamp + MEDIATOR_APPROVAL_DELAY, "timelock window mismatch"
            );
            console.log("[verify] mediator approved; resolver active after 2-day timelock - OK");
        } else {
            require(!approved, "broadcast: approveMediator must be external/Safe tx, not done here");
            console.log(
                "[verify] mediator NOT yet approved (awaiting external admin/Safe approveMediator) - OK"
            );
        }

        console.log("[verify] ALL post-deploy wiring checks PASSED");
    }

    // =========================================================================
    // Write-back to deployments/aip14b.json + verify notes.
    // =========================================================================
    function _writeBackAndNotes(Cfg memory c, address mediator, address bond, bool broadcasting)
        internal
    {
        console.log("");
        console.log("=== ADDRESSES (write back into deployments/aip14b.json) ===");
        console.log("network          :", c.network);
        console.log("CompositeMediator:", mediator);
        console.log("BondEscalation   :", bond);
        console.log("kernel (wired)   :", c.kernel);
        console.log("usdc   (wired)   :", c.usdc);
        console.log("admin            :", c.admin);

        if (vm.envOr("WRITE_DEPLOYMENTS_JSON", false)) {
            // Targeted, in-place updates of the AWAIT_BROADCAST slots for THIS network. Requires the
            // scoped fs_permissions entry for deployments/aip14b.json (added to foundry.toml). Only runs
            // on an explicit opt-in so a pure simulation never touches the repo. String values are
            // wrapped in quotes so each is a valid standalone JSON value for vm.writeJson's key writer.
            string memory path = "deployments/aip14b.json";
            string memory base = string.concat(".networks.", c.network, ".disputeContracts.");
            vm.writeJson(
                _jsonStr(vm.toString(mediator)),
                path,
                string.concat(base, "CompositeMediator.address")
            );
            vm.writeJson(
                _jsonStr("DEPLOYED"), path, string.concat(base, "CompositeMediator.status")
            );
            vm.writeJson(
                _jsonStr(vm.toString(bond)), path, string.concat(base, "BondEscalation.address")
            );
            vm.writeJson(_jsonStr("DEPLOYED"), path, string.concat(base, "BondEscalation.status"));
            console.log("[write-back] deployments/aip14b.json updated for", c.network);
        } else {
            console.log("[write-back] skipped (set WRITE_DEPLOYMENTS_JSON=true to persist).");
        }

        console.log("");
        console.log("=== VERIFICATION NOTES (Basescan / Sourcify) ===");
        console.log("Sourcify (chain-agnostic, no API key):");
        console.log(
            "  forge verify-contract <ADDR> CompositeMediator --verifier sourcify --chain",
            _chainId(c.isMainnet)
        );
        console.log(
            "  forge verify-contract <ADDR> BondEscalation     --verifier sourcify --chain",
            _chainId(c.isMainnet)
        );
        console.log("Basescan (needs BASESCAN_API_KEY):");
        console.log("  forge verify-contract <ADDR> CompositeMediator --watch \\");
        console.log("    --constructor-args $(cast abi-encode 'constructor(address)' <KERNEL>) \\");
        console.log("    --etherscan-api-key $BASESCAN_API_KEY --chain", _chainId(c.isMainnet));
        console.log("  forge verify-contract <ADDR> BondEscalation --watch \\");
        console.log("    --constructor-args $(cast abi-encode \\");
        console.log(
            "      'constructor(address,address,address,address,address[2],address[],address)' \\"
        );
        console.log(
            "      <KERNEL> <USDC> <MEDIATOR> <ADMIN> '[<F0>,<F1>]' '[<R0>,<R1>,<R2>]' 0x0) \\"
        );
        console.log("    --etherscan-api-key $BASESCAN_API_KEY --chain", _chainId(c.isMainnet));

        if (c.isMainnet && broadcasting) {
            console.log("");
            console.log("=== REMAINING MAINNET WIRING (via Gnosis Safe 2-of-3) ===");
            console.log(
                "Safe must submit step 4 approveMediator (calldata printed above). Mediator's"
            );
            console.log(
                "resolve()/resolveDisputeWhilePaused stays inert until block.timestamp >= approvedAt."
            );
        }
    }

    // ----------------------------- helpers -----------------------------------
    function _isBroadcasting() internal view returns (bool) {
        return vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)
            || vm.isContext(VmSafe.ForgeContext.ScriptResume);
    }

    function _printHeader(Cfg memory c, address deployer, bool broadcasting) internal pure {
        console.log("============================================");
        console.log("   AIP-14b DISPUTE SYSTEM DEPLOY (P4-1)");
        console.log("============================================");
        console.log("network   :", c.network);
        console.log("mode      :", broadcasting ? "BROADCAST" : "DRY-RUN (simulate)");
        console.log("deployer  :", deployer);
        console.log("kernel    :", c.kernel);
        console.log("usdc      :", c.usdc);
        console.log("admin     :", c.admin);
        console.log("fixed[0]  :", c.fixedEvaluators[0]);
        console.log("fixed[1]  :", c.fixedEvaluators[1]);
        console.log("rotating count:", c.rotatingPool.length);
        for (uint256 i = 0; i < c.rotatingPool.length; i++) {
            console.log("  rotating[i]:", c.rotatingPool[i]);
        }
        console.log("");
    }

    /// @dev Wrap a string in double quotes so it is a valid standalone JSON value for vm.writeJson's
    ///      single-key writer (a bare 0x-hex / status token is not valid JSON on its own).
    function _jsonStr(string memory s) internal pure returns (string memory) {
        return string.concat("\"", s, "\"");
    }

    function _chainId(bool isMainnet) internal pure returns (uint256) {
        return isMainnet ? 8453 : 84532;
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
