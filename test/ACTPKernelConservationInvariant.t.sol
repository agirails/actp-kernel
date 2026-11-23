// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ACTPKernel.sol";
import "../src/tokens/MockUSDC.sol";
import "../src/escrow/EscrowVault.sol";

/**
 * ACTPKernelConservationInvariant — P3 (Codex audit 2026-07-16) stateful fuzz campaign for the
 * "Global USDC conservation" property family that the audit's STATEFUL-FUZZING-CAMPAIGNS.md marks
 * PARTIAL (the existing invariant suite covers BondEscalation, not the kernel escrow/fee paths).
 *
 * The handler drives randomized create→deliver→settle and create→milestone sequences through the
 * REAL kernel + EscrowVault + MockUSDC (every action try/catch-guarded so a bounced `require` does
 * not abort the sequence — Foundry `fail_on_revert=false`). Two invariants hold after every step:
 *   - INV: no USDC is created or destroyed — the sum across every actor + the escrow + the kernel
 *     equals the initial mint (catches double-release / repeated-fee-charge / dust drift, the class
 *     of the deferred F17/F59 economic findings).
 *   - INV: the kernel is NON-CUSTODIAL — it never holds USDC (all funds live in the vault).
 */
contract KernelConservationHandler is Test {
    ACTPKernel public kernel;
    MockUSDC public usdc;
    EscrowVault public escrow;

    address public requester = address(0xA11CE);
    address public provider = address(0xB0B);
    address public feeCollector = address(0xFEE);

    uint256 public constant ONE_USDC = 1_000_000;

    bytes32[] public delivered; // txIds sitting in DELIVERED, awaiting settle
    uint256 internal salt;

    // ghost counters (surfaced for run visibility — proves the sequence is NOT all-revert)
    uint256 public settles;
    uint256 public milestones;

    constructor(ACTPKernel _kernel, MockUSDC _usdc, EscrowVault _escrow) {
        kernel = _kernel;
        usdc = _usdc;
        escrow = _escrow;
    }

    /// Full self-contained lifecycle: create→quote→commit(fund)→deliver→(warp)→settle.
    function createDeliverSettle(uint96 amtRaw) external {
        uint256 amount = bound(uint256(amtRaw), kernel.MIN_FEE() + 1, ONE_USDC);
        if (usdc.balanceOf(requester) < amount) return; // requester tapped out — skip (conservation intact)
        bytes32 escrowId = keccak256(abi.encode("cons", salt++));

        try this._runToDelivered(amount, escrowId) returns (bytes32 txId) {
            vm.warp(block.timestamp + 2 days + 1);
            vm.prank(provider);
            try kernel.transitionState(txId, IACTPKernel.State.SETTLED, "") {
                settles++;
            } catch {
                delivered.push(txId); // settle bounced — leave it for a later attempt
            }
        } catch {
            // create/quote/commit/deliver bounced — nothing committed, conservation intact
        }
    }

    /// create→quote→commit→IN_PROGRESS→releaseMilestone (exercises the per-fragment fee path).
    function partialMilestone(uint96 amtRaw, uint96 msRaw) external {
        uint256 amount = bound(uint256(amtRaw), kernel.MIN_FEE() + 1, ONE_USDC);
        if (usdc.balanceOf(requester) < amount) return;
        bytes32 escrowId = keccak256(abi.encode("ms", salt++));

        try this._runToInProgress(amount, escrowId) returns (bytes32 txId) {
            uint256 ms = bound(uint256(msRaw), kernel.MIN_FEE() + 1, amount);
            vm.prank(requester);
            try kernel.releaseMilestone(txId, ms) {
                milestones++;
            } catch {}
        } catch {}
    }

    /// Settle a previously-stranded delivered tx (drains the `delivered` backlog).
    function settleBacklog(uint256 idxRaw) external {
        if (delivered.length == 0) return;
        uint256 i = bound(idxRaw, 0, delivered.length - 1);
        bytes32 txId = delivered[i];
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(provider);
        try kernel.transitionState(txId, IACTPKernel.State.SETTLED, "") {
            settles++;
            delivered[i] = delivered[delivered.length - 1];
            delivered.pop();
        } catch {}
    }

    // ---- external helpers so the try/catch above can wrap the whole multi-step flow ----

    function _runToDelivered(uint256 amount, bytes32 escrowId) external returns (bytes32 txId) {
        require(msg.sender == address(this));
        txId = _runToInProgress(amount, escrowId);
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(uint256(1 days), keccak256("result")));
    }

    function _runToInProgress(uint256 amount, bytes32 escrowId) public returns (bytes32 txId) {
        vm.prank(requester);
        txId = kernel.createTransaction(provider, requester, amount, block.timestamp + 2 days, 1 hours, keccak256("service"), bytes32(0), 0, 0);
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.QUOTED, "");
        vm.startPrank(requester);
        usdc.approve(address(escrow), amount);
        kernel.linkEscrow(txId, address(escrow), escrowId);
        vm.stopPrank();
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");
    }
}

contract ACTPKernelConservationInvariant is Test {
    ACTPKernel internal kernel;
    MockUSDC internal usdc;
    EscrowVault internal escrow;
    KernelConservationHandler internal handler;

    uint256 internal constant INITIAL_MINT = 1_000_000_000;
    address internal feeCollector = address(0xFEE);

    function setUp() external {
        usdc = new MockUSDC();
        kernel = new ACTPKernel(address(this), address(this), feeCollector, address(0), address(usdc), 1 hours);
        escrow = new EscrowVault(address(usdc), address(kernel));
        kernel.approveEscrowVault(address(escrow), true);

        handler = new KernelConservationHandler(kernel, usdc, escrow);
        usdc.mint(handler.requester(), INITIAL_MINT);

        targetContract(address(handler));
    }

    /// INV: USDC is conserved — nothing minted or burned across the whole lifecycle.
    function invariant_UsdcConservation() external view {
        uint256 total = usdc.balanceOf(handler.requester())
            + usdc.balanceOf(handler.provider())
            + usdc.balanceOf(feeCollector)
            + usdc.balanceOf(address(escrow))
            + usdc.balanceOf(address(kernel));
        assertEq(total, INITIAL_MINT, "USDC conservation violated");
    }

    /// INV: the kernel is non-custodial — it never holds USDC (all funds live in the vault).
    function invariant_KernelHoldsNoUsdc() external view {
        assertEq(usdc.balanceOf(address(kernel)), 0, "kernel custodies USDC");
    }
}
