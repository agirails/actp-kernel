// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/DisputeTestBase.sol";
import {AIRuling} from "../src/interfaces/DisputeTypes.sol";

/// @title BondEscalationD7Adversarial — adversarial attack suite for AIP-14c D7 CID binding.
/// @notice Independent red-team of the D7 evidence-authentication invariants. Each test either
///         demonstrates a real bypass (fail) or confirms the invariant holds (pass). Claims proven:
///           (a) submitAIRuling with a recomputed-ref != signed-ref REVERTS before any bond transfer
///               or state change;
///           (b) a zero/empty CID reverts (before any transfer/state change);
///           (c) a same-bundle CID mutation is rejected;
///           (d) escalateToUMA with a CID != the persisted evidence reverts (before the UMA bond moves);
///           (e) NO functional 3-arg submitAIRuling overload remains (old selector 0x5e035e52 dead).
///         Plus deeper attacks: laundering a swap by also mutating the signed ref (fails on sigs),
///         the persisted ref can never be zero for a signed dispute (conditional Tier-2 bind always
///         fires), and escalateToUMA rejects a valid-but-wrong (reasoning) CID.
contract BondEscalationD7Adversarial is DisputeTestBase {
    uint256 internal constant INITIAL_BOND = 20_000_000; // (1e9 * 200)/10000 = $20
    uint256 internal constant MAX_BOND = 500_000_000;

    // Old, pre-D7 3-arg submitAIRuling(bytes32,(AIRuling),bytes[]) selector — MUST be dead on the D7 ABI.
    bytes4 internal constant OLD_SUBMIT_SELECTOR = 0x5e035e52;
    // New, non-bypassable 5-arg submitAIRuling(bytes32,(AIRuling),string,string,bytes[]) selector.
    bytes4 internal constant NEW_SUBMIT_SELECTOR = 0xca74ab82;

    function setUp() external {
        _setUpStack();
    }

    // ---------------------------------------------------------------------
    // Local accessors over the disputes() 13-tuple.
    // ---------------------------------------------------------------------
    function _tierOf(bytes32 d) internal view returns (uint8 t) {
        (,,,,,,,, t,,,,) = bondEscalation.disputes(d);
    }

    function _currentBondOf(bytes32 d) internal view returns (uint256 b) {
        (,,, b,,,,,,,,,) = bondEscalation.disputes(d);
    }

    function _opened() internal returns (bytes32 disputeId) {
        bytes32 txId = _createDisputed();
        disputeId = bondEscalation.openDispute(txId);
    }

    function _twoEvaluatorSigs(AIRuling memory r) internal view returns (bytes[] memory sigs) {
        sigs = new bytes[](2);
        sigs[0] = _signRuling(r, fixed0Pk);
        sigs[1] = _signRuling(r, fixed1Pk);
    }

    /// @dev Enter Tier-1 via submitAIRuling (committing EVIDENCE_CID) then challenge to the $500 ceiling
    ///      so escalateToUMA's preconditions (tier==1, bond==MAX, within liveness) are all met.
    function _submitToCeiling(bytes32 disputeId) internal {
        AIRuling memory r = _ruling(disputeId, 0, 0);
        bytes[] memory sigs = _twoEvaluatorSigs(r);
        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), INITIAL_BOND);
        bondEscalation.submitAIRuling(disputeId, r, EVIDENCE_CID, REASONING_CID, sigs);
        vm.stopPrank();

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
    }

    // =====================================================================
    // (a) Mismatched ref REVERTS before any bond transfer or state change
    // =====================================================================
    function test_a_MismatchedEvidenceCID_RevertsBeforeAnyEffect() external {
        bytes32 disputeId = _opened();
        AIRuling memory r = _ruling(disputeId, 0, 0); // refs signed over EVIDENCE_CID / REASONING_CID
        bytes[] memory sigs = _twoEvaluatorSigs(r);

        uint256 keeperBefore = usdc.balanceOf(keeper);
        uint256 contractBefore = usdc.balanceOf(address(bondEscalation));

        // Attacker holds a real 2/3 evaluator quorum but swaps the evidence CID.
        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), INITIAL_BOND); // approval in place — proves no pull happens
        vm.expectRevert("Evidence CID mismatch");
        bondEscalation.submitAIRuling(disputeId, r, "QmSwappedEvidence", REASONING_CID, sigs);
        vm.stopPrank();

        // NO state change: still tier 0, no persisted commitment.
        assertEq(_tierOf(disputeId), 0, "tier must remain 0 after a rejected submit");
        assertEq(bondEscalation.evidenceRefHashOf(disputeId), bytes32(0), "no ref may be persisted");
        assertEq(bondEscalation.reasoningRefHashOf(disputeId), bytes32(0), "no reasoning ref may be persisted");
        assertEq(bondEscalation.evidenceBundleHashOf(disputeId), bytes32(0), "no bundle may be persisted");
        // NO bond transfer.
        assertEq(usdc.balanceOf(keeper), keeperBefore, "keeper bond must NOT be pulled");
        assertEq(usdc.balanceOf(address(bondEscalation)), contractBefore, "contract must NOT custody a bond");
    }

    /// @dev The swap cannot be laundered by ALSO mutating the signed ref: the CID recompute then passes,
    ///      but the evaluator signatures are over the ORIGINAL ref, so the digest changes and the 2/3
    ///      check fails. Binding ultimately rests on the evaluator quorum, exactly as intended.
    function test_a_LaunderSwapByMutatingSignedRef_FailsOnSignatures() external {
        bytes32 disputeId = _opened();
        (, uint256 attackerPk) = makeAddrAndKey("attacker");

        bytes32 bundleHash = keccak256("bundle");
        AIRuling memory r = _ruling(disputeId, 0, 0);
        // Attacker sets the ref to MATCH the swapped CID → the CID recompute check passes...
        r.evidenceRefHash = _evidenceRef(bundleHash, "QmSwappedEvidence");
        // ...but only the attacker (not the fixed evaluators) will sign this doctored ruling.
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signRuling(r, attackerPk);
        sigs[1] = _signRuling(r, attackerPk);

        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), INITIAL_BOND);
        // Passes the CID recompute, dies on the evaluator quorum — no favorable ruling laundered.
        vm.expectRevert("Insufficient valid signatures");
        bondEscalation.submitAIRuling(disputeId, r, "QmSwappedEvidence", REASONING_CID, sigs);
        vm.stopPrank();

        assertEq(_tierOf(disputeId), 0, "doctored ruling must not advance the dispute");
    }

    // =====================================================================
    // (b) Zero / empty CID reverts (before any transfer or state change)
    // =====================================================================
    function test_b_EmptyEvidenceCID_Reverts() external {
        bytes32 disputeId = _opened();
        AIRuling memory r = _ruling(disputeId, 0, 0);
        bytes[] memory sigs = _twoEvaluatorSigs(r);

        uint256 keeperBefore = usdc.balanceOf(keeper);
        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), INITIAL_BOND);
        vm.expectRevert("CID required");
        bondEscalation.submitAIRuling(disputeId, r, "", REASONING_CID, sigs);
        vm.stopPrank();

        assertEq(_tierOf(disputeId), 0, "empty-CID submit must not advance");
        assertEq(usdc.balanceOf(keeper), keeperBefore, "no bond may be pulled on empty CID");
        assertEq(bondEscalation.evidenceRefHashOf(disputeId), bytes32(0), "no ref persisted on empty CID");
    }

    function test_b_EmptyReasoningCID_Reverts() external {
        bytes32 disputeId = _opened();
        AIRuling memory r = _ruling(disputeId, 0, 0);
        bytes[] memory sigs = _twoEvaluatorSigs(r);
        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), INITIAL_BOND);
        vm.expectRevert("CID required");
        bondEscalation.submitAIRuling(disputeId, r, EVIDENCE_CID, "", sigs);
        vm.stopPrank();
        assertEq(_tierOf(disputeId), 0, "empty reasoning CID must not advance");
    }

    // =====================================================================
    // (c) Same-bundle CID mutation is rejected (a single-char change → different ref)
    // =====================================================================
    function test_c_SameBundleCIDMutation_Rejected() external {
        bytes32 disputeId = _opened();
        AIRuling memory r = _ruling(disputeId, 0, 0); // bundleHash == keccak("bundle")
        bytes[] memory sigs = _twoEvaluatorSigs(r);

        // Same signed bundleHash, but a mutated evidence CID (append one byte).
        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), INITIAL_BOND);
        vm.expectRevert("Evidence CID mismatch");
        bondEscalation.submitAIRuling(disputeId, r, string.concat(EVIDENCE_CID, "x"), REASONING_CID, sigs);
        vm.stopPrank();

        // And the reasoning CID mutation is caught on its own leg.
        vm.startPrank(keeper);
        vm.expectRevert("Reasoning CID mismatch");
        bondEscalation.submitAIRuling(disputeId, r, EVIDENCE_CID, string.concat(REASONING_CID, "y"), sigs);
        vm.stopPrank();

        assertEq(_tierOf(disputeId), 0, "no mutated-CID submit may advance");
    }

    /// @dev Positive control: the EXACT signed CIDs are accepted and persist the signed refs. Proves the
    ///      negative tests fail for the right reason (binding), not because every submit reverts.
    function test_c_ExactCIDs_Accepted_AndPersistSignedRefs() external {
        bytes32 disputeId = _opened();
        AIRuling memory r = _ruling(disputeId, 0, 0);
        bytes[] memory sigs = _twoEvaluatorSigs(r);
        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), INITIAL_BOND);
        bondEscalation.submitAIRuling(disputeId, r, EVIDENCE_CID, REASONING_CID, sigs);
        vm.stopPrank();

        assertEq(_tierOf(disputeId), 1, "exact CIDs must advance to tier 1");
        assertEq(bondEscalation.evidenceRefHashOf(disputeId), r.evidenceRefHash, "signed evidence ref persisted");
        assertEq(bondEscalation.reasoningRefHashOf(disputeId), r.reasoningRefHash, "signed reasoning ref persisted");
        assertEq(bondEscalation.evidenceBundleHashOf(disputeId), r.bundleHash, "signed bundle persisted");
        // Persisted ref is provably non-zero → the conditional Tier-2 bind will ALWAYS fire for a signed
        // dispute (keccak of any input is never 0), closing the "ref==0 bypass" concern.
        assertTrue(bondEscalation.evidenceRefHashOf(disputeId) != bytes32(0), "signed ref can never be zero");
    }

    // =====================================================================
    // (d) escalateToUMA with a CID != the persisted evidence reverts (pre-bond-move)
    // =====================================================================
    function test_d_EscalateToUMA_MutatedCID_RevertsBeforeBondMove() external {
        bytes32 disputeId = _opened();
        _submitToCeiling(disputeId);

        uint256 keeperBefore = usdc.balanceOf(keeper);
        uint256 contractBefore = usdc.balanceOf(address(bondEscalation));

        // (i) Mutated CID (same committed bundle) → reverts.
        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), MAX_BOND);
        vm.expectRevert("Evidence CID mismatch");
        bondEscalation.escalateToUMA(disputeId, "QmSwappedEvidence", REASONING_CID);
        vm.stopPrank();

        // (ii) A valid-but-WRONG CID (the reasoning CID) is likewise rejected — only the committed
        //      evidence CID is forwardable to the DVM.
        vm.startPrank(keeper);
        vm.expectRevert("Evidence CID mismatch");
        bondEscalation.escalateToUMA(disputeId, REASONING_CID, REASONING_CID);
        vm.stopPrank();

        // (ii.b) The committed evidence CID with a valid-but-WRONG reasoning CID is rejected on the
        //        reasoning leg — the persisted reasoning ref binds the second forwardable CID too.
        vm.startPrank(keeper);
        vm.expectRevert("Reasoning CID mismatch");
        bondEscalation.escalateToUMA(disputeId, EVIDENCE_CID, "QmSwappedReasoning");
        vm.stopPrank();

        // No UMA bond moved, no assertion opened, still Tier-1.
        assertEq(_tierOf(disputeId), 1, "must remain Tier-1 after rejected escalation");
        assertEq(bondEscalation.disputeToAssertion(disputeId), bytes32(0), "no assertion may be created");
        assertEq(usdc.balanceOf(keeper), keeperBefore, "UMA bond must NOT be pulled on a swapped CID");
        assertEq(usdc.balanceOf(address(bondEscalation)), contractBefore, "no funds may move on a swapped CID");

        // (iii) The EXACT committed CID escalates cleanly to Tier-2.
        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), MAX_BOND);
        bondEscalation.escalateToUMA(disputeId, EVIDENCE_CID, REASONING_CID);
        vm.stopPrank();
        assertEq(_tierOf(disputeId), 2, "exact committed CID must reach Tier-2");
        assertTrue(bondEscalation.disputeToAssertion(disputeId) != bytes32(0), "assertion must be recorded");
    }

    // =====================================================================
    // (e) NO functional 3-arg submitAIRuling overload remains
    // =====================================================================
    function test_e_Old3ArgSelector_DoesNotResolve() external {
        bytes32 disputeId = _opened();
        AIRuling memory r = _ruling(disputeId, 0, 0);
        bytes[] memory sigs = _twoEvaluatorSigs(r);

        // Encode the pre-D7 3-arg call shape against the live contract.
        bytes memory oldCall = abi.encodeWithSelector(OLD_SUBMIT_SELECTOR, disputeId, r, sigs);
        (bool okOld,) = address(bondEscalation).call(oldCall);
        assertFalse(okOld, "old 3-arg submitAIRuling selector must NOT resolve (no CID-free bypass)");

        // Positive control: the 5-arg selector IS the live entrypoint and dispatches to real logic.
        // Driven as a funded+approved caller so a success proves DISPATCH (not just an approval revert).
        bytes memory newCall =
            abi.encodeWithSelector(NEW_SUBMIT_SELECTOR, disputeId, r, EVIDENCE_CID, REASONING_CID, sigs);
        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), INITIAL_BOND);
        (bool okNew,) = address(bondEscalation).call(newCall);
        vm.stopPrank();
        assertTrue(okNew, "new 5-arg submitAIRuling must dispatch and succeed with matching CIDs");
        assertEq(_tierOf(disputeId), 1, "new entrypoint actually advanced the dispute");
    }

    /// @dev Belt-and-suspenders: the runtime bytecode must not contain the old selector as a dispatch
    ///      entry. (A raw-call revert could in principle come from a fallback; there is none here, but we
    ///      also assert the selector is genuinely absent from the deployed dispatch table.)
    function test_e_Old3ArgSelector_AbsentFromBytecode() external view {
        bytes memory code = address(bondEscalation).code;
        // The Solidity dispatcher compares calldata's selector against each function selector as a
        // PUSH4 constant. If the old selector never appears in the runtime code, no dispatch path exists.
        bool found = false;
        if (code.length >= 4) {
            for (uint256 i = 0; i + 4 <= code.length; i++) {
                if (
                    code[i] == OLD_SUBMIT_SELECTOR[0] && code[i + 1] == OLD_SUBMIT_SELECTOR[1]
                        && code[i + 2] == OLD_SUBMIT_SELECTOR[2] && code[i + 3] == OLD_SUBMIT_SELECTOR[3]
                ) {
                    found = true;
                    break;
                }
            }
        }
        assertFalse(found, "old 3-arg submitAIRuling selector must be absent from the dispatch table");
    }
}
