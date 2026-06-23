// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ACTPKernel.sol";
import "../src/CompositeMediator.sol";
import "../src/tokens/MockUSDC.sol";
import "../src/escrow/EscrowVault.sol";
import {ICompositeMediator} from "../src/interfaces/ICompositeMediator.sol";

/// @title CompositeMediatorTest — P1-1: ruling → kernel-state mapping (AIP-14b §6).
/// @notice Exercises the thin CompositeMediator end-to-end against a real ACTPKernel +
///         EscrowVault. The mediator is wired as an approved+timelocked kernel resolver
///         (P0-3) and as the BondEscalation back-reference (G4 write-once init), then
///         driven through every ruling, the access guards, the init one-shot guard, and
///         the input-validation reverts.
///
///         Harness mirrors test/ResolverAuth.t.sol: MockUSDC + ACTPKernel(admin, pauser,
///         feeCollector, address(0), usdc) + EscrowVault(usdc, kernel); a fresh DISPUTED tx
///         per resolution via the replicated _disputed() helper.
contract CompositeMediatorTest is Test {
    ACTPKernel kernel;
    MockUSDC usdc;
    EscrowVault escrow;
    CompositeMediator mediator;

    address admin = address(this);
    address pauser = address(0xFA053);
    address requester = address(0x1);
    address provider = address(0x2);
    address rando = address(0xBAD);
    address feeCollector = address(0xFEE);

    // The wired dispute tier system (BondEscalation) is a test EOA — the ONLY caller
    // allowed to invoke mediator.resolve().
    address bondEscalation = address(0xB0AD);

    uint256 constant ONE_USDC = 1_000_000;
    uint256 constant TRANSACTION_AMOUNT = 1_000 * ONE_USDC;

    // Mirror of ICompositeMediator.DisputeSplitRecorded for vm.expectEmit.
    event DisputeSplitRecorded(
        bytes32 indexed txId,
        address indexed requester,
        address indexed provider,
        uint16 splitBps
    );

    function setUp() external {
        usdc = new MockUSDC();
        kernel = new ACTPKernel(admin, pauser, feeCollector, address(0), address(usdc), 1 hours);
        escrow = new EscrowVault(address(usdc), address(kernel));
        kernel.approveEscrowVault(address(escrow), true);
        usdc.mint(requester, 100_000 * ONE_USDC);
        usdc.mint(provider, 100_000 * ONE_USDC);

        // Deploy + wire the mediator.
        mediator = new CompositeMediator(IACTPKernel(address(kernel)));
        mediator.initialize(bondEscalation); // G4 write-once init (admin == deployer == address(this))

        // Kernel-side resolver auth (P0-3): approve as mediator + pass its 2-day timelock.
        kernel.approveMediator(address(mediator), true);
        vm.warp(block.timestamp + 2 days + 1);
    }

    // =========================================================================
    // RULINGS — each gets a fresh DISPUTED tx
    // =========================================================================

    /// @notice ruling 0 = provider wins → SETTLED.
    function test_Resolve_ProviderWins_Settled() external {
        bytes32 txId = _disputed();
        vm.prank(bondEscalation);
        mediator.resolve(txId, 0, 0);
        assertEq(uint8(kernel.getTransaction(txId).state), uint8(IACTPKernel.State.SETTLED));
    }

    /// @notice ruling 1 = requester wins → SETTLED.
    function test_Resolve_RequesterWins_Settled() external {
        bytes32 txId = _disputed();
        vm.prank(bondEscalation);
        mediator.resolve(txId, 1, 0);
        assertEq(uint8(kernel.getTransaction(txId).state), uint8(IACTPKernel.State.SETTLED));
    }

    /// @notice ruling 2 = split → CANCELLED, with DisputeSplitRecorded emitted BEFORE the
    ///         transition (INV-22). splitBps = 5000 (50/50) keeps both legs > 0.
    function test_Resolve_Split_Cancelled_EmitsSplitRecorded() external {
        bytes32 txId = _disputed();

        // INV-22: the neutral split trace fires before the kernel transition.
        vm.expectEmit(true, true, true, true, address(mediator));
        emit DisputeSplitRecorded(txId, requester, provider, 5000);

        vm.prank(bondEscalation);
        mediator.resolve(txId, 2, 5000);
        assertEq(uint8(kernel.getTransaction(txId).state), uint8(IACTPKernel.State.CANCELLED));
    }

    /// @notice Split actually moves the right amounts: 50% to provider (net of fee),
    ///         the remainder refunded to requester. Sanity that the 64-byte CANCELLED
    ///         proof maps to a real fund split, not just a state flip.
    function test_Resolve_Split_DistributesEscrow() external {
        bytes32 txId = _disputed();

        uint256 reqBefore = usdc.balanceOf(requester);
        uint256 provBefore = usdc.balanceOf(provider);

        vm.prank(bondEscalation);
        mediator.resolve(txId, 2, 5000);

        // Provider receives 50% of escrow net of the locked platform fee; requester gets
        // the other 50% refunded. Exact fee math is the kernel's; here we only assert that
        // both parties' balances strictly increased (escrow was apportioned, not stranded).
        assertGt(usdc.balanceOf(requester), reqBefore, "requester not refunded");
        assertGt(usdc.balanceOf(provider), provBefore, "provider not paid split share");
    }

    // =========================================================================
    // ZERO-REMAINING ESCROW (P1-1 review fix) — milestone-drained dispute
    // =========================================================================
    // A tx can reach DISPUTED with remaining == 0: releaseMilestone (requester-callable
    // in IN_PROGRESS) drains the escrow, then IN_PROGRESS → DELIVERED → DISPUTED. Before
    // the fix, the mediator forwarded an all-zero proof and the kernel decoder reverted
    // with "Empty resolution" BEFORE its `if (remaining > 0)` skip — deadlocking the
    // dispute. These tests prove resolve() now finalizes for every ruling without revert,
    // moves no escrow funds (there are none), and still returns the dispute bond.

    /// @notice ruling 0 over a fully-drained escrow → SETTLED, no revert, bond returned.
    function test_Resolve_ZeroRemaining_ProviderWins_NoRevert() external {
        bytes32 txId = _disputedDrained();
        assertEq(_remaining(txId), 0, "precondition: escrow must be drained");

        vm.prank(bondEscalation);
        mediator.resolve(txId, 0, 0); // must NOT revert
        assertEq(uint8(kernel.getTransaction(txId).state), uint8(IACTPKernel.State.SETTLED));
        assertEq(_remaining(txId), 0, "no escrow should move on a drained dispute");
    }

    /// @notice ruling 1 over a fully-drained escrow → SETTLED, no revert.
    function test_Resolve_ZeroRemaining_RequesterWins_NoRevert() external {
        bytes32 txId = _disputedDrained();
        assertEq(_remaining(txId), 0, "precondition: escrow must be drained");

        vm.prank(bondEscalation);
        mediator.resolve(txId, 1, 0); // must NOT revert
        assertEq(uint8(kernel.getTransaction(txId).state), uint8(IACTPKernel.State.SETTLED));
        assertEq(_remaining(txId), 0, "no escrow should move on a drained dispute");
    }

    /// @notice ruling 2 (split) over a fully-drained escrow → CANCELLED, no revert.
    ///         splitBps is irrelevant when remaining == 0; assert the split trace still fires.
    function test_Resolve_ZeroRemaining_Split_NoRevert() external {
        bytes32 txId = _disputedDrained();
        assertEq(_remaining(txId), 0, "precondition: escrow must be drained");

        vm.expectEmit(true, true, true, true, address(mediator));
        emit DisputeSplitRecorded(txId, requester, provider, 5000);

        vm.prank(bondEscalation);
        mediator.resolve(txId, 2, 5000); // must NOT revert
        assertEq(uint8(kernel.getTransaction(txId).state), uint8(IACTPKernel.State.CANCELLED));
        assertEq(_remaining(txId), 0, "no escrow should move on a drained dispute");
    }

    /// @notice The dispute bond (a separate deposit, not escrow `remaining`) is still
    ///         returned to the disputer on a drained-escrow resolution. Proves the
    ///         transition runs bond distribution even though escrow split was skipped.
    function test_Resolve_ZeroRemaining_BondStillReturned() external {
        bytes32 txId = _disputedDrained();
        uint256 reqBefore = usdc.balanceOf(requester); // requester is the disputer here

        vm.prank(bondEscalation);
        mediator.resolve(txId, 2, 5000); // CANCELLED → bond returns to disputer

        assertGt(usdc.balanceOf(requester), reqBefore, "dispute bond not returned to disputer");
    }

    // =========================================================================
    // ACCESS CONTROL — onlyBondEscalation
    // =========================================================================

    /// @notice A non-bondEscalation caller is rejected by the onlyBondEscalation modifier.
    function test_Resolve_NonBondEscalation_Reverts() external {
        bytes32 txId = _disputed();
        vm.prank(rando);
        vm.expectRevert("Only tier system");
        mediator.resolve(txId, 0, 0);
    }

    /// @notice Even the kernel admin / deployer cannot call resolve directly — only the
    ///         wired tier system may.
    function test_Resolve_Admin_Reverts() external {
        bytes32 txId = _disputed();
        vm.expectRevert("Only tier system");
        mediator.resolve(txId, 0, 0); // msg.sender == address(this) == admin/deployer
    }

    // =========================================================================
    // G4 WRITE-ONCE INIT
    // =========================================================================

    /// @notice initialize() is one-shot: a second call reverts.
    function test_Initialize_SecondCall_Reverts() external {
        // setUp already called initialize(bondEscalation) once.
        vm.expectRevert("Already initialized");
        mediator.initialize(address(0xCAFE));
    }

    /// @notice initialize() is deployer-only: a non-deployer call reverts.
    function test_Initialize_NonDeployer_Reverts() external {
        CompositeMediator fresh = new CompositeMediator(IACTPKernel(address(kernel)));
        vm.prank(rando);
        vm.expectRevert("Only deployer");
        fresh.initialize(bondEscalation);
    }

    /// @notice initialize() rejects a zero bondEscalation address.
    function test_Initialize_ZeroAddress_Reverts() external {
        CompositeMediator fresh = new CompositeMediator(IACTPKernel(address(kernel)));
        vm.expectRevert("bondEscalation=0");
        fresh.initialize(address(0));
    }

    // =========================================================================
    // INPUT VALIDATION
    // =========================================================================

    /// @notice ruling > 2 is rejected.
    function test_Resolve_InvalidRuling_Reverts() external {
        bytes32 txId = _disputed();
        vm.prank(bondEscalation);
        vm.expectRevert("Invalid ruling");
        mediator.resolve(txId, 3, 0);
    }

    /// @notice splitBps > 10000 is rejected.
    function test_Resolve_SplitBpsTooHigh_Reverts() external {
        bytes32 txId = _disputed();
        vm.prank(bondEscalation);
        vm.expectRevert("Invalid split");
        mediator.resolve(txId, 2, 10001);
    }

    /// @notice A non-split ruling (0) with splitBps != 0 is rejected.
    function test_Resolve_NonSplitWithBps_Reverts() external {
        bytes32 txId = _disputed();
        vm.prank(bondEscalation);
        vm.expectRevert("splitBps only for splits");
        mediator.resolve(txId, 0, 1);
    }

    // =========================================================================
    // constructor guard
    // =========================================================================

    /// @notice Constructor rejects a zero kernel.
    function test_Constructor_ZeroKernel_Reverts() external {
        vm.expectRevert("kernel=0");
        new CompositeMediator(IACTPKernel(address(0)));
    }

    // =========================================================================
    // helper: create a transaction and drive it to DISPUTED (mirrors ResolverAuth.t.sol)
    // =========================================================================
    function _disputed() internal returns (bytes32 txId) {
        vm.prank(requester);
        txId = kernel.createTransaction(
            provider, requester, TRANSACTION_AMOUNT, block.timestamp + 30 days, 2 days, keccak256("service"), 0, 0
        );

        vm.startPrank(requester);
        usdc.approve(address(escrow), TRANSACTION_AMOUNT);
        kernel.linkEscrow(txId, address(escrow), txId);
        vm.stopPrank();

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(10 days));

        uint256 bond = (TRANSACTION_AMOUNT * kernel.disputeBondBps()) / kernel.MAX_BPS();
        vm.startPrank(requester);
        usdc.approve(address(escrow), bond);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");
        vm.stopPrank();
    }

    // =========================================================================
    // helper: drive a tx to DISPUTED with the ESCROW FULLY DRAINED via milestones.
    // releaseMilestone(grossAmount) disburses provider-net + fee == grossAmount, so a
    // single release of the full `remaining` drives remaining → 0 (P1-1 precondition).
    // The dispute bond is a separate deposit, so DISPUTED still succeeds on a drained escrow.
    // =========================================================================
    function _disputedDrained() internal returns (bytes32 txId) {
        vm.prank(requester);
        txId = kernel.createTransaction(
            provider, requester, TRANSACTION_AMOUNT, block.timestamp + 30 days, 2 days, keccak256("service"), 0, 0
        );

        vm.startPrank(requester);
        usdc.approve(address(escrow), TRANSACTION_AMOUNT);
        kernel.linkEscrow(txId, address(escrow), txId);
        vm.stopPrank();

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");

        // Drain the entire escrow via a single milestone release (requester-callable).
        uint256 full = _remaining(txId);
        vm.prank(requester);
        kernel.releaseMilestone(txId, full);
        require(_remaining(txId) == 0, "drain helper failed to empty escrow");

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(10 days));

        uint256 bond = (TRANSACTION_AMOUNT * kernel.disputeBondBps()) / kernel.MAX_BPS();
        vm.startPrank(requester);
        usdc.approve(address(escrow), bond);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");
        vm.stopPrank();
    }

    /// @notice Read the escrow's remaining balance for a txId via the vault.
    function _remaining(bytes32 txId) internal view returns (uint256) {
        IACTPKernel.TransactionView memory txn = kernel.getTransaction(txId);
        return escrow.remaining(txn.escrowId);
    }
}
