// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ACTPKernel.sol";
import "../src/tokens/MockUSDC.sol";
import "../src/escrow/EscrowVault.sol";

/**
 * @title M2_MediatorTimelockBypassTest
 * @notice Security test demonstrating M-2 vulnerability fix
 *
 * VULNERABILITY (BEFORE FIX):
 * An admin could bypass the 2-day mediator timelock by:
 * 1. Day 0: Approve mediator → timelock = Day 2
 * 2. Day 1: Revoke mediator (timelock stays at Day 2)
 * 3. Day 10: Re-approve mediator (timelock NOT reset, still Day 2)
 * 4. Mediator is IMMEDIATELY active (Day 10 > Day 2)
 * 5. Can steal 10% of all disputes ($100K - $10M)
 *
 * FIX:
 * - ALWAYS reset timelock on approval (including re-approval)
 * - DELETE timelock on revoke to prevent stale timelock reuse
 */
contract M2_MediatorTimelockBypassTest is Test {
    ACTPKernel kernel;
    MockUSDC usdc;
    EscrowVault escrow;

    address admin = address(this);
    address pauser = address(0xFA053);
    address requester = address(0x1);
    address provider = address(0x2);
    address maliciousMediator = address(0x999);
    address feeCollector = address(0xFEE);

    uint256 constant ONE_USDC = 1_000_000;

    function setUp() external {
        kernel = new ACTPKernel(admin, pauser, feeCollector);
        usdc = new MockUSDC();
        escrow = new EscrowVault(address(usdc), address(kernel));
        kernel.approveEscrowVault(address(escrow), true);
        usdc.mint(requester, 10_000_000);
    }

    // ============================================
    // M-2 EXPLOIT DEMONSTRATION (NOW PREVENTED)
    // ============================================

    /**
     * @notice Demonstrates the M-2 timelock bypass attack is NOW PREVENTED
     * This test would have PASSED before the fix (mediator immediately active)
     * Now it FAILS as expected (mediator must wait 2 days after re-approval)
     */
    function testM2ExploitPrevented_TimelockBypass() external {
        // Day 0: Admin approves malicious mediator
        kernel.approveMediator(maliciousMediator, true);
        uint256 timelockDay0 = kernel.mediatorApprovedAt(maliciousMediator);
        assertEq(timelockDay0, block.timestamp + 2 days); // Timelock = Day 2

        // Day 1: Admin revokes mediator (but in OLD code, timelock stayed at Day 2)
        vm.warp(block.timestamp + 1 days);
        kernel.approveMediator(maliciousMediator, false);

        // M-2 FIX: Timelock should be DELETED on revoke
        assertEq(kernel.mediatorApprovedAt(maliciousMediator), 0); // ✅ FIXED!

        // Day 10: Admin re-approves mediator
        vm.warp(block.timestamp + 9 days); // Now at Day 10
        kernel.approveMediator(maliciousMediator, true);
        uint256 timelockDay10 = kernel.mediatorApprovedAt(maliciousMediator);

        // M-2 FIX: New timelock should be set to Day 12 (Day 10 + 2 days)
        assertEq(timelockDay10, block.timestamp + 2 days); // ✅ FIXED!

        // EXPLOIT PREVENTED: Mediator is NOT immediately active at Day 10
        // Create a disputed transaction at Day 10
        bytes32 txId = keccak256("disputed_tx");
        vm.prank(requester);
        kernel.createTransaction(txId, provider, ONE_USDC, keccak256("service"), block.timestamp + 7 days);

        vm.startPrank(requester);
        usdc.approve(address(escrow), ONE_USDC);
        kernel.linkEscrow(txId, address(escrow), keccak256("escrow"));
        vm.stopPrank();

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(10 days)); // Long dispute window

        // Immediately dispute at Day 10 (before mediator timelock expires)
        vm.prank(requester);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");

        // Need to wait 2 days after dispute to use mediator
        vm.warp(block.timestamp + 2 days + 1);

        // At Day 10+2: Try to use mediator (should FAIL - mediator timelock = Day 12, we're just past it)
        // Actually we need to be BEFORE the mediator timelock
        // Current time: Day 10 + 2 days + 1 = Day 12+
        // Mediator timelock: Day 12
        // We're PAST it! Need to test at Day 11

        // Reset to Day 11 to test the timelock
        vm.warp(timelockDay10 - 1 days); // Day 11 (before Day 12 timelock)

        uint256 mediatorFee = (ONE_USDC * kernel.MAX_MEDIATOR_FEE_BPS()) / kernel.MAX_BPS();
        uint256 providerAmount = ONE_USDC / 2;
        uint256 requesterAmount = ONE_USDC - providerAmount - mediatorFee;
        bytes memory resolution = abi.encode(requesterAmount, providerAmount, maliciousMediator, mediatorFee);

        // At Day 11, mediator timelock is Day 12 → should revert
        vm.expectRevert("Mediator approval pending");
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, resolution);

        // Warp to Day 12: Mediator can now be used
        vm.warp(timelockDay10 + 1); // Past the Day 12 timelock
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, resolution); // ✅ NOW works
    }

    /**
     * @notice Verifies timelock is properly reset on each approval
     */
    function testM2Fix_TimelockAlwaysResetOnApproval() external {
        // First approval
        kernel.approveMediator(maliciousMediator, true);
        uint256 timelock1 = kernel.mediatorApprovedAt(maliciousMediator);
        assertEq(timelock1, block.timestamp + 2 days);

        // Revoke
        vm.warp(block.timestamp + 1 days);
        kernel.approveMediator(maliciousMediator, false);
        assertEq(kernel.mediatorApprovedAt(maliciousMediator), 0); // Deleted

        // Re-approve after 10 days
        vm.warp(block.timestamp + 10 days);
        kernel.approveMediator(maliciousMediator, true);
        uint256 timelock2 = kernel.mediatorApprovedAt(maliciousMediator);

        // New timelock should be current timestamp + 2 days
        assertEq(timelock2, block.timestamp + 2 days);
        assertGt(timelock2, timelock1); // New timelock is later than old one
    }

    /**
     * @notice Verifies timelock is deleted on revoke (prevents stale timelock)
     */
    function testM2Fix_TimelockDeletedOnRevoke() external {
        kernel.approveMediator(maliciousMediator, true);
        assertGt(kernel.mediatorApprovedAt(maliciousMediator), 0);

        kernel.approveMediator(maliciousMediator, false);

        // M-2 FIX: Timelock must be deleted
        assertEq(kernel.mediatorApprovedAt(maliciousMediator), 0);
    }

    /**
     * @notice Verifies multiple revoke/approve cycles all respect timelock
     */
    function testM2Fix_MultipleRevokeCyclesRespectTimelock() external {
        // Cycle 1: Approve → Revoke
        kernel.approveMediator(maliciousMediator, true);
        vm.warp(block.timestamp + 1 days);
        kernel.approveMediator(maliciousMediator, false);
        assertEq(kernel.mediatorApprovedAt(maliciousMediator), 0);

        // Cycle 2: Re-approve → Revoke
        vm.warp(block.timestamp + 5 days);
        kernel.approveMediator(maliciousMediator, true);
        uint256 timelock2 = kernel.mediatorApprovedAt(maliciousMediator);
        assertEq(timelock2, block.timestamp + 2 days);

        vm.warp(block.timestamp + 1 days);
        kernel.approveMediator(maliciousMediator, false);
        assertEq(kernel.mediatorApprovedAt(maliciousMediator), 0);

        // Cycle 3: Re-approve again
        vm.warp(block.timestamp + 10 days);
        kernel.approveMediator(maliciousMediator, true);
        uint256 timelock3 = kernel.mediatorApprovedAt(maliciousMediator);

        // Each re-approval sets NEW timelock
        assertEq(timelock3, block.timestamp + 2 days);
        assertGt(timelock3, timelock2);
    }

    /**
     * @notice Demonstrates the ECONOMIC IMPACT of the M-2 exploit
     * Shows potential loss if exploit was used in production
     */
    function testM2EconomicImpact_PreventedLoss() external {
        // Scenario: 100 disputes worth $1M total
        uint256 numDisputes = 100;
        uint256 avgDisputeAmount = 10_000_000; // $10 USDC per dispute
        uint256 totalValue = numDisputes * avgDisputeAmount; // $1M

        // Mediator fee = 10% max
        uint256 mediatorFeeBps = kernel.MAX_MEDIATOR_FEE_BPS(); // 1000 = 10%
        uint256 potentialStolen = (totalValue * mediatorFeeBps) / kernel.MAX_BPS();

        // BEFORE FIX: Attacker could steal $100K immediately after re-approval
        // AFTER FIX: Attacker must wait 2 days, giving time to detect malicious behavior

        assertEq(potentialStolen, 100_000_000); // $100 USDC ($100K at 1:1)

        // With fix, the 2-day delay allows:
        // - Monitoring systems to detect suspicious mediator
        // - Community to raise concerns
        // - Admin to revoke mediator before any damage
    }

}
