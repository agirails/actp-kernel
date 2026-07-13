// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {DisputeTestBase} from "../helpers/DisputeTestBase.sol";
import {BondEscalation} from "../../src/BondEscalation.sol";
import {IACTPKernel} from "../../src/interfaces/IACTPKernel.sol";
import {ICompositeMediator} from "../../src/interfaces/ICompositeMediator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AIRuling} from "../../src/interfaces/DisputeTypes.sol";

/// @dev [Apex F-C] A treasury that ACKS receiveFunds but never pulls — must not leave a
///      dangling allowance from the kernel.
contract NoPullTreasury {
    function receiveFunds(uint256) external {}
}

/**
 * @title ApexSecurityRead2026_07_12
 * @notice Regression anchors for the fixes landed in response to Apex's 2026-07-12
 *         pre-audit security read (H2/H4 + F-3/F-9/F-10/F-11/F-II/F-III/F-C).
 *         The superseded-semantics updates live in the pre-existing suites; this file
 *         adds the POSITIVE coverage of each new guard.
 */
contract ApexSecurityRead2026_07_12 is DisputeTestBase {
    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event AdminTransferInitiated(address indexed currentAdmin, address indexed pendingAdmin);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);

    function setUp() public {
        _setUpStack();
    }

    function _opened() internal returns (bytes32 disputeId) {
        bytes32 txId = _createDisputed();
        disputeId = bondEscalation.openDispute(txId);
    }

    // =====================================================================
    // H2 — forceResolveStale tier guard (positive: tier-1 unaffected)
    // =====================================================================

    /// @notice A tier-1 (non-UMA) dispute still force-resolves at the plain 30-day mark —
    ///         the Apex H2 grace applies ONLY to tier-2. (Tier-2 blocked/extended cases are
    ///         asserted in BondEscalation.t / ThreatModel / UMAIntegration.)
    function test_ApexH2_Tier1_ForceStale_StillWorksAt30Days() external {
        bytes32 disputeId = _opened();
        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), type(uint256).max);
        bondEscalation.proposeDirectly(disputeId, 0, 0); // tier 1
        vm.stopPrank();

        (, , , , , , uint64 disputedAt, , uint8 tier, , , , ) = bondEscalation.disputes(disputeId);
        assertEq(tier, 1, "precondition: tier 1");

        vm.warp(uint256(disputedAt) + 30 days + 1);
        bondEscalation.forceResolveStale(disputeId);
        (, uint8 ruling, uint16 splitBps, , , , , , , bool resolved, , , ) = bondEscalation.disputes(disputeId);
        assertTrue(resolved);
        assertEq(ruling, 2);
        assertEq(splitBps, 5000);
    }

    // =====================================================================
    // F-9 — future-dated ruling timestamp
    // =====================================================================

    function test_ApexF9_FutureDatedRuling_Rejected() external {
        bytes32 disputeId = _opened();
        AIRuling memory r = _ruling(disputeId, 1, 0);
        r.timestamp = uint64(block.timestamp + 6 minutes); // beyond the 5-minute skew

        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signRuling(r, fixed0Pk);
        sigs[1] = _signRuling(r, fixed1Pk);

        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), type(uint256).max);
        vm.expectRevert("Ruling timestamp in future");
        bondEscalation.submitAIRuling(disputeId, r, EVIDENCE_CID, REASONING_CID, sigs);
        vm.stopPrank();
    }

    function test_ApexF9_SmallClockSkew_Tolerated() external {
        bytes32 disputeId = _opened();
        AIRuling memory r = _ruling(disputeId, 1, 0);
        r.timestamp = uint64(block.timestamp + 4 minutes); // within the 5-minute skew

        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signRuling(r, fixed0Pk);
        sigs[1] = _signRuling(r, fixed1Pk);

        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), type(uint256).max);
        bondEscalation.submitAIRuling(disputeId, r, EVIDENCE_CID, REASONING_CID, sigs); // must NOT revert
        vm.stopPrank();
    }

    // =====================================================================
    // F-10 — post-fork domain separator
    // =====================================================================

    function test_ApexF10_DomainSeparator_RecomputedAfterFork() external {
        bytes32 before = bondEscalation.DOMAIN_SEPARATOR();
        vm.chainId(99999);
        bytes32 afterFork = bondEscalation.DOMAIN_SEPARATOR();
        assertTrue(before != afterFork, "separator must track the live chainid");
    }

    function test_ApexF10_PreForkSignatures_RejectedAfterFork() external {
        bytes32 disputeId = _opened();
        AIRuling memory r = _ruling(disputeId, 1, 0);
        // Sign under the CURRENT chainid domain…
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signRuling(r, fixed0Pk);
        sigs[1] = _signRuling(r, fixed1Pk);
        // …then fork: the pre-fork signatures must not verify (no cross-fork replay).
        vm.chainId(99999);
        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), type(uint256).max);
        vm.expectRevert("Insufficient valid signatures");
        bondEscalation.submitAIRuling(disputeId, r, EVIDENCE_CID, REASONING_CID, sigs);
        vm.stopPrank();
    }

    // =====================================================================
    // F-3 / F-11 — rotating-pool dedup + size cap
    // =====================================================================

    function test_ApexF3_Constructor_RejectsDuplicateRotating() external {
        address[2] memory fixedEvals = [fixed0, fixed1];
        address[] memory pool = new address[](2);
        pool[0] = rotating0;
        pool[1] = rotating0; // duplicate
        vm.expectRevert("Duplicate rotating");
        new BondEscalation(
            IACTPKernel(address(kernel)), IERC20(address(usdc)),
            ICompositeMediator(address(compositeMediator)), admin, fixedEvals, pool, address(oov3)
        );
    }

    function test_ApexF3_ProposeDuplicateRotating_Reverts() external {
        vm.expectRevert("Duplicate rotating");
        bondEscalation.proposeRotatingPoolAddition(rotating0); // already in the pool
    }

    function test_ApexF3_ExecuteTimeDuplicate_Caught() external {
        // Two identical additions can be QUEUED (the pool does not contain X yet)…
        address x = address(0xD0D0);
        bondEscalation.proposeRotatingPoolAddition(x);
        bondEscalation.proposeRotatingPoolAddition(x);
        vm.warp(block.timestamp + 2 days);
        bondEscalation.executeRotatingPoolAddition(0);
        // …but the second execute must catch the now-duplicate at execute time.
        vm.expectRevert("Duplicate rotating");
        bondEscalation.executeRotatingPoolAddition(0);
    }

    function test_ApexF11_Constructor_RejectsOversizedPool() external {
        address[2] memory fixedEvals = [fixed0, fixed1];
        address[] memory pool = new address[](33); // MAX_ROTATING_POOL = 32
        for (uint160 i = 0; i < 33; i++) {
            pool[i] = address(uint160(0xF000) + i);
        }
        vm.expectRevert("Rotating pool too large");
        new BondEscalation(
            IACTPKernel(address(kernel)), IERC20(address(usdc)),
            ICompositeMediator(address(compositeMediator)), admin, fixedEvals, pool, address(oov3)
        );
    }

    // =====================================================================
    // H4 — vault revocation timelock
    // =====================================================================

    function test_ApexH4_SettlementUnaffectedWhileRevocationPending() external {
        // Schedule a revocation of the LIVE vault; in-flight settlement must keep working
        // during the whole 2-day window (that window is the point of the timelock).
        kernel.scheduleEscrowVaultRevocation(address(escrow));

        bytes32 txId = _createDisputed();
        bytes32 disputeId = bondEscalation.openDispute(txId);
        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), type(uint256).max);
        bondEscalation.proposeDirectly(disputeId, 1, 0); // requester wins
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days); // still inside the revocation window
        bondEscalation.finalize(disputeId);
        assertEq(
            uint8(kernel.getTransaction(txId).state),
            uint8(IACTPKernel.State.SETTLED),
            "settlement must work while a revocation is pending"
        );
    }

    function test_ApexH4_ScheduleGuards() external {
        vm.expectRevert("Vault not approved");
        kernel.scheduleEscrowVaultRevocation(address(0xDEAD));

        kernel.scheduleEscrowVaultRevocation(address(escrow));
        vm.expectRevert("Revocation already scheduled");
        kernel.scheduleEscrowVaultRevocation(address(escrow));

        vm.prank(rando);
        vm.expectRevert(); // onlyAdmin — a stranger cannot cancel-by-reapprove
        kernel.approveEscrowVault(address(escrow), true);

        // Execute is PERMISSIONLESS post-timelock (admin cannot be forced to hold it back).
        vm.warp(block.timestamp + 2 days);
        vm.prank(rando);
        kernel.executeEscrowVaultRevocation(address(escrow));
        assertFalse(kernel.approvedEscrowVaults(address(escrow)));
    }

    // =====================================================================
    // F-III — pause events + two-step admin rotation (BondEscalation)
    // =====================================================================

    function test_ApexFIII_PauseUnpause_EmitEvents() external {
        vm.expectEmit(true, false, false, false, address(bondEscalation));
        emit Paused(address(this));
        bondEscalation.pause();

        vm.expectEmit(true, false, false, false, address(bondEscalation));
        emit Unpaused(address(this));
        bondEscalation.unpause();
    }

    function test_ApexFIII_TwoStepAdminRotation() external {
        address newAdmin = address(0xA11CE);

        vm.prank(rando);
        vm.expectRevert("Only admin");
        bondEscalation.transferAdmin(newAdmin);

        vm.expectEmit(true, true, false, false, address(bondEscalation));
        emit AdminTransferInitiated(address(this), newAdmin);
        bondEscalation.transferAdmin(newAdmin);

        // Authority does NOT move until acceptance; only the nominee can accept.
        assertEq(bondEscalation.admin(), address(this));
        vm.prank(rando);
        vm.expectRevert("Not pending admin");
        bondEscalation.acceptAdmin();

        vm.prank(newAdmin);
        vm.expectEmit(true, true, false, false, address(bondEscalation));
        emit AdminTransferred(address(this), newAdmin);
        bondEscalation.acceptAdmin();
        assertEq(bondEscalation.admin(), newAdmin);
        assertEq(bondEscalation.pendingAdmin(), address(0));
    }

    // =====================================================================
    // F-C — no dangling allowance toward a no-pull treasury
    // =====================================================================

    function test_ApexFC_NoPullTreasury_LeavesZeroAllowance() external {
        NoPullTreasury treasury = new NoPullTreasury();
        kernel.setArchiveTreasury(address(treasury));

        bytes32 txId = _createDisputed();
        bytes32 disputeId = bondEscalation.openDispute(txId);
        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), type(uint256).max);
        bondEscalation.proposeDirectly(disputeId, 0, 0); // provider wins → fee path runs
        vm.stopPrank();
        vm.warp(block.timestamp + 5 hours);
        bondEscalation.finalize(disputeId);

        assertEq(
            usdc.allowance(address(kernel), address(treasury)),
            0,
            "no live allowance may dangle toward the treasury"
        );
    }
}
