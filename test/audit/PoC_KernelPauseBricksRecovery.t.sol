// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/ACTPKernel.sol";
import "../../src/BondEscalation.sol";
import "../../src/CompositeMediator.sol";
import "../../src/tokens/MockUSDC.sol";
import "../../src/escrow/EscrowVault.sol";

/*//////////////////////////////////////////////////////////////////////////
                       AUDIT PoC — F-2 FIXED (regression test)
////////////////////////////////////////////////////////////////////////////

  FINDING (HIGH — NOW RESOLVED): Kernel pause() transitively BRICKED
  BondEscalation's documented "NOT-pausable" recovery paths. INV-9 was DEFEATED.

  INV-9 (INVARIANT-TRACEABILITY.md L20):
    "Recovery paths are NOT pausable (recovery runs while paused)."
    finalize / forceResolveStale / claimEscalationRefund / syncExternalResolution
    deliberately carry NO whenNotPaused modifier.

  ACTPKernel NatSpec: "Pause blocks state changes, NOT fund recovery."

  HISTORICAL ROOT CAUSE: every dispute-resolution path funnelled through
    ACTPKernel.transitionState  (whenNotPaused -> "Kernel paused")
  via: finalize / forceResolveStale / assertionResolvedCallback ->
       compositeMediator.resolve -> kernel.transitionState(SETTLED|CANCELLED).
  A single pause() froze ALL of them — even the permissionless 30-day walk-away.

  THE FIX (F-2): a pause-exempt resolver entrypoint on the kernel,
    ACTPKernel.resolveDisputeWhilePaused(txId, {SETTLED|CANCELLED}, proof)
  restricted to `_isApprovedResolver` AND the DISPUTED->{SETTLED,CANCELLED}
  transition only. CompositeMediator.resolve now routes its DISPUTED-exit through
  it, so honest dispute recovery survives a pause while every NORMAL/forward
  transition stays frozen exactly as before.

  This PoC now asserts the FIXED behavior (permanent regression test):
    (A) finalize() SUCCEEDS while paused                       -> recovery alive
    (B) forceResolveStale() (the permissionless walk-away)
        SUCCEEDS while paused                                   -> walk-away alive
    (C) the GENERAL transitionState entrypoint STAYS frozen while paused (normal
        forward transitions still blocked), but the approved resolver can recover
        the DISPUTED txn via the pause-exempt resolveDisputeWhilePaused.
    (D) regression sanity: recovery also works normally after unpause().
*///////////////////////////////////////////////////////////////////////////

contract PoC_KernelPauseBricksRecovery is Test {
    ACTPKernel kernel;
    BondEscalation bond;
    CompositeMediator mediator;
    MockUSDC usdc;
    EscrowVault escrow;

    address admin = address(this);
    address pauser = address(0xFA053);
    address requester = address(0x1);
    address provider = address(0x2);
    address keeper = address(0xCAFE);
    address feeCollector = address(0xFEE);
    address ev0 = address(0xE0);
    address ev1 = address(0xE1);
    address rot0 = address(0xC0);

    uint256 constant ONE = 1_000_000;
    uint256 constant AMT = 1_000 * ONE;

    function setUp() external {
        usdc = new MockUSDC();
        kernel = new ACTPKernel(admin, pauser, feeCollector, address(0), address(usdc));
        escrow = new EscrowVault(address(usdc), address(kernel));
        kernel.approveEscrowVault(address(escrow), true);
        mediator = new CompositeMediator(IACTPKernel(address(kernel)));
        address[2] memory fixedEvs = [ev0, ev1];
        address[] memory rot = new address[](1);
        rot[0] = rot0;
        bond = new BondEscalation(
            IACTPKernel(address(kernel)),
            IERC20(address(usdc)),
            ICompositeMediator(address(mediator)),
            admin,
            fixedEvs,
            rot,
            address(0xab1234) // non-zero dummy OOV3 (Tier-2 not exercised here)
        );
        mediator.initialize(address(bond));
        kernel.approveMediator(address(mediator), true);
        vm.warp(block.timestamp + 2 days + 1); // clear mediator timelock

        usdc.mint(requester, 100_000 * ONE);
        usdc.mint(keeper, 100_000 * ONE);
    }

    /// Drives a fresh transaction all the way into DISPUTED.
    function _disputed() internal returns (bytes32 txId) {
        vm.prank(requester);
        txId = kernel.createTransaction(
            provider, requester, AMT, block.timestamp + 30 days, 2 days, keccak256("svc"), 0, 0
        );
        vm.startPrank(requester);
        usdc.approve(address(escrow), type(uint256).max);
        kernel.linkEscrow(txId, address(escrow), txId);
        vm.stopPrank();
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(uint256(10 days)));
        vm.prank(requester);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");
    }

    // ───────────────────────────────────────────────────────────────────────
    // (A) finalize() — Tier-1 happy-path recovery — SURVIVES kernel pause (F-2).
    // ───────────────────────────────────────────────────────────────────────
    function test_A_KernelPause_finalizeSurvivesPause() external {
        bytes32 txId = _disputed();
        bond.openDispute(txId);
        bytes32 disputeId = keccak256(abi.encode("ACTP_DISPUTE_V1", txId));

        vm.startPrank(keeper);
        usdc.approve(address(bond), type(uint256).max);
        bond.proposeDirectly(disputeId, 0, 0); // provider wins
        vm.stopPrank();

        vm.warp(block.timestamp + 9 hours); // liveness expires

        // INV-9: finalize() is NOT pausable. The F-2 pause-exempt resolver entrypoint honors that.
        kernel.pause();
        assertTrue(kernel.paused(), "kernel must be paused");

        // FLIPPED: recovery now succeeds even while the kernel is paused.
        vm.prank(keeper);
        bond.finalize(disputeId);

        // Provider won (ruling 0) -> DISPUTED resolves to SETTLED despite the pause.
        assertEq(
            uint8(kernel.getTransaction(txId).state),
            uint8(IACTPKernel.State.SETTLED),
            "finalize moved DISPUTED->SETTLED while paused (INV-9 honored)"
        );
        assertEq(escrow.remaining(txId), 0, "escrow released during pause - funds not frozen");
    }

    // ───────────────────────────────────────────────────────────────────────
    // (B) forceResolveStale() — the permissionless 30-day WALK-AWAY escape
    //     hatch — SURVIVES a single pause() (F-2). The load-bearing one.
    // ───────────────────────────────────────────────────────────────────────
    function test_B_KernelPause_forceResolveStaleWalkawaySurvivesPause() external {
        bytes32 txId = _disputed();
        bond.openDispute(txId);
        bytes32 disputeId = keccak256(abi.encode("ACTP_DISPUTE_V1", txId));

        vm.warp(block.timestamp + 31 days); // past MAX_DISPUTE_DURATION (30d)

        kernel.pause();

        // FLIPPED: the permissionless walk-away escape hatch is alive under pause.
        vm.prank(keeper);
        bond.forceResolveStale(disputeId);

        // Stale path forces a 50/50 split -> CANCELLED, escrow released, even while paused.
        assertEq(
            uint8(kernel.getTransaction(txId).state),
            uint8(IACTPKernel.State.CANCELLED),
            "walk-away resolved DISPUTED->CANCELLED while paused (INV-9 honored)"
        );
        assertEq(escrow.remaining(txId), 0, "escrow released during pause - walk-away guarantee held");
    }

    // ───────────────────────────────────────────────────────────────────────
    // (C) NARROW SCOPE of F-2: the GENERAL transitionState entrypoint STAYS
    //     frozen under pause (no power creep — normal/forward transitions still
    //     blocked), but the approved resolver CAN recover the DISPUTED txn via
    //     the pause-exempt resolveDisputeWhilePaused. Proves the fix grants no
    //     new power beyond the documented INV-9 dispute-recovery exemption.
    // ───────────────────────────────────────────────────────────────────────
    function test_C_KernelPause_GeneralEntryFrozen_ButResolverRecovers() external {
        bytes32 txId = _disputed();
        kernel.pause();

        // The GENERAL entrypoint still carries whenNotPaused — stays frozen for everyone.
        vm.prank(admin);
        vm.expectRevert("Kernel paused");
        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, "");

        vm.prank(admin);
        vm.expectRevert("Kernel paused");
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, "");

        // A NON-resolver cannot use the pause-exempt entrypoint either (scope guard).
        vm.prank(keeper);
        vm.expectRevert("Resolver only");
        kernel.resolveDisputeWhilePaused(txId, IACTPKernel.State.CANCELLED, abi.encode(AMT, uint256(0)));

        // The approved resolver (admin) CAN recover the DISPUTED txn while paused — the
        // documented INV-9 exemption, and ONLY for the DISPUTED->{SETTLED,CANCELLED} exit.
        vm.prank(admin);
        kernel.resolveDisputeWhilePaused(txId, IACTPKernel.State.CANCELLED, abi.encode(AMT, uint256(0)));

        assertEq(
            uint8(kernel.getTransaction(txId).state),
            uint8(IACTPKernel.State.CANCELLED),
            "approved resolver recovered DISPUTED->CANCELLED via pause-exempt entry"
        );
    }

    // ───────────────────────────────────────────────────────────────────────
    // (D) REGRESSION SANITY: recovery also works on the NORMAL (unpaused) path.
    //     The F-2 pause-exempt entrypoint must not have broken the ordinary
    //     unpaused dispute-resolution flow.
    // ───────────────────────────────────────────────────────────────────────
    function test_D_Unpause_RecoveryStillWorks_fundsNotLost() external {
        bytes32 txId = _disputed();
        bond.openDispute(txId);
        bytes32 disputeId = keccak256(abi.encode("ACTP_DISPUTE_V1", txId));

        vm.warp(block.timestamp + 31 days);

        // Pause then unpause: the ordinary (unpaused) recovery path is unaffected by F-2.
        kernel.pause();
        kernel.unpause();
        assertFalse(kernel.paused(), "kernel unpaused");

        vm.prank(keeper);
        bond.forceResolveStale(disputeId);

        IACTPKernel.State st = kernel.getTransaction(txId).state;
        assertTrue(
            st == IACTPKernel.State.SETTLED || st == IACTPKernel.State.CANCELLED,
            "on the unpaused path, dispute resolves and txn leaves DISPUTED"
        );
        assertEq(escrow.remaining(txId), 0, "escrow released on the normal path");
    }
}
