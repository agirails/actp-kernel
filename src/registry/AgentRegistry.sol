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
 *  AgenticOS Organism - Agent Registry (AIP-7)
 */

import {IAgentRegistry} from "../interfaces/IAgentRegistry.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title AgentRegistry
 * @notice On-chain registry for AI agent profiles, service capabilities, and reputation
 * @dev Implements AIP-7 Agent Identity, Registry & Storage System
 *
 * ## Query Limitations (IMPORTANT)
 *
 * The queryAgentsByService() function has an on-chain limit of MAX_QUERY_AGENTS (1000).
 * When registry exceeds 1000 agents, the function reverts with "Too many agents - use off-chain indexer".
 *
 * **For production systems with >1000 agents**:
 * 1. Use an off-chain indexer (The Graph, Goldsky, Alchemy Subgraphs)
 * 2. Index AgentRegistered, ServiceTypeUpdated, ActiveStatusUpdated events
 * 3. Query the indexer instead of calling queryAgentsByService() on-chain
 *
 * **Why this limit exists**:
 * - Gas cost grows O(n) with registry size - unbounded iteration is DoS vector
 * - At 1000 agents, a full scan costs ~3-5M gas (approaching block limits)
 * - Off-chain indexers provide better UX (instant queries, filtering, sorting)
 *
 * **SDK Support**: The SDK's AgentRegistryClient.queryAgentsByService() method
 * automatically catches the revert and throws QueryCapExceededError with
 * instructions to use an off-chain indexer.
 *
 * @custom:security-contact security@agirails.io
 */
contract AgentRegistry is IAgentRegistry, ReentrancyGuard {
    // ========== STATE VARIABLES ==========

    address public immutable actpKernel;
    uint256 public immutable chainId; // Stored at deployment for DID generation

    mapping(address => AgentProfile) public agents;
    mapping(string => address) public didToAddress; // DID string → agent address
    mapping(address => ServiceDescriptor[]) private serviceDescriptors;
    mapping(address => mapping(bytes32 => bool)) private supportedServices;
    mapping(bytes32 => bool) private processedTransactions;
    address[] private registeredAgents;

    // ========== MODIFIERS ==========

    modifier onlyRegisteredAgent() {
        require(agents[msg.sender].registeredAt > 0, "Not registered");
        _;
    }

    modifier onlyKernel() {
        require(msg.sender == actpKernel, "Only ACTPKernel");
        _;
    }

    // ========== CONSTRUCTOR ==========

    constructor(address _actpKernel) {
        require(_actpKernel != address(0), "Kernel addr required");
        actpKernel = _actpKernel;
        chainId = block.chainid; // Store as decimal for DID format
    }

    // ========== CORE FUNCTIONS ==========

    uint256 public constant MAX_SERVICE_DESCRIPTORS = 100;
    uint256 public constant MAX_REGISTERED_AGENTS = 10000;
    uint256 public constant MAX_QUERY_AGENTS = 1000;
    uint256 public constant MAX_SERVICE_TYPE_LENGTH = 64;
    uint256 public constant MAX_ENDPOINT_LENGTH = 256;

    function registerAgent(
        string calldata endpoint,
        ServiceDescriptor[] calldata serviceDescriptors_
    ) external override {
        require(agents[msg.sender].registeredAt == 0, "Already registered");
        require(bytes(endpoint).length > 0, "Empty endpoint");
        require(bytes(endpoint).length <= MAX_ENDPOINT_LENGTH, "Endpoint too long");
        require(serviceDescriptors_.length > 0, "At least one service required");
        require(serviceDescriptors_.length <= MAX_SERVICE_DESCRIPTORS, "Too many services");
        require(registeredAgents.length < MAX_REGISTERED_AGENTS, "Registry full");

        // Validate and normalize service types (MUST be lowercase, no whitespace)
        bytes32[] memory serviceTypeHashes = new bytes32[](serviceDescriptors_.length);
        for (uint256 i = 0; i < serviceDescriptors_.length; i++) {
            bytes32 computedHash = _validateServiceType(serviceDescriptors_[i].serviceType);
            require(computedHash == serviceDescriptors_[i].serviceTypeHash, "Hash mismatch");
            serviceTypeHashes[i] = computedHash;

            // Store service descriptor
            serviceDescriptors[msg.sender].push(serviceDescriptors_[i]);
            supportedServices[msg.sender][computedHash] = true;
        }

        // Build DID: did:ethr:<chainId>:<address>
        string memory did = string(abi.encodePacked(
            "did:ethr:",
            _toString(chainId),
            ":",
            _toLowerAddress(msg.sender)
        ));

        agents[msg.sender] = AgentProfile({
            agentAddress: msg.sender,
            did: did,
            endpoint: endpoint,
            serviceTypes: serviceTypeHashes,
            stakedAmount: 0,
            reputationScore: 0,
            totalTransactions: 0,
            disputedTransactions: 0,
            totalVolumeUSDC: 0,
            registeredAt: block.timestamp,
            updatedAt: block.timestamp,
            isActive: true
        });

        require(didToAddress[did] == address(0), "DID already registered");
        didToAddress[did] = msg.sender;
        registeredAgents.push(msg.sender);

        emit AgentRegistered(msg.sender, did, endpoint, block.timestamp);
    }

    function updateEndpoint(string calldata newEndpoint) external override onlyRegisteredAgent {
        require(bytes(newEndpoint).length > 0, "Empty endpoint");
        require(bytes(newEndpoint).length <= MAX_ENDPOINT_LENGTH, "Endpoint too long");

        string memory oldEndpoint = agents[msg.sender].endpoint;
        agents[msg.sender].endpoint = newEndpoint;
        agents[msg.sender].updatedAt = block.timestamp;

        emit EndpointUpdated(msg.sender, oldEndpoint, newEndpoint, block.timestamp);
    }

    function addServiceType(string calldata serviceType) external override onlyRegisteredAgent {
        require(serviceDescriptors[msg.sender].length < MAX_SERVICE_DESCRIPTORS, "Service limit reached");

        bytes32 serviceTypeHash = _validateServiceType(serviceType);
        require(!supportedServices[msg.sender][serviceTypeHash], "Service already added");

        agents[msg.sender].serviceTypes.push(serviceTypeHash);
        supportedServices[msg.sender][serviceTypeHash] = true;
        agents[msg.sender].updatedAt = block.timestamp;

        serviceDescriptors[msg.sender].push(ServiceDescriptor({
            serviceTypeHash: serviceTypeHash,
            serviceType: serviceType,
            schemaURI: "",
            minPrice: 0,
            maxPrice: 0,
            avgCompletionTime: 0,
            metadataCID: ""
        }));

        emit ServiceTypeUpdated(msg.sender, serviceTypeHash, true, block.timestamp);
    }

    function removeServiceType(bytes32 serviceTypeHash) external override onlyRegisteredAgent {
        require(supportedServices[msg.sender][serviceTypeHash], "Service not found");

        // Remove from serviceTypes array
        bytes32[] storage serviceTypes = agents[msg.sender].serviceTypes;
        for (uint256 i = 0; i < serviceTypes.length; i++) {
            if (serviceTypes[i] == serviceTypeHash) {
                serviceTypes[i] = serviceTypes[serviceTypes.length - 1];
                serviceTypes.pop();
                break;
            }
        }

        ServiceDescriptor[] storage descriptors = serviceDescriptors[msg.sender];
        for (uint256 i = 0; i < descriptors.length; i++) {
            if (descriptors[i].serviceTypeHash == serviceTypeHash) {
                descriptors[i] = descriptors[descriptors.length - 1];
                descriptors.pop();
                break;
            }
        }

        supportedServices[msg.sender][serviceTypeHash] = false;
        agents[msg.sender].updatedAt = block.timestamp;

        emit ServiceTypeUpdated(msg.sender, serviceTypeHash, false, block.timestamp);
    }

    function setActiveStatus(bool isActive) external override onlyRegisteredAgent {
        agents[msg.sender].isActive = isActive;
        agents[msg.sender].updatedAt = block.timestamp;

        emit ActiveStatusUpdated(msg.sender, isActive, block.timestamp);
    }

    // ========== VIEW FUNCTIONS ==========

    function getAgent(address agentAddress)
        external
        view
        override
        returns (AgentProfile memory profile)
    {
        return agents[agentAddress];
    }

    function getAgentByDID(string calldata did)
        external
        view
        override
        returns (AgentProfile memory profile)
    {
        bytes memory didBytes = bytes(did);
        require(didBytes.length >= 20 && didBytes.length <= 100, "Invalid DID length");

        address agentAddress = didToAddress[did];
        return agents[agentAddress];
    }

    /**
     * @notice Query agents that support a specific service type
     * @dev IMPORTANT: This function reverts when registry size exceeds MAX_QUERY_AGENTS (1000).
     *      For production systems, use an off-chain indexer instead.
     *      See contract-level NatSpec for migration guidance.
     *
     * @dev [H-2 SECURITY FIX] Enforces strict limit validation to prevent DoS
     *      - limit parameter must be between 1-100 (prevents unbounded iteration)
     *      - Registry size capped at MAX_QUERY_AGENTS (1000)
     *      - Early exit when limit reached
     *
     * @param serviceTypeHash keccak256 hash of the service type string
     * @param minReputation Minimum reputation score (0-10000 scale)
     * @param offset Number of matching results to skip (pagination)
     * @param limit Maximum results to return (MUST be 1-100, use pagination for more)
     * @return Array of agent addresses matching criteria
     */
    function queryAgentsByService(
        bytes32 serviceTypeHash,
        uint256 minReputation,
        uint256 offset,
        uint256 limit
    ) external view override returns (address[] memory) {
        // [H-2 FIX] Enforce strict limit bounds to prevent DoS (reject limit=0 or limit>100)
        require(limit > 0 && limit <= 100, "Limit must be 1-100");

        // [L-4] Enforce query cap to prevent DoS via unbounded iteration
        // When exceeded, callers must migrate to off-chain indexer
        require(registeredAgents.length <= MAX_QUERY_AGENTS, "Too many agents - use off-chain indexer");

        address[] memory tempResults = new address[](limit);
        uint256 collected = 0;
        uint256 skipped = 0;

        for (uint256 i = 0; i < registeredAgents.length; i++) {
            address agent = registeredAgents[i];
            AgentProfile storage profile = agents[agent];

            if (supportedServices[agent][serviceTypeHash] &&
                profile.reputationScore >= minReputation &&
                profile.isActive) {

                if (skipped < offset) {
                    skipped++;
                } else if (collected < limit) {
                    tempResults[collected] = agent;
                    collected++;
                } else {
                    break; // Early exit when limit reached
                }
            }
        }

        // Trim to actual size
        address[] memory results = new address[](collected);
        for (uint256 i = 0; i < collected; i++) {
            results[i] = tempResults[i];
        }
        return results;
    }

    function getServiceDescriptors(address agentAddress)
        external
        view
        override
        returns (ServiceDescriptor[] memory descriptors)
    {
        return serviceDescriptors[agentAddress];
    }

    function supportsService(address agentAddress, bytes32 serviceTypeHash)
        external
        view
        override
        returns (bool supported)
    {
        return supportedServices[agentAddress][serviceTypeHash];
    }

    // ========== KERNEL-ONLY FUNCTIONS ==========

    function updateReputationOnSettlement(
        address agentAddress,
        bytes32 txId,
        uint256 txAmount,
        bool wasDisputed
    ) external override onlyKernel {
        require(agentAddress != address(0), "Zero address");
        AgentProfile storage profile = agents[agentAddress];
        require(profile.registeredAt > 0, "Agent not registered");

        require(!processedTransactions[txId], "Transaction already processed");
        processedTransactions[txId] = true;

        uint256 oldScore = profile.reputationScore;

        // Atomic update of all reputation-related fields
        profile.totalTransactions += 1;
        profile.totalVolumeUSDC += txAmount;
        if (wasDisputed) {
            profile.disputedTransactions += 1;
        }

        // Recalculate reputation score (formula defined in AIP-7 §3.4)
        uint256 newScore = _calculateReputationScore(profile);
        profile.reputationScore = newScore;
        profile.updatedAt = block.timestamp;

        emit ReputationUpdated(agentAddress, oldScore, newScore, txId, block.timestamp);
        emit TransactionProcessed(txId, agentAddress);
    }

    // ========== INTERNAL HELPERS ==========

    /// @dev Calculate reputation score based on success rate and volume
    /// @dev SECURITY [M-4 FIX]: Increased volume thresholds to resist Sybil attacks
    ///      Previous thresholds ($10, $100, $1K, $10K) allowed reputation inflation
    ///      with minimal capital. New thresholds require substantial transaction volume.
    /// @param profile Agent profile to calculate score for
    /// @return score Reputation score (0-10000 scale)
    function _calculateReputationScore(AgentProfile storage profile) internal view returns (uint256) {
        require(profile.disputedTransactions <= profile.totalTransactions, "Data corruption detected");

        // Success Rate component (0-10000 scale, 70% weight)
        uint256 successRate = 10000; // Default 100% if no disputes
        if (profile.totalTransactions > 0) {
            successRate = ((profile.totalTransactions - profile.disputedTransactions) * 10000) / profile.totalTransactions;
        }
        uint256 successComponent = (successRate * 7000) / 10000;

        // Volume component (0-10000 scale, 30% weight)
        // SECURITY [M-4 FIX]: 10x increase in volume thresholds for Sybil resistance
        // Previous: $10, $100, $1K, $10K (vulnerable to $50 self-transaction attacks)
        // New: $100, $1K, $10K, $100K (requires substantial capital to game)
        uint256 volumeUSD = profile.totalVolumeUSDC / 1e6; // Convert from 6-decimal USDC to USD
        uint256 logVolume = 0;
        if (volumeUSD >= 100000) {        // $100K+ volume → full volume score
            logVolume = 10000;
        } else if (volumeUSD >= 10000) {  // $10K-$100K → high volume score
            logVolume = 7500;
        } else if (volumeUSD >= 1000) {   // $1K-$10K → medium volume score
            logVolume = 5000;
        } else if (volumeUSD >= 100) {    // $100-$1K → low volume score
            logVolume = 2500;
        }
        // Below $100 → 0 volume component (no reputation boost from micro-transactions)
        uint256 volumeComponent = (logVolume * 3000) / 10000;

        uint256 score = successComponent + volumeComponent;
        return score > 10000 ? 10000 : score;
    }

    /// @dev Convert address to lowercase hex string with 0x prefix
    function _toLowerAddress(address addr) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory data = abi.encodePacked(addr);
        bytes memory str = new bytes(42);
        str[0] = '0';
        str[1] = 'x';
        for (uint256 i = 0; i < 20; i++) {
            str[2 + i * 2] = alphabet[uint8(data[i] >> 4)];
            str[2 + i * 2 + 1] = alphabet[uint8(data[i] & 0x0f)];
        }
        return string(str);
    }

    /// @dev Convert uint256 to decimal string
    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    /// @dev Validate service type format and return its hash
    function _validateServiceType(string calldata serviceType) internal pure returns (bytes32) {
        bytes memory serviceTypeBytes = bytes(serviceType);
        require(serviceTypeBytes.length > 0, "Empty service type");
        require(serviceTypeBytes.length <= MAX_SERVICE_TYPE_LENGTH, "Service type too long");

        for (uint256 j = 0; j < serviceTypeBytes.length; j++) {
            bytes1 char = serviceTypeBytes[j];

            // Reject whitespace (space, tab, newline, etc.)
            require(char != 0x20 && char != 0x09 && char != 0x0A && char != 0x0D,
                "Service type contains whitespace");

            // Reject uppercase A-Z (0x41-0x5A)
            require(char < 0x41 || char > 0x5A, "Service type must be lowercase");

            // Allow only: lowercase a-z (0x61-0x7A), digits 0-9 (0x30-0x39), hyphen (0x2D)
            require(
                (char >= 0x61 && char <= 0x7A) || // a-z
                (char >= 0x30 && char <= 0x39) || // 0-9
                char == 0x2D,                      // hyphen
                "Invalid character in service type (allowed: a-z, 0-9, hyphen)"
            );

            // Check for consecutive hyphens
            if (j > 0 && char == 0x2D && serviceTypeBytes[j - 1] == 0x2D) {
                revert("Consecutive hyphens");
            }
        }

        require(serviceTypeBytes[0] != 0x2D, "Cannot start with hyphen");
        require(serviceTypeBytes[serviceTypeBytes.length - 1] != 0x2D, "Cannot end with hyphen");

        return keccak256(abi.encodePacked(serviceType));
    }

}
