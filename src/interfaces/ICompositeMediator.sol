// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/// @title ICompositeMediator — thin mediator mapping a final dispute ruling to a kernel state
///        transition (AIP-14b §6).
/// @notice Does ONE thing: read escrow amounts (read-only) and call `kernel.transitionState`.
///         It never touches funds or the EscrowVault bond methods (INV-2). The kernel must
///         recognize this contract as an approved+timelocked mediator (AIP-14b P0-3).
interface ICompositeMediator {
    /// @notice Neutral reputation trace emitted on every ruling-2 (split) resolution (§3.4, INV-22).
    ///         Carries no on-chain penalty; indexers surface per-agent split rates.
    event DisputeSplitRecorded(
        bytes32 indexed txId,
        address indexed requester,
        address indexed provider,
        uint16 splitBps
    );

    /// @notice Enact a final ruling. Callable ONLY by the BondEscalation contract.
    /// @param txId   The ACTP transaction being resolved.
    /// @param ruling 0 = provider wins → SETTLED; 1 = requester wins → SETTLED; 2 = split → CANCELLED. (INV-1)
    /// @param splitBps Provider share when ruling == 2; MUST be 0 otherwise.
    function resolve(bytes32 txId, uint8 ruling, uint16 splitBps) external;

    /// @notice One-shot wiring of the BondEscalation back-reference.
    /// @dev Decision G4 (AIP14B-DECISIONS.md) = write-once init, NOT immutable: the back-reference is a
    ///      storage var set exactly once here (guarded by a one-shot flag), because CompositeMediator and
    ///      BondEscalation reference each other and cannot both be set in constructors. Reverts if already set.
    function initialize(address bondEscalation) external;
}
