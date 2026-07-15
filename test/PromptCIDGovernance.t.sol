// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DisputeTestBase} from "./helpers/DisputeTestBase.sol";

/// @title PromptCIDGovernanceTest — §4.2 on-chain canonical-prompt-CID governance (HIGH-1 closure).
/// @notice The evaluator prompt CID is committed on-chain and governed by the same 2-day
///         EVALUATOR_UPDATE_DELAY as evaluator changes (mirrors proposeFixedEvaluatorUpdate). Genesis =
///         the first propose+execute, run in parallel with the mediator-approval timelock — no separate
///         non-timelocked init surface. The AI ruling is advisory, so this is a transparency commitment,
///         not a fund path; tests assert access control, the timelock, the state machine, and events.
contract PromptCIDGovernanceTest is DisputeTestBase {
    uint64 internal constant DELAY = 2 days; // mirrors BondEscalation.EVALUATOR_UPDATE_DELAY
    address internal outsider = address(0xBAD);

    string internal constant CID_A = "ipfs://bafkreigenesispromptaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    string internal constant CID_B = "ipfs://bafkreiupdatedpromptbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    // mirror events for vm.expectEmit (must match IBondEscalationAdmin signatures exactly)
    event PromptCIDProposed(string newCID, uint64 unlockTime);
    event PromptCIDUpdated(string cid);
    event PromptCIDProposalCancelled();

    function setUp() external {
        _setUpStack();
    }

    // --- genesis happy path: propose -> wait -> execute ---
    function test_Genesis_ProposeWaitExecute_SetsActive() external {
        assertEq(bytes(bondEscalation.activePromptCID()).length, 0, "active starts empty");

        bondEscalation.proposePromptCID(CID_A);
        assertEq(bondEscalation.pendingPromptCID(), CID_A, "pending set");
        assertEq(bondEscalation.promptCIDUnlockTime(), uint64(block.timestamp) + DELAY, "unlock set");
        assertEq(bytes(bondEscalation.activePromptCID()).length, 0, "active still empty pre-timelock");

        vm.warp(block.timestamp + DELAY);
        bondEscalation.executePromptCID();
        assertEq(bondEscalation.activePromptCID(), CID_A, "active = CID_A after execute");
        assertEq(bytes(bondEscalation.pendingPromptCID()).length, 0, "pending cleared");
        assertEq(bondEscalation.promptCIDUnlockTime(), 0, "unlock cleared");
    }

    // --- timelock enforced ---
    function test_Execute_BeforeTimelock_Reverts() external {
        bondEscalation.proposePromptCID(CID_A);
        vm.warp(block.timestamp + DELAY - 1);
        vm.expectRevert("Timelock active");
        bondEscalation.executePromptCID();
    }

    function test_Execute_NoPending_Reverts() external {
        vm.expectRevert("No pending update");
        bondEscalation.executePromptCID();
    }

    // --- update path (active already set) replaces ---
    function test_Update_ProposeExecute_Replaces() external {
        bondEscalation.proposePromptCID(CID_A);
        vm.warp(block.timestamp + DELAY);
        bondEscalation.executePromptCID();

        bondEscalation.proposePromptCID(CID_B);
        assertEq(bondEscalation.activePromptCID(), CID_A, "active stays CID_A during update timelock");
        vm.warp(block.timestamp + DELAY);
        bondEscalation.executePromptCID();
        assertEq(bondEscalation.activePromptCID(), CID_B, "active = CID_B after update");
    }

    // --- cancel clears the pending proposal ---
    function test_Cancel_ClearsPending() external {
        bondEscalation.proposePromptCID(CID_A);
        bondEscalation.cancelPromptCID();
        assertEq(bytes(bondEscalation.pendingPromptCID()).length, 0, "pending cleared");
        assertEq(bondEscalation.promptCIDUnlockTime(), 0, "unlock cleared");
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert("No pending update");
        bondEscalation.executePromptCID();
    }

    // --- access control + validation ---
    function test_Propose_NonAdmin_Reverts() external {
        vm.prank(outsider);
        vm.expectRevert();
        bondEscalation.proposePromptCID(CID_A);
    }

    function test_Propose_EmptyCID_Reverts() external {
        vm.expectRevert("Empty CID");
        bondEscalation.proposePromptCID("");
    }

    function test_Cancel_NonAdmin_Reverts() external {
        bondEscalation.proposePromptCID(CID_A);
        vm.prank(outsider);
        vm.expectRevert();
        bondEscalation.cancelPromptCID();
    }

    // --- execute is PERMISSIONLESS after the delay (mirrors executeFixedEvaluatorUpdate) ---
    function test_Execute_PermissionlessAfterDelay() external {
        bondEscalation.proposePromptCID(CID_A);
        vm.warp(block.timestamp + DELAY);
        vm.prank(outsider); // not admin
        bondEscalation.executePromptCID();
        assertEq(bondEscalation.activePromptCID(), CID_A, "anyone may execute post-timelock");
    }

    // --- events ---
    function test_Events_ProposeAndUpdate() external {
        vm.expectEmit(false, false, false, true);
        emit PromptCIDProposed(CID_A, uint64(block.timestamp) + DELAY);
        bondEscalation.proposePromptCID(CID_A);

        vm.warp(block.timestamp + DELAY);
        vm.expectEmit(false, false, false, true);
        emit PromptCIDUpdated(CID_A);
        bondEscalation.executePromptCID();
    }
}
