// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/**
 *   █████╗ ██████╗ ██╗  ██╗ █████╗
 *  ██╔══██╗██╔══██╗██║  ██║██╔══██╗
 *  ███████║██████╔╝███████║███████║
 *  ██╔══██║██╔══██╗██╔══██║██╔══██║
 *  ██║  ██║██║  ██║██║  ██║██║  ██║
 *  ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝
 *
 *  AgenticOS Organism
 */

import {IACTPKernel} from "./interfaces/IACTPKernel.sol";
import {IEscrowValidator} from "./interfaces/IEscrowValidator.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title ACTPKernel - Arha Transaction Coordinator
 * @notice Minimal implementation of the ACTP on-chain coordinator.
 *         It follows the specification in Docs/99. Final Public Papers/Core/AGIRAILS_Yellow_Paper.md.
 */
contract ACTPKernel is IACTPKernel, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Transaction {
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
        uint256 disputeWindow; // timestamp (expiry)
        bytes32 metadata; // For quote hash (AIP-2) or other protocol metadata
        uint16 platformFeeBpsLocked; // AIP-5: Lock platform fee % at creation time
    }

    mapping(bytes32 => Transaction) private transactions;

    uint256 public constant DEFAULT_DISPUTE_WINDOW = 2 days;
    uint256 public constant MIN_DISPUTE_WINDOW = 1 hours; // Minimum 1 hour to prevent instant finalization
    uint256 public constant MAX_DISPUTE_WINDOW = 30 days;
    uint256 public constant MAX_BPS = 10_000;
    uint16 public constant MAX_PLATFORM_FEE_CAP = 500; // 5%
    uint16 public constant MAX_REQUESTER_PENALTY_CAP = 5_000; // 50%
    uint16 public constant MAX_MEDIATOR_FEE_BPS = 1_000; // 10% max mediator fee
    uint256 public constant MIN_TRANSACTION_AMOUNT = 50_000; // $0.05 USDC (6 decimals) - prevents spam
    uint256 public constant MAX_TRANSACTION_AMOUNT = 1_000_000_000e6; // 1B USDC (with 6 decimals)
    uint256 public constant MAX_DEADLINE = 365 days; // Maximum 1 year deadline
    uint256 public constant ECONOMIC_PARAM_DELAY = 2 days;
    uint256 public constant MEDIATOR_APPROVAL_DELAY = 2 days; // Time-lock for mediator approvals
    // C-4 FIX: EMERGENCY_WITHDRAW_DELAY removed - kernel never holds funds
    address public admin;
    address public pauser;
    address public feeRecipient;
    address public pendingAdmin;
    uint16 public platformFeeBps;
    uint16 public requesterPenaltyBps;
    bool public paused;

    mapping(address => bool) public approvedEscrowVaults;
    mapping(address => bool) public approvedMediators;
    mapping(address => uint256) public mediatorApprovedAt; // Timestamp when mediator was approved

    event MediatorApproved(address indexed mediator, bool approved);
    event AdminTransferInitiated(address indexed currentAdmin, address indexed pendingAdmin);

    struct PendingEconomicParams {
        uint16 platformFeeBps;
        uint16 requesterPenaltyBps;
        uint256 executeAfter;
        bool active;
    }

    // C-4 FIX: PendingEmergencyWithdraw struct removed - kernel never holds funds

    PendingEconomicParams private pendingEconomicParams;
    // C-4 FIX: pendingEmergencyWithdraw removed - kernel never holds funds

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    modifier onlyPauser() {
        require(msg.sender == pauser || msg.sender == admin, "Not pauser");
        _;
    }

    modifier whenNotPaused() {
        // Pause blocks state changes, not fund recovery
        require(!paused, "Kernel paused");
        _;
    }

    constructor(address _admin, address _pauser, address _feeRecipient) {
        require(_admin != address(0), "Admin required");
        require(_feeRecipient != address(0), "Fee recipient required");
        admin = _admin;
        pauser = _pauser == address(0) ? _admin : _pauser;
        feeRecipient = _feeRecipient;
        _validatePlatformFee(100);
        _validateRequesterPenalty(500);
        platformFeeBps = 100;
        requesterPenaltyBps = 500;
    }

    // ---------------------------------------------------------------------
    // Transaction lifecycle
    // ---------------------------------------------------------------------

    /**
     * @notice Creates a new transaction between requester and provider
     * @dev IMPORTANT: Before calling this function, ensure that:
     *      1. At least one escrow vault is approved by the admin
     *      2. You have sufficient funds to create escrow in an approved vault
     *      3. The provider address is correct and trusted
     * @dev transactionId is generated deterministically from the inputs
     * @param provider Address of the service provider
     * @param requester Address of the requester (must match msg.sender)
     * @param amount Amount in tokens (must be > 0 and <= MAX_TRANSACTION_AMOUNT)
     * @param deadline Timestamp when the transaction expires
     * @param disputeWindow Duration in seconds for the dispute window
     * @param serviceHash Hash of the service agreement
     * @return transactionId The generated transaction ID
     */
    function createTransaction(
        address provider,
        address requester,
        uint256 amount,
        uint256 deadline,
        uint256 disputeWindow,
        bytes32 serviceHash
    ) external override whenNotPaused returns (bytes32 transactionId) {
        require(msg.sender == requester, "Requester mismatch");
        require(provider != address(0), "Zero provider");
        require(requester != provider, "Self-transaction not allowed");
        require(amount >= MIN_TRANSACTION_AMOUNT, "Amount below minimum");
        require(amount <= MAX_TRANSACTION_AMOUNT, "Amount exceeds maximum");
        require(deadline > block.timestamp, "Deadline in past");
        require(deadline <= block.timestamp + MAX_DEADLINE, "Deadline too far");
        require(disputeWindow >= MIN_DISPUTE_WINDOW, "Dispute window too short");
        require(disputeWindow <= MAX_DISPUTE_WINDOW, "Dispute window too long");

        // Generate deterministic transactionId
        transactionId = keccak256(
            abi.encodePacked(requester, provider, amount, serviceHash, block.timestamp, block.number)
        );
        require(transactions[transactionId].createdAt == 0, "Tx exists");

        Transaction storage txn = transactions[transactionId];
        txn.transactionId = transactionId;
        txn.requester = requester;
        txn.provider = provider;
        txn.state = State.INITIATED;
        txn.amount = amount;
        txn.createdAt = block.timestamp;
        txn.updatedAt = block.timestamp;
        txn.deadline = deadline;
        txn.disputeWindow = disputeWindow;
        txn.serviceHash = serviceHash;
        txn.platformFeeBpsLocked = platformFeeBps; // AIP-5: Lock current platform fee % at creation

        // State changes must be observable
        emit TransactionCreated(transactionId, requester, provider, amount, serviceHash, deadline, block.timestamp);
    }

    function transitionState(
        bytes32 transactionId,
        State newState,
        bytes calldata proof
    ) external override whenNotPaused nonReentrant {
        Transaction storage txn = _getTransaction(transactionId);
        State oldState = txn.state;
        require(newState != oldState, "No-op");
        // State machine monotonicity: no backwards transitions
        require(_isValidTransition(oldState, newState), "Invalid transition");
        _enforceAuthorization(txn, oldState, newState);
        _enforceTiming(txn, oldState, newState);

        if (newState == State.DELIVERED) {
            // Bilateral protection: both parties get dispute window
            uint256 window = _decodeDisputeWindow(proof);
            txn.disputeWindow = block.timestamp + (window == 0 ? DEFAULT_DISPUTE_WINDOW : window);
        } else if (newState == State.QUOTED && proof.length > 0) {
            // AIP-2: Store quote hash for verification (optional - only if proof provided)
            require(proof.length == 32, "Quote hash must be 32 bytes");
            bytes32 quoteHash = abi.decode(proof, (bytes32));
            require(quoteHash != bytes32(0), "Invalid quote hash");
            txn.metadata = quoteHash;
        }

        txn.state = newState;
        txn.updatedAt = block.timestamp;

        emit StateTransitioned(transactionId, oldState, newState, msg.sender, block.timestamp);

        if (newState == State.SETTLED) {
            if (oldState == State.DISPUTED) {
                _handleDisputeSettlement(txn, proof);
            } else {
                _releaseEscrow(txn);
            }
        } else if (newState == State.CANCELLED) {
            _handleCancellation(txn, oldState, proof, msg.sender);
        }
    }

    function getTransaction(bytes32 transactionId) external view override returns (TransactionView memory) {
        Transaction storage txn = _getTransaction(transactionId);
        return
            TransactionView({
                transactionId: txn.transactionId,
                requester: txn.requester,
                provider: txn.provider,
                state: txn.state,
                amount: txn.amount,
                createdAt: txn.createdAt,
                updatedAt: txn.updatedAt,
                deadline: txn.deadline,
                serviceHash: txn.serviceHash,
                escrowContract: txn.escrowContract,
                escrowId: txn.escrowId,
                attestationUID: txn.attestationUID,
                disputeWindow: txn.disputeWindow,
                metadata: txn.metadata,
                platformFeeBpsLocked: txn.platformFeeBpsLocked // AIP-5: Return locked fee %
            });
    }

    // ---------------------------------------------------------------------
    // Escrow & Attestation hooks
    // ---------------------------------------------------------------------

    function linkEscrow(bytes32 transactionId, address escrowContract, bytes32 escrowId) external override whenNotPaused nonReentrant {
        // CHECKS: Validate inputs and permissions
        require(escrowContract != address(0), "Escrow addr");
        require(approvedEscrowVaults[escrowContract], "Escrow not approved");
        Transaction storage txn = _getTransaction(transactionId);
        require(txn.state == State.INITIATED || txn.state == State.QUOTED, "Invalid state for linking escrow");
        // Authorization: only transaction requester
        require(msg.sender == txn.requester, "Only requester");
        require(block.timestamp <= txn.deadline, "Transaction expired");

        // CHECKS: Store old state before transition for event emission
        State oldState = txn.state;

        // INTERACTIONS: Create escrow in the vault
        // Note: The vault will pull funds from the requester
        // The vault's createEscrow() will revert if escrowId already exists (defense against reuse)
        IEscrowValidator(escrowContract).createEscrow(
            escrowId,
            txn.requester,
            txn.provider,
            txn.amount
        );

        // EFFECTS: Update transaction state
        txn.escrowContract = escrowContract;
        txn.escrowId = escrowId;
        txn.state = State.COMMITTED;
        txn.updatedAt = block.timestamp;

        // INTERACTIONS: Emit events
        emit EscrowLinked(transactionId, escrowContract, escrowId, txn.amount, block.timestamp);
        emit StateTransitioned(transactionId, oldState, State.COMMITTED, msg.sender, block.timestamp);
    }

    function releaseMilestone(bytes32 transactionId, uint256 amount) external override whenNotPaused nonReentrant {
        require(amount > 0, "Amount zero");
        Transaction storage txn = _getTransaction(transactionId);
        require(txn.state == State.IN_PROGRESS, "Not in progress");
        require(msg.sender == txn.requester, "Only requester");
        require(txn.escrowContract != address(0), "Escrow missing");

        IEscrowValidator vault = IEscrowValidator(txn.escrowContract);
        uint256 remaining = vault.remaining(txn.escrowId);
        // Solvency invariant: guarantee before commitment
        require(amount <= remaining, "Insufficient escrow");

        _payoutProviderAmount(txn, vault, amount);
        emit EscrowMilestoneReleased(transactionId, amount, block.timestamp);
        txn.updatedAt = block.timestamp;
    }

    function releaseEscrow(bytes32 transactionId) external override nonReentrant {
        Transaction storage txn = _getTransaction(transactionId);
        require(txn.state == State.SETTLED, "Not settled");
        _releaseEscrow(txn);
    }

    function anchorAttestation(bytes32 transactionId, bytes32 attestationUID) external override whenNotPaused {
        require(attestationUID != bytes32(0), "Attestation missing");
        Transaction storage txn = _getTransaction(transactionId);
        require(txn.state == State.SETTLED, "Only settled");
        require(msg.sender == txn.requester || msg.sender == txn.provider, "Not participant");

        txn.attestationUID = attestationUID;
        emit AttestationAnchored(transactionId, attestationUID, msg.sender, block.timestamp);
    }

    // ---------------------------------------------------------------------
    // Governance
    // ---------------------------------------------------------------------

    function pause() external override onlyPauser {
        require(!paused, "Already paused");
        paused = true;
        emit KernelPaused(msg.sender, block.timestamp);
    }

    function unpause() external override onlyPauser {
        require(paused, "Not paused");
        paused = false;
        emit KernelUnpaused(msg.sender, block.timestamp);
    }

    function updatePauser(address newPauser) external onlyAdmin {
        require(newPauser != address(0), "Zero pauser");
        address oldPauser = pauser;
        pauser = newPauser;
        emit PauserUpdated(oldPauser, newPauser);
    }

    function updateFeeRecipient(address newRecipient) external onlyAdmin {
        require(newRecipient != address(0), "Zero recipient");
        address oldRecipient = feeRecipient;
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(oldRecipient, newRecipient);
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "Zero admin");
        pendingAdmin = newAdmin;
        emit AdminTransferInitiated(admin, newAdmin);
    }

    function acceptAdmin() external {
        require(msg.sender == pendingAdmin, "Not pending admin");
        address oldAdmin = admin;
        admin = pendingAdmin;
        delete pendingAdmin;
        emit AdminTransferred(oldAdmin, admin);
    }

    function approveEscrowVault(address vault, bool approved) external onlyAdmin {
        require(vault != address(0), "Zero vault");
        approvedEscrowVaults[vault] = approved;
        emit EscrowVaultApproved(vault, approved);
    }

    function approveMediator(address mediator, bool approved) external onlyAdmin {
        require(mediator != address(0), "Zero mediator");

        if (approved) {
            // M-2 FIX: ALWAYS reset timelock on approval (including re-approval)
            // This prevents timelock bypass via revoke → re-approve
            mediatorApprovedAt[mediator] = block.timestamp + MEDIATOR_APPROVAL_DELAY;
            approvedMediators[mediator] = true;
        } else {
            // M-2 FIX: Clear timelock on revoke to prevent stale timelock reuse
            approvedMediators[mediator] = false;
            delete mediatorApprovedAt[mediator];
        }

        emit MediatorApproved(mediator, approved);
    }

    function scheduleEconomicParams(uint16 newPlatformFeeBps, uint16 newRequesterPenaltyBps) external override onlyAdmin {
        require(!pendingEconomicParams.active, "Pending update exists - cancel first");
        _validatePlatformFee(newPlatformFeeBps);
        _validateRequesterPenalty(newRequesterPenaltyBps);

        pendingEconomicParams = PendingEconomicParams({
            platformFeeBps: newPlatformFeeBps,
            requesterPenaltyBps: newRequesterPenaltyBps,
            executeAfter: block.timestamp + ECONOMIC_PARAM_DELAY,
            active: true
        });

        emit EconomicParamsUpdateScheduled(newPlatformFeeBps, newRequesterPenaltyBps, pendingEconomicParams.executeAfter);
    }

    function cancelEconomicParamsUpdate() external override onlyAdmin {
        require(pendingEconomicParams.active, "No pending");
        emit EconomicParamsUpdateCancelled(
            pendingEconomicParams.platformFeeBps,
            pendingEconomicParams.requesterPenaltyBps,
            block.timestamp
        );
        delete pendingEconomicParams;
    }

    function executeEconomicParamsUpdate() external override {
        PendingEconomicParams memory pending = pendingEconomicParams;
        require(pending.active, "No pending");
        // Economic changes require advance notice
        require(block.timestamp >= pending.executeAfter, "Too early");

        platformFeeBps = pending.platformFeeBps;
        requesterPenaltyBps = pending.requesterPenaltyBps;
        delete pendingEconomicParams;

        emit EconomicParamsUpdated(platformFeeBps, requesterPenaltyBps, block.timestamp);
    }

    function getPendingEconomicParams()
        external
        view
        override
        returns (uint16, uint16, uint256, bool)
    {
        PendingEconomicParams memory pending = pendingEconomicParams;
        return (pending.platformFeeBps, pending.requesterPenaltyBps, pending.executeAfter, pending.active);
    }

    // C-4 FIX: Emergency withdraw functions removed - kernel never holds funds by design
    // All user funds go directly to EscrowVault
    // Platform fees go directly to feeRecipient (line 675: vault.payout(txn.escrowId, feeRecipient, fee))
    // If tokens are accidentally sent to kernel, they are permanently lost (user error, not protocol responsibility)

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    function _getTransaction(bytes32 transactionId) internal view returns (Transaction storage) {
        require(transactions[transactionId].createdAt != 0, "Tx missing");
        return transactions[transactionId];
    }

    function _isValidTransition(State fromState, State toState) internal pure returns (bool) {
        if (fromState == State.INITIATED && toState == State.QUOTED) return true;
        if (fromState == State.INITIATED && toState == State.COMMITTED) return true; // Allow skip QUOTED
        if (fromState == State.QUOTED && toState == State.COMMITTED) return true;
        if (fromState == State.COMMITTED && toState == State.IN_PROGRESS) return true;
        if (fromState == State.IN_PROGRESS && toState == State.DELIVERED) return true;
        if (fromState == State.DELIVERED && (toState == State.SETTLED || toState == State.DISPUTED)) return true;
        if (fromState == State.DISPUTED && (toState == State.SETTLED || toState == State.CANCELLED)) return true;
        if (
            (fromState == State.INITIATED || fromState == State.QUOTED || fromState == State.COMMITTED
                || fromState == State.IN_PROGRESS) && toState == State.CANCELLED
        ) return true;
        return false;
    }

    function _enforceAuthorization(Transaction storage txn, State fromState, State toState) internal view {
        if (fromState == State.INITIATED && toState == State.QUOTED) {
            require(msg.sender == txn.provider, "Only provider");
        } else if (fromState == State.QUOTED && toState == State.COMMITTED) {
            require(msg.sender == txn.requester, "Only requester");
        } else if (fromState == State.COMMITTED && toState == State.IN_PROGRESS) {
            require(msg.sender == txn.provider, "Only provider");
        } else if (fromState == State.IN_PROGRESS && toState == State.DELIVERED) {
            require(msg.sender == txn.provider, "Only provider");
        } else if (fromState == State.DELIVERED && toState == State.SETTLED) {
            require(msg.sender == txn.requester || msg.sender == txn.provider, "Only participant");
        } else if (fromState == State.DELIVERED && toState == State.DISPUTED) {
            require(msg.sender == txn.requester || msg.sender == txn.provider, "Party only");
        } else if (
            fromState == State.DISPUTED && (toState == State.SETTLED || toState == State.CANCELLED)
        ) {
            require(msg.sender == admin || msg.sender == pauser, "Resolver only");
        } else if (toState == State.CANCELLED) {
            // State-specific cancellation authorization
            if (fromState == State.INITIATED || fromState == State.QUOTED) {
                // Only requester can cancel before commitment
                require(msg.sender == txn.requester, "Only requester can cancel");
            } else if (fromState == State.COMMITTED || fromState == State.IN_PROGRESS) {
                // Both parties can cancel after commitment
                require(msg.sender == txn.requester || msg.sender == txn.provider, "Party only");
            }
        }
    }

    function _enforceTiming(Transaction storage txn, State fromState, State toState) internal view {
        // Enforce deadline for all forward progressions (not cancellation or dispute)
        if (toState != State.CANCELLED && toState != State.DISPUTED) {
            require(block.timestamp <= txn.deadline, "Transaction expired");
        }

        if (fromState == State.COMMITTED && toState == State.CANCELLED) {
            // Provider can cancel anytime (voluntary refund), requester must wait for deadline
            if (msg.sender == txn.requester) {
                require(block.timestamp > txn.deadline, "Deadline not reached");
            }
            // Provider (msg.sender == txn.provider) can cancel immediately without penalty
        }
        if (fromState == State.DELIVERED && toState == State.DISPUTED) {
            require(block.timestamp <= txn.disputeWindow, "Dispute window closed");
        }
        if (
            fromState == State.DELIVERED && toState == State.SETTLED && msg.sender != txn.requester
        ) {
            require(block.timestamp > txn.disputeWindow, "Requester decision pending");
        }
    }

    function _decodeDisputeWindow(bytes calldata proof) internal view returns (uint256) {
        if (proof.length == 0) return 0;
        require(proof.length == 32, "Invalid dispute window proof");
        uint256 window = abi.decode(proof, (uint256));
        // If window is 0, DEFAULT_DISPUTE_WINDOW will be used (which meets minimum)
        // If window > 0, enforce minimum and maximum bounds
        if (window > 0) {
            require(window >= MIN_DISPUTE_WINDOW, "Dispute window too short");
            require(window <= MAX_DISPUTE_WINDOW, "Dispute window too long");
        }
        require(window <= type(uint256).max - block.timestamp, "Timestamp overflow");
        return window;
    }

    function _decodeResolutionProof(bytes calldata proof)
        internal
        pure
        returns (uint256 requesterAmount, uint256 providerAmount, address mediator, uint256 mediatorAmount, bool hasResolution)
    {
        if (proof.length == 0) {
            return (0, 0, address(0), 0, false);
        }
        if (proof.length == 64) {
            // 64-byte proof: only requester/provider split, NO mediator
            (requesterAmount, providerAmount) = abi.decode(proof, (uint256, uint256));
            require(requesterAmount > 0 || providerAmount > 0, "Empty resolution");
            return (requesterAmount, providerAmount, address(0), 0, true);
        }
        // 128-byte proof: requester/provider split + mediator payout
        require(proof.length == 128, "Invalid resolution proof");
        (requesterAmount, providerAmount, mediator, mediatorAmount) =
            abi.decode(proof, (uint256, uint256, address, uint256));
        require(requesterAmount > 0 || providerAmount > 0 || mediatorAmount > 0, "Empty resolution");
        // If mediator payout requested, mediator address MUST be valid
        require(mediatorAmount == 0 || mediator != address(0), "Mediator address required");
        return (requesterAmount, providerAmount, mediator, mediatorAmount, true);
    }

    function _releaseEscrow(Transaction storage txn) internal {
        require(txn.escrowContract != address(0), "Escrow missing");
        IEscrowValidator vault = IEscrowValidator(txn.escrowContract);
        uint256 remaining = vault.remaining(txn.escrowId);
        require(remaining > 0, "Escrow empty");
        _payoutProviderAmount(txn, vault, remaining);
    }

    function _handleDisputeSettlement(Transaction storage txn, bytes calldata proof) internal {
        if (txn.escrowContract == address(0)) return;
        IEscrowValidator vault = IEscrowValidator(txn.escrowContract);
        uint256 remaining = vault.remaining(txn.escrowId);
        if (remaining == 0) return;

        (uint256 requesterAmount, uint256 providerAmount, address mediator, uint256 mediatorAmount, bool hasResolution) =
            _decodeResolutionProof(proof);

        if (!hasResolution) {
            _payoutProviderAmount(txn, vault, remaining);
            return;
        }

        // H-2 FIX: Prevent empty or partial dispute resolutions
        uint256 totalDistributed = requesterAmount + providerAmount + mediatorAmount;
        require(totalDistributed > 0, "Empty resolution not allowed");
        require(totalDistributed == remaining, "Must distribute ALL funds");
        require(totalDistributed <= txn.amount, "Resolution exceeds transaction amount");

        if (providerAmount > 0) {
            _payoutProviderAmount(txn, vault, providerAmount);
        }
        if (requesterAmount > 0) {
            _refundRequester(txn, vault, requesterAmount);
        }
        if (mediatorAmount > 0) {
            _payoutMediator(txn, vault, mediator, mediatorAmount);
        }

        // H-2 FIX: No leftover handling needed - resolution MUST distribute exact amount
        // If there's any leftover, the require above will catch it
    }

    function _handleCancellation(
        Transaction storage txn,
        State oldState,
        bytes calldata proof,
        address triggeredBy
    ) internal {
        if (txn.escrowContract == address(0)) return;
        IEscrowValidator vault = IEscrowValidator(txn.escrowContract);
        uint256 remaining = vault.remaining(txn.escrowId);
        if (remaining == 0) return;

        (uint256 requesterAmount, uint256 providerAmount, address mediator, uint256 mediatorAmount, bool hasResolution) =
            _decodeResolutionProof(proof);
        if (oldState == State.DISPUTED && hasResolution) {
            require(triggeredBy == admin || triggeredBy == pauser, "Resolver only");

            // H-2 FIX: Prevent empty or partial dispute resolutions
            uint256 totalDistributed = requesterAmount + providerAmount + mediatorAmount;
            require(totalDistributed > 0, "Empty resolution not allowed");
            require(totalDistributed == remaining, "Must distribute ALL funds");
            require(totalDistributed <= txn.amount, "Resolution exceeds transaction amount");

            if (providerAmount > 0) {
                _payoutProviderAmount(txn, vault, providerAmount);
            }
            if (requesterAmount > 0) {
                _refundRequester(txn, vault, requesterAmount);
            }
            if (mediatorAmount > 0) {
                _payoutMediator(txn, vault, mediator, mediatorAmount);
            }

            // H-2 FIX: No leftover handling needed - resolution MUST distribute exact amount
            return;
        }

        if (triggeredBy == txn.requester && (oldState == State.COMMITTED || oldState == State.IN_PROGRESS)) {
            uint256 penalty = (remaining * requesterPenaltyBps) / MAX_BPS;
            uint256 refund = remaining - penalty;
            _refundRequester(txn, vault, refund);
            if (penalty > 0) {
                _payoutProviderAmount(txn, vault, penalty);
            }
            return;
        }

        _refundRequester(txn, vault, remaining);
    }

    function _payoutProviderAmount(
        Transaction storage txn,
        IEscrowValidator vault,
        uint256 grossAmount
    ) internal {
        require(grossAmount > 0, "Amount zero");

        // Verify vault is approved (defense-in-depth)
        require(approvedEscrowVaults[address(vault)], "Vault not approved");

        // Verify escrow has sufficient balance BEFORE payout
        uint256 available = vault.remaining(txn.escrowId);
        require(available >= grossAmount, "Insufficient escrow balance");

        // AIP-5: Use locked fee percentage from transaction creation
        uint256 fee = _calculateFee(grossAmount, txn.platformFeeBpsLocked);
        require(fee <= grossAmount, "Fee exceeds amount");
        uint256 providerNet = grossAmount - fee;

        if (providerNet > 0) {
            vault.payoutToProvider(txn.escrowId, providerNet);
            emit EscrowReleased(txn.transactionId, txn.provider, providerNet, block.timestamp);
        }
        if (fee > 0) {
            vault.payout(txn.escrowId, feeRecipient, fee);
            emit PlatformFeeAccrued(txn.transactionId, feeRecipient, fee, block.timestamp);
        }
    }

    function _refundRequester(Transaction storage txn, IEscrowValidator vault, uint256 amount) internal {
        require(amount > 0, "Refund amount zero");
        require(approvedEscrowVaults[address(vault)], "Vault not approved");
        vault.refundToRequester(txn.escrowId, amount);
        emit EscrowRefunded(txn.transactionId, txn.requester, amount, block.timestamp);
    }

    function _payoutMediator(Transaction storage txn, IEscrowValidator vault, address mediator, uint256 amount) internal {
        require(mediator != address(0), "Mediator zero");
        require(approvedMediators[mediator], "Mediator not approved");
        require(block.timestamp >= mediatorApprovedAt[mediator], "Mediator approval pending");
        require(amount > 0, "Mediator amount zero");
        require(approvedEscrowVaults[address(vault)], "Vault not approved");

        // Validate mediator fee doesn't exceed maximum (10% of transaction amount)
        uint256 maxMediatorFee = (txn.amount * MAX_MEDIATOR_FEE_BPS) / MAX_BPS;
        require(amount <= maxMediatorFee, "Mediator fee exceeds maximum");

        vault.payout(txn.escrowId, mediator, amount);
        emit EscrowMediatorPaid(txn.transactionId, mediator, amount, block.timestamp);
    }

    /**
     * @notice Calculate platform fee using locked fee percentage from transaction creation
     * @dev AIP-5: Uses locked fee % to guarantee 1% fee commitment
     * @param grossAmount Amount before fee deduction
     * @param lockedFeeBps Locked platform fee basis points from transaction creation
     */
    function _calculateFee(uint256 grossAmount, uint16 lockedFeeBps) internal pure returns (uint256) {
        return (grossAmount * lockedFeeBps) / MAX_BPS;
    }

    function _validatePlatformFee(uint16 newFee) internal pure {
        require(newFee <= MAX_PLATFORM_FEE_CAP, "Fee cap");
    }

    function _validateRequesterPenalty(uint16 newPenalty) internal pure {
        require(newPenalty <= MAX_REQUESTER_PENALTY_CAP, "Penalty cap");
    }
}
