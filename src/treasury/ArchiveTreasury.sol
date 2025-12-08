// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.20;

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

import {IArchiveTreasury} from "../interfaces/IArchiveTreasury.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title ArchiveTreasury - Arha Archive Funding Manager
 * @notice Manages funding for permanent Arweave storage of settled transactions
 * @dev Receives 0.1% of protocol fees, used to pay for Arweave uploads via Irys/Bundlr
 *
 * ## Architecture
 *
 * This contract is part of AGIRAILS Phase 2 (AIP-7) storage infrastructure:
 * 1. ACTPKernel transfers 0.1% of platform fees to this treasury via receiveFunds()
 * 2. Uploader service periodically withdraws USDC via withdrawForArchiving()
 * 3. Uploader swaps USDC → ETH (off-chain) and funds Irys account
 * 4. Uploader bundles transaction data and uploads to Arweave via Irys
 * 5. Uploader calls anchorArchive() to record Arweave TX ID on-chain
 *
 * ## Fee Flow Example
 *
 * Transaction: $100 USDC
 * Platform Fee (1%): $1.00 USDC
 *   ├── Treasury (99.9%): $0.999 USDC
 *   └── Archive (0.1%): $0.001 USDC → ArchiveTreasury
 *
 * At $10M monthly GMV:
 * - $100K total fees → $100 to archive treasury
 * - Arweave cost: ~$0.0001 per 1KB upload
 * - $100 funds ~1M transaction archives
 *
 * ## Security Model
 *
 * - Immutable USDC and kernel addresses (set in constructor)
 * - Only uploader can withdraw funds and anchor archives
 * - Only owner can change uploader address
 * - Validates transaction exists and is in terminal state before anchoring
 * - Prevents duplicate archiving via exists flag
 * - ReentrancyGuard on withdrawForArchiving
 *
 * ## Trusted Uploader Model (IMPORTANT)
 *
 * The uploader is a TRUSTED off-chain service. This design trades off some
 * decentralization for operational simplicity:
 *
 * RISKS if uploader key is compromised:
 * - Attacker can withdraw all treasury funds via withdrawForArchiving()
 * - Attacker can anchor arbitrary Arweave TX IDs (not linked to real uploads)
 * - No on-chain verification that withdrawn funds were actually spent on Arweave
 *
 * MITIGATIONS (operational, not enforced on-chain):
 * - Uploader key should be stored in HSM or hardware wallet
 * - Owner (multisig) can replace compromised uploader via setUploader()
 * - Off-chain monitoring should alert on unusual withdrawal patterns
 * - Consider rate limiting in future versions (e.g., daily withdrawal cap)
 * - Consider "payout intent" pattern: commit to archive before withdrawal
 *
 * This model is acceptable for testnet/early mainnet. For full decentralization,
 * future versions may implement:
 * - On-chain oracle verification of Arweave uploads
 * - Withdrawal escrow with proof-of-upload requirement
 * - Multi-uploader rotation with slashing
 *
 * @custom:security-contact security@agirails.io
 */
contract ArchiveTreasury is IArchiveTreasury, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ========== STATE VARIABLES ==========

    /// @notice USDC token contract
    IERC20 public immutable USDC;

    /// @notice ACTPKernel contract for transaction state validation
    IACTPKernel public immutable kernel;

    /// @notice Authorized address to withdraw for Arweave uploads
    address public uploader;

    /// @notice Cumulative USDC received from protocol
    uint256 public totalReceived;

    /// @notice Cumulative USDC spent on archiving
    uint256 public totalSpent;

    /// @notice Count of archived transactions
    uint256 public totalArchived;

    /// @notice Mapping of ACTP transaction ID to archive record
    mapping(bytes32 => ArchiveRecord) public archives;

    // SECURITY [M-3 FIX]: Rate limiting for withdrawals
    /// @notice Maximum USDC that can be withdrawn per day
    uint256 public constant MAX_DAILY_WITHDRAWAL = 1000e6; // $1000 USDC

    /// @notice Last day (in Unix days) when withdrawal occurred
    uint256 public lastWithdrawalDay;

    /// @notice Amount withdrawn in current day
    uint256 public dailyWithdrawn;

    // ========== CONSTRUCTOR ==========

    /**
     * @notice Initialize Archive Treasury
     * @param _usdc USDC token address
     * @param _kernel ACTPKernel address for transaction validation
     * @param _uploader Initial uploader address
     */
    constructor(address _usdc, address _kernel, address _uploader) Ownable(msg.sender) {
        require(_usdc != address(0), "Zero USDC address");
        require(_kernel != address(0), "Zero Kernel address");
        require(_uploader != address(0), "Zero uploader address");

        USDC = IERC20(_usdc);
        kernel = IACTPKernel(_kernel);
        uploader = _uploader;
    }

    // ========== CORE FUNCTIONS ==========

    /**
     * @notice Receive archive funding from protocol fee distribution
     * @dev Called by ACTPKernel during settlement to transfer archive allocation
     * @param amount USDC amount to deposit (0.1% of platform fee)
     */
    function receiveFunds(uint256 amount) external override {
        // [M-3 FIX] Only ACTPKernel can deposit funds
        require(msg.sender == address(kernel), "Only kernel can deposit");
        require(amount > 0, "Amount zero");

        // Transfer USDC from caller (should be ACTPKernel)
        USDC.safeTransferFrom(msg.sender, address(this), amount);

        // Update accounting
        totalReceived += amount;

        emit FundsReceived(msg.sender, amount);
    }

    /**
     * @notice Anchor Arweave TX ID for a settled ACTP transaction
     * @dev Validates transaction is in terminal state (SETTLED or CANCELLED) before anchoring.
     *      Prevents duplicate archiving via exists flag.
     * @param txId ACTP transaction ID (from ACTPKernel)
     * @param arweaveTxId Arweave transaction ID (from Irys/Bundlr upload, 43 chars)
     */
    function anchorArchive(bytes32 txId, string calldata arweaveTxId) external override onlyUploader {
        // Prevent duplicate archiving
        require(!archives[txId].exists, "Already archived");

        // Validate Arweave TX ID (must be exactly 43 chars - base64url encoded 32 bytes)
        require(bytes(arweaveTxId).length == 43, "Invalid Arweave TX ID length");

        // [L-4 FIX] Validate base64url character set (A-Za-z0-9_-)
        bytes memory txIdBytes = bytes(arweaveTxId);
        for (uint256 i = 0; i < 43; i++) {
            bytes1 char = txIdBytes[i];
            require(
                (char >= 0x30 && char <= 0x39) || // 0-9
                (char >= 0x41 && char <= 0x5A) || // A-Z
                (char >= 0x61 && char <= 0x7A) || // a-z
                char == 0x2D ||                   // -
                char == 0x5F,                     // _
                "Invalid base64url character"
            );
        }

        // Validate transaction state and get participants
        (address requester, address provider) = _validateAndGetParties(txId);

        // Store archive record
        archives[txId] = ArchiveRecord({
            arweaveTxId: arweaveTxId,
            archivedAt: uint64(block.timestamp),
            exists: true
        });

        // Update counter
        totalArchived++;

        emit ArchiveAnchored(txId, arweaveTxId, requester, provider);
    }

    /**
     * @notice Withdraw USDC to pay for Arweave uploads
     * @dev Only callable by uploader. Uses nonReentrant to prevent reentrancy attacks.
     *      SECURITY [M-3 FIX]: Rate limited to MAX_DAILY_WITHDRAWAL ($1000) per day.
     *      Uploader will swap USDC → ETH off-chain and fund Irys account.
     * @param amount USDC amount to withdraw
     */
    function withdrawForArchiving(uint256 amount) external override onlyUploader nonReentrant {
        require(amount > 0, "Amount zero");
        require(amount <= USDC.balanceOf(address(this)), "Insufficient balance");

        // SECURITY [M-3 FIX]: Daily withdrawal rate limiting
        // Reset daily counter if new day (Unix day = block.timestamp / 86400)
        uint256 currentDay = block.timestamp / 1 days;
        if (currentDay > lastWithdrawalDay) {
            dailyWithdrawn = 0;
            lastWithdrawalDay = currentDay;
        }

        // Enforce daily withdrawal limit to prevent uploader key compromise from draining funds
        require(dailyWithdrawn + amount <= MAX_DAILY_WITHDRAWAL, "Daily withdrawal limit exceeded");
        dailyWithdrawn += amount;

        // Update accounting
        totalSpent += amount;

        // Transfer USDC to uploader
        USDC.safeTransfer(uploader, amount);

        emit FundsWithdrawn(uploader, amount);
    }

    /**
     * @notice Update authorized uploader address
     * @dev Only callable by owner (multisig). Uploader can withdraw funds and anchor archives.
     * @param newUploader New uploader address
     */
    function setUploader(address newUploader) external override onlyOwner {
        require(newUploader != address(0), "Zero address");

        address oldUploader = uploader;
        uploader = newUploader;

        emit UploaderUpdated(oldUploader, newUploader);
    }

    // ========== INTERNAL FUNCTIONS ==========

    /**
     * @notice Validate transaction state and return parties
     * @dev Internal helper to avoid stack too deep in anchorArchive
     * @param txId ACTP transaction ID
     * @return requester Transaction requester address
     * @return provider Transaction provider address
     */
    function _validateAndGetParties(bytes32 txId) internal view returns (address requester, address provider) {
        // Get transaction details from kernel
        IACTPKernel.TransactionView memory txView = kernel.getTransaction(txId);

        // Validate transaction exists
        require(txView.requester != address(0), "Transaction does not exist");

        // Validate transaction is in terminal state
        require(
            txView.state == IACTPKernel.State.SETTLED || txView.state == IACTPKernel.State.CANCELLED,
            "Transaction not in terminal state"
        );

        return (txView.requester, txView.provider);
    }

    // ========== VIEW FUNCTIONS ==========

    /**
     * @notice Get archive record for an ACTP transaction
     * @param txId ACTP transaction ID
     * @return record Archive record struct (empty if not archived)
     */
    function getArchiveRecord(bytes32 txId) external view override returns (ArchiveRecord memory record) {
        return archives[txId];
    }

    /**
     * @notice Check if transaction has been archived
     * @param txId ACTP transaction ID
     * @return archived True if transaction has been archived
     */
    function isArchived(bytes32 txId) external view override returns (bool archived) {
        return archives[txId].exists;
    }

    /**
     * @notice Get Arweave gateway URL for a transaction
     * @dev Reverts if transaction has not been archived
     * @param txId ACTP transaction ID
     * @return url Full Arweave gateway URL (https://arweave.net/{arweaveTxId})
     */
    function getArchiveURL(bytes32 txId) external view override returns (string memory url) {
        require(archives[txId].exists, "Not archived");

        return string(abi.encodePacked("https://arweave.net/", archives[txId].arweaveTxId));
    }

    /**
     * @notice Get current USDC balance in treasury
     * @return balance USDC balance
     */
    function getBalance() external view override returns (uint256 balance) {
        return USDC.balanceOf(address(this));
    }

    // ========== MODIFIERS ==========

    /**
     * @notice Modifier to restrict function to uploader only
     */
    modifier onlyUploader() {
        require(msg.sender == uploader, "Not authorized uploader");
        _;
    }
}

/**
 * @notice ACTPKernel interface subset (for transaction validation)
 * @dev Only includes what ArchiveTreasury needs to validate transactions
 */
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
        uint16 platformFeeBpsLocked;
    }

    function getTransaction(bytes32 txId) external view returns (TransactionView memory);
}
