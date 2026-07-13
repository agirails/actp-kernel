// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../helpers/DisputeTestBase.sol";
import {IACTPKernel} from "../../src/interfaces/IACTPKernel.sol";

/// @title PoC_UMABondTheft — F-3 FIXED (regression test).
/// @notice Free-rider bond theft via the UMA escalator overwrite — NOW RESOLVED.
///
/// HISTORICAL FINDING (HIGH): BondEscalation.escalateToUMA (BondEscalation.sol L522)
///          `lastProposerForRuling[disputeId][0] = msg.sender;`
///   UNCONDITIONALLY overwrote the ruling-0 "winner of record" with whoever called
///   escalateToUMA — regardless of whether that caller ever posted a single Tier-1 bond.
///
///   escalateToUMA is single-shot and permissionless (first-caller-wins => front-runnable).
///   On a TRUE UMA resolution (ruling 0), assertionResolvedCallback pays the ENTIRE
///   accumulatedBonds pool to lastProposerForRuling[0]. A non-participant who front-ran the
///   escalation collected the whole Tier-1 pool; the honest last ruling-0 proposer who actually
///   funded the winning direction got $0.
///
/// THE FIX (F-3): DELETE L522. The escalator merely posts the $500 UMA bond (returned by UMA on a
///   TRUE resolution); they are NOT necessarily a Tier-1 depositor. With the overwrite gone, the
///   ruling-0 winner-of-record stays the GENUINE last ruling-0 proposer, so the Tier-1 pool flows
///   to the honest bonder and the free-rider receives nothing from the pool.
///
/// SCENARIO (mirrors the finding's numbers):
///   escrow = $1000 -> bond curve 20,40,80,160,320,500,500 => pool = $1,620.
///   keeper genuinely posts the ruling-0 bonds ($920 total) and IS the real
///   lastProposerForRuling[0] just before escalation. A non-participant `attacker`
///   (deposits == 0) front-runs escalateToUMA. UMA resolves TRUE.
///
/// EXPECTED (FIXED) behaviour, asserted below (permanent regression test):
///   - escalateToUMA does NOT overwrite the ruling-0 winner-of-record (stays keeper).
///   - the full $1,620 Tier-1 pool flows to the honest keeper; the attacker gets $0 from the pool.
///
/// Run:
///   forge test --match-path "test/audit/PoC_UMABondTheft.t.sol" -vvv
contract PoC_UMABondTheft is DisputeTestBase {
    uint256 internal constant INITIAL_BOND = 20_000_000; // $20  = escrow*200/10000
    uint256 internal constant MAX_BOND = 500_000_000; // $500 ceiling
    uint256 internal constant UMA_BOND = 500_000_000; // $500 assertion bond
    uint256 internal constant EXPECTED_POOL = 1_620_000_000; // $1,620 = 20+40+80+160+320+500+500

    // A non-participant attacker: NEVER posts a Tier-1 bond, just front-runs the escalation.
    address internal attacker = address(0xA77ACC);

    function setUp() external {
        _setUpStack();
        // Fund the attacker ONLY enough to pay the UMA bond (their sole real cost). They post
        // ZERO Tier-1 bonds — proving they free-ride the pool the honest party funded.
        usdc.mint(attacker, UMA_BOND);
    }

    /// @notice F-3 FIXED: the free-rider escalator gets NOTHING; the honest bonder is paid.
    function test_PoC_FreeRiderGetsNothing_HonestBonderPaid() external {
        // ----- 1) Open dispute + drive bonds to the $500 ceiling -----
        // keeper proposes ruling 0, then keeper/rando alternate-challenge to the ceiling.
        // End state: keeper deposits $920 (ruling-0), rando deposits $700 (ruling-1),
        //            pool = $1,620, lastProposerForRuling[0] == keeper (the GENUINE winner).
        bytes32 disputeId = _openedAtCeiling();

        // Sanity: the pool and the honest ruling-0 winner-of-record are exactly as the finding states.
        assertEq(_accumulatedBondsOf(disputeId), EXPECTED_POOL, "pool should be $1,620");
        assertEq(_depositOf(disputeId, keeper), 920_000_000, "keeper funded $920 of ruling-0 bonds");
        assertEq(_depositOf(disputeId, rando), 700_000_000, "rando funded $700 of ruling-1 bonds");
        assertEq(_depositOf(disputeId, attacker), 0, "attacker funded NOTHING");
        assertEq(
            bondEscalation.lastProposerForRuling(disputeId, 0),
            keeper,
            "GENUINE ruling-0 winner-of-record is keeper (he last proposed ruling 0)"
        );

        // ----- 2) Attacker FRONT-RUNS escalateToUMA (permissionless, single-shot) -----
        // FLIPPED: with L522 deleted (F-3), escalateToUMA does NOT overwrite the ruling-0 slot.
        // The non-participant attacker only posts the $500 UMA bond; the honest keeper keeps the slot.
        vm.startPrank(attacker);
        usdc.approve(address(bondEscalation), UMA_BOND);
        bondEscalation.escalateToUMA(disputeId, "QmAttackerEvidenceCID", "QmReasoningCID");
        vm.stopPrank();

        assertEq(
            bondEscalation.lastProposerForRuling(disputeId, 0),
            keeper,
            "F-3 FIX: ruling-0 winner slot is UNTOUCHED by the escalator (stays keeper)"
        );

        bytes32 assertionId = bondEscalation.disputeToAssertion(disputeId);

        // ----- 3) UMA resolves TRUE => ruling 0 ("provider delivered") -----
        // assertionResolvedCallback pays the ENTIRE accumulatedBonds pool to lastProposerForRuling[0]
        // (= the honest keeper). No settle-bounty is taken on this direct mockResolve path
        // (pendingSettler == 0), so the keeper receives the FULL pool.
        uint256 keeperBefore = usdc.balanceOf(keeper);
        uint256 attackerBefore = usdc.balanceOf(attacker);

        oov3.mockResolve(assertionId, true);

        uint256 keeperGain = usdc.balanceOf(keeper) - keeperBefore;
        uint256 attackerGain = usdc.balanceOf(attacker) - attackerBefore;

        // ----- 4) ASSERT THE FIXED BEHAVIOUR -----
        // The full $1,620 Tier-1 pool is paid to the honest keeper who funded the winning direction.
        assertEq(keeperGain, EXPECTED_POOL, "FIXED: honest ruling-0 proposer (keeper) receives the ENTIRE $1,620 pool");

        // The non-participant escalator receives NOTHING from the Tier-1 pool (their UMA bond is
        // refunded separately by OOV3 on the TRUE resolution — never via accumulatedBonds).
        assertEq(attackerGain, 0, "FIXED: free-rider escalator receives $0 from the Tier-1 pool");

        // winnerPaid set, pool fully drained TO THE HONEST WINNER.
        assertTrue(_winnerPaidOf(disputeId), "winner-takes-all path executed for the honest winner");
        assertEq(_accumulatedBondsOf(disputeId), 0, "pool fully paid out (to the honest keeper)");

        // Ruling is 0 (winner-takes-all): the attacker has no split-refund route to claw back funds.
        assertEq(_currentRulingOf(disputeId), 0, "ruling is 0 (winner-takes-all) - no split refund route");
        vm.prank(attacker);
        vm.expectRevert("Not a split - winner takes all");
        bondEscalation.claimEscalationRefund(disputeId);

        emit log_named_decimal_uint("Honest keeper ($920 funded) received   [USDC]", keeperGain, 6);
        emit log_named_decimal_uint("Free-rider escalator pool gain          [USDC]", attackerGain, 6);
    }

    // ==========================================================================================
    // Lifecycle helper — open + drive to the $500 ceiling (mirrors UMAIntegration.t.sol).
    // keeper is the last ruling-0 proposer; rando the last ruling-1 proposer.
    // ==========================================================================================
    function _openedAtCeiling() internal returns (bytes32 disputeId) {
        bytes32 txId = _createDisputed();
        disputeId = bondEscalation.openDispute(txId);

        // keeper proposes ruling 0 ($20).
        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), INITIAL_BOND);
        bondEscalation.proposeDirectly(disputeId, 0, 0);
        vm.stopPrank();

        // 6 alternating challenges: 40,80,160,320,500,500. rando on even i (ruling 1),
        // keeper on odd i (ruling 0) => keeper is the LAST ruling-0 proposer at the ceiling.
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
        require(bondEscalation.lastProposerForRuling(disputeId, 0) == keeper, "keeper must be last r0 proposer");
    }

    // ==========================================================================================
    // Typed accessors over the 13-tuple `disputes` getter.
    // struct order: transactionId, currentRuling, splitBps, currentBond, accumulatedBonds,
    //   livenessEnd, disputedAt, lastProposer, tier, resolved, winnerPaid, originalPool, escrowAmount
    // ==========================================================================================
    function _currentRulingOf(bytes32 d) internal view returns (uint8 r) {
        (, r,,,,,,,,,,,) = bondEscalation.disputes(d);
    }

    function _currentBondOf(bytes32 d) internal view returns (uint256 b) {
        (,,, b,,,,,,,,,) = bondEscalation.disputes(d);
    }

    function _accumulatedBondsOf(bytes32 d) internal view returns (uint256 a) {
        (,,,, a,,,,,,,,) = bondEscalation.disputes(d);
    }

    function _winnerPaidOf(bytes32 d) internal view returns (bool w) {
        (,,,,,,,,,, w,,) = bondEscalation.disputes(d);
    }

    function _depositOf(bytes32 d, address who) internal view returns (uint256) {
        return bondEscalation.deposits(d, who);
    }
}
