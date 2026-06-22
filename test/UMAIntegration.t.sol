// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/DisputeTestBase.sol";
import {AIRuling} from "../src/interfaces/DisputeTypes.sol";
import {IACTPKernel} from "../src/interfaces/IACTPKernel.sol";
import {IOptimisticOracleV3} from "../src/interfaces/IOptimisticOracleV3.sol";
import {MockOOV3} from "./mocks/MockOOV3.sol";

/// @notice OOV3 spy that records the `identifier` argument passed to `assertTruth` and reports a
///         DISTINCT, non-default `defaultIdentifier()`. Used by `test_EscalateToUMA_UsesDefaultIdentifier`
///         to prove BondEscalation reads the identifier at runtime via `defaultIdentifier()` (§8.4 /
///         INV-20) rather than hardcoding `"ASSERT_TRUTH"` or any custom constant. If the contract ever
///         regressed to a hardcoded identifier, the recorded value would NOT equal this spy's default and
///         the assertion would fail. The base `MockOOV3.assertTruth` discards the identifier arg (and is
///         not `virtual`), so a purpose-built standalone spy is required — inheritance cannot capture it.
contract IdentifierSpyOOV3 is IOptimisticOracleV3 {
    /// @dev Intentionally NOT "ASSERT_TRUTH": a distinct sentinel so a hardcoded identifier would mismatch.
    bytes32 public constant SPY_IDENTIFIER = bytes32("SPY_DEFAULT_ID");
    uint256 public constant MIN_BOND = 500_000_000;

    bytes32 public capturedIdentifier;
    bytes public capturedClaim;
    bool public assertTruthCalled;
    uint256 internal _nonce;

    function assertTruth(
        bytes memory claim,
        address asserter,
        address, /* callbackRecipient */
        address, /* escalationManager */
        uint64, /* liveness */
        IERC20 currency,
        uint256 bond,
        bytes32 identifier,
        bytes32 /* domainId */
    ) external override returns (bytes32 assertionId) {
        // Real bond custody so the escalator's USDC actually moves (mirrors MockOOV3).
        require(currency.transferFrom(msg.sender, address(this), bond), "SpyOOV3: bond transfer failed");
        capturedIdentifier = identifier;
        capturedClaim = claim;
        assertTruthCalled = true;
        assertionId = keccak256(abi.encode(claim, asserter, _nonce++));
    }

    function defaultIdentifier() external pure override returns (bytes32) {
        return SPY_IDENTIFIER;
    }

    function getMinimumBond(address) external pure override returns (uint256) {
        return MIN_BOND;
    }

    // Unused surface — minimal stubs to satisfy the interface.
    function settleAssertion(bytes32) external override {}
    function disputeAssertion(bytes32, address) external override {}
    function settleAndGetAssertionResult(bytes32) external override returns (bool) {
        return false;
    }
    function getAssertionResult(bytes32) external view override returns (bool) {
        return false;
    }
    function defaultCurrency() external view override returns (IERC20) {
        return IERC20(address(0));
    }
    function burnedBondPercentage() external pure override returns (uint256) {
        return 5e17;
    }
}

/// @title UMAIntegrationTest — AIP-14b §11 "Required Integration Tests" UMA-matrix gap-fill.
/// @notice GAP-FILLING ONLY. The §11 UMA rows already covered by BondEscalation.t.sol and
///         BondEscalationAdversarial.t.sol are NOT re-asserted here; this file fills the rows those
///         suites leave open. Concretely:
///
///           Row (§11)                                    | Status before this file
///           ---------------------------------------------|------------------------------------------
///           DoesNotAddToAccumulatedBonds                 | BondEscalation.t (Ceiling...NotInAccumulated)
///           RequiresCeiling                              | BondEscalation.t (RevertsIfBelowCeiling)
///           RequiresEvidenceCID                          | BondEscalation.t (RevertsWithoutCID)
///           WinnerByDirection                            | BondEscalation.t (ResolvedTrue_ProviderWins)
///           NoWinnerFallsBackToSplit                     | BondEscalation.t (ResolvedFalse_...SplitFallback)
///           CallbackGraceAfterStale                      | BondEscalation.t (GracefulNoOpAfterStale)
///           ---------------------------------------------|------------------------------------------
///           RequiresLiveness (expired → revert)          | *** GAP — filled here ***
///           UsesDefaultIdentifier                        | *** GAP — filled here ***
///           ClaimEmbedsEvidence (ipfs:// + CID)          | *** GAP — filled here ***
///           CallbackGraceAfterSync (+ UMACallbackIgnored)| *** GAP — filled here ***
///           DisputedCallback_OnlyUMA + event arg         | *** GAP — filled here ***
///           forceResolveStale after disputed callback    | *** GAP — filled here ***
///
///         Each test that needs to reach the $500 ceiling drives the documented bond curve
///         20→40→80→160→320→500(capped) via openDispute → proposeDirectly → 6× challenge, then
///         escalateToUMA — matching the helper in BondEscalation.t.sol so the on-chain custody and
///         accounting reflect reality.
contract UMAIntegrationTest is DisputeTestBase {
    uint256 internal constant ESCROW = TRANSACTION_AMOUNT; // 1e9
    uint256 internal constant INITIAL_BOND = 20_000_000; // (1e9 * 200)/10000 = $20
    uint64 internal constant LIVENESS = 4 hours; // escrow in [500M, 5B)
    uint256 internal constant MAX_BOND = 500_000_000; // $500 ceiling
    uint256 internal constant UMA_BOND = 500_000_000; // $500 assertion bond

    // Mirror events for vm.expectEmit.
    event UMACallbackIgnored(bytes32 indexed disputeId, bytes32 indexed assertionId, string reason);
    event UMADisputeEscalated(bytes32 indexed disputeId, bytes32 indexed assertionId);

    function setUp() external {
        _setUpStack();
    }

    // =====================================================================
    // §8.4 escalateToUMA — preconditions not covered elsewhere
    // =====================================================================

    /// @notice INV-11 / §8.4: escalateToUMA requires the liveness window to be ACTIVE. At the ceiling
    ///         the parties may keep challenging (each challenge resets liveness) OR escalate — but once
    ///         liveness LAPSES the only path is finalize(). Reaching the ceiling and then warping past
    ///         livenessEnd MUST make escalateToUMA revert "Liveness expired - use finalize()".
    ///         (BondEscalation.t covers the ceiling/CID/accumulated rows but never the expired-liveness
    ///          branch — this is the gap.)
    function test_EscalateToUMA_RequiresLiveness() external {
        bytes32 disputeId = _opened();
        _escalateBondToCeiling(disputeId);
        assertEq(_currentBondOf(disputeId), MAX_BOND, "precondition: at ceiling");

        // Let the (reset-on-last-challenge) liveness window lapse.
        vm.warp(_livenessEndOf(disputeId) + 1);

        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), UMA_BOND);
        vm.expectRevert("Liveness expired - use finalize()");
        bondEscalation.escalateToUMA(disputeId, "QmEvidenceCID");
        vm.stopPrank();
    }

    /// @notice §8.4 / INV-20: the identifier handed to OOV3.assertTruth MUST come from the oracle's
    ///         `defaultIdentifier()` at runtime, NOT a hardcoded constant (a custom identifier is not in
    ///         UMA's IdentifierWhitelist and would revert on mainnet). We deploy a fresh BondEscalation
    ///         wired to an IdentifierSpyOOV3 that reports a DISTINCT default ("SPY_DEFAULT_ID") and records
    ///         whatever identifier it was passed. The recorded identifier must equal the spy's default —
    ///         proving the value was read from defaultIdentifier(), not baked in.
    function test_EscalateToUMA_UsesDefaultIdentifier() external {
        IdentifierSpyOOV3 spy = new IdentifierSpyOOV3();
        BondEscalation be = _deployBondEscalationWithOracle(address(spy));

        bytes32 disputeId = _openedFor(be);
        _escalateBondToCeilingFor(be, disputeId);

        vm.startPrank(keeper);
        usdc.approve(address(be), UMA_BOND);
        be.escalateToUMA(disputeId, "QmEvidenceCID");
        vm.stopPrank();

        assertTrue(spy.assertTruthCalled(), "assertTruth was not invoked");
        assertEq(
            spy.capturedIdentifier(),
            spy.SPY_IDENTIFIER(),
            "identifier must be read from defaultIdentifier(), not hardcoded"
        );
        // Sanity: it is NOT the canonical Base-mainnet default — i.e. the value tracked the spy.
        assertTrue(spy.capturedIdentifier() != bytes32("ASSERT_TRUTH"), "identifier appears hardcoded");
    }

    /// @notice §8.4 / INV-20: the assertion claim bytes MUST embed the IPFS evidence bundle —
    ///         literally "ipfs://" + the supplied CID — so DVM voters can verify what they rule on.
    ///         We escalate against the recording MockOOV3, read back the stored claim, and assert the
    ///         claim contains both the "ipfs://" scheme and the exact CID substring.
    function test_EscalateToUMA_ClaimEmbedsEvidence() external {
        bytes32 disputeId = _opened();
        _escalateBondToCeiling(disputeId);

        string memory cid = "QmEvidenceBundleCID12345";
        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), UMA_BOND);
        bondEscalation.escalateToUMA(disputeId, cid);
        vm.stopPrank();

        bytes32 assertionId = bondEscalation.disputeToAssertion(disputeId);
        (bytes memory claim,,,,,,,,) = oov3.assertions(assertionId);

        assertTrue(_contains(claim, bytes("ipfs://")), "claim missing ipfs:// scheme");
        assertTrue(_contains(claim, bytes(cid)), "claim missing evidence CID");
        // The CID must be ipfs-scheme-prefixed (i.e. "ipfs://<cid>" appears verbatim).
        assertTrue(_contains(claim, bytes(string.concat("ipfs://", cid))), "CID not ipfs-prefixed in claim");
    }

    // =====================================================================
    // §8.5 UMA callbacks — grace + disputed paths not covered elsewhere
    // =====================================================================

    /// @notice INV-19 / §8.1: if the dispute was resolved via syncExternalResolution() (admin moved the
    ///         kernel out of DISPUTED, then anyone synced the local state) BEFORE UMA settles, the late
    ///         resolved-callback MUST be a graceful no-op: it emits UMACallbackIgnored and pays nothing.
    ///         BondEscalation.t covers the STALE pre-resolution variant; the SYNC variant (distinct entry
    ///         point exercising the `if (d.resolved)` early-return, not the kernel re-read) is the gap.
    function test_UMA_CallbackGraceAfterSync() external {
        bytes32 disputeId = _opened();
        bytes32 txId = _txIdOf(disputeId);
        _escalateBondToCeiling(disputeId);

        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), UMA_BOND);
        bondEscalation.escalateToUMA(disputeId, "QmEvidenceCID");
        vm.stopPrank();

        bytes32 assertionId = bondEscalation.disputeToAssertion(disputeId);

        // Admin moves the kernel DISPUTED -> CANCELLED via the INV-6 override (no BondEscalation touch).
        uint256 remaining = _remaining(txId);
        bytes memory proof = abi.encode(remaining / 2, remaining - remaining / 2);
        vm.prank(admin);
        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, proof);

        // Sync the local resolution explicitly (the entry point under test).
        bondEscalation.syncExternalResolution(disputeId);
        assertTrue(_resolvedOf(disputeId), "precondition: synced/resolved");

        // The late UMA callback hits the `if (d.resolved)` branch → emits UMACallbackIgnored, no payout.
        uint256 contractBalBefore = usdc.balanceOf(address(bondEscalation));
        vm.expectEmit(true, true, false, true, address(bondEscalation));
        emit UMACallbackIgnored(disputeId, assertionId, "Already resolved locally");
        oov3.mockResolve(assertionId, true);

        assertEq(usdc.balanceOf(address(bondEscalation)), contractBalBefore, "sync-grace callback paid out");
        // No double-resolution side effects: still resolved, still a sync-snapshot split, no winner paid.
        assertTrue(_resolvedOf(disputeId));
        assertFalse(_winnerPaidOf(disputeId), "no winner should be paid on grace no-op");
        assertEq(_splitBpsOf(disputeId), 5000, "sync snapshot is 50/50");
    }

    /// @notice §8.5 / INV-19 disputed-callback row, three properties in one flow:
    ///         (1) onlyUMA — a non-OOV3 caller is rejected ("Only UMA");
    ///         (2) UMADisputeEscalated fires with the CORRECT (disputeId, assertionId) — proving the
    ///             reverse mapping lookup is wired (BondEscalation.t's disputed test asserts no state
    ///             change but never the event args);
    ///         (3) the dispute is NOT resolved by the disputed callback (DVM result still pending), and the
    ///             30-day forceResolveStale() fallback STILL works afterwards (Limitation §8.6: stale
    ///             applies regardless of UMA state) — the post-disputed-callback recovery path is the gap.
    function test_DisputedCallback_OnlyUMA_EventArgs_AndStaleStillWorks() external {
        bytes32 disputeId = _opened();
        bytes32 txId = _txIdOf(disputeId);
        _escalateBondToCeiling(disputeId);

        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), UMA_BOND);
        bondEscalation.escalateToUMA(disputeId, "QmEvidenceCID");
        vm.stopPrank();

        bytes32 assertionId = bondEscalation.disputeToAssertion(disputeId);

        // (1) onlyUMA: a stranger cannot drive the disputed callback.
        vm.prank(rando);
        vm.expectRevert("Only UMA");
        bondEscalation.assertionDisputedCallback(assertionId);

        // (2) UMA-driven disputed callback emits UMADisputeEscalated with the exact (disputeId, assertionId).
        vm.expectEmit(true, true, false, false, address(bondEscalation));
        emit UMADisputeEscalated(disputeId, assertionId);
        oov3.mockDispute(assertionId);

        // Dispute went to the DVM but did NOT resolve locally; tier stays 2.
        assertFalse(_resolvedOf(disputeId), "disputed callback must not resolve");
        assertEq(_tierOf(disputeId), 2, "should remain tier 2 after dispute");

        // (3) §8.6: the 30-day stale fallback still resolves the dispute even after a disputed callback,
        //     because the DVM may exceed the window. After warping past disputedAt + 30 days,
        //     forceResolveStale() resolves locally to a 50/50 split and CANCELS the kernel tx.
        vm.warp(_disputedAtOf(disputeId) + 30 days + 1);
        bondEscalation.forceResolveStale(disputeId);

        assertTrue(_resolvedOf(disputeId), "stale fallback must resolve post-dispute");
        assertEq(_splitBpsOf(disputeId), 5000, "stale -> 50/50 split");
        assertEq(
            uint8(kernel.getTransaction(txId).state),
            uint8(IACTPKernel.State.CANCELLED),
            "stale -> kernel CANCELLED"
        );

        // Tier-1 bonds remain reclaimable via the split path (recovery still works post-dispute+stale).
        uint256 keeperBefore = usdc.balanceOf(keeper);
        vm.prank(keeper);
        bondEscalation.claimEscalationRefund(disputeId);
        assertGt(usdc.balanceOf(keeper), keeperBefore, "tier-1 bond must be reclaimable");
    }

    // =====================================================================
    // Helpers — typed accessors over the `disputes` public getter (13-tuple).
    // =====================================================================
    function _txIdOf(bytes32 disputeId) internal view returns (bytes32 t) {
        (t,,,,,,,,,,,,) = bondEscalation.disputes(disputeId);
    }

    function _tierOf(bytes32 disputeId) internal view returns (uint8 tier) {
        (,,,,,,,, tier,,,,) = bondEscalation.disputes(disputeId);
    }

    function _currentBondOf(bytes32 disputeId) internal view returns (uint256 b) {
        (,,, b,,,,,,,,,) = bondEscalation.disputes(disputeId);
    }

    function _splitBpsOf(bytes32 disputeId) internal view returns (uint16 s) {
        (,, s,,,,,,,,,,) = bondEscalation.disputes(disputeId);
    }

    function _lastProposerOf(bytes32 disputeId) internal view returns (address p) {
        (,,,,,,, p,,,,,) = bondEscalation.disputes(disputeId);
    }

    function _resolvedOf(bytes32 disputeId) internal view returns (bool r) {
        (,,,,,,,,, r,,,) = bondEscalation.disputes(disputeId);
    }

    function _winnerPaidOf(bytes32 disputeId) internal view returns (bool w) {
        (,,,,,,,,,, w,,) = bondEscalation.disputes(disputeId);
    }

    function _livenessEndOf(bytes32 disputeId) internal view returns (uint64 l) {
        (,,,,, l,,,,,,,) = bondEscalation.disputes(disputeId);
    }

    function _disputedAtOf(bytes32 disputeId) internal view returns (uint64 d) {
        (,,,,,, d,,,,,,) = bondEscalation.disputes(disputeId);
    }

    // =====================================================================
    // Lifecycle helpers (default injected MockOOV3 path).
    // =====================================================================
    function _opened() internal returns (bytes32 disputeId) {
        bytes32 txId = _createDisputed();
        disputeId = bondEscalation.openDispute(txId);
    }

    function _propose(bytes32 disputeId, address who, uint8 ruling, uint16 splitBps) internal {
        vm.startPrank(who);
        usdc.approve(address(bondEscalation), INITIAL_BOND);
        bondEscalation.proposeDirectly(disputeId, ruling, splitBps);
        vm.stopPrank();
    }

    /// @dev Propose (ruling 0) then challenge 6× alternating 0/1 so currentBond climbs
    ///      20→40→80→160→320→500(capped)→500 and lands at the $500 ceiling with keeper as the last
    ///      proposer for ruling 0 (the escalator direction). Mirrors BondEscalation.t's ceiling helper.
    function _escalateBondToCeiling(bytes32 disputeId) internal {
        _propose(disputeId, keeper, 0, 0);
        uint256 bond = INITIAL_BOND;
        uint8 ruling = 0;
        for (uint256 i = 0; i < 6; i++) {
            ruling = ruling == 0 ? 1 : 0;
            bond = bond * 2;
            if (bond > MAX_BOND) bond = MAX_BOND;
            address who = (i % 2 == 0) ? rando : keeper;
            vm.startPrank(who);
            usdc.approve(address(bondEscalation), bond);
            bondEscalation.challenge(disputeId, ruling, 0);
            vm.stopPrank();
        }
        require(_currentBondOf(disputeId) == MAX_BOND, "ceiling not reached");
        require(_lastProposerOf(disputeId) == keeper, "keeper should be last proposer (ruling 0)");
    }

    // =====================================================================
    // Lifecycle helpers parameterized by a specific BondEscalation instance
    // (used by the UsesDefaultIdentifier test, which wires a custom oracle).
    // =====================================================================

    /// @dev Deploy a fresh BondEscalation wired to `oracle`, wiring a dedicated CompositeMediator and the
    ///      same kernel resolver-auth + 2-day timelock the base harness uses (so resolutions could
    ///      transition kernel state). Reuses the harness evaluators and admin.
    function _deployBondEscalationWithOracle(address oracle) internal returns (BondEscalation be) {
        CompositeMediator mediator = new CompositeMediator(IACTPKernel(address(kernel)));
        address[2] memory fixedEvaluators = [fixed0, fixed1];
        address[] memory rotatingPool = new address[](1);
        rotatingPool[0] = rotating0;
        be = new BondEscalation(
            IACTPKernel(address(kernel)),
            IERC20(address(usdc)),
            ICompositeMediator(address(mediator)),
            admin,
            fixedEvaluators,
            rotatingPool,
            oracle
        );
        mediator.initialize(address(be));
        kernel.approveMediator(address(mediator), true);
        // Pass the new mediator's 2-day timelock (the base setUp already warped 2 days for its own mediator).
        vm.warp(block.timestamp + 2 days + 1);
    }

    function _openedFor(BondEscalation be) internal returns (bytes32 disputeId) {
        bytes32 txId = _createDisputed();
        disputeId = be.openDispute(txId);
    }

    function _proposeFor(BondEscalation be, bytes32 disputeId, address who, uint8 ruling, uint16 splitBps) internal {
        vm.startPrank(who);
        usdc.approve(address(be), INITIAL_BOND);
        be.proposeDirectly(disputeId, ruling, splitBps);
        vm.stopPrank();
    }

    function _currentBondOfFor(BondEscalation be, bytes32 disputeId) internal view returns (uint256 b) {
        (,,, b,,,,,,,,,) = be.disputes(disputeId);
    }

    function _escalateBondToCeilingFor(BondEscalation be, bytes32 disputeId) internal {
        _proposeFor(be, disputeId, keeper, 0, 0);
        uint256 bond = INITIAL_BOND;
        uint8 ruling = 0;
        for (uint256 i = 0; i < 6; i++) {
            ruling = ruling == 0 ? 1 : 0;
            bond = bond * 2;
            if (bond > MAX_BOND) bond = MAX_BOND;
            address who = (i % 2 == 0) ? rando : keeper;
            vm.startPrank(who);
            usdc.approve(address(be), bond);
            be.challenge(disputeId, ruling, 0);
            vm.stopPrank();
        }
        require(_currentBondOfFor(be, disputeId) == MAX_BOND, "ceiling not reached");
    }

    // =====================================================================
    // bytes substring search (for ClaimEmbedsEvidence).
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
