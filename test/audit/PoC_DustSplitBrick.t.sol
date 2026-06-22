// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DisputeTestBase} from "../helpers/DisputeTestBase.sol";
import {IACTPKernel} from "../../src/interfaces/IACTPKernel.sol";

/**
 * @title PoC_DustSplitBrick — AUDIT PoC (AIP-14b dispute system) — F-1 FIXED (regression test)
 *
 * FINDING (production-readiness report F-1, HIGH — NOW RESOLVED):
 *   "Sub-MIN_FEE provider split share BRICKS dispute finalization for up to 30 days" via the
 *    MIN_FEE > share fee check.  Severity: HIGH (fund-LOCK + permissionless-recovery DoS).
 *
 * ROOT CAUSE (ACTPKernel.sol — historical):
 *   _calculateFee FLOORED the platform fee at MIN_FEE = 50_000 ($0.05):
 *       bpsFee = grossAmount * lockedFeeBps / MAX_BPS;
 *       return bpsFee > MIN_FEE ? bpsFee : MIN_FEE;
 *   _payoutProviderAmount then required:
 *       uint256 fee = _calculateFee(grossAmount, txn.platformFeeBpsLocked);
 *       require(fee <= grossAmount, "Fee exceeds amount");
 *   On a SPLIT ruling (==2), CompositeMediator.resolve computes the provider share with NO floor
 *   (providerAmount = remaining*splitBps/10000) and emits a 64-byte CANCELLED proof routed to
 *   _handleCancellation -> _payoutProviderAmount when providerAmount > 0. If that share was below
 *   MIN_FEE the floored fee EXCEEDED the share and the whole transition REVERTED atomically.
 *
 * THE FIX (F-1):
 *   _calculateFee now CLAMPS the floored fee to gross: `if (fee > grossAmount) fee = grossAmount;`.
 *   On a sub-MIN_FEE gross the provider nets 0 and the fee absorbs the dust; `fee <= grossAmount`
 *   always holds, so `providerNet + fee == grossAmount` exactly and `totalDistributed == remaining`
 *   still holds (solvency preserved). The single fee chokepoint covers BOTH the split provider-amount
 *   path and the normal `_releaseEscrow` tiny-tail path.
 *
 * FIVE demonstrations — flipped to ASSERT the FIXED behavior (permanent regression tests):
 *
 *   [1] test_FIXED_dustSplit_finalizesCleanly
 *       STRONGEST: a HEALTHY $100 escrow with an attacker-settable splitBps=1 ($0.01 provider share,
 *       in the old (0, MIN_FEE) dead band) now finalize()s CLEANLY. The dust is absorbed by the fee
 *       (provider nets 0), the dispute resolves, and the escrow is fully distributed (no lock).
 *
 *   [2] test_FIXED_forceResolveStale_recoversCleanly_subTenCents
 *       The PERMISSIONLESS keeper recovery (forceResolveStale, hardcoded resolve(2,5000)) now
 *       recovers a $0.08 escrow (provider half = $0.04 < MIN_FEE) cleanly — the walk-away escape
 *       hatch is alive again.
 *
 *   [3] test_FIXED_largeEscrowDrainedToDust_recovers
 *       Escrow size is NOT a limit: a requester drains a $1000 escrow to $0.08 dust via the
 *       requester-only releaseMilestone BEFORE disputing, and the keeper path now recovers cleanly.
 *
 *   [4] test_severityTemper_adminEscapeHatch_allToRequester (CONTROL — UNCHANGED)
 *       The all-to-requester SETTLED proof path (providerAmount==0 skips the fee path) still works.
 *
 *   [5] test_CONTROL_fiftyFiftySplit_resolvesCleanly (CONTROL — UNCHANGED)
 *       A 50/50 split on the SAME small escrow finalizes fine — the above-MIN_FEE path is unaffected.
 */
contract PoC_DustSplitBrick is DisputeTestBase {
    uint256 internal constant MIN_FEE = 50_000;             // mirror of ACTPKernel.MIN_FEE ($0.05)
    uint256 internal constant HEALTHY_ESCROW = 100_000_000; // $100

    function setUp() external {
        _setUpStack();
    }

    // ---- helpers ----------------------------------------------------------------------

    /// Drive a fresh tx with an arbitrary escrow `amount` to DISPUTED + open the BondEscalation dispute.
    function _openDisputeWithAmount(uint256 amount, bytes32 svc) internal returns (bytes32 disputeId, bytes32 txId) {
        vm.prank(requester);
        txId = kernel.createTransaction(
            provider, requester, amount, block.timestamp + 365 days, 30 days, svc, 0, 0
        );

        vm.startPrank(requester);
        usdc.approve(address(escrow), amount);
        kernel.linkEscrow(txId, address(escrow), txId);
        vm.stopPrank();

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");
        vm.prank(provider);
        // DELIVERED dispute-window proof = 30 days (== MAX_DISPUTE_WINDOW) so DISPUTED stays open.
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(30 days));

        // dispute bond = max(amount*disputeBondBpsLocked/MAX_BPS, MIN_DISPUTE_BOND). Approve generously;
        // requester is funded with 1M USDC by the base.
        vm.startPrank(requester);
        usdc.approve(address(escrow), type(uint256).max);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");
        vm.stopPrank();

        vm.prank(rando); // permissionless
        disputeId = bondEscalation.openDispute(txId);
    }

    // DisputeState tuple has 13 fields (BondEscalation.sol L78-92).
    function _tier(bytes32 disputeId) internal view returns (uint8 tier) {
        (,,,,,,,, tier,,,,) = bondEscalation.disputes(disputeId);
    }
    function _resolved(bytes32 disputeId) internal view returns (bool r) {
        (,,,,,,,,, r,,,) = bondEscalation.disputes(disputeId);
    }
    function _livenessEnd(bytes32 disputeId) internal view returns (uint64 l) {
        (,,,,, l,,,,,,,) = bondEscalation.disputes(disputeId);
    }

    function _propose(bytes32 disputeId, address who, uint8 ruling, uint16 splitBps) internal {
        vm.startPrank(who);
        usdc.approve(address(bondEscalation), type(uint256).max);
        bondEscalation.proposeDirectly(disputeId, ruling, splitBps);
        vm.stopPrank();
    }

    // ==================================================================================
    // [1] F-1 FIXED: dust split finalize() on a HEALTHY $100 escrow now resolves CLEANLY.
    // ==================================================================================
    function test_FIXED_dustSplit_finalizesCleanly() external {
        (bytes32 disputeId, bytes32 txId) = _openDisputeWithAmount(HEALTHY_ESCROW, keccak256("dust-finalize"));

        assertGe(HEALTHY_ESCROW, kernel.MIN_TRANSACTION_AMOUNT(), "escrow is a valid above-min tx");
        assertEq(_remaining(txId), HEALTHY_ESCROW, "escrow fully funded");

        // Attacker (or honest low-value resolver) proposes a split with splitBps=1. Guards in
        // proposeDirectly only require ruling<=2, splitBps<=10000, (ruling==2 || splitBps==0).
        _propose(disputeId, keeper, 2, 1);
        assertEq(_tier(disputeId), 1, "tier 1 after proposal");

        uint256 providerShare = (HEALTHY_ESCROW * 1) / 10000; // $0.01
        assertEq(providerShare, 10_000, "provider share = $0.01");
        assertLt(providerShare, MIN_FEE, "share is in the OLD (0, MIN_FEE) dead band");

        // Snapshot balances to prove the dust is absorbed by the fee, provider nets 0 (solvency).
        uint256 reqBefore = usdc.balanceOf(requester);
        uint256 provBefore = usdc.balanceOf(provider);

        vm.warp(_livenessEnd(disputeId) + 1);

        // KEY ASSERTION (FLIPPED): finalize() no longer reverts — the F-1 clamp lets the dust
        // provider-share absorb fully into the fee (provider nets 0) and the transition completes.
        bondEscalation.finalize(disputeId);

        // The dispute resolves and the escrow is fully distributed (CANCELLED split path).
        assertTrue(_resolved(disputeId), "dispute resolved (no brick)");
        assertEq(uint8(kernel.getTransaction(txId).state), uint8(IACTPKernel.State.CANCELLED), "tx settled to CANCELLED");
        assertEq(_remaining(txId), 0, "escrow fully released - no lock, no permanent loss");

        // Solvency: the $0.01 provider dust share is absorbed by the fee → provider nets 0; the
        // requester receives its $99.99 share back (plus the returned dispute bond on CANCELLED).
        assertEq(usdc.balanceOf(provider), provBefore, "provider nets 0 - dust absorbed by fee");
        assertGt(usdc.balanceOf(requester), reqBefore, "requester refunded its split share");

        // Idempotency: the dispute is a one-way latch — a second finalize() is a no-op revert,
        // NOT the old deterministic "Fee exceeds amount" brick.
        vm.expectRevert(bytes("Already resolved"));
        bondEscalation.finalize(disputeId);
    }

    // ==================================================================================
    // [2] F-1 FIXED: the PERMISSIONLESS keeper recovery (forceResolveStale) recovers sub-$0.10.
    // ==================================================================================
    function test_FIXED_forceResolveStale_recoversCleanly_subTenCents() external {
        // $0.08 escrow -> forceResolveStale hardcodes 50/50 -> provider share $0.04 = 40_000 < MIN_FEE.
        (bytes32 disputeId, bytes32 txId) = _openDisputeWithAmount(80_000, keccak256("brick-80k"));

        vm.warp(block.timestamp + 31 days); // past MAX_DISPUTE_DURATION (30 days)

        assertLt((80_000 * 5000) / 10000, MIN_FEE, "provider half < MIN_FEE");

        // FLIPPED: the keeper walk-away path now recovers cleanly (dust absorbed by the fee clamp).
        vm.prank(rando);
        bondEscalation.forceResolveStale(disputeId);

        assertTrue(_resolved(disputeId), "stale dispute resolved by permissionless keeper");
        assertEq(uint8(kernel.getTransaction(txId).state), uint8(IACTPKernel.State.CANCELLED), "tx recovered to CANCELLED");
        assertEq(_remaining(txId), 0, "escrow fully released - walk-away escape hatch is alive");

        // A retry by anyone is now an idempotent no-op, NOT the old "Fee exceeds amount" brick.
        vm.prank(keeper);
        vm.expectRevert(bytes("Already resolved"));
        bondEscalation.forceResolveStale(disputeId);
    }

    // ==================================================================================
    // [3] F-1 FIXED: escrow size is NOT a limit — drain a $1000 escrow to dust, keeper recovers.
    // ==================================================================================
    function test_FIXED_largeEscrowDrainedToDust_recovers() external {
        uint256 amount = HEALTHY_ESCROW * 10; // $1000

        vm.prank(requester);
        bytes32 txId = kernel.createTransaction(
            provider, requester, amount, block.timestamp + 365 days, 30 days, keccak256("drain-1000"), 0, 0
        );
        vm.startPrank(requester);
        usdc.approve(address(escrow), amount);
        kernel.linkEscrow(txId, address(escrow), txId);
        vm.stopPrank();
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");

        // Requester-only releaseMilestone drains escrow to $0.08 while IN_PROGRESS.
        vm.prank(requester);
        kernel.releaseMilestone(txId, amount - 80_000);
        assertEq(_remaining(txId), 80_000, "escrow drained to dust");

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(30 days));
        vm.startPrank(requester);
        usdc.approve(address(escrow), type(uint256).max);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");
        vm.stopPrank();

        vm.prank(rando);
        bytes32 disputeId = bondEscalation.openDispute(txId);
        vm.warp(block.timestamp + 31 days);

        // FLIPPED: the drained-to-dust escrow recovers cleanly via the permissionless keeper path.
        vm.prank(rando);
        bondEscalation.forceResolveStale(disputeId);

        assertTrue(_resolved(disputeId), "drained-to-dust dispute resolved");
        assertEq(uint8(kernel.getTransaction(txId).state), uint8(IACTPKernel.State.CANCELLED), "tx recovered to CANCELLED");
        assertEq(_remaining(txId), 0, "milestone-drained dust escrow fully released");
    }

    // ==================================================================================
    // [4] SEVERITY TEMPER: admin escapes via all-to-requester SETTLED proof (no permanent loss),
    //     but one admin action per junk dispute = the DoS that keeps severity `high`.
    // ==================================================================================
    function test_severityTemper_adminEscapeHatch_allToRequester() external {
        (, bytes32 txId) = _openDisputeWithAmount(80_000, keccak256("escape-80k"));

        uint256 reqBefore = usdc.balanceOf(requester);

        // 96-byte SETTLED proof: all to requester, providerAmount == 0 -> _payoutProviderAmount skipped.
        bytes memory settledProof = abi.encode(uint256(80_000), uint256(0), true);

        // admin == address(this) is an approved resolver (_isApprovedResolver).
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, settledProof);

        assertEq(uint8(kernel.getTransaction(txId).state), uint8(IACTPKernel.State.SETTLED), "admin escapes via SETTLED");
        // Requester recovers AT LEAST the $0.08 dust escrow (also gets the $1 dispute bond back as the
        // non-faulting initiator — hence > 80_000). The point: funds are recovered, no permanent loss.
        assertGe(usdc.balanceOf(requester) - reqBefore, 80_000, "requester refunded at least the dust escrow");
        assertEq(_remaining(txId), 0, "escrow released, no permanent loss");
    }

    // ==================================================================================
    // [5] CONTROL: 50/50 split on the SAME small escrow finalizes cleanly.
    // ==================================================================================
    function test_CONTROL_fiftyFiftySplit_resolvesCleanly() external {
        (bytes32 disputeId, bytes32 txId) = _openDisputeWithAmount(HEALTHY_ESCROW, keccak256("control"));

        _propose(disputeId, keeper, 2, 5000);
        vm.warp(_livenessEnd(disputeId) + 1);

        assertGt((HEALTHY_ESCROW * 5000) / 10000, MIN_FEE, "control share > MIN_FEE");

        bondEscalation.finalize(disputeId); // no revert

        assertTrue(_resolved(disputeId), "control split resolves");
        assertEq(uint8(kernel.getTransaction(txId).state), uint8(IACTPKernel.State.CANCELLED), "lands CANCELLED");
    }
}
