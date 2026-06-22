// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/// @title IBondEscalationAdmin — governance & admin surface (AIP-14b §7.2, §4.9).
/// @notice Restricted to admin or timelocked-governance patterns. Fixed-evaluator updates and
///         rotating-pool additions are timelocked (EVALUATOR_UPDATE_DELAY = 2 days, INV-17);
///         rotating-pool removals are immediate.
interface IBondEscalationAdmin {
    // --- Governance Events (§4.9) ---
    event FixedEvaluatorUpdateProposed(uint8 indexed slot, address newEvaluator, uint64 unlockTime);
    event FixedEvaluatorUpdated(uint8 indexed slot, address evaluator);
    event FixedEvaluatorUpdateCancelled(uint8 indexed slot);
    event RotatingPoolAdditionProposed(address evaluator, uint64 unlockTime);
    event RotatingPoolUpdated(address evaluator, bool added);

    // --- Pause Control (does NOT gate recovery paths, INV-9) ---
    function pause() external; // onlyAdmin
    function unpause() external; // onlyAdmin

    // --- Evaluator Registry Governance (§4.9) ---
    function proposeFixedEvaluatorUpdate(uint8 slot, address newEvaluator) external; // onlyAdmin, timelocked
    function executeFixedEvaluatorUpdate(uint8 slot) external; // after timelock
    function cancelFixedEvaluatorUpdate(uint8 slot) external; // onlyAdmin
    function proposeRotatingPoolAddition(address evaluator) external; // onlyAdmin, timelocked
    function executeRotatingPoolAddition(uint256 index) external; // after timelock
    function removeFromRotatingPool(uint256 index) external; // onlyAdmin, immediate
}
