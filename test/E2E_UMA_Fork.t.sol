// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ACTPKernel} from "../src/ACTPKernel.sol";
import {EscrowVault} from "../src/escrow/EscrowVault.sol";
import {CompositeMediator} from "../src/CompositeMediator.sol";
import {BondEscalation} from "../src/BondEscalation.sol";
import {IACTPKernel} from "../src/interfaces/IACTPKernel.sol";
import {ICompositeMediator} from "../src/interfaces/ICompositeMediator.sol";
import {IOptimisticOracleV3, IUMAFinder, IUMAIdentifierWhitelist} from "../src/interfaces/IOptimisticOracleV3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Minimal extension over the vendored `IOptimisticOracleV3` exposing the on-chain
///         `getAssertion` view (and the subset of its `Assertion` struct this fork test needs).
///         Declared LOCALLY (not added to the shared interface) so the unit-test mocks
///         (`MockOOV3`, `IdentifierSpyOOV3`) are NOT forced to implement it. The field ORDER and
///         types mirror UMA's canonical OptimisticOracleV3 `Assertion` struct verbatim — any drift
///         would silently mis-decode, so future readers must keep this in lockstep with UMA's ABI.
///         (Verified against UMAprotocol/protocol OptimisticOracleV3Interface 2026-06-24.)
interface IOOV3Extended {
    struct EscalationManagerSettings {
        bool arbitrateViaEscalationManager;
        bool discardOracle;
        bool validateDisputers;
        address assertingCaller;
        address escalationManager;
    }

    struct Assertion {
        EscalationManagerSettings escalationManagerSettings;
        address asserter;
        uint64 assertionTime;
        bool settled;
        IERC20 currency;
        uint64 expirationTime;
        bool settlementResolution;
        bytes32 domainId;
        bytes32 identifier;
        uint256 bond;
        address callbackRecipient;
        address disputer;
    }

    function getAssertion(bytes32 assertionId) external view returns (Assertion memory);
}

/// @title E2E_UMA_Fork — AIP-14b §7.4 / §8.1–8.6 / §11 Tier-2 UMA escalation against the REAL
///        Base-mainnet OptimisticOracleV3 (0x2aBf…500c), exercised on a Base-MAINNET fork.
///
/// @notice WHY A MAINNET FORK (G2 / OQ-2): Base SEPOLIA has NO UMA OOV3 at the spec address
///         (eth_getCode = 0x, G2 probe 2026-06-21 — see deployments/aip14b.json). So the only place
///         the Tier-2 path can run against a REAL oracle is a Base-mainnet fork, where OOV3 lives and
///         `getMinimumBond(USDC)` == $500 (== UMA_BOND, exactly at the floor). The unit suites
///         (BondEscalation*.t.sol, UMAIntegration.t.sol) drive the SAME path against MockOOV3; this
///         file proves BondEscalation's `escalateToUMA` + both callbacks are wire-compatible with the
///         genuine on-chain OOV3 ABI (assertTruth 9-arg selector, identifier read, bond custody,
///         msg.sender==OOV3 callback guard, real liveness/settle, real dispute routing to the DVM).
///
/// @dev    FORK-REQUIRED, CLEAN-SKIP, OPT-IN. A plain `forge test` ALWAYS skips this file cleanly — this
///         file NEVER reverts merely because the fork URL is absent. The guard is `_forkActive`,
///         which is true ONLY when FORK_UMA=1 AND `BASE_MAINNET_RPC` is set, non-empty, and NOT the .env.example
///         placeholder, AND a fork was actually created. To RUN it:
///
///           export FORK_UMA=1
    ///           export BASE_MAINNET_RPC=https://YOUR_BASE_MAINNET_GATEWAY
///           forge test --match-contract E2E_UMA_Fork -vvv
///
///         (No --fork-url flag is needed; the contract calls vm.createSelectFork itself so the skip
///          guard can key off the env var directly.)
contract E2E_UMA_Fork is Test {
    // ----- ground-truth Base-mainnet immutables (per task brief / aip14b.json) -----
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // Circle USDC (Base)
    address internal constant UMA_OOV3 = 0x2aBf1Bd76655de80eDB3086114315Eec75AF500c; // canonical OOV3
    bytes32 internal constant ASSERT_TRUTH = bytes32("ASSERT_TRUTH"); // OOV3.defaultIdentifier() on Base (RETIRED from whitelist)
    bytes32 internal constant ASSERT_TRUTH2 = bytes32("ASSERT_TRUTH2"); // live-whitelisted successor on Base mainnet

    // ----- BondEscalation constants mirrored from src (for assertions, NOT redefined behaviour) -----
    uint256 internal constant UMA_BOND = 500_000_000; // $500 (6dp) — BondEscalation.UMA_BOND
    uint64 internal constant UMA_LIVENESS = 7200; // 2 hours — BondEscalation.UMA_LIVENESS
    uint256 internal constant MAX_BOND = 500_000_000; // $500 Tier-1 ceiling — MAX_ESCALATION_BOND
    uint256 internal constant INITIAL_BOND = 20_000_000; // (1e9 * 200bps)/1e4 = $20 — first Tier-1 bond

    // ----- stack (deployed fresh ON the fork; wired to REAL USDC + REAL OOV3) -----
    ACTPKernel internal kernel;
    EscrowVault internal escrow;
    CompositeMediator internal mediator;
    BondEscalation internal bondEscalation;

    // ----- actors -----
    address internal admin = address(this);
    address internal pauser = address(0xFA053);
    address internal feeCollector = address(0xFEE);
    address internal requester = address(0xA001);
    address internal provider = address(0xB002);
    address internal keeper = address(0x3); // escalator / proposer / settler
    address internal rando = address(0xBAD);
    address internal disputer = address(0xD15);

    // evaluators (constructor disjointness — never used to sign here, Tier-2 path only)
    address internal fixed0;
    address internal fixed1;
    address internal rotating0;

    uint256 internal constant ESCROW_AMOUNT = 1_000_000_000; // $1,000 (escrow) — keeps Tier-1 curve $20→$500

    bool internal _forkActive;

    // Mirror events for vm.expectEmit against BondEscalation.
    event UMADisputeEscalated(bytes32 indexed disputeId, bytes32 indexed assertionId);
    event EscalatedToUMA(
        bytes32 indexed disputeId, bytes32 indexed assertionId, address indexed escalator, uint256 bond, string evidenceCID
    );

    // =====================================================================
    // setUp — create the fork ONLY if the RPC is configured; otherwise leave
    // _forkActive=false so every test vm.skips cleanly (no revert, no network).
    // =====================================================================
    function setUp() public {
        if (!_forkEnabled()) {
            // Opt-in only: a plain `forge test` NEVER attempts the fork — even when BASE_MAINNET_RPC
            // is set in .env for the deploy scripts — so a slow / rate-limited / absent gateway can
            // never turn this opportunistic coverage into a red suite. Tests guard on _forkActive.
            return;
        }

        // Create + select the Base-mainnet fork. try/catch so a transient RPC failure degrades to a
        // clean skip rather than a red suite (this file is opportunistic infra coverage, not a gate
        // that should break CI when the gateway is down).
        string memory rpc = vm.envString("BASE_MAINNET_RPC");
        try vm.createSelectFork(rpc) {
            // Belt-and-suspenders: only proceed if OOV3 actually has code on the forked chain.
            if (UMA_OOV3.code.length == 0) {
                _forkActive = false;
                return;
            }
            _forkActive = true;
        } catch {
            _forkActive = false;
            return;
        }

        _deployStackOnFork();
    }

    /// @dev The fork runs ONLY when explicitly opted in via FORK_UMA=1 (or =true) AND a real RPC is
    ///      configured. Decoupled from the mere PRESENCE of BASE_MAINNET_RPC (which the deploy scripts
    ///      also read), so a default `forge test` always skips cleanly regardless of the ambient env.
    ///      (A foundry fork RPC-fetch failure is a runtime abort, NOT a Solidity revert — it cannot be
    ///      try/catch'd — so the only robust guard is to not attempt the fork unless deliberately asked.)
    function _forkEnabled() internal view returns (bool) {
        bytes32 h = keccak256(bytes(vm.envOr("FORK_UMA", string(""))));
        bool optedIn = (h == keccak256(bytes("1")) || h == keccak256(bytes("true")));
        return optedIn && _rpcConfigured();
    }

    /// @dev The fork is "configured" iff BASE_MAINNET_RPC is set, non-empty, and not the placeholder.
    function _rpcConfigured() internal view returns (bool) {
        string memory rpc = vm.envOr("BASE_MAINNET_RPC", string(""));
        bytes memory b = bytes(rpc);
        if (b.length == 0) return false;
        // Reject the .env.example placeholder so a half-filled env doesn't masquerade as configured.
        if (
            keccak256(b) == keccak256(bytes("https://YOUR_BASE_MAINNET_GATEWAY"))
                || keccak256(b) == keccak256(bytes("YOUR_BASE_MAINNET_GATEWAY"))
        ) return false;
        return true;
    }

    /// @dev Resolves the live UMA IdentifierWhitelist via the OOV3's own finder and checks membership.
    ///      This is the durable invariant escalateToUMA must satisfy (the exact gate assertTruth applies).
    function _identifierWhitelisted(bytes32 identifier) internal view returns (bool) {
        address whitelist =
            IUMAFinder(IOptimisticOracleV3(UMA_OOV3).finder()).getImplementationAddress(bytes32("IdentifierWhitelist"));
        return IUMAIdentifierWhitelist(whitelist).isIdentifierSupported(identifier);
    }

    /// @dev Deploy the full dispute stack on the fork, wired to REAL USDC + REAL OOV3 (umaOOV3=0 →
    ///      BondEscalation resolves DEFAULT_UMA_OOV3 == 0x2aBf…500c, the production default). recoveryGrace
    ///      is the 7-day MAINNET value (matches deployments/aip14b.json) so the grace branch is the real one.
    function _deployStackOnFork() internal {
        kernel = new ACTPKernel(admin, pauser, feeCollector, address(0), USDC, 7 days);
        escrow = new EscrowVault(USDC, address(kernel));
        kernel.approveEscrowVault(address(escrow), true);

        fixed0 = makeAddr("fixed0");
        fixed1 = makeAddr("fixed1");
        rotating0 = makeAddr("rotating0");

        mediator = new CompositeMediator(IACTPKernel(address(kernel)));

        address[2] memory fixedEvaluators = [fixed0, fixed1];
        address[] memory rotatingPool = new address[](1);
        rotatingPool[0] = rotating0;
        bondEscalation = new BondEscalation(
            IACTPKernel(address(kernel)),
            IERC20(USDC),
            ICompositeMediator(address(mediator)),
            admin,
            fixedEvaluators,
            rotatingPool,
            address(0) // production: resolves DEFAULT_UMA_OOV3 (0x2aBf…500c) — the LIVE Base OOV3.
        );
        mediator.initialize(address(bondEscalation));
        kernel.approveMediator(address(mediator), true);

        // Pass the 2-day mediator timelock so resolutions can transition kernel state.
        vm.warp(block.timestamp + 2 days + 1);

        // Fund every actor with REAL USDC via cheatcode balance write (works on standard ERC20s).
        deal(USDC, requester, 5_000_000 * 1e6);
        deal(USDC, keeper, 5_000_000 * 1e6);
        deal(USDC, rando, 5_000_000 * 1e6);
        deal(USDC, disputer, 5_000_000 * 1e6);
    }

    // =====================================================================
    // Sanity: the fork really points at the canonical OOV3 with the expected
    // identifier + bond floor. Proves the wiring assumptions (G2 recon) hold
    // on the live chain, not just in the deploy JSON.
    // =====================================================================
    function test_Fork_OOV3_IdentifierAndBondFloor() external {
        if (!_forkActive) {
            vm.skip(true);
            return;
        }

        // BondEscalation resolved the canonical address from umaOOV3=0.
        assertEq(bondEscalation.UMA_OOV3(), UMA_OOV3, "BondEscalation must target the canonical OOV3");

        IOptimisticOracleV3 oov3 = IOptimisticOracleV3(UMA_OOV3);

        // The OOV3 still REPORTS ASSERT_TRUTH as its default, but that identifier has been RETIRED from
        // the live IdentifierWhitelist (AIP-14b root cause); ASSERT_TRUTH2 is its whitelisted successor.
        // escalateToUMA must therefore select ASSERT_TRUTH2, never the stale default.
        assertEq(oov3.defaultIdentifier(), ASSERT_TRUTH, "OOV3.defaultIdentifier() still reports ASSERT_TRUTH on Base");
        assertFalse(_identifierWhitelisted(ASSERT_TRUTH), "root cause: ASSERT_TRUTH must be de-whitelisted on Base");
        assertTrue(_identifierWhitelisted(ASSERT_TRUTH2), "fix: ASSERT_TRUTH2 must be the live-whitelisted identifier");

        // UMA_BOND ($500) is the hard FLOOR for the posted bond; the live USDC minimum sits exactly
        // at it today (G2). Since the R6 fix, escalateToUMA posts max(UMA_BOND, getMinimumBond(USDC)),
        // so a UMA governance raise of this floor no longer bricks escalation — it adapts by posting
        // the higher live minimum. This assertion remains a DRIFT MONITOR: if it flips, escalation
        // still works but the escalator's posted bond (and the SDK's escalate-cost quote) will exceed
        // $500, which the team should surface via the R6 min-bond drift alert (OPS P5-4).
        uint256 minBond = oov3.getMinimumBond(USDC);
        assertGe(UMA_BOND, minBond, "UMA_BOND floor no longer covers the live OOV3 minimum (R6 drift)");
        assertEq(minBond, UMA_BOND, "G2 drift monitor: live USDC min bond diverged from UMA_BOND ($500)");
    }

    // =====================================================================
    // §8.4 escalateToUMA against the REAL OOV3:
    //   - assertTruth returns a NON-ZERO assertionId (9-arg selector accepted),
    //   - identifier recorded on the assertion == OOV3.defaultIdentifier() (ASSERT_TRUTH),
    //   - the emitted claim embeds "ipfs://" + CID (decoded from the REAL AssertionMade event),
    //   - the $500 bond left the escalator and is custodied by the real OOV3.
    // =====================================================================
    function test_Fork_EscalateToUMA_RealOracle_AssertTruth() external {
        if (!_forkActive) {
            vm.skip(true);
            return;
        }

        bytes32 disputeId = _openedAtCeiling();
        string memory cid = "QmEvidenceBundleCID12345";

        uint256 escalatorBefore = IERC20(USDC).balanceOf(keeper);
        uint256 oov3Before = IERC20(USDC).balanceOf(UMA_OOV3);

        // Capture the REAL OOV3 AssertionMade event so we can decode its non-indexed `claim` bytes.
        vm.recordLogs();

        vm.startPrank(keeper);
        IERC20(USDC).approve(address(bondEscalation), UMA_BOND);
        bondEscalation.escalateToUMA(disputeId, cid, "QmReasoningCID");
        vm.stopPrank();

        // (1) Non-zero assertionId recorded in BondEscalation's reverse map.
        bytes32 assertionId = bondEscalation.disputeToAssertion(disputeId);
        assertTrue(assertionId != bytes32(0), "real assertTruth must return a non-zero assertionId");

        // (2) Identifier on the live assertion must be one the live IdentifierWhitelist ACCEPTS — the
        //     durable invariant (else OOV3 would have reverted at assertTruth). On Base the retired
        //     default forces the ASSERT_TRUTH2 fallback (AIP-14b identifier-rotation fix), asserted
        //     explicitly as a drift monitor.
        IOOV3Extended.Assertion memory a = IOOV3Extended(UMA_OOV3).getAssertion(assertionId);
        assertTrue(_identifierWhitelisted(a.identifier), "escalateToUMA must post a live-whitelisted identifier");
        assertEq(a.identifier, ASSERT_TRUTH2, "Base drift monitor: expected the ASSERT_TRUTH2 fallback today");
        assertEq(a.bond, UMA_BOND, "assertion bond must be $500");
        assertEq(address(a.currency), USDC, "assertion currency must be USDC");
        assertEq(a.callbackRecipient, address(bondEscalation), "callbackRecipient must be BondEscalation");
        assertFalse(a.settled, "fresh assertion must not be settled");

        // (3) The claim embeds ipfs://<cid> — decoded from the genuine on-chain AssertionMade event.
        bytes memory claim = _claimFromLogs(assertionId);
        assertTrue(claim.length > 0, "could not recover claim from AssertionMade event");
        assertTrue(_contains(claim, bytes("ipfs://")), "claim missing ipfs:// scheme");
        assertTrue(_contains(claim, bytes(cid)), "claim missing evidence CID");
        assertTrue(_contains(claim, bytes(string.concat("ipfs://", cid))), "CID not ipfs-prefixed in claim");

        // (4) Bond custody: $500 left the escalator and the OOV3 balance rose by $500.
        assertEq(IERC20(USDC).balanceOf(keeper), escalatorBefore - UMA_BOND, "escalator must post the $500 bond");
        assertEq(IERC20(USDC).balanceOf(UMA_OOV3), oov3Before + UMA_BOND, "OOV3 must custody the $500 bond");

        // Tier advanced to 2 (UMA), and the UMA bond is NOT folded into Tier-1 accumulatedBonds.
        assertEq(_tierOf(disputeId), 2, "dispute must be in Tier 2 after escalation");
    }

    // =====================================================================
    // R13 — UMA callback gas-forwarding / revert-vs-swallow (FIRST-RESOLUTION OOG mitigation).
    // ---------------------------------------------------------------------------------------------
    // VERIFIED against UMAprotocol/protocol OptimisticOracleV3._callbackOnAssertionResolve /
    // _callbackOnAssertionDispute (2026-06-24):
    //   * NO try/catch — a callback REVERT bubbles up and BLOCKS settleAssertion, STRANDING the $500
    //     UMA bond until the dispute's 30-day forceResolveStale fallback.
    //   * NO explicit gas cap — ALL remaining gas is forwarded to the callback (standard Solidity
    //     external-call semantics). UMA's own docs: "The recipient MUST implement these callbacks and
    //     not revert or the assertion resolution will be blocked."
    // MITIGATION (already in src/BondEscalation.assertionResolvedCallback, exercised by the resolved
    // test below): the UNBOUNDED leg (compositeMediator.resolve → kernel.transitionState →
    // _distributeFee/_releaseEscrow/reputation) is wrapped in a local try/catch (F-4). On OOG/revert
    // of that leg the callback DOES NOT revert — it flags the escrow leg `mediatorRetryPending` and
    // returns, so UMA settlement still commits and the bond is returned; the escrow movement is
    // re-driven permissionlessly via retryMediatorResolution. The Tier-1 distribution + settle-bounty
    // (F-6) complete BEFORE that external call under CEI + nonReentrant. Net: BondEscalation's
    // resolved-callback can NEVER block UMA's all-gas, no-catch settlement on a first-resolution OOG.
    // Because the callback receives ALL forwarded gas, the only way to OOG it is the caller itself
    // under-provisioning settleUMAAssertion — which the F-4 deferral + retry path tolerates.
    // The fork test below drives the genuine all-gas, no-catch resolved callback to completion.
    // =====================================================================

    // =====================================================================
    // §8.5 RESOLVED callback (undisputed → TRUE) against the REAL OOV3:
    //   warp past the real 2h liveness, drive settleUMAAssertion → the real OOV3 fires
    //   assertionResolvedCallback(msg.sender==OOV3) SYNCHRONOUSLY → BondEscalation resolves
    //   locally (ruling 0 = provider delivered), returns the $500 bond to the asserter, and the
    //   kernel-side escrow leg settles. Proves the msg.sender==OOV3 guard accepts the genuine caller.
    // =====================================================================
    function test_Fork_ResolvedCallback_RealOracle_Undisputed() external {
        if (!_forkActive) {
            vm.skip(true);
            return;
        }

        bytes32 disputeId = _openedAtCeiling();
        bytes32 txId = _txIdOf(disputeId);

        vm.startPrank(keeper);
        IERC20(USDC).approve(address(bondEscalation), UMA_BOND);
        bondEscalation.escalateToUMA(disputeId, "QmEvidenceCID", "QmReasoningCID");
        vm.stopPrank();

        bytes32 assertionId = bondEscalation.disputeToAssertion(disputeId);
        uint256 keeperBefore = IERC20(USDC).balanceOf(keeper);
        uint256 oov3Before = IERC20(USDC).balanceOf(UMA_OOV3);

        // Warp past the REAL liveness window (2h) so an UNDISPUTED assertion can settle TRUE.
        vm.warp(block.timestamp + uint256(UMA_LIVENESS) + 1);

        // settleUMAAssertion routes through the real OOV3.settleAssertion, which fires the resolved
        // callback back into BondEscalation with msg.sender == OOV3 (the guard's happy path).
        vm.prank(keeper);
        bondEscalation.settleUMAAssertion(disputeId);

        // Local resolution: ruling 0 (provider delivered = asserted truthfully), dispute resolved.
        assertTrue(_resolvedOf(disputeId), "resolved callback must mark the dispute resolved");
        assertEq(_rulingOf(disputeId), 0, "undisputed TRUE assertion -> ruling 0 (provider delivered)");

        // The real OOV3 returns the FULL $500 bond on a truthful, undisputed assertion (no burn — burn
        // applies only to DISPUTED assertions). The bond goes to the asserter (keeper); we measure the
        // OOV3 side precisely (its balance MUST drop by exactly $500).
        assertEq(IERC20(USDC).balanceOf(UMA_OOV3), oov3Before - UMA_BOND, "OOV3 must release exactly the $500 bond");

        // Keeper is here BOTH the asserter (gets the $500 UMA bond back) AND the ruling-0 winner-of-record
        // + settler (gets the Tier-1 pool + F-6 settle-bounty). So keeper's gain is AT LEAST the $500 UMA
        // bond; the exact Tier-1 distribution split is the P1-7 MOCK suite's job, not this fork test's.
        assertGe(
            IERC20(USDC).balanceOf(keeper),
            keeperBefore + UMA_BOND,
            "asserter must receive at least the $500 bond back on a truthful undisputed assertion"
        );

        // Assertion is now settled TRUE on the live oracle.
        IOOV3Extended.Assertion memory a = IOOV3Extended(UMA_OOV3).getAssertion(assertionId);
        assertTrue(a.settled, "assertion must be settled on the oracle");
        assertTrue(a.settlementResolution, "undisputed assertion must resolve TRUE");

        // Kernel-side escrow leg moved to a terminal state (SETTLED for a provider-win ruling 0).
        assertEq(
            uint8(kernel.getTransaction(txId).state),
            uint8(IACTPKernel.State.SETTLED),
            "ruling 0 (provider wins) must drive the kernel tx to SETTLED"
        );
    }

    // =====================================================================
    // §8.5 DISPUTED callback against the REAL OOV3:
    //   a real counterparty (funded via deal) calls OOV3.disputeAssertion → the real OOV3 fires
    //   assertionDisputedCallback(msg.sender==OOV3) into BondEscalation → emits UMADisputeEscalated,
    //   tier stays 2, dispute NOT yet resolved (now with the DVM). This exercises the genuine
    //   disputed-callback path + its msg.sender==OOV3 guard end-to-end against the live oracle.
    //   POST-DVM resolution is asynchronous (UMA DVM vote, days) and is NOT driveable in a fork; the
    //   P1-7 MOCK suite (UMAIntegration.t / BondEscalation*.t via MockOOV3.mockResolve) is AUTHORITATIVE
    //   for the post-dispute resolved-callback distribution math. Here we additionally prove the §8.6
    //   30-day forceResolveStale fallback still recovers a DVM-stuck dispute.
    // =====================================================================
    function test_Fork_DisputedCallback_RealOracle_AndStaleFallback() external {
        if (!_forkActive) {
            vm.skip(true);
            return;
        }

        bytes32 disputeId = _openedAtCeiling();
        bytes32 txId = _txIdOf(disputeId);

        vm.startPrank(keeper);
        IERC20(USDC).approve(address(bondEscalation), UMA_BOND);
        bondEscalation.escalateToUMA(disputeId, "QmEvidenceCID", "QmReasoningCID");
        vm.stopPrank();

        bytes32 assertionId = bondEscalation.disputeToAssertion(disputeId);

        // (1) msg.sender==OOV3 guard: a stranger CANNOT drive the disputed callback directly.
        vm.prank(rando);
        vm.expectRevert("Only UMA");
        bondEscalation.assertionDisputedCallback(assertionId);

        // (2) A real counterparty disputes WITHIN liveness. The disputer must post a matching bond to
        //     the real OOV3 (which pulls it via transferFrom). This fires the genuine disputed callback.
        vm.startPrank(disputer);
        IERC20(USDC).approve(UMA_OOV3, UMA_BOND);
        vm.expectEmit(true, true, false, false, address(bondEscalation));
        emit UMADisputeEscalated(disputeId, assertionId);
        IOptimisticOracleV3(UMA_OOV3).disputeAssertion(assertionId, disputer);
        vm.stopPrank();

        // The disputed callback did NOT resolve locally — it is now with the DVM; tier stays 2.
        assertFalse(_resolvedOf(disputeId), "disputed callback must NOT resolve (DVM pending)");
        assertEq(_tierOf(disputeId), 2, "dispute must remain Tier 2 after a real dispute");

        // The live oracle records the disputer on the assertion.
        IOOV3Extended.Assertion memory a = IOOV3Extended(UMA_OOV3).getAssertion(assertionId);
        assertEq(a.disputer, disputer, "OOV3 must record the disputer");

        // (3) §8.6 Limitation: the DVM may exceed the window. After 30 days, forceResolveStale recovers
        //     the dispute to a 50/50 split + CANCELS the kernel tx — recovery works even post-dispute.
        //     (NOTE: the genuine post-DVM resolved-callback distribution is covered by the P1-7 mock
        //      suite, which is authoritative for that branch.)
        vm.warp(_disputedAtOf(disputeId) + 30 days + 1);
        bondEscalation.forceResolveStale(disputeId);

        assertTrue(_resolvedOf(disputeId), "stale fallback must resolve a DVM-stuck dispute");
        assertEq(_splitBpsOf(disputeId), 5000, "stale -> 50/50 split");
        assertEq(
            uint8(kernel.getTransaction(txId).state),
            uint8(IACTPKernel.State.CANCELLED),
            "stale -> kernel tx CANCELLED"
        );
    }

    // =====================================================================
    // Helpers — drive a fresh tx to DISPUTED, open it, and walk the Tier-1
    // bond curve to the $500 ceiling so escalateToUMA's preconditions are met.
    // (Mirrors DisputeTestBase / UMAIntegration.t against REAL USDC on the fork.)
    // =====================================================================
    function _openedAtCeiling() internal returns (bytes32 disputeId) {
        bytes32 txId = _createDisputed();
        disputeId = bondEscalation.openDispute(txId);
        _escalateBondToCeiling(disputeId);
        require(_currentBondOf(disputeId) == MAX_BOND, "precondition: Tier-1 at $500 ceiling");
        require(_lastProposerOf(disputeId) == keeper, "precondition: keeper is last ruling-0 proposer");
    }

    function _createDisputed() internal returns (bytes32 txId) {
        vm.prank(requester);
        txId = kernel.createTransaction(
            provider, requester, ESCROW_AMOUNT, block.timestamp + 30 days, 2 days, keccak256(abi.encode("svc", _salt())), bytes32(0), 0, 0
        );

        vm.startPrank(requester);
        IERC20(USDC).approve(address(escrow), ESCROW_AMOUNT);
        kernel.linkEscrow(txId, address(escrow), txId);
        vm.stopPrank();

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(10 days, keccak256("result")));

        uint256 bond = (ESCROW_AMOUNT * kernel.disputeBondBps()) / kernel.MAX_BPS();
        if (bond < kernel.MIN_DISPUTE_BOND()) bond = kernel.MIN_DISPUTE_BOND();
        vm.startPrank(requester);
        IERC20(USDC).approve(address(escrow), bond);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");
        vm.stopPrank();
    }

    /// @dev Unique-per-call salt so multiple disputes in one test run never collide on txId.
    uint256 internal _saltNonce;

    function _salt() internal returns (uint256) {
        return _saltNonce++;
    }

    /// @dev Propose ruling 0, then 6 alternating challenges → bond climbs $20→$40→…→$500 (capped),
    ///      landing at the ceiling with keeper as the last ruling-0 proposer (the escalator direction).
    function _escalateBondToCeiling(bytes32 disputeId) internal {
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

    // =====================================================================
    // AssertionMade log decoder — recovers the non-indexed `claim` bytes from
    // the REAL OOV3 event, keyed by the indexed assertionId (topic[1]).
    // Event: AssertionMade(bytes32 indexed assertionId, bytes32 domainId, bytes claim,
    //        address indexed asserter, address callbackRecipient, address escalationManager,
    //        address caller, uint64 expirationTime, IERC20 currency, uint256 bond,
    //        bytes32 indexed identifier)
    // Non-indexed data = abi.encode(domainId, claim, callbackRecipient, escalationManager,
    //                               caller, expirationTime, currency, bond).
    // =====================================================================
    function _claimFromLogs(bytes32 assertionId) internal returns (bytes memory) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256(
            "AssertionMade(bytes32,bytes32,bytes,address,address,address,address,uint64,address,uint256,bytes32)"
        );
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != UMA_OOV3) continue;
            if (logs[i].topics.length < 2) continue;
            if (logs[i].topics[0] != sig) continue;
            if (logs[i].topics[1] != assertionId) continue;
            // Decode the non-indexed tuple; `claim` is the 2nd member.
            (, bytes memory claim,,,,,,) =
                abi.decode(logs[i].data, (bytes32, bytes, address, address, address, uint64, address, uint256));
            return claim;
        }
        return bytes("");
    }

    // =====================================================================
    // Typed accessors over the `disputes` public getter (13-tuple — order per
    // BondEscalation.DisputeState; mirrors UMAIntegration.t.sol).
    // (transactionId, currentRuling, splitBps, currentBond, accumulatedBonds,
    //  livenessEnd, disputedAt, lastProposer, tier, resolved, winnerPaid,
    //  originalPool, escrowAmount)
    // =====================================================================
    function _txIdOf(bytes32 d) internal view returns (bytes32 t) {
        (t,,,,,,,,,,,,) = bondEscalation.disputes(d);
    }

    function _rulingOf(bytes32 d) internal view returns (uint8 r) {
        (, r,,,,,,,,,,,) = bondEscalation.disputes(d);
    }

    function _splitBpsOf(bytes32 d) internal view returns (uint16 s) {
        (,, s,,,,,,,,,,) = bondEscalation.disputes(d);
    }

    function _currentBondOf(bytes32 d) internal view returns (uint256 b) {
        (,,, b,,,,,,,,,) = bondEscalation.disputes(d);
    }

    function _disputedAtOf(bytes32 d) internal view returns (uint64 da) {
        (,,,,,, da,,,,,,) = bondEscalation.disputes(d);
    }

    function _lastProposerOf(bytes32 d) internal view returns (address p) {
        (,,,,,,, p,,,,,) = bondEscalation.disputes(d);
    }

    function _tierOf(bytes32 d) internal view returns (uint8 tier) {
        (,,,,,,,, tier,,,,) = bondEscalation.disputes(d);
    }

    function _resolvedOf(bytes32 d) internal view returns (bool r) {
        (,,,,,,,,, r,,,) = bondEscalation.disputes(d);
    }

    // =====================================================================
    // bytes substring search (for the ipfs:// + CID claim assertion).
    // =====================================================================
    function _contains(bytes memory haystack, bytes memory needle) internal pure returns (bool) {
        if (needle.length == 0) return true;
        if (needle.length > haystack.length) return false;
        for (uint256 i = 0; i <= haystack.length - needle.length; i++) {
            bool matched = true;
            for (uint256 j = 0; j < needle.length; j++) {
                if (haystack[i + j] != needle[j]) {
                    matched = false;
                    break;
                }
            }
            if (matched) return true;
        }
        return false;
    }
}
