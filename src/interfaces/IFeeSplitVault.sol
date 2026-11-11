// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {IEscrowValidator} from "./IEscrowValidator.sol";

/// @title IFeeSplitVault — escrow vault with an integrator fee and an optional post-dispute refund fee.
/// @notice Fee rules (normative). Per escrow: `p` = the transaction's locked protocol fee bps, `b` = the
///         locked integrator bps, `D` = deposit, `N` = cumulative amount the kernel passed to
///         `payoutToProvider`, `R` = cumulative amount the kernel passed to `refundToRequester` after the
///         escrow was disputed.
///         - Provider side (both profiles): integrator total = min(floor(N*b/(10000-p)), floor(D*b/10000)).
///         - Refund side, PAYOUT_ONLY: refunds are untouched.
///         - Refund side, BOTH_AFTER_DISPUTE, disputed escrows only: protocol fee floor(R*p/10000) and
///           integrator fee floor(R*min(b,p)/10000), both deducted from the refunded amount.
///         - Mediator payouts and dispute bonds never carry a vault fee.
interface IFeeSplitVault is IEscrowValidator {
    enum FeeProfile { PAYOUT_ONLY, BOTH_AFTER_DISPUTE }
    enum TermsState { NONE, PENDING_CONFIRM, CONFIRMED, VOID }

    event IntegratorApprovalSet(address indexed provider, address indexed integrator, uint16 maxBps);
    event EscrowTermsRegistered(address indexed requester, bytes32 indexed escrowId, address indexed integrator, uint16 bps, FeeProfile profile);
    event EscrowTermsCleared(address indexed requester, bytes32 indexed escrowId);
    event IntegratorTermsLocked(bytes32 indexed escrowId, address indexed provider, address indexed integrator, uint16 bps, FeeProfile profile);
    event TermsConfirmed(bytes32 indexed escrowId, uint16 protocolBps);
    event TermsVoided(bytes32 indexed escrowId);
    event EscrowDisputed(bytes32 indexed escrowId);
    event IntegratorFeeSplit(
        bytes32 indexed escrowId, address indexed provider, address indexed integrator,
        uint256 providerSideAmount,   // what the kernel passed in (== kernel EscrowReleased.amount)
        uint256 providerAmount,       // transferred to the provider
        uint256 integratorAmount,     // integrator share of this call
        bool integratorCredited
    );
    event RefundFeeSplit(
        bytes32 indexed escrowId, address indexed requester, address indexed integrator,
        uint256 refundSideAmount,     // what the kernel passed in (== kernel EscrowRefunded.amount)
        uint256 requesterAmount,      // transferred to the requester
        uint256 protocolFee,          // to kernel.feeRecipient() (or credited)
        uint256 integratorFee,        // to integrator (or credited)
        bool protocolCredited,
        bool integratorCredited
    );
    event IntegratorCreditWithdrawn(address indexed integrator, uint256 amount);
    event ProtocolCreditWithdrawn(address indexed recipient, uint256 amount);

    function MAX_INTEGRATOR_BPS() external view returns (uint16);   // constant 1000

    // Provider consent. msg.sender = provider. maxBps == 0 revokes for future escrows.
    function setIntegratorApproval(address integrator, uint16 maxBps) external;
    function integratorMaxBps(address provider, address integrator) external view returns (uint16);

    // Requester registration (the profile is chosen per escrow here). msg.sender = requester.
    function setEscrowTerms(bytes32 escrowId, address integrator, uint16 bps, FeeProfile profile) external;
    function clearEscrowTerms(bytes32 escrowId) external;
    function pendingTerms(address requester, bytes32 escrowId) external view
        returns (address integrator, uint16 bps, FeeProfile profile);

    // Locked at createEscrow; permanent record.
    function lockedTerms(bytes32 escrowId) external view returns (
        address integrator, uint16 bps, FeeProfile profile, TermsState state,
        uint16 protocolBps, bool disputed, bool used);
    // Cumulative counters of a live escrow (deleted with the escrow record).
    function splitState(bytes32 escrowId) external view returns (
        uint256 providerSide, uint256 integratorProviderSide,
        uint256 refundSide, uint256 protocolRefundFee, uint256 integratorRefundFee);
    function quotePayout(bytes32 escrowId, uint256 amount) external view returns (uint256 providerAmount, uint256 integratorAmount);
    // ACTUAL quote for the escrow's current state: zero fees while the escrow is undisputed.
    function quoteRefund(bytes32 escrowId, uint256 amount) external view returns (uint256 requesterAmount, uint256 protocolFee, uint256 integratorFee);
    // HYPOTHETICAL disclosure previews. Never used for accounting.
    // Before funding: no on-chain terms exist yet, so the caller supplies the proposed terms.
    // Applies the refund-side cap itself: integratorFee uses min(integratorBps, protocolBps).
    function previewDisputeRefund(uint256 refundAmount, uint16 protocolBps, uint16 integratorBps) external pure
        returns (uint256 requesterAmount, uint256 protocolFee, uint256 integratorFee);
    // After funding: what refundToRequester(escrowId, amount) WOULD pay if the escrow were disputed now,
    // from the locked terms and the current cumulative counters (so it is right after milestones too).
    // Zero fees for PAYOUT_ONLY, no-terms and VOID escrows. rateConfirmed = false means protocolBps was
    // read live from the kernel view because the escrow is still PENDING_CONFIRM.
    function quoteRefundIfDisputed(bytes32 escrowId, uint256 amount) external view
        returns (uint256 requesterAmount, uint256 protocolFee, uint256 integratorFee, bool rateConfirmed);
    // Deploy-gate probe: the vault's own decoding of kernel.getTransaction(txId).
    function kernelViewProbe(bytes32 txId) external view returns (bool ok, address requester, address provider,
        uint256 amount, address escrowContract, bytes32 escrowId, uint16 protocolBps);

    // Credits (only used when a push fails).
    function integratorCredit(address integrator) external view returns (uint256);
    function withdrawIntegratorCredit(address integrator) external returns (uint256);   // pays `integrator` only
    function protocolCredit() external view returns (uint256);
    function withdrawProtocolCredit() external returns (uint256);                        // pays current kernel.feeRecipient()

    // Solvency: token.balanceOf(vault) >= totalLocked + totalBonds + totalIntegratorCredit + protocolCredit
    function totalLocked() external view returns (uint256);
    function totalBonds() external view returns (uint256);
    function totalIntegratorCredit() external view returns (uint256);
}
