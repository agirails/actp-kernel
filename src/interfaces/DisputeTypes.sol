// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/// @title DisputeTypes — shared types for the AIP-14b three-tier dispute system.
/// @notice The AIRuling field order MUST match AIP-14b §4.4 exactly: it is hashed into the
///         EIP-712 RULING_TYPEHASH, so any reorder breaks signature verification across the
///         off-chain evaluator, the SDK, and the on-chain `_verifyEvaluatorSignatures`.
struct AIRuling {
    bytes32 disputeId;
    uint8 ruling;        // 0 = provider wins, 1 = requester wins, 2 = split (INV-1)
    uint16 confidence;   // basis points
    uint16 splitBps;     // provider share when ruling == 2
    uint64 timestamp;
    bytes32 reasoningHash;
    bytes32 bundleHash;
}
