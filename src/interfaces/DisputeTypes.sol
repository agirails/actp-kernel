// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/// @title DisputeTypes — shared types for the AIP-14b three-tier dispute system.
/// @notice The AIRuling field order MUST match AIP-14b §4.4 / AIP-14c §3.2 exactly: it is hashed into
///         the EIP-712 RULING_TYPEHASH, so any reorder breaks signature verification across the
///         off-chain evaluator, the SDK, and the on-chain `_verifyEvaluatorSignatures`.
/// @dev    AIP-14c (v2): `evidenceRefHash` and `reasoningRefHash` bind the evidence/reasoning CID
///         strings into the signature (bundleHash/reasoningHash alone do NOT cover the CID). Formulas:
///           evidenceRefHash  = keccak256(abi.encode(bundleHash,   keccak256(bytes(evidenceCID))))
///           reasoningRefHash = keccak256(abi.encode(reasoningHash, keccak256(bytes(reasoningCID))))
struct AIRuling {
    bytes32 disputeId;
    uint8 ruling;        // 0 = provider wins, 1 = requester wins, 2 = split (INV-1)
    uint16 confidence;   // basis points
    uint16 splitBps;     // provider share when ruling == 2
    uint64 timestamp;
    bytes32 reasoningHash;
    bytes32 bundleHash;
    bytes32 evidenceRefHash;  // AIP-14c: binds evidence CID into the signature (see §3.2)
    bytes32 reasoningRefHash; // AIP-14c: binds reasoning CID into the signature (see §3.2)
}
