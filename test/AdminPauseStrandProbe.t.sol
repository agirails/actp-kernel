// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ACTPKernel.sol";
import "../src/BondEscalation.sol";
import "../src/CompositeMediator.sol";
import "../src/tokens/MockUSDC.sol";
import "../src/escrow/EscrowVault.sol";

/// Probe (F-2 FIXED, regression test): pausing the KERNEL no longer transitively
/// bricks BondEscalation's NOT-pausable recovery paths (finalize / forceResolveStale).
/// CompositeMediator.resolve now routes its DISPUTED-exit through the pause-exempt
/// kernel.resolveDisputeWhilePaused, so honest recovery survives a pause (INV-9).
contract AdminPauseStrandProbe is Test {
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
            address(0xab1234) // non-zero dummy OOV3, Tier-2 not exercised here
        );
        mediator.initialize(address(bond));
        // Approve mediator (CompositeMediator) on kernel + timelock
        kernel.approveMediator(address(mediator), true);
        vm.warp(block.timestamp + 2 days + 1);

        usdc.mint(requester, 100_000 * ONE);
        usdc.mint(keeper, 100_000 * ONE);
    }

    function _disputed() internal returns (bytes32 txId) {
        vm.prank(requester);
        txId = kernel.createTransaction(provider, requester, AMT, block.timestamp + 30 days, 2 days, keccak256("svc"), 0, 0);
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

    function test_KernelPause_FinalizeSurvivesPause() external {
        bytes32 txId = _disputed();
        // open the BondEscalation dispute + a Tier-1 proposal
        bond.openDispute(txId);
        bytes32 disputeId = keccak256(abi.encode("ACTP_DISPUTE_V1", txId));
        vm.startPrank(keeper);
        usdc.approve(address(bond), type(uint256).max);
        bond.proposeDirectly(disputeId, 0, 0); // provider wins
        vm.stopPrank();

        // liveness expires
        vm.warp(block.timestamp + 9 hours);

        // ADMIN PAUSES THE KERNEL (not BondEscalation)
        kernel.pause();
        assertTrue(kernel.paused());

        // finalize() is documented NOT-pausable (INV-9). With F-2 it routes through the
        // pause-exempt resolver entrypoint, so it now SUCCEEDS while paused.
        vm.prank(keeper);
        bond.finalize(disputeId);

        assertEq(
            uint8(kernel.getTransaction(txId).state),
            uint8(IACTPKernel.State.SETTLED),
            "finalize resolved DISPUTED->SETTLED while paused"
        );
        assertEq(escrow.remaining(txId), 0, "escrow released during pause");
    }

    function test_KernelPause_ForceResolveStaleSurvivesPause() external {
        bytes32 txId = _disputed();
        bond.openDispute(txId);
        bytes32 disputeId = keccak256(abi.encode("ACTP_DISPUTE_V1", txId));

        // wait past MAX_DISPUTE_DURATION (30 days)
        vm.warp(block.timestamp + 31 days);

        kernel.pause();

        // The permissionless walk-away escape hatch now survives the pause (F-2).
        vm.prank(keeper);
        bond.forceResolveStale(disputeId);

        assertEq(
            uint8(kernel.getTransaction(txId).state),
            uint8(IACTPKernel.State.CANCELLED),
            "forceResolveStale resolved DISPUTED->CANCELLED while paused"
        );
        assertEq(escrow.remaining(txId), 0, "escrow released during pause");
    }
}
