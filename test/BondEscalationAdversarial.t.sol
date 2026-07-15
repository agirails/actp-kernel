// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/DisputeTestBase.sol";
import {AIRuling} from "../src/interfaces/DisputeTypes.sol";
import {IACTPKernel} from "../src/interfaces/IACTPKernel.sol";

/// @title BondEscalationAdversarialTest — regression coverage for the adversarial-review findings.
/// @notice Locks in the fixes for:
///   - MAJOR-1: evaluator-set overlap collapsing the 2-of-3 signature threshold to 1-of-1.
///   - MAJOR-2: assertionResolvedCallback reverting (instead of no-op) when the kernel was
///              admin-resolved out of DISPUTED via the INV-6 override while a UMA assertion is live.
///   - MINOR (sig DoS): a single malformed / high-s-malleable signature must be silently ignored
///              (no revert) per AIP-14b §4.7 step 6, so 2 valid + 1 garbage still passes.
///   - MINOR (callback guard): assertionDisputedCallback rejects an unknown assertionId.
///   - INV-9 scope: claimEscalationRefund stays open even under a KERNEL pause.
contract BondEscalationAdversarialTest is DisputeTestBase {
    uint256 internal constant ESCROW = TRANSACTION_AMOUNT; // 1e9
    uint256 internal constant INITIAL_BOND = 20_000_000; // (1e9 * 200) / 10000 = $20
    uint64 internal constant LIVENESS = 4 hours;
    uint256 internal constant MAX_BOND = 500_000_000;

    function setUp() external {
        _setUpStack();
    }

    // =====================================================================
    // MAJOR-1: evaluator-set overlap signature-threshold bypass
    // =====================================================================

    /// @notice Write-time disjointness: the constructor MUST reject a rotating member that overlaps a
    ///         fixed slot (the overlap config is exactly what enabled the 1-of-1 bypass).
    function test_Major1_Constructor_RejectsRotatingOverlapsFixed() external {
        address[2] memory fixedEvaluators = [fixed0, fixed1];
        address[] memory rotatingPool = new address[](1);
        rotatingPool[0] = fixed0; // OVERLAP: rotating == fixed slot 0

        vm.expectRevert("Rotating overlaps fixed");
        new BondEscalation(
            IACTPKernel(address(kernel)),
            IERC20(address(usdc)),
            ICompositeMediator(address(compositeMediator)),
            admin,
            fixedEvaluators,
            rotatingPool,
            address(oov3)
        );
    }

    /// @notice Write-time disjointness: the two fixed slots must themselves differ.
    function test_Major1_Constructor_RejectsFixedSlotsEqual() external {
        address[2] memory fixedEvaluators = [fixed0, fixed0]; // duplicate fixed slots
        address[] memory rotatingPool = new address[](1);
        rotatingPool[0] = rotating0;

        vm.expectRevert("Fixed slots must differ");
        new BondEscalation(
            IACTPKernel(address(kernel)),
            IERC20(address(usdc)),
            ICompositeMediator(address(compositeMediator)),
            admin,
            fixedEvaluators,
            rotatingPool,
            address(oov3)
        );
    }

    /// @notice Governance write path: proposing a rotating addition that overlaps a fixed slot reverts.
    function test_Major1_ProposeRotatingOverlap_Reverts() external {
        vm.prank(admin);
        vm.expectRevert("Rotating overlaps fixed");
        bondEscalation.proposeRotatingPoolAddition(fixed0);
    }

    /// @notice Governance write path: executing a fixed-slot update that collides with a current
    ///         rotating member reverts (would otherwise re-introduce overlap).
    function test_Major1_ExecuteFixedUpdate_OverlapRotating_Reverts() external {
        // Propose fixed slot 1 -> rotating0 (which is already in the rotating pool).
        vm.prank(admin);
        bondEscalation.proposeFixedEvaluatorUpdate(1, rotating0);

        vm.warp(block.timestamp + 2 days + 1);
        vm.expectRevert("Fixed overlaps rotating");
        bondEscalation.executeFixedEvaluatorUpdate(1);
    }

    /// @notice Governance write path: a fixed-slot update equal to the OTHER fixed slot reverts.
    function test_Major1_ExecuteFixedUpdate_EqualOtherSlot_Reverts() external {
        vm.prank(admin);
        bondEscalation.proposeFixedEvaluatorUpdate(1, fixed0); // slot 1 -> fixed0 (== slot 0)

        vm.warp(block.timestamp + 2 days + 1);
        vm.expectRevert("Fixed slots must differ");
        bondEscalation.executeFixedEvaluatorUpdate(1);
    }

    /// @notice Verification-time defense (the load-bearing guard): even if an overlap configuration
    ///         somehow existed, a SINGLE keypair occupying both a fixed slot AND the selected rotating
    ///         slot cannot reach validCount==2. We prove the verification path directly by deploying a
    ///         BondEscalation whose rotating pool is a SUPERSET that includes a fixed-slot address via a
    ///         malicious harness, then asserting one keypair's two signatures still fail.
    ///
    ///         Because the constructor now blocks the obvious overlap, we exercise the in-loop guard by
    ///         deploying with a disjoint config and confirming the canonical attack (one fixed key,
    ///         signed twice) reverts "Insufficient valid signatures" — the same property the in-loop
    ///         `thirdCandidate==address(0)` and per-slot `seen` checks guarantee on any config.
    function test_Major1_SingleKeypairCannotReachTwoOfThree() external {
        bytes32 disputeId = _opened();
        AIRuling memory r = _ruling(disputeId, 0, 0);

        // One keypair (fixed0) signs twice. The per-slot `seen` guard + overlap-zeroing means this can
        // never satisfy 2/3 regardless of whether fixed0 also happens to be the rotating pick.
        bytes[] memory sigs = new bytes[](3);
        sigs[0] = _signRuling(r, fixed0Pk);
        sigs[1] = _signRuling(r, fixed0Pk);
        sigs[2] = _signRuling(r, fixed0Pk);

        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), INITIAL_BOND);
        vm.expectRevert("Insufficient valid signatures");
        bondEscalation.submitAIRuling(disputeId, r, EVIDENCE_CID, REASONING_CID, sigs);
        vm.stopPrank();
    }

    /// @notice Verification-time guard, exercised on a TRULY OVERLAPPING config (review finding 3): force
    ///         `rotatingPool[0] == fixed0` directly in storage (the constructor + governance now forbid it,
    ///         so a storage mutation is the only way to reach it). The per-dispute pick is index 0
    ///         (rotatingPool.length == 1), so `thirdEvaluator == fixed0 == fixedEvaluators[0]`. WITHOUT the
    ///         overlap-zeroing, ONE key (fixed0) signing twice would fill seen[0] AND fall through the
    ///         else-if into the rotating slot seen[2] → validCount==2 (the 1-of-1 bypass). The guard zeros
    ///         the rotating candidate on overlap, so the duplicate cannot count → revert.
    function test_Major1_RuntimeOverlapGuard_OneKeyCannotCountTwice() external {
        // rotatingPool is a dynamic array at storage slot 8 → element 0 at keccak256(abi.encode(8)).
        bytes32 elemSlot = keccak256(abi.encode(uint256(8)));
        vm.store(address(bondEscalation), elemSlot, bytes32(uint256(uint160(fixed0))));
        assertEq(bondEscalation.rotatingPool(0), fixed0, "overlap was not forced into storage");

        bytes32 disputeId = _opened();
        AIRuling memory r = _ruling(disputeId, 0, 0);

        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signRuling(r, fixed0Pk);
        sigs[1] = _signRuling(r, fixed0Pk); // same key twice

        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), INITIAL_BOND);
        vm.expectRevert("Insufficient valid signatures");
        bondEscalation.submitAIRuling(disputeId, r, EVIDENCE_CID, REASONING_CID, sigs);
        vm.stopPrank();
    }

    /// @notice Positive control for the overlap guard: even with `rotatingPool[0] == fixed0` forced, TWO
    ///         DISTINCT fixed keys (fixed0 + fixed1) still reach validCount==2 — the guard is surgical
    ///         (it only neutralizes the overlapping rotating slot, never a legitimate distinct-key 2/3).
    function test_Major1_RuntimeOverlapGuard_DistinctKeysStillPass() external {
        bytes32 elemSlot = keccak256(abi.encode(uint256(8)));
        vm.store(address(bondEscalation), elemSlot, bytes32(uint256(uint160(fixed0))));

        bytes32 disputeId = _opened();
        AIRuling memory r = _ruling(disputeId, 0, 0);

        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signRuling(r, fixed0Pk);
        sigs[1] = _signRuling(r, fixed1Pk); // two distinct fixed keys

        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), INITIAL_BOND);
        bondEscalation.submitAIRuling(disputeId, r, EVIDENCE_CID, REASONING_CID, sigs); // must NOT revert
        vm.stopPrank();

        assertEq(bondEscalation.lastProposerForRuling(disputeId, 0), keeper, "valid 2/3 should have landed");
    }

    /// @notice Review finding 1 — the execute-time re-check on rotating additions. The propose-time
    ///         disjointness check is NOT sufficient: queue a rotating add for X (passes — X is not a fixed
    ///         slot yet), then change a fixed slot to X while it sits in the timelock (executeFixedUpdate's
    ///         loop scans only the COMMITTED rotatingPool, so it does not see X in pendingRotatingAdditions),
    ///         then execute-rotating X. Without the execute-time re-check this would commit the overlap;
    ///         with it, execution reverts.
    function test_Major1_ExecuteRotatingAddition_OverlapAfterFixedChange_Reverts() external {
        address x = makeAddr("newEvaluatorX");

        // 1) queue rotating add for X (X is not yet a fixed slot → passes propose-time check).
        vm.prank(admin);
        bondEscalation.proposeRotatingPoolAddition(x);

        // 2) change fixed slot 1 -> X while the rotating add sits in the timelock queue.
        vm.prank(admin);
        bondEscalation.proposeFixedEvaluatorUpdate(1, x);
        vm.warp(block.timestamp + 2 days + 1);
        bondEscalation.executeFixedEvaluatorUpdate(1);
        assertEq(bondEscalation.fixedEvaluators(1), x, "fixed slot 1 should now be X");

        // 3) execute the queued rotating add for X → must revert (execute-time re-check), else X would be
        //    BOTH fixed slot 1 AND a rotating member.
        vm.expectRevert("Rotating overlaps fixed");
        bondEscalation.executeRotatingPoolAddition(0);
    }

    // =====================================================================
    // MINOR: malformed / malleable signature tolerance (§4.7 step 6)
    // =====================================================================

    /// @notice 2 valid fixed sigs + 1 wrong-length garbage sig must STILL pass (validCount==2). Before
    ///         the tryRecover fix, ECDSA.recover reverted ECDSAInvalidSignatureLength → cheap DoS.
    function test_Minor_MalformedThirdSig_StillPasses() external {
        bytes32 disputeId = _opened();
        AIRuling memory r = _ruling(disputeId, 0, 0);

        bytes[] memory sigs = new bytes[](3);
        sigs[0] = _signRuling(r, fixed0Pk);
        sigs[1] = _signRuling(r, fixed1Pk);
        sigs[2] = hex"deadbeef"; // 4 bytes — wrong length, must be skipped not reverted

        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), INITIAL_BOND);
        bondEscalation.submitAIRuling(disputeId, r, EVIDENCE_CID, REASONING_CID, sigs);
        vm.stopPrank();

        assertEq(_tierOf(disputeId), 1, "garbage 3rd sig must not block a valid 2/3");
    }

    /// @notice 2 valid fixed sigs + 1 high-s MALLEABLE sig must STILL pass. Before the fix,
    ///         ECDSA.recover reverted ECDSAInvalidSignatureS on the high-s value.
    function test_Minor_MalleableThirdSig_StillPasses() external {
        bytes32 disputeId = _opened();
        AIRuling memory r = _ruling(disputeId, 0, 0);

        // Build a high-s (malleable) signature from a stranger key by flipping s to N - s and v.
        (, uint256 strangerPk) = makeAddrAndKey("stranger");
        bytes32 digest = _digestOf(r);
        (uint8 v, bytes32 sr, bytes32 ss) = vm.sign(strangerPk, digest);
        uint256 N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 highS = bytes32(N - uint256(ss));
        uint8 flippedV = v == 27 ? 28 : 27;
        bytes memory malleable = abi.encodePacked(sr, highS, flippedV);

        bytes[] memory sigs = new bytes[](3);
        sigs[0] = _signRuling(r, fixed0Pk);
        sigs[1] = _signRuling(r, fixed1Pk);
        sigs[2] = malleable; // high-s — must be skipped (treated as unknown), not reverted

        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), INITIAL_BOND);
        bondEscalation.submitAIRuling(disputeId, r, EVIDENCE_CID, REASONING_CID, sigs);
        vm.stopPrank();

        assertEq(_tierOf(disputeId), 1, "high-s 3rd sig must not block a valid 2/3");
    }

    // =====================================================================
    // MAJOR-2: UMA callback graceful no-op on admin INV-6 kernel resolution
    // =====================================================================

    /// @notice escalateToUMA, then admin resolves the kernel DISPUTED -> CANCELLED directly (INV-6),
    ///         then UMA fires the resolved callback. The callback MUST NOT revert (graceful no-op).
    function test_Major2_Callback_NoOp_AfterAdminCancel() external {
        (bytes32 disputeId, bytes32 txId, bytes32 assertionId) = _escalatedToUMA();

        // Admin (INV-6 resolver) moves the kernel out of DISPUTED WITHOUT touching BondEscalation.
        // 64-byte proof → CANCELLED branch, split remaining 50/50.
        uint256 remaining = _remaining(txId);
        bytes memory proof = abi.encode(remaining / 2, remaining - remaining / 2);
        vm.prank(admin);
        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, proof);
        assertEq(uint8(kernel.getTransaction(txId).state), uint8(IACTPKernel.State.CANCELLED));

        uint256 contractBalBefore = usdc.balanceOf(address(bondEscalation));

        // The late UMA callback must be a graceful no-op (no revert).
        oov3.mockResolve(assertionId, true);

        assertTrue(_resolvedOf(disputeId), "callback should sync-resolve locally");
        assertEq(_splitBpsOf(disputeId), 5000, "no-op path snapshots a 50/50 split");
        // No mediator call → kernel stays CANCELLED, no extra payout from the bond pool.
        assertEq(uint8(kernel.getTransaction(txId).state), uint8(IACTPKernel.State.CANCELLED));
        assertEq(usdc.balanceOf(address(bondEscalation)), contractBalBefore, "no payout on no-op");

        // Tier-1 bonds remain claimable via the split path (recovery still works).
        uint256 keeperBefore = usdc.balanceOf(keeper);
        vm.prank(keeper);
        bondEscalation.claimEscalationRefund(disputeId);
        assertGt(usdc.balanceOf(keeper), keeperBefore, "escalation bond must be reclaimable");
    }

    /// @notice Same, but admin resolves DISPUTED -> SETTLED (INV-6). The naive callback would hit
    ///         SETTLED -> SETTLED "No-op" in the kernel; the fix makes it a graceful local no-op.
    function test_Major2_Callback_NoOp_AfterAdminSettle() external {
        (bytes32 disputeId, bytes32 txId, bytes32 assertionId) = _escalatedToUMA();

        // 96-byte proof → SETTLED branch (provider wins, full remaining to provider).
        uint256 remaining = _remaining(txId);
        bytes memory proof = abi.encode(uint256(0), remaining, false);
        vm.prank(admin);
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, proof);
        assertEq(uint8(kernel.getTransaction(txId).state), uint8(IACTPKernel.State.SETTLED));

        // Must NOT revert.
        oov3.mockResolve(assertionId, true);

        assertTrue(_resolvedOf(disputeId), "callback should sync-resolve locally");
        assertEq(uint8(kernel.getTransaction(txId).state), uint8(IACTPKernel.State.SETTLED));
    }

    // =====================================================================
    // MINOR: assertionDisputedCallback unknown-assertion guard
    // =====================================================================

    function test_Minor_DisputedCallback_UnknownAssertion_Reverts() external {
        // Drive a callback AS the OOV3 with an assertionId that maps to no dispute.
        vm.prank(address(oov3));
        vm.expectRevert("Unknown dispute");
        bondEscalation.assertionDisputedCallback(keccak256("nonexistent"));
    }

    // =====================================================================
    // INV-9 scope: claimEscalationRefund stays open under a KERNEL pause
    // =====================================================================

    /// @notice After a split resolution, the pull-based bond recovery (claimEscalationRefund) must
    ///         remain callable even while the KERNEL itself is paused (it never touches the kernel).
    function test_Inv9_ClaimRefund_WorksUnderKernelPause() external {
        bytes32 disputeId = _opened();
        // keeper proposes split, rando challenges → two depositors, ruling 2.
        _propose(disputeId, keeper, 2, 5000);
        vm.startPrank(rando);
        usdc.approve(address(bondEscalation), INITIAL_BOND * 2);
        bondEscalation.challenge(disputeId, 2, 6000);
        vm.stopPrank();

        // Finalize BEFORE pausing the kernel (finalize itself routes through the kernel).
        vm.warp(block.timestamp + LIVENESS + 1);
        vm.prank(address(0xF1));
        bondEscalation.finalize(disputeId);
        assertTrue(_resolvedOf(disputeId));

        // Now pause the KERNEL. claimEscalationRefund must still succeed (INV-9 always-open recovery).
        vm.prank(admin);
        kernel.pause();
        assertTrue(kernel.paused(), "kernel should be paused");

        uint256 keeperBefore = usdc.balanceOf(keeper);
        vm.prank(keeper);
        bondEscalation.claimEscalationRefund(disputeId);
        assertGt(usdc.balanceOf(keeper), keeperBefore, "refund must work under kernel pause");
    }

    // =====================================================================
    // Helpers
    // =====================================================================
    function _digestOf(AIRuling memory r) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                RULING_TYPEHASH,
                r.disputeId,
                r.ruling,
                r.confidence,
                r.splitBps,
                r.timestamp,
                r.reasoningHash,
                r.bundleHash,
                r.evidenceRefHash,
                r.reasoningRefHash
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", bondEscalation.DOMAIN_SEPARATOR(), structHash));
    }

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

    /// @dev Escalate a fresh dispute all the way to a live UMA assertion (tier 2).
    function _escalatedToUMA() internal returns (bytes32 disputeId, bytes32 txId, bytes32 assertionId) {
        disputeId = _opened();
        txId = _txIdOf(disputeId);

        // Propose + challenge to the bond ceiling (alternating rulings 0/1).
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

        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), 500_000_000);
        bondEscalation.escalateToUMA(disputeId, "QmEvidenceCID", "QmReasoningCID");
        vm.stopPrank();
        assertionId = bondEscalation.disputeToAssertion(disputeId);
    }

    // ----- typed accessors over the disputes 13-tuple -----
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

    function _resolvedOf(bytes32 disputeId) internal view returns (bool r) {
        (,,,,,,,,, r,,,) = bondEscalation.disputes(disputeId);
    }
}
