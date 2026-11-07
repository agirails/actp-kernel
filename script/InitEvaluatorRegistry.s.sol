// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {BondEscalation} from "../src/BondEscalation.sol";
import {CompositeMediator} from "../src/CompositeMediator.sol";
import {IACTPKernel} from "../src/interfaces/IACTPKernel.sol";
import {ICompositeMediator} from "../src/interfaces/ICompositeMediator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title InitEvaluatorRegistry
 * @notice P4-4 — evaluator-registry GENESIS init for the AIP-14b dispute system (BondEscalation).
 *
 * AIP-14b refs: §4.1 (tier overview), §4.6 (evaluator registry), §4.8 (rotating pick),
 *               §4.9 (registry governance), OQ-5 (genesis seeding path).
 * Invariants:   INV-16 (AI verdict is challengeable, never authoritative on its own),
 *               INV-17 (registry mutations are timelocked: fixed updates + rotating additions =
 *                       2-day EVALUATOR_UPDATE_DELAY; removals immediate),
 *               INV-18 (evaluator disjointness — fixed slots distinct from each other and from the
 *                       rotating pool, so one keypair can never control >=2 of the 3 evaluator roles).
 *
 * WHY A SEED-AT-CONSTRUCTION SCRIPT (OQ-5):
 *   BondEscalation's registry is seeded NON-timelocked in the CONSTRUCTOR (see
 *   `src/BondEscalation.sol` lines 164-208 "OQ-5 genesis seeding"). There is NO post-deploy
 *   "seed()" entrypoint — if there were, first dispute use would be blocked behind the 2-day
 *   timelock that guards every *later* mutation (INV-17). Therefore "initializing the registry"
 *   == "constructing BondEscalation with the genesis evaluator set". This script performs exactly
 *   that genesis construction (plus the front-run-proof CompositeMediator wiring per G4) and then
 *   ASSERTS the seeded registry matches the env-supplied set and satisfies INV-18.
 *
 * KEY CUSTODY (see docs/AIP14B-EVALUATOR-KEY-CUSTODY.md):
 *   Evaluator ADDRESSES are CONSTRUCTOR/ENV PARAMETERS ONLY. The matching private keys are
 *   KMS/keystore-resident and are generated BEFORE this task — they NEVER appear in this repo,
 *   this script, or any committed file. D1 fixed the vendor LINEAGES (Claude / GPT / Gemini) but
 *   the signing ADDRESSES are KMS-derived, so the env placeholders below are intentionally generic.
 *
 * SAFETY:
 *   - NO --broadcast in any documented invocation here: this is a simulate/dry-run + assertion
 *     harness for P4-4. Real Sepolia broadcast is P4-1; real mainnet is P6-1 (Safe-submitted).
 *   - NO private keys in this file. Mainnet admin = Gnosis Safe (Safe-submittable calldata only).
 *   - Addresses (kernel/usdc/mediator/evaluators) come from env / deployments/aip14b.json — never
 *     hardcoded broadcast literals. The only hardcoded value is the known immutable USDC fallback.
 *
 * USAGE (dry-run / simulation ONLY — never pass --broadcast from this script):
 *   # Base Sepolia genesis simulation (testnet admin = deployer EOA; UMA Tier-2 inert by design)
 *   DISPUTE_ADMIN=0x... \
 *   EVALUATOR_FIXED_0=0x... EVALUATOR_FIXED_1=0x... \
 *   EVALUATOR_ROTATING=0xaaa,0xbbb,0xccc \
 *   forge script script/InitEvaluatorRegistry.s.sol --rpc-url $BASE_SEPOLIA_RPC --sig "runSepolia()"
 *
 *   # Base Mainnet genesis simulation (admin = Gnosis Safe; kernel = v2 redeploy from env)
 *   MAINNET_KERNEL_V2=0x... DISPUTE_ADMIN=0x61fE...b7f2 \
 *   EVALUATOR_FIXED_0=0x... EVALUATOR_FIXED_1=0x... EVALUATOR_ROTATING=0x..,0x..,0x.. \
 *   forge script script/InitEvaluatorRegistry.s.sol --rpc-url $BASE_MAINNET_RPC --sig "runMainnet()"
 *
 * Required env vars (NO defaults for evaluator addresses — fail-closed so a missing KMS address can
 * never be silently replaced by a zero/placeholder):
 *   - DISPUTE_ADMIN        BondEscalation.admin (testnet: deployer EOA; mainnet: Gnosis Safe)
 *   - EVALUATOR_FIXED_0    Fixed evaluator slot 0 (KMS-derived; distinct)
 *   - EVALUATOR_FIXED_1    Fixed evaluator slot 1 (KMS-derived; distinct from slot 0)
 *   - EVALUATOR_ROTATING   Comma-delimited rotating pool (KMS-derived; >=3; disjoint from fixed)
 *                          (legacy fallback: EVALUATOR_ROTATING_0/_1/_2 individually)
 * Optional env vars:
 *   - DISPUTE_KERNEL       Kernel address (overrides per-chain default; G3 v2 re-point hook)
 *   - DISPUTE_USDC         USDC address (overrides per-chain default)
 *   - COMPOSITE_MEDIATOR_ADDRESS  Pre-deployed mediator to reuse (else a fresh one is deployed here)
 *   - UMA_OOV3             UMA OptimisticOracleV3 override (production leaves blank → 0 → on-chain
 *                          DEFAULT_UMA_OOV3 resolution; tests pass a MockOOV3, §8.4)
 */
contract InitEvaluatorRegistry is Script {
    // ---------------------------------------------------------------------
    // Known immutables (allowed hardcodes — match deployments/aip14b.json "existing" + umaConstants)
    // ---------------------------------------------------------------------
    // Base Sepolia
    uint256 internal constant SEPOLIA_CHAIN_ID = 84532;
    address internal constant SEPOLIA_KERNEL = 0x469CBADbACFFE096270594F0a31f0EEC53753411;
    address internal constant SEPOLIA_USDC = 0x444b4e1A65949AB2ac75979D5d0166Eb7A248Ccb; // MockUSDC
    // Base Mainnet
    uint256 internal constant MAINNET_CHAIN_ID = 8453;
    address internal constant MAINNET_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // Circle USDC
    address internal constant MAINNET_SAFE_ADMIN = 0x61fE58E9EdB380EA65EC74bD364D9D2cba30B7f2; // 2-of-3

    /// @notice Minimum rotating-pool size we ENFORCE at genesis. The contract only requires >=1
    ///         (BondEscalation line 183), but P4-4 mandates >=3 so the §4.8 rotating pick has real
    ///         entropy (a 1-member pool degenerates the 3rd evaluator to a constant). Defense-in-depth
    ///         on top of the contract minimum.
    uint256 internal constant MIN_ROTATING_POOL = 3;

    struct Config {
        uint256 chainId;
        address kernel;
        address usdc;
        address admin;
        address[2] fixedEvaluators;
        address[] rotatingPool;
        address umaOOV3; // 0 in production → on-chain DEFAULT_UMA_OOV3 resolution (§8.4)
        address mediator; // 0 → deploy a fresh CompositeMediator in this run
    }

    // =====================================================================
    // Public entrypoints
    // =====================================================================

    /// @notice Genesis-init the evaluator registry against Base Sepolia wiring.
    function runSepolia() external {
        Config memory cfg = _loadConfig(SEPOLIA_CHAIN_ID, SEPOLIA_KERNEL, SEPOLIA_USDC);
        _run(cfg);
    }

    /// @notice Genesis-init the evaluator registry against Base Mainnet wiring (admin = Gnosis Safe).
    /// @dev Kernel address has NO hardcoded default — per G3 the dispute system wires against the
    ///      v2 redeploy supplied via MAINNET_KERNEL_V2 / DISPUTE_KERNEL, never the pre-v2 literal.
    function runMainnet() external {
        address kernel = _envKernel(address(0));
        require(kernel != address(0), "Set MAINNET_KERNEL_V2 (or DISPUTE_KERNEL) - no pre-v2 default (G3)");
        Config memory cfg = _loadConfig(MAINNET_CHAIN_ID, kernel, MAINNET_USDC);
        // Mainnet admin defaults to the Gnosis Safe (Safe-submitted wiring). Overridable via env.
        if (vm.envOr("DISPUTE_ADMIN", address(0)) == address(0)) {
            cfg.admin = MAINNET_SAFE_ADMIN;
        }
        _run(cfg);
    }

    /// @notice Chain-agnostic entrypoint — resolves kernel/usdc per `block.chainid`. Lets the same
    ///         script be driven by a forked chain id in the P4-5 mainnet-fork harness without picking
    ///         a network-specific function.
    function run() external {
        if (block.chainid == MAINNET_CHAIN_ID) {
            address kernel = _envKernel(address(0));
            require(kernel != address(0), "Set MAINNET_KERNEL_V2 (or DISPUTE_KERNEL) on mainnet (G3)");
            Config memory cfg = _loadConfig(MAINNET_CHAIN_ID, kernel, MAINNET_USDC);
            if (vm.envOr("DISPUTE_ADMIN", address(0)) == address(0)) cfg.admin = MAINNET_SAFE_ADMIN;
            _run(cfg);
        } else {
            // Default to Sepolia wiring for testnet / local / fork-of-sepolia simulation.
            Config memory cfg = _loadConfig(SEPOLIA_CHAIN_ID, SEPOLIA_KERNEL, SEPOLIA_USDC);
            _run(cfg);
        }
    }

    // =====================================================================
    // Config loading (env-driven; fail-closed on evaluator addresses)
    // =====================================================================

    function _loadConfig(uint256 chainId, address defaultKernel, address defaultUsdc)
        internal
        view
        returns (Config memory cfg)
    {
        cfg.chainId = chainId;
        cfg.kernel = _envKernel(defaultKernel);
        cfg.usdc = vm.envOr("DISPUTE_USDC", defaultUsdc);
        // admin: read soft (0 default) so runMainnet() can substitute the Gnosis Safe when unset.
        // _validate() fail-closes on admin==0 with a clear message (testnet has no Safe default).
        cfg.admin = vm.envOr("DISPUTE_ADMIN", address(0));
        cfg.fixedEvaluators[0] = vm.envAddress("EVALUATOR_FIXED_0"); // REQUIRED — fail-closed (no default)
        cfg.fixedEvaluators[1] = vm.envAddress("EVALUATOR_FIXED_1"); // REQUIRED — fail-closed (no default)
        cfg.rotatingPool = _loadRotatingPool();
        // Production: leave UMA_OOV3 unset → 0 → BondEscalation resolves canonical DEFAULT_UMA_OOV3
        // on-chain. Tests/forks may inject a MockOOV3 here (§8.4 testability override).
        cfg.umaOOV3 = vm.envOr("UMA_OOV3", address(0));
        // Reuse a pre-deployed mediator if one is supplied; else _run() deploys a fresh one (G4).
        cfg.mediator = vm.envOr("COMPOSITE_MEDIATOR_ADDRESS", address(0));
    }

    /// @dev Kernel resolution order: DISPUTE_KERNEL → MAINNET_KERNEL_V2 → defaultKernel. The env
    ///      overrides are the G3 v2 re-point hook (deploy scripts read addresses from env, never
    ///      stale broadcast literals).
    function _envKernel(address defaultKernel) internal view returns (address) {
        address k = vm.envOr("DISPUTE_KERNEL", address(0));
        if (k != address(0)) return k;
        k = vm.envOr("MAINNET_KERNEL_V2", address(0));
        if (k != address(0)) return k;
        return defaultKernel;
    }

    /// @dev Rotating pool source priority:
    ///        1. EVALUATOR_ROTATING — comma-delimited list (preferred; supports any pool size).
    ///        2. EVALUATOR_ROTATING_0.._N — legacy individual vars (matches .env.example, deployments
    ///           aip14b.json constructorArgs). We read indices 0..7 and stop at the first unset.
    ///      Fail-closed: a fully-empty pool reverts (we never silently seed an empty/short pool).
    function _loadRotatingPool() internal view returns (address[] memory pool) {
        // Preferred: comma-delimited list.
        address[] memory empty = new address[](0);
        address[] memory listed = vm.envOr("EVALUATOR_ROTATING", ",", empty);
        if (listed.length > 0) return listed;

        // Legacy: EVALUATOR_ROTATING_0 .. EVALUATOR_ROTATING_7 (stop at first unset).
        address[] memory tmp = new address[](8);
        uint256 n = 0;
        for (uint256 i = 0; i < 8; i++) {
            address a = vm.envOr(string.concat("EVALUATOR_ROTATING_", vm.toString(i)), address(0));
            if (a == address(0)) break;
            tmp[n++] = a;
        }
        require(n > 0, "No rotating evaluators (set EVALUATOR_ROTATING=0x..,0x..,0x.. or _0/_1/_2)");
        pool = new address[](n);
        for (uint256 i = 0; i < n; i++) pool[i] = tmp[i];
    }

    // =====================================================================
    // Genesis init + assertions
    // =====================================================================

    function _run(Config memory cfg) internal {
        _validate(cfg);
        _logIntro(cfg);

        // P4-4 is a simulate/assert harness. We DELIBERATELY do NOT call vm.startBroadcast here —
        // this run produces no signed transactions. The CompositeMediator + BondEscalation are
        // constructed in-simulation purely to ASSERT that the genesis evaluator set seeds correctly
        // and satisfies INV-16/17/18 BEFORE the real P4-1 (Sepolia) / P6-1 (mainnet Safe) broadcast.
        //
        // G4 deploy order (mirrors deployments/aip14b.json "wiring.deployOrder"):
        //   1. CompositeMediator(kernel)               — captures THIS sender as the only initialize() caller.
        //   2. BondEscalation(kernel, usdc, mediator, admin, fixed[2], rotating[], umaOOV3=0)
        //                                              — OQ-5 genesis seeds the registry in-constructor.
        //   3. mediator.initialize(bondEscalation)     — one-shot, deployer-guarded back-reference.
        //   4. kernel.approveMediator(...)             — 2-day timelock; handled in P4-1/P6-1, NOT here.

        CompositeMediator mediator;
        if (cfg.mediator != address(0)) {
            mediator = CompositeMediator(cfg.mediator);
            console.log("Reusing CompositeMediator:", cfg.mediator);
        } else {
            mediator = new CompositeMediator(IACTPKernel(cfg.kernel)); // step 1
            console.log("Deployed CompositeMediator (simulation):", address(mediator));
        }

        // step 2 — OQ-5 genesis seeding happens inside this constructor (non-timelocked).
        BondEscalation bond = new BondEscalation(
            IACTPKernel(cfg.kernel),
            IERC20(cfg.usdc),
            ICompositeMediator(address(mediator)),
            cfg.admin,
            cfg.fixedEvaluators,
            cfg.rotatingPool,
            cfg.umaOOV3
        );
        console.log("Deployed BondEscalation (simulation):", address(bond));

        // step 3 — only possible when we deployed the mediator in THIS run (we are the deployer).
        if (cfg.mediator == address(0)) {
            mediator.initialize(address(bond));
            console.log("Wired CompositeMediator.initialize(bondEscalation) [G4 write-once]");
        } else {
            console.log("Skipping mediator.initialize (reused mediator; wire via its own deployer)");
        }

        _assertRegistry(bond, cfg);
        _logCalldataHints(cfg, address(mediator), address(bond));
    }

    /// @dev Off-chain (script-side) pre-checks mirroring the on-chain constructor guards, so a bad env
    ///      set is rejected with a clear message BEFORE the deploy reverts with a terse string.
    function _validate(Config memory cfg) internal pure {
        require(cfg.kernel != address(0), "kernel=0");
        require(cfg.usdc != address(0), "usdc=0");
        require(cfg.admin != address(0), "DISPUTE_ADMIN=0");
        require(cfg.fixedEvaluators[0] != address(0), "EVALUATOR_FIXED_0=0");
        require(cfg.fixedEvaluators[1] != address(0), "EVALUATOR_FIXED_1=0");
        // INV-18: fixed slots distinct.
        require(cfg.fixedEvaluators[0] != cfg.fixedEvaluators[1], "INV-18: fixed slots must differ");
        // P4-4: rotating pool >= 3 (defense-in-depth over contract's >=1).
        require(cfg.rotatingPool.length >= MIN_ROTATING_POOL, "P4-4: rotating pool must be >= 3");
        // INV-18: rotating disjoint from fixed, and internally unique.
        for (uint256 i = 0; i < cfg.rotatingPool.length; i++) {
            require(cfg.rotatingPool[i] != address(0), "rotating[i]=0");
            require(
                cfg.rotatingPool[i] != cfg.fixedEvaluators[0] && cfg.rotatingPool[i] != cfg.fixedEvaluators[1],
                "INV-18: rotating overlaps fixed"
            );
            for (uint256 j = i + 1; j < cfg.rotatingPool.length; j++) {
                require(cfg.rotatingPool[i] != cfg.rotatingPool[j], "INV-18: duplicate rotating member");
            }
        }
    }

    /// @dev Read the seeded live registry back out of the deployed contract and assert it matches the
    ///      intended genesis set. This is the actual P4-4 verification: proves OQ-5 non-timelocked
    ///      seeding landed and INV-18 holds on-chain (not just in our pre-check).
    function _assertRegistry(BondEscalation bond, Config memory cfg) internal view {
        require(bond.admin() == cfg.admin, "seed: admin mismatch");
        require(bond.fixedEvaluators(0) == cfg.fixedEvaluators[0], "seed: fixed[0] mismatch");
        require(bond.fixedEvaluators(1) == cfg.fixedEvaluators[1], "seed: fixed[1] mismatch");
        require(bond.rotatingPoolLength() == cfg.rotatingPool.length, "seed: rotating length mismatch");
        for (uint256 i = 0; i < cfg.rotatingPool.length; i++) {
            require(bond.rotatingPool(i) == cfg.rotatingPool[i], "seed: rotating member mismatch");
        }
        // Wiring sanity (immutables).
        require(address(bond.kernel()) == cfg.kernel, "seed: kernel mismatch");
        require(address(bond.USDC()) == cfg.usdc, "seed: usdc mismatch");
        require(bond.paused() == false, "seed: should not be paused at genesis");
        console.log("");
        console.log("REGISTRY ASSERTIONS PASSED:");
        console.log("  fixed[0]:        ", bond.fixedEvaluators(0));
        console.log("  fixed[1]:        ", bond.fixedEvaluators(1));
        console.log("  rotating count:  ", bond.rotatingPoolLength());
        console.log("  admin:           ", bond.admin());
        console.log("  UMA_OOV3:        ", bond.UMA_OOV3());
    }

    // =====================================================================
    // Logging
    // =====================================================================

    function _logIntro(Config memory cfg) internal pure {
        console.log("===========================================================");
        console.log("  AIP-14b P4-4 - EVALUATOR REGISTRY GENESIS INIT (OQ-5)");
        console.log("  (simulation/assert only - NO broadcast, NO key, NO commit)");
        console.log("===========================================================");
        console.log("Chain ID:         ", cfg.chainId);
        console.log("Kernel:           ", cfg.kernel);
        console.log("USDC:             ", cfg.usdc);
        console.log("Dispute admin:    ", cfg.admin);
        console.log("Fixed[0]:         ", cfg.fixedEvaluators[0]);
        console.log("Fixed[1]:         ", cfg.fixedEvaluators[1]);
        console.log("Rotating count:   ", cfg.rotatingPool.length);
        for (uint256 i = 0; i < cfg.rotatingPool.length; i++) {
            console.log("  rotating[i]:    ", cfg.rotatingPool[i]);
        }
        console.log("UMA_OOV3 (0=prod):", cfg.umaOOV3);
        console.log("");
    }

    /// @dev Emit the post-deploy wiring calls operators must run. On mainnet these are Safe-submitted
    ///      (admin = Gnosis Safe); the operator builds the txs from these hints. NO private keys.
    function _logCalldataHints(Config memory cfg, address mediator, address bond) internal view {
        console.log("");
        console.log("=== POST-DEPLOY WIRING (operator / Safe - NOT executed by this script) ===");
        console.log("Step 3 (if mediator deployed separately):");
        console.log("  To:       ", mediator);
        console.log("  Function: initialize(address)");
        console.log("  Arg:      ", bond);
        console.log("");
        console.log("Step 4: approve mediator on kernel (starts 2-day MEDIATOR_APPROVAL_DELAY):");
        console.log("  To:       ", cfg.kernel);
        console.log("  Function: approveMediator(address,bool)");
        console.log("  Args:     [", mediator, ", true ]");
        if (cfg.chainId == MAINNET_CHAIN_ID) {
            console.log("  Submit via Gnosis Safe (2-of-3):", MAINNET_SAFE_ADMIN);
        }
        console.log("");
        console.log("WRITE-BACK: record BondEscalation + CompositeMediator into deployments/aip14b.json");
        console.log("  (disputeContracts.*.address + status=DEPLOYED) at REAL broadcast time (P4-1/P6-1).");
        console.log("");
        console.log("Registry mutations AFTER genesis are TIMELOCKED (INV-17, 2-day EVALUATOR_UPDATE_DELAY):");
        console.log("  add/swap = propose -> wait 2 days -> execute; removal = immediate (pool>1).");
        console.log("  See docs/AIP14B-EVALUATOR-KEY-CUSTODY.md for the full add/remove/swap runbook.");
    }
}
