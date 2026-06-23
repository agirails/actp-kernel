// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ACTPKernel.sol";
import "../src/tokens/MockUSDC.sol";
import "../src/escrow/EscrowVault.sol";

/**
 * Coverage for the four new behaviors introduced alongside requesterPenaltyBpsLocked:
 *
 *   1. Penalty rate locked at createTransaction — governance changes to
 *      requesterPenaltyBps do not retroactively re-price open transactions.
 *   2. Settlement via _releaseEscrow succeeds even when milestone releases
 *      already drained the escrow (remaining == 0).
 *   3. Pauser can no longer act as resolver for DISPUTED → SETTLED/CANCELLED.
 *      Only admin may resolve.
 *   4. (X402Relay-side test lives in X402RelayDustGuardTest.t.sol.)
 */
contract ACTPKernelLockedPenaltyTest is Test {
    ACTPKernel kernel;
    MockUSDC usdc;
    EscrowVault escrow;

    address admin;
    address pauser = address(0xDADA);
    address feeCollector = address(0xFEE);
    address requester = address(0x1);
    address provider = address(0x2);

    uint256 constant ONE_USDC = 1_000_000;
    uint16 constant DEFAULT_PENALTY_BPS = 500;   // 5% — kernel constructor default
    uint16 constant NEW_PENALTY_BPS = 2000;      // 20% — to verify the lock holds

    function setUp() external {
        admin = address(this);
        usdc = new MockUSDC();
        // ACTPKernel(admin, pauser, feeRecipient, agentRegistry, usdc)
        kernel = new ACTPKernel(admin, pauser, feeCollector, address(0), address(usdc), 1 hours);
        escrow = new EscrowVault(address(usdc), address(kernel));
        kernel.approveEscrowVault(address(escrow), true);
        usdc.mint(requester, 1_000_000_000);
    }

    // ── Helpers ───────────────────────────────────────────────────────────

    function _create(uint256 amount) internal returns (bytes32 txId) {
        vm.prank(requester);
        txId = kernel.createTransaction(
            provider, requester, amount, block.timestamp + 7 days, 2 days,
            keccak256("svc"), 0, 0
        );
    }

    function _quote(bytes32 txId) internal {
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.QUOTED, "");
    }

    function _commit(bytes32 txId, bytes32 escrowId, uint256 amount) internal {
        vm.startPrank(requester);
        usdc.approve(address(escrow), amount);
        kernel.linkEscrow(txId, address(escrow), escrowId);
        vm.stopPrank();
    }

    function _bumpPenaltyTo(uint16 newBps) internal {
        kernel.scheduleEconomicParams(kernel.platformFeeBps(), newBps);
        vm.warp(block.timestamp + kernel.ECONOMIC_PARAM_DELAY() + 1);
        kernel.executeEconomicParamsUpdate();
    }

    /// Requester needs USDC allowance to vault for the dispute bond.
    /// Bond = max(amount * disputeBondBps / MAX_BPS, MIN_DISPUTE_BOND).
    function _approveBond(uint256 amount) internal {
        uint256 bond = (amount * kernel.disputeBondBps()) / kernel.MAX_BPS();
        if (bond < kernel.MIN_DISPUTE_BOND()) bond = kernel.MIN_DISPUTE_BOND();
        vm.prank(requester);
        usdc.approve(address(escrow), bond);
    }

    // ── 1. Penalty lock at creation ──────────────────────────────────────

    function testRequesterPenaltyLocked_OldTxKeepsOldRate() external {
        // Tx is opened under the default 5% penalty regime.
        bytes32 txId = _create(ONE_USDC);
        _quote(txId);
        _commit(txId, keccak256("escA"), ONE_USDC);

        // Governance bumps the global rate to 20%.
        _bumpPenaltyTo(NEW_PENALTY_BPS);
        assertEq(kernel.requesterPenaltyBps(), NEW_PENALTY_BPS, "global must update");

        // Requester can only cancel from COMMITTED after the deadline passes.
        // _create set deadline = block.timestamp + 7 days; warp past it.
        vm.warp(block.timestamp + 8 days);

        // Requester cancels — the OLD locked rate (5%) must apply,
        // not the post-bump global rate.
        uint256 balBefore = usdc.balanceOf(requester);
        vm.prank(requester);
        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, "");
        uint256 refunded = usdc.balanceOf(requester) - balBefore;

        uint256 expectedPenalty = (ONE_USDC * DEFAULT_PENALTY_BPS) / kernel.MAX_BPS();
        uint256 expectedRefund = ONE_USDC - expectedPenalty;
        assertEq(refunded, expectedRefund, "refund must use locked (old) penalty rate");
    }

    function testRequesterPenaltyLocked_NewTxUsesNewRate() external {
        // Symmetric check: a tx opened AFTER the bump uses the new rate.
        _bumpPenaltyTo(NEW_PENALTY_BPS);

        bytes32 txId = _create(ONE_USDC);
        _quote(txId);
        _commit(txId, keccak256("escB"), ONE_USDC);

        // Same deadline pre-condition as the locked-rate test.
        vm.warp(block.timestamp + 8 days);

        uint256 balBefore = usdc.balanceOf(requester);
        vm.prank(requester);
        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, "");
        uint256 refunded = usdc.balanceOf(requester) - balBefore;

        uint256 expectedPenalty = (ONE_USDC * NEW_PENALTY_BPS) / kernel.MAX_BPS();
        uint256 expectedRefund = ONE_USDC - expectedPenalty;
        assertEq(refunded, expectedRefund, "post-bump tx must use new rate");
    }

    // ── 2. Settlement OK when milestones drained the escrow ──────────────

    function testReleaseEscrow_SucceedsWhenMilestonesAlreadyReleasedAll() external {
        bytes32 txId = _create(ONE_USDC);
        _quote(txId);
        _commit(txId, keccak256("escMS"), ONE_USDC);

        // Provider moves to IN_PROGRESS; the requester releases all funds via
        // a single milestone (releaseMilestone is a requester-only call).
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");
        vm.prank(requester);
        kernel.releaseMilestone(txId, ONE_USDC);

        // Escrow is now empty. Move through DELIVERED → SETTLED — must not revert
        // even though _releaseEscrow finds remaining == 0.
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(uint256(2 days)));

        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, "");

        IACTPKernel.TransactionView memory v = kernel.getTransaction(txId);
        assertEq(uint8(v.state), uint8(IACTPKernel.State.SETTLED), "tx must reach SETTLED");
    }

    // ── 3. Pauser can no longer resolve disputes ─────────────────────────

    function testPauserCannotResolveDispute() external {
        bytes32 txId = _create(ONE_USDC);
        _quote(txId);
        _commit(txId, keccak256("escD"), ONE_USDC);

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(uint256(2 days)));

        // AIP-14: requester opening a dispute deposits a bond into the vault.
        _approveBond(ONE_USDC);
        vm.prank(requester);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");

        // Pauser attempts SETTLED resolve — must revert.
        vm.prank(pauser);
        vm.expectRevert("Resolver only");
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, "");

        // Pauser attempts CANCELLED resolve — must revert.
        vm.prank(pauser);
        vm.expectRevert("Resolver only");
        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, "");

        // Admin still can — must include a valid resolution proof distributing
        // ALL remaining escrow (here: full payout to provider).
        bytes memory resolution = abi.encode(
            uint256(0),         // requesterAmount
            ONE_USDC,           // providerAmount: full to provider
            address(0),         // mediator
            uint256(0)          // mediatorAmount
        );
        vm.prank(admin);
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, resolution);
        IACTPKernel.TransactionView memory v = kernel.getTransaction(txId);
        assertEq(uint8(v.state), uint8(IACTPKernel.State.SETTLED), "admin must remain authorized");
    }
}
