// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IACTPKernel {
    enum State {
        INITIATED,
        QUOTED,
        COMMITTED,
        IN_PROGRESS,
        DELIVERED,
        SETTLED,
        DISPUTED,
        CANCELLED
    }

    struct TransactionView {
        bytes32 transactionId;
        address requester;
        address provider;
        State state;
        uint256 amount;
        uint256 createdAt;
        uint256 updatedAt;
        uint256 deadline;
        bytes32 serviceHash;
        address escrowContract;
        bytes32 escrowId;
        bytes32 attestationUID;
        uint256 disputeWindow;
        bytes32 metadata;
        uint16 platformFeeBpsLocked; // AIP-5: Locked platform fee % from creation
    }

    event TransactionCreated(
        bytes32 indexed transactionId,
        address indexed requester,
        address indexed provider,
        uint256 amount,
        bytes32 serviceHash,
        uint256 deadline,
        uint256 timestamp
    );

    event StateTransitioned(
        bytes32 indexed transactionId,
        State indexed oldState,
        State indexed newState,
        address triggeredBy,
        uint256 timestamp
    );

    event EscrowLinked(
        bytes32 indexed transactionId,
        address escrowContract,
        bytes32 escrowId,
        uint256 amount,
        uint256 timestamp
    );

    event EscrowReleased(bytes32 indexed transactionId, address recipient, uint256 amount, uint256 timestamp);

    event EscrowRefunded(bytes32 indexed transactionId, address recipient, uint256 amount, uint256 timestamp);

    event EscrowMilestoneReleased(bytes32 indexed transactionId, uint256 amount, uint256 timestamp);

    event PlatformFeeAccrued(
        bytes32 indexed transactionId,
        address indexed recipient,
        uint256 amount,
        uint256 timestamp
    );

    event EscrowMediatorPaid(
        bytes32 indexed transactionId,
        address indexed mediator,
        uint256 amount,
        uint256 timestamp
    );

    event AttestationAnchored(
        bytes32 indexed transactionId,
        bytes32 indexed attestationUID,
        address attester,
        uint256 timestamp
    );

    event DisputeOpened(bytes32 indexed transactionId, address indexed initiator, bytes32 disputeId, uint256 timestamp);

    event DisputeResolved(
        bytes32 indexed transactionId,
        bytes32 indexed disputeId,
        uint8 resolution,
        uint256 timestamp
    );

    event KernelPaused(address indexed by, uint256 timestamp);
    event KernelUnpaused(address indexed by, uint256 timestamp);
    event KernelUpgraded(address indexed oldImplementation, address indexed newImplementation, uint256 timestamp);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);
    event EscrowVaultApproved(address indexed vault, bool approved);
    event PauserUpdated(address indexed oldPauser, address indexed newPauser);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    // C-4 FIX: EmergencyWithdraw events removed - kernel never holds funds by design

    event EconomicParamsUpdateScheduled(
        uint16 newPlatformFeeBps,
        uint16 newRequesterPenaltyBps,
        uint256 executeAfter
    );

    event EconomicParamsUpdateCancelled(
        uint16 pendingPlatformFeeBps,
        uint16 pendingRequesterPenaltyBps,
        uint256 timestamp
    );

    event EconomicParamsUpdated(uint16 platformFeeBps, uint16 requesterPenaltyBps, uint256 timestamp);

    function createTransaction(
        bytes32 transactionId,
        address provider,
        uint256 amount,
        bytes32 serviceHash,
        uint256 deadline
    ) external;

    function transitionState(bytes32 transactionId, State newState, bytes calldata proof) external;

    function getTransaction(bytes32 transactionId) external view returns (TransactionView memory);

    function linkEscrow(bytes32 transactionId, address escrowContract, bytes32 escrowId) external;

    function releaseMilestone(bytes32 transactionId, uint256 amount) external;

    function releaseEscrow(bytes32 transactionId) external;

    function anchorAttestation(bytes32 transactionId, bytes32 attestationUID) external;

    function pause() external;

    function unpause() external;

    function scheduleEconomicParams(uint16 newPlatformFeeBps, uint16 newRequesterPenaltyBps) external;

    function executeEconomicParamsUpdate() external;

    function cancelEconomicParamsUpdate() external;

    function getPendingEconomicParams()
        external
        view
        returns (uint16 platformFeeBps, uint16 requesterPenaltyBps, uint256 executeAfter, bool active);
}
