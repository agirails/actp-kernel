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
 *  AgenticOS Organism - Agent Registry Interface (AIP-7)
 */

interface IAgentRegistry {
    /// @notice Agent profile data structure
    struct AgentProfile {
        address agentAddress;           // Agent's Ethereum address (controller of DID)
        string did;                     // Full DID (e.g., did:ethr:8453:0x...)
        string endpoint;                // HTTPS endpoint or IPFS gateway URL
        bytes32[] serviceTypes;         // Supported service type hashes (keccak256 of service name)
        uint256 stakedAmount;           // USDC staked (V1: always 0, V2: slashing for disputes)
        uint256 reputationScore;        // Aggregated reputation (scale: 0-10000, 2 decimals precision)
        uint256 totalTransactions;      // Count of completed SETTLED transactions
        uint256 disputedTransactions;   // Count of transactions that went to DISPUTED state
        uint256 totalVolumeUSDC;        // Cumulative transaction volume (6 decimals)
        uint256 registeredAt;           // Block timestamp of registration
        uint256 updatedAt;              // Last profile update timestamp
        bool isActive;                  // Agent is accepting new requests
    }

    /// @notice Service descriptor metadata (stored off-chain, hash on-chain)
    struct ServiceDescriptor {
        bytes32 serviceTypeHash;        // keccak256(lowercase(serviceType)) - MUST be lowercase
        string serviceType;             // Human-readable service type (lowercase, alphanumeric + hyphens)
        string schemaURI;               // IPFS/HTTPS URL to JSON Schema for inputData
        uint256 minPrice;               // Minimum price in USDC base units (6 decimals)
        uint256 maxPrice;               // Maximum price in USDC base units
        uint256 avgCompletionTime;      // Average completion time in seconds
        string metadataCID;             // IPFS CID to full service descriptor JSON
    }

    // ========== EVENTS ==========

    /// @notice Emitted when agent registers or updates profile
    event AgentRegistered(
        address indexed agentAddress,
        string did,
        string endpoint,
        uint256 timestamp
    );

    /// @notice Emitted when agent updates endpoint
    event EndpointUpdated(
        address indexed agentAddress,
        string oldEndpoint,
        string newEndpoint,
        uint256 timestamp
    );

    /// @notice Emitted when agent adds/removes service type
    event ServiceTypeUpdated(
        address indexed agentAddress,
        bytes32 indexed serviceTypeHash,
        bool added,
        uint256 timestamp
    );

    /// @notice Emitted when agent reputation is updated (post-transaction settlement)
    event ReputationUpdated(
        address indexed agentAddress,
        uint256 oldScore,
        uint256 newScore,
        bytes32 indexed txId,
        uint256 timestamp
    );

    /// @notice Emitted when agent active status changes
    event ActiveStatusUpdated(
        address indexed agentAddress,
        bool isActive,
        uint256 timestamp
    );

    /// @notice Emitted when transaction is processed for reputation update
    event TransactionProcessed(
        bytes32 indexed txId,
        address indexed agentAddress
    );

    // ========== CORE FUNCTIONS (msg.sender == agent) ==========

    /// @notice Register a new agent profile
    /// @dev msg.sender becomes the agentAddress; cannot register for another address
    /// @param endpoint HTTPS endpoint or IPFS gateway URL
    /// @param serviceDescriptors List of services the agent provides
    /// @dev V1: stakedAmount is ignored (set to 0 by contract)
    function registerAgent(
        string calldata endpoint,
        ServiceDescriptor[] calldata serviceDescriptors
    ) external;

    /// @notice Update agent endpoint (webhook URL or IPFS gateway)
    /// @dev Only callable by the agent itself (msg.sender == agentAddress)
    /// @param newEndpoint New endpoint URL
    function updateEndpoint(string calldata newEndpoint) external;

    /// @notice Add supported service type
    /// @dev Only callable by the agent itself (msg.sender == agentAddress)
    /// @param serviceType Lowercase service type string (e.g., "text-generation")
    function addServiceType(string calldata serviceType) external;

    /// @notice Remove supported service type
    /// @dev Only callable by the agent itself (msg.sender == agentAddress)
    /// @param serviceTypeHash keccak256 hash of service type
    function removeServiceType(bytes32 serviceTypeHash) external;

    /// @notice Update agent active status (pause/resume accepting requests)
    /// @dev Only callable by the agent itself (msg.sender == agentAddress)
    /// @param isActive New active status
    function setActiveStatus(bool isActive) external;

    // ========== VIEW FUNCTIONS ==========

    /// @notice Get agent profile by address
    /// @param agentAddress Agent's Ethereum address
    /// @return profile Agent profile struct
    function getAgent(address agentAddress)
        external
        view
        returns (AgentProfile memory profile);

    /// @notice Get agent profile by DID
    /// @param did Agent's DID (did:ethr:...)
    /// @return profile Agent profile struct
    function getAgentByDID(string calldata did)
        external
        view
        returns (AgentProfile memory profile);

    /// @notice Query agents by service type
    /// @param serviceTypeHash keccak256 of service type
    /// @param minReputation Minimum reputation score (0-10000)
    /// @param offset Skip first N results (for pagination)
    /// @param limit Maximum number of results to return
    /// @return agents List of agent addresses matching criteria
    function queryAgentsByService(
        bytes32 serviceTypeHash,
        uint256 minReputation,
        uint256 offset,
        uint256 limit
    ) external view returns (address[] memory agents);

    /// @notice Get service descriptors for an agent
    /// @param agentAddress Agent's Ethereum address
    /// @return descriptors List of service descriptors
    function getServiceDescriptors(address agentAddress)
        external
        view
        returns (ServiceDescriptor[] memory descriptors);

    /// @notice Check if agent supports a service type
    /// @param agentAddress Agent's Ethereum address
    /// @param serviceTypeHash keccak256 of service type
    /// @return supported True if agent supports the service
    function supportsService(address agentAddress, bytes32 serviceTypeHash)
        external
        view
        returns (bool supported);

    // ========== KERNEL-ONLY FUNCTIONS ==========

    /// @notice Update agent reputation (called by ACTPKernel after settlement)
    /// @dev Only callable by ACTPKernel contract
    /// @param agentAddress Agent to update
    /// @param txId Transaction ID that triggered update
    /// @param txAmount Transaction amount for volume calculation
    /// @param wasDisputed Whether transaction went through dispute
    function updateReputationOnSettlement(
        address agentAddress,
        bytes32 txId,
        uint256 txAmount,
        bool wasDisputed
    ) external;
}
