// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {ICompositeMediator} from "./interfaces/ICompositeMediator.sol";
import {IACTPKernel} from "./interfaces/IACTPKernel.sol";
import {IEscrowValidator} from "./interfaces/IEscrowValidator.sol";

/// @title CompositeMediator — thin ruling → kernel-state mapper (AIP-14b §6).
/// @author AGIRAILS
/// @notice The CompositeMediator is the single, narrow bridge between the dispute tier system
///         (BondEscalation) and the ACTP kernel. It does exactly one thing: take a *final* ruling
///         and translate it into one `kernel.transitionState` call, supplying the proof blob the
///         kernel decodes into a fund-movement instruction.
///
/// Design contract (AIP-14b §6):
///   - INV-1 (load-bearing encoding): `ruling` is the canonical tri-state outcome.
///       0 = provider wins      → SETTLED, full `remaining` to provider (providerAtFault = false)
///       1 = requester wins     → SETTLED, full `remaining` to requester (providerAtFault = true)
///       2 = split              → CANCELLED, `remaining` apportioned by `splitBps` (provider share)
///     The kernel's proof decoder is keyed off the proof length:
///       96-byte abi.encode(requesterAmount, providerAmount, bool providerAtFault) → SETTLED branch.
///       64-byte abi.encode(requesterAmount, providerAmount)                       → CANCELLED branch.
///     The CompositeMediator MUST emit exactly these two encodings — they are the wire contract.
///   - INV-2: the mediator NEVER moves funds and NEVER touches an EscrowVault bond method
///       (depositBond / releaseBond / bondBalance). Its only EscrowVault contact is the read-only
///       `remaining(escrowId)`. All value movement happens inside the kernel during
///       `transitionState`; the entry bond return is handled there too.
///   - INV-22: on a split (ruling 2) the neutral `DisputeSplitRecorded` reputation trace is emitted
///       BEFORE `kernel.transitionState`, so the recorded event ordering is deterministic for
///       indexers regardless of any events the kernel emits during the transition.
///
/// Trust / authority:
///   - resolve() is callable ONLY by the wired BondEscalation contract (`onlyBondEscalation`).
///   - The kernel separately recognizes THIS contract as an approved + timelocked mediator
///     (AIP-14b P0-3 resolver-auth). This contract therefore needs no kernel-side privileges of
///     its own beyond being on the kernel's approved-resolver list.
///
/// Decision G4 (AIP14B-DECISIONS.md) — WRITE-ONCE INIT, not immutable:
///   CompositeMediator and BondEscalation reference each other, so the back-reference cannot be an
///   `immutable` set in the constructor (one of the two does not yet exist at the other's deploy).
///   Instead `bondEscalation` is a storage var set exactly once via `initialize`, which is guarded
///   so it can be called ONCE and ONLY by the deployer. This closes the front-running window where
///   an attacker could otherwise wire a malicious BondEscalation before the legitimate deployer.
contract CompositeMediator is ICompositeMediator {
    /// @notice The ACTP kernel this mediator drives. Exists at deploy time → immutable.
    IACTPKernel public immutable kernel;

    /// @notice The deployer, captured at construction. Only this address may run `initialize`.
    /// @dev Pinned immutable so the one-shot wiring cannot be hijacked even before `initialize`.
    address public immutable deployer;

    /// @notice The wired BondEscalation contract — the ONLY permitted caller of `resolve`.
    /// @dev NOT immutable (Decision G4): set exactly once by `initialize`. Zero until wired.
    address public bondEscalation;

    /// @notice One-shot guard for `initialize`. Once true, the back-reference is frozen forever.
    bool private _initialized;

    /// @notice Inert amount (1 wei) emitted in a resolution proof ONLY when escrow `remaining == 0`.
    /// @dev    Satisfies the kernel decoder's `require(... > 0, "Empty resolution")` existence check.
    ///         Provably never transferred: both kernel handlers gate distribution behind
    ///         `if (remaining > 0)`, which is false whenever this sentinel is used (P1-1 review fix).
    uint256 private constant ZERO_REMAINING_SENTINEL = 1;

    /// @notice Restricts `resolve` to the wired dispute tier system (BondEscalation).
    /// @dev Reverts before `bondEscalation` is wired, since msg.sender can never equal address(0).
    modifier onlyBondEscalation() {
        require(msg.sender == bondEscalation, "Only tier system");
        _;
    }

    /// @param kernel_ The ACTP kernel address (already deployed). Reverts on zero.
    constructor(IACTPKernel kernel_) {
        require(address(kernel_) != address(0), "kernel=0");
        kernel = kernel_;
        deployer = msg.sender;
    }

    /// @inheritdoc ICompositeMediator
    /// @dev G4 write-once init. Callable ONCE and ONLY by the deployer. Front-running protection:
    ///      because `deployer` is immutable and equals the constructor caller, no third party can
    ///      pre-empt the wiring with a malicious `bondEscalation_`.
    function initialize(address bondEscalation_) external {
        require(msg.sender == deployer, "Only deployer");
        require(!_initialized, "Already initialized");
        require(bondEscalation_ != address(0), "bondEscalation=0");
        _initialized = true;
        bondEscalation = bondEscalation_;
    }

    /// @inheritdoc ICompositeMediator
    /// @dev Enacts a FINAL ruling (AIP-14b §6). Pure mapping — no fund movement here (INV-2).
    ///
    ///      ruling 0 (provider wins) / 1 (requester wins) → SETTLED via the 96-byte proof:
    ///          abi.encode(requesterAmount, providerAmount, bool providerAtFault).
    ///      ruling 2 (split)                              → CANCELLED via the 64-byte legacy proof:
    ///          abi.encode(requesterAmount, providerAmount).
    ///
    ///      64-byte CANCELLED branch (legacy / OQ-7): the kernel forces `providerAtFault = true` on
    ///      the CANCELLED path because it carries no explicit fault flag. That is HARMLESS here — on
    ///      a split the dispute is mutual fault, no party "wins", and the entry bond always returns
    ///      to the disputer on CANCELLED regardless of the forced flag. We keep the 64-byte encoding
    ///      deliberately so no kernel decoder change is needed (Decision OQ-7).
    ///
    ///      ZERO-REMAINING ESCROW (P1-1 review fix): a transaction can reach DISPUTED with the escrow
    ///      already fully drained by `releaseMilestone` (requester-callable in IN_PROGRESS), then
    ///      IN_PROGRESS → DELIVERED → DISPUTED. With `remaining == 0`, an all-zero amount proof would
    ///      be rejected by the kernel decoder's `require(... > 0, "Empty resolution")` guard BEFORE
    ///      the kernel's own `if (remaining > 0)` skip is reached — deadlocking the dispute with no
    ///      funds at stake. We handle this here so the tier system can always finalize:
    ///        - There is nothing to apportion (escrow is empty), so we emit a `SENTINEL` of 1 wei in
    ///          the prevailing party's amount field purely to satisfy the decoder's existence check.
    ///        - This sentinel is PROVABLY INERT: both kernel handlers gate every `_payout*`/`_refund*`
    ///          call behind `if (remaining > 0)`, which is false here, so the sentinel is never read
    ///          for any transfer. The transition still runs bond distribution and flips kernel state.
    ///      This keeps INV-2 intact (the mediator moves no funds) and needs no kernel decoder change.
    function resolve(bytes32 txId, uint8 ruling, uint16 splitBps) external onlyBondEscalation {
        require(ruling <= 2, "Invalid ruling");
        require(splitBps <= 10000, "Invalid split");
        require(ruling == 2 || splitBps == 0, "splitBps only for splits");

        IACTPKernel.TransactionView memory txn = kernel.getTransaction(txId);

        // INV-2: read-only escrow inspection — never a bond method, never a transfer.
        IEscrowValidator vault = IEscrowValidator(txn.escrowContract);
        uint256 remaining = vault.remaining(txn.escrowId);

        if (ruling == 2) {
            // Split: apportion the remaining escrow by provider share (splitBps).
            // P1-1: with remaining == 0 there is nothing to apportion; emit the inert sentinel
            // in the provider field so the 64-byte CANCELLED decoder's existence check passes.
            uint256 providerAmount;
            uint256 requesterAmount;
            if (remaining == 0) {
                providerAmount = ZERO_REMAINING_SENTINEL;
                requesterAmount = 0;
            } else {
                providerAmount = (remaining * splitBps) / 10000;
                requesterAmount = remaining - providerAmount;
            }

            // 64-byte CANCELLED proof (legacy branch — see NatSpec above / OQ-7).
            bytes memory proof = abi.encode(requesterAmount, providerAmount);

            // INV-22: emit the neutral reputation trace BEFORE the kernel transition so event
            //         ordering is deterministic for indexers.
            emit DisputeSplitRecorded(txId, txn.requester, txn.provider, splitBps);

            kernel.transitionState(txId, IACTPKernel.State.CANCELLED, proof);
        } else {
            // Clean win: all remaining escrow goes to the prevailing party.
            // ruling 1 (requester wins) ⇒ providerAtFault = true; ruling 0 (provider wins) ⇒ false.
            bool providerAtFault = (ruling == 1);
            uint256 providerAmount;
            uint256 requesterAmount;
            if (remaining == 0) {
                // P1-1: nothing to award; emit the inert sentinel in the prevailing party's field
                // so the 96-byte SETTLED decoder's existence check passes. Never read (remaining==0).
                providerAmount = providerAtFault ? 0 : ZERO_REMAINING_SENTINEL;
                requesterAmount = providerAtFault ? ZERO_REMAINING_SENTINEL : 0;
            } else {
                providerAmount = providerAtFault ? 0 : remaining;
                requesterAmount = providerAtFault ? remaining : 0;
            }

            // 96-byte SETTLED proof with explicit fault flag.
            bytes memory proof = abi.encode(requesterAmount, providerAmount, providerAtFault);

            kernel.transitionState(txId, IACTPKernel.State.SETTLED, proof);
        }
    }
}
