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

/**
 * @title IArchiveTreasury
 * @notice Interface for the Archive Treasury contract
 * @dev Manages funding for permanent Arweave storage of settled transactions
 */
interface IArchiveTreasury {
    /**
     * @notice Archive record structure
     * @param arweaveTxId Arweave transaction ID (max 43 characters)
     * @param archivedAt Timestamp when archive was anchored
     * @param exists Flag indicating if record exists (for gas-efficient checks)
     */
    struct ArchiveRecord {
        string arweaveTxId;
        uint64 archivedAt;
        bool exists;
    }

    /**
     * @notice Emitted when funds are received from protocol
     * @param from Address that sent funds (ACTPKernel)
     * @param amount USDC amount received
     */
    event FundsReceived(address indexed from, uint256 amount);

    /**
     * @notice Emitted when archive is anchored
     * @param txId ACTP transaction ID
     * @param arweaveTxId Arweave transaction ID
     * @param requester Original transaction requester
     * @param provider Original transaction provider
     */
    event ArchiveAnchored(
        bytes32 indexed txId,
        string arweaveTxId,
        address indexed requester,
        address indexed provider
    );

    /**
     * @notice Emitted when funds are withdrawn for archiving
     * @param to Address that received funds (uploader)
     * @param amount USDC amount withdrawn
     */
    event FundsWithdrawn(address indexed to, uint256 amount);

    /**
     * @notice Emitted when uploader address is updated
     * @param oldUploader Previous uploader address
     * @param newUploader New uploader address
     */
    event UploaderUpdated(address indexed oldUploader, address indexed newUploader);

    /**
     * @notice Receive archive funding from protocol fee distribution
     * @param amount USDC amount to deposit
     */
    function receiveFunds(uint256 amount) external;

    /**
     * @notice Anchor Arweave TX ID for a settled ACTP transaction
     * @dev Only callable by uploader. Validates transaction is in terminal state.
     * @param txId ACTP transaction ID (from ACTPKernel)
     * @param arweaveTxId Arweave transaction ID (from Irys/Bundlr upload)
     */
    function anchorArchive(bytes32 txId, string calldata arweaveTxId) external;

    /**
     * @notice Withdraw USDC to pay for Arweave uploads
     * @dev Only callable by uploader
     * @param amount USDC amount to withdraw
     */
    function withdrawForArchiving(uint256 amount) external;

    /**
     * @notice Update authorized uploader address
     * @dev Only callable by owner
     * @param newUploader New uploader address
     */
    function setUploader(address newUploader) external;

    /**
     * @notice Get archive record for an ACTP transaction
     * @param txId ACTP transaction ID
     * @return record Archive record struct
     */
    function getArchiveRecord(bytes32 txId) external view returns (ArchiveRecord memory record);

    /**
     * @notice Check if transaction has been archived
     * @param txId ACTP transaction ID
     * @return archived True if transaction has been archived
     */
    function isArchived(bytes32 txId) external view returns (bool archived);

    /**
     * @notice Get Arweave gateway URL for a transaction
     * @param txId ACTP transaction ID
     * @return url Full Arweave gateway URL (https://arweave.net/{arweaveTxId})
     */
    function getArchiveURL(bytes32 txId) external view returns (string memory url);

    /**
     * @notice Get current USDC balance in treasury
     * @return balance USDC balance
     */
    function getBalance() external view returns (uint256 balance);
}
