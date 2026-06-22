// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {AIRuling} from "./DisputeTypes.sol";

/// @title IBondEscalation — core dispute lifecycle accessible to external callers (AIP-14b §7.1).
/// @notice Tier-1 bond-escalation game + Tier-2 UMA bridge. The kernel remains the sole fund
///         authority; this contract holds only its own Tier-1 escalation bonds (`accumulatedBonds`).
interface IBondEscalation {
    // --- Events ---
    event DisputeOpened(bytes32 indexed disputeId, bytes32 indexed txId, uint256 escrowAmount, address opener);
    event DirectProposalSubmitted(
        bytes32 indexed disputeId, uint8 ruling, uint16 splitBps, address indexed proposer, uint256 bond
    );
    event AIRulingSubmitted(
        bytes32 indexed disputeId, uint8 ruling, uint16 confidence, address indexed submitter, uint256 bond
    );
    event ChallengeSubmitted(
        bytes32 indexed disputeId, uint8 counterRuling, uint16 counterSplitBps, address indexed challenger, uint256 bond
    );
    event DisputeFinalized(
        bytes32 indexed disputeId, uint8 ruling, address indexed winner, address indexed finalizer, uint256 bounty
    );
    event EscalationRefundClaimed(bytes32 indexed disputeId, address indexed claimant, uint256 share);
    /// @dev `kernelState` is the kernel's State enum value (typed as uint8 to keep this interface
    ///      decoupled from IACTPKernel).
    event ExternalResolutionSynced(bytes32 indexed disputeId, bytes32 indexed txId, uint8 kernelState);
    event StaleDisputeResolved(bytes32 indexed disputeId, address indexed caller);
    event EscalatedToUMA(
        bytes32 indexed disputeId, bytes32 indexed assertionId, address indexed escalator, uint256 bond, string evidenceCID
    );
    event UMAResolutionReceived(
        bytes32 indexed disputeId, bytes32 indexed assertionId, uint8 ruling, address winner, uint256 payout
    );
    event UMACallbackIgnored(bytes32 indexed disputeId, bytes32 indexed assertionId, string reason);
    event UMADisputeEscalated(bytes32 indexed disputeId, bytes32 indexed assertionId);

    // --- Dispute Lifecycle ---
    function openDispute(bytes32 txId) external returns (bytes32 disputeId);
    function submitAIRuling(bytes32 disputeId, AIRuling calldata ruling, bytes[] calldata signatures) external;
    function proposeDirectly(bytes32 disputeId, uint8 ruling, uint16 splitBps) external;
    function challenge(bytes32 disputeId, uint8 counterRuling, uint16 counterSplitBps) external;
    function finalize(bytes32 disputeId) external;
    function escalateToUMA(bytes32 disputeId, string calldata evidenceCID) external;

    // --- Recovery & Sync (never pausable, INV-9) ---
    function syncExternalResolution(bytes32 disputeId) external;
    function forceResolveStale(bytes32 disputeId) external;
    function claimEscalationRefund(bytes32 disputeId) external;
}
