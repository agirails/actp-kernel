// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/registry/AgentRegistry.sol";
import "../src/ACTPKernel.sol";
import "../src/tokens/MockUSDC.sol";

/**
 * @title AgentRegistryTest
 * @notice Comprehensive tests for AgentRegistry (AIP-7)
 * @dev Covers registration, reputation, DID, queries, and access control
 */
contract AgentRegistryTest is Test {
    // Copy events from interface for testing
    event AgentRegistered(address indexed agentAddress, string did, string endpoint, uint256 timestamp);
    event EndpointUpdated(address indexed agentAddress, string oldEndpoint, string newEndpoint, uint256 timestamp);
    event ServiceTypeUpdated(address indexed agentAddress, bytes32 indexed serviceTypeHash, bool added, uint256 timestamp);
    event ReputationUpdated(address indexed agentAddress, uint256 oldScore, uint256 newScore, bytes32 indexed txId, uint256 timestamp);
    event ActiveStatusUpdated(address indexed agentAddress, bool isActive, uint256 timestamp);
    event TransactionProcessed(bytes32 indexed txId, address indexed agentAddress);
    AgentRegistry registry;
    ACTPKernel kernel;
    MockUSDC usdc;

    address admin = address(this);
    address agent1 = address(0xA1);
    address agent2 = address(0xA2);
    address agent3 = address(0xA3);
    address nonAgent = address(0xBAD);
    address feeCollector = address(0xFEE);

    uint256 constant ONE_USDC = 1_000_000; // 6 decimals

    function setUp() external {
        // Deploy kernel first (registry needs kernel address)
        usdc = new MockUSDC();
        kernel = new ACTPKernel(admin, admin, feeCollector, address(0), address(usdc));
        registry = new AgentRegistry(address(kernel));
    }

    // ============================================
    // CONSTRUCTOR TESTS
    // ============================================

    function testConstructorRejectsZeroKernel() external {
        vm.expectRevert("Kernel addr required");
        new AgentRegistry(address(0));
    }

    function testConstructorStoresChainId() external {
        assertEq(registry.chainId(), block.chainid);
    }

    function testConstructorStoresKernelAddress() external {
        assertEq(registry.actpKernel(), address(kernel));
    }

    // ============================================
    // REGISTER AGENT TESTS
    // ============================================

    function testRegisterAgentSuccess() external {
        IAgentRegistry.ServiceDescriptor[] memory services = _createSingleService("text-generation");

        vm.prank(agent1);
        registry.registerAgent("https://agent1.example.com/webhook", services);

        IAgentRegistry.AgentProfile memory profile = registry.getAgent(agent1);
        assertEq(profile.agentAddress, agent1);
        assertEq(profile.endpoint, "https://agent1.example.com/webhook");
        assertEq(profile.serviceTypes.length, 1);
        assertEq(profile.serviceTypes[0], keccak256(abi.encodePacked("text-generation")));
        assertEq(profile.reputationScore, 0);
        assertEq(profile.totalTransactions, 0);
        assertEq(profile.disputedTransactions, 0);
        assertEq(profile.totalVolumeUSDC, 0);
        assertGt(profile.registeredAt, 0);
        assertTrue(profile.isActive);
    }

    function testRegisterAgentEmitsEvent() external {
        IAgentRegistry.ServiceDescriptor[] memory services = _createSingleService("code-review");

        vm.expectEmit(true, false, false, true);
        emit AgentRegistered(
            agent1,
            string(abi.encodePacked("did:ethr:", _toString(block.chainid), ":", _toLowerAddress(agent1))),
            "https://agent1.example.com",
            block.timestamp
        );

        vm.prank(agent1);
        registry.registerAgent("https://agent1.example.com", services);
    }

    function testRegisterAgentRejectsDoubleRegistration() external {
        IAgentRegistry.ServiceDescriptor[] memory services = _createSingleService("text-generation");

        vm.prank(agent1);
        registry.registerAgent("https://agent1.example.com", services);

        vm.prank(agent1);
        vm.expectRevert("Already registered");
        registry.registerAgent("https://agent1.example.com/v2", services);
    }

    function testRegisterAgentRejectsEmptyEndpoint() external {
        IAgentRegistry.ServiceDescriptor[] memory services = _createSingleService("text-generation");

        vm.prank(agent1);
        vm.expectRevert("Empty endpoint");
        registry.registerAgent("", services);
    }

    function testRegisterAgentRejectsTooLongEndpoint() external {
        IAgentRegistry.ServiceDescriptor[] memory services = _createSingleService("text-generation");

        // Create endpoint longer than MAX_ENDPOINT_LENGTH (256)
        bytes memory longEndpoint = new bytes(257);
        for (uint i = 0; i < 257; i++) {
            longEndpoint[i] = "a";
        }

        vm.prank(agent1);
        vm.expectRevert("Endpoint too long");
        registry.registerAgent(string(longEndpoint), services);
    }

    function testRegisterAgentRejectsNoServices() external {
        IAgentRegistry.ServiceDescriptor[] memory services = new IAgentRegistry.ServiceDescriptor[](0);

        vm.prank(agent1);
        vm.expectRevert("At least one service required");
        registry.registerAgent("https://agent1.example.com", services);
    }

    function testRegisterAgentRejectsTooManyServices() external {
        // Create 101 services (MAX is 100)
        IAgentRegistry.ServiceDescriptor[] memory services = new IAgentRegistry.ServiceDescriptor[](101);
        for (uint i = 0; i < 101; i++) {
            string memory serviceType = string(abi.encodePacked("service", _toString(i)));
            services[i] = IAgentRegistry.ServiceDescriptor({
                serviceTypeHash: keccak256(abi.encodePacked(serviceType)),
                serviceType: serviceType,
                schemaURI: "",
                minPrice: 0,
                maxPrice: 0,
                avgCompletionTime: 0,
                metadataCID: ""
            });
        }

        vm.prank(agent1);
        vm.expectRevert("Too many services");
        registry.registerAgent("https://agent1.example.com", services);
    }

    function testRegisterAgentRejectsHashMismatch() external {
        IAgentRegistry.ServiceDescriptor[] memory services = new IAgentRegistry.ServiceDescriptor[](1);
        services[0] = IAgentRegistry.ServiceDescriptor({
            serviceTypeHash: keccak256(abi.encodePacked("wrong-hash")), // Wrong hash
            serviceType: "text-generation",
            schemaURI: "",
            minPrice: 0,
            maxPrice: 0,
            avgCompletionTime: 0,
            metadataCID: ""
        });

        vm.prank(agent1);
        vm.expectRevert("Hash mismatch");
        registry.registerAgent("https://agent1.example.com", services);
    }

    // ============================================
    // SERVICE TYPE VALIDATION TESTS
    // ============================================

    function testRejectsUppercaseServiceType() external {
        IAgentRegistry.ServiceDescriptor[] memory services = new IAgentRegistry.ServiceDescriptor[](1);
        services[0] = IAgentRegistry.ServiceDescriptor({
            serviceTypeHash: keccak256(abi.encodePacked("Text-Generation")), // Uppercase
            serviceType: "Text-Generation",
            schemaURI: "",
            minPrice: 0,
            maxPrice: 0,
            avgCompletionTime: 0,
            metadataCID: ""
        });

        vm.prank(agent1);
        vm.expectRevert("Service type must be lowercase");
        registry.registerAgent("https://agent1.example.com", services);
    }

    function testRejectsServiceTypeWithWhitespace() external {
        IAgentRegistry.ServiceDescriptor[] memory services = new IAgentRegistry.ServiceDescriptor[](1);
        services[0] = IAgentRegistry.ServiceDescriptor({
            serviceTypeHash: keccak256(abi.encodePacked("text generation")), // Space
            serviceType: "text generation",
            schemaURI: "",
            minPrice: 0,
            maxPrice: 0,
            avgCompletionTime: 0,
            metadataCID: ""
        });

        vm.prank(agent1);
        vm.expectRevert("Service type contains whitespace");
        registry.registerAgent("https://agent1.example.com", services);
    }

    function testRejectsServiceTypeWithInvalidChars() external {
        IAgentRegistry.ServiceDescriptor[] memory services = new IAgentRegistry.ServiceDescriptor[](1);
        services[0] = IAgentRegistry.ServiceDescriptor({
            serviceTypeHash: keccak256(abi.encodePacked("text_generation")), // Underscore
            serviceType: "text_generation",
            schemaURI: "",
            minPrice: 0,
            maxPrice: 0,
            avgCompletionTime: 0,
            metadataCID: ""
        });

        vm.prank(agent1);
        vm.expectRevert("Invalid character in service type (allowed: a-z, 0-9, hyphen)");
        registry.registerAgent("https://agent1.example.com", services);
    }

    function testRejectsConsecutiveHyphens() external {
        IAgentRegistry.ServiceDescriptor[] memory services = new IAgentRegistry.ServiceDescriptor[](1);
        services[0] = IAgentRegistry.ServiceDescriptor({
            serviceTypeHash: keccak256(abi.encodePacked("text--generation")), // Double hyphen
            serviceType: "text--generation",
            schemaURI: "",
            minPrice: 0,
            maxPrice: 0,
            avgCompletionTime: 0,
            metadataCID: ""
        });

        vm.prank(agent1);
        vm.expectRevert("Consecutive hyphens");
        registry.registerAgent("https://agent1.example.com", services);
    }

    function testRejectsLeadingHyphen() external {
        IAgentRegistry.ServiceDescriptor[] memory services = new IAgentRegistry.ServiceDescriptor[](1);
        services[0] = IAgentRegistry.ServiceDescriptor({
            serviceTypeHash: keccak256(abi.encodePacked("-text-generation")),
            serviceType: "-text-generation",
            schemaURI: "",
            minPrice: 0,
            maxPrice: 0,
            avgCompletionTime: 0,
            metadataCID: ""
        });

        vm.prank(agent1);
        vm.expectRevert("Cannot start with hyphen");
        registry.registerAgent("https://agent1.example.com", services);
    }

    function testRejectsTrailingHyphen() external {
        IAgentRegistry.ServiceDescriptor[] memory services = new IAgentRegistry.ServiceDescriptor[](1);
        services[0] = IAgentRegistry.ServiceDescriptor({
            serviceTypeHash: keccak256(abi.encodePacked("text-generation-")),
            serviceType: "text-generation-",
            schemaURI: "",
            minPrice: 0,
            maxPrice: 0,
            avgCompletionTime: 0,
            metadataCID: ""
        });

        vm.prank(agent1);
        vm.expectRevert("Cannot end with hyphen");
        registry.registerAgent("https://agent1.example.com", services);
    }

    function testAcceptsValidServiceTypes() external {
        // Test various valid formats
        string[5] memory validTypes = [
            "text-generation",
            "code-review-v2",
            "summarize123",
            "a",
            "abc123def456"
        ];

        for (uint i = 0; i < validTypes.length; i++) {
            AgentRegistry tempRegistry = new AgentRegistry(address(kernel));
            address tempAgent = address(uint160(0x1000 + i));

            IAgentRegistry.ServiceDescriptor[] memory services = new IAgentRegistry.ServiceDescriptor[](1);
            services[0] = IAgentRegistry.ServiceDescriptor({
                serviceTypeHash: keccak256(abi.encodePacked(validTypes[i])),
                serviceType: validTypes[i],
                schemaURI: "",
                minPrice: 0,
                maxPrice: 0,
                avgCompletionTime: 0,
                metadataCID: ""
            });

            vm.prank(tempAgent);
            tempRegistry.registerAgent("https://example.com", services);

            assertTrue(tempRegistry.supportsService(tempAgent, keccak256(abi.encodePacked(validTypes[i]))));
        }
    }

    // ============================================
    // DID GENERATION AND LOOKUP TESTS
    // ============================================

    function testDIDGenerationFormat() external {
        IAgentRegistry.ServiceDescriptor[] memory services = _createSingleService("text-generation");

        vm.prank(agent1);
        registry.registerAgent("https://agent1.example.com", services);

        IAgentRegistry.AgentProfile memory profile = registry.getAgent(agent1);

        // Verify DID format: did:ethr:<chainId>:<lowercase_address>
        string memory expectedDid = string(abi.encodePacked(
            "did:ethr:",
            _toString(block.chainid),
            ":",
            _toLowerAddress(agent1)
        ));

        assertEq(profile.did, expectedDid);
    }

    function testGetAgentByDID() external {
        IAgentRegistry.ServiceDescriptor[] memory services = _createSingleService("text-generation");

        vm.prank(agent1);
        registry.registerAgent("https://agent1.example.com", services);

        string memory did = string(abi.encodePacked(
            "did:ethr:",
            _toString(block.chainid),
            ":",
            _toLowerAddress(agent1)
        ));

        IAgentRegistry.AgentProfile memory profile = registry.getAgentByDID(did);
        assertEq(profile.agentAddress, agent1);
    }

    function testGetAgentByDIDRejectsInvalidLength() external {
        vm.expectRevert("Invalid DID length");
        registry.getAgentByDID("short");

        // Too long (>100 chars)
        bytes memory longDid = new bytes(101);
        for (uint i = 0; i < 101; i++) {
            longDid[i] = "a";
        }
        vm.expectRevert("Invalid DID length");
        registry.getAgentByDID(string(longDid));
    }

    function testGetAgentByDIDReturnsZeroForUnregistered() external {
        string memory fakeDid = "did:ethr:12345:0x0000000000000000000000000000000000000001";
        IAgentRegistry.AgentProfile memory profile = registry.getAgentByDID(fakeDid);
        assertEq(profile.agentAddress, address(0));
        assertEq(profile.registeredAt, 0);
    }

    // ============================================
    // UPDATE ENDPOINT TESTS
    // ============================================

    function testUpdateEndpointSuccess() external {
        _registerAgent(agent1, "text-generation");

        vm.prank(agent1);
        registry.updateEndpoint("https://agent1.example.com/v2");

        IAgentRegistry.AgentProfile memory profile = registry.getAgent(agent1);
        assertEq(profile.endpoint, "https://agent1.example.com/v2");
    }

    function testUpdateEndpointEmitsEvent() external {
        _registerAgent(agent1, "text-generation");

        vm.expectEmit(true, false, false, true);
        emit EndpointUpdated(
            agent1,
            "https://example.com",
            "https://new.example.com",
            block.timestamp
        );

        vm.prank(agent1);
        registry.updateEndpoint("https://new.example.com");
    }

    function testUpdateEndpointRejectsNonRegistered() external {
        vm.prank(nonAgent);
        vm.expectRevert("Not registered");
        registry.updateEndpoint("https://new.example.com");
    }

    function testUpdateEndpointRejectsEmptyEndpoint() external {
        _registerAgent(agent1, "text-generation");

        vm.prank(agent1);
        vm.expectRevert("Empty endpoint");
        registry.updateEndpoint("");
    }

    function testUpdateEndpointRejectsTooLong() external {
        _registerAgent(agent1, "text-generation");

        bytes memory longEndpoint = new bytes(257);
        for (uint i = 0; i < 257; i++) {
            longEndpoint[i] = "a";
        }

        vm.prank(agent1);
        vm.expectRevert("Endpoint too long");
        registry.updateEndpoint(string(longEndpoint));
    }

    // ============================================
    // ADD/REMOVE SERVICE TYPE TESTS
    // ============================================

    function testAddServiceTypeSuccess() external {
        _registerAgent(agent1, "text-generation");

        vm.prank(agent1);
        registry.addServiceType("code-review");

        assertTrue(registry.supportsService(agent1, keccak256(abi.encodePacked("code-review"))));

        IAgentRegistry.AgentProfile memory profile = registry.getAgent(agent1);
        assertEq(profile.serviceTypes.length, 2);
    }

    function testAddServiceTypeEmitsEvent() external {
        _registerAgent(agent1, "text-generation");

        bytes32 serviceHash = keccak256(abi.encodePacked("code-review"));

        vm.expectEmit(true, true, false, true);
        emit ServiceTypeUpdated(agent1, serviceHash, true, block.timestamp);

        vm.prank(agent1);
        registry.addServiceType("code-review");
    }

    function testAddServiceTypeRejectsNonRegistered() external {
        vm.prank(nonAgent);
        vm.expectRevert("Not registered");
        registry.addServiceType("code-review");
    }

    function testAddServiceTypeRejectsDuplicate() external {
        _registerAgent(agent1, "text-generation");

        vm.prank(agent1);
        vm.expectRevert("Service already added");
        registry.addServiceType("text-generation");
    }

    function testAddServiceTypeRejectsAtLimit() external {
        // Register with 100 services (max)
        IAgentRegistry.ServiceDescriptor[] memory services = new IAgentRegistry.ServiceDescriptor[](100);
        for (uint i = 0; i < 100; i++) {
            string memory serviceType = string(abi.encodePacked("service", _toString(i)));
            services[i] = IAgentRegistry.ServiceDescriptor({
                serviceTypeHash: keccak256(abi.encodePacked(serviceType)),
                serviceType: serviceType,
                schemaURI: "",
                minPrice: 0,
                maxPrice: 0,
                avgCompletionTime: 0,
                metadataCID: ""
            });
        }

        vm.prank(agent1);
        registry.registerAgent("https://example.com", services);

        // Try to add one more
        vm.prank(agent1);
        vm.expectRevert("Service limit reached");
        registry.addServiceType("newservice");
    }

    function testRemoveServiceTypeSuccess() external {
        _registerAgent(agent1, "text-generation");

        vm.prank(agent1);
        registry.addServiceType("code-review");

        bytes32 serviceHash = keccak256(abi.encodePacked("code-review"));
        assertTrue(registry.supportsService(agent1, serviceHash));

        vm.prank(agent1);
        registry.removeServiceType(serviceHash);

        assertFalse(registry.supportsService(agent1, serviceHash));
    }

    function testRemoveServiceTypeEmitsEvent() external {
        _registerAgent(agent1, "text-generation");

        bytes32 serviceHash = keccak256(abi.encodePacked("text-generation"));

        vm.expectEmit(true, true, false, true);
        emit ServiceTypeUpdated(agent1, serviceHash, false, block.timestamp);

        vm.prank(agent1);
        registry.removeServiceType(serviceHash);
    }

    function testRemoveServiceTypeRejectsNonRegistered() external {
        vm.prank(nonAgent);
        vm.expectRevert("Not registered");
        registry.removeServiceType(keccak256(abi.encodePacked("text-generation")));
    }

    function testRemoveServiceTypeRejectsNotFound() external {
        _registerAgent(agent1, "text-generation");

        vm.prank(agent1);
        vm.expectRevert("Service not found");
        registry.removeServiceType(keccak256(abi.encodePacked("code-review")));
    }

    // ============================================
    // SET ACTIVE STATUS TESTS
    // ============================================

    function testSetActiveStatusSuccess() external {
        _registerAgent(agent1, "text-generation");

        assertTrue(registry.getAgent(agent1).isActive);

        vm.prank(agent1);
        registry.setActiveStatus(false);

        assertFalse(registry.getAgent(agent1).isActive);

        vm.prank(agent1);
        registry.setActiveStatus(true);

        assertTrue(registry.getAgent(agent1).isActive);
    }

    function testSetActiveStatusEmitsEvent() external {
        _registerAgent(agent1, "text-generation");

        vm.expectEmit(true, false, false, true);
        emit ActiveStatusUpdated(agent1, false, block.timestamp);

        vm.prank(agent1);
        registry.setActiveStatus(false);
    }

    function testSetActiveStatusRejectsNonRegistered() external {
        vm.prank(nonAgent);
        vm.expectRevert("Not registered");
        registry.setActiveStatus(false);
    }

    // ============================================
    // QUERY AGENTS BY SERVICE TESTS
    // ============================================

    function testQueryAgentsByServiceReturnsMatchingAgents() external {
        _registerAgent(agent1, "text-generation");
        _registerAgent(agent2, "text-generation");
        _registerAgent(agent3, "code-review");

        bytes32 textGenHash = keccak256(abi.encodePacked("text-generation"));
        address[] memory results = registry.queryAgentsByService(textGenHash, 0, 0, 10);

        assertEq(results.length, 2);
        assertTrue(results[0] == agent1 || results[1] == agent1);
        assertTrue(results[0] == agent2 || results[1] == agent2);
    }

    function testQueryAgentsByServiceRespectsMinReputation() external {
        _registerAgent(agent1, "text-generation");
        _registerAgent(agent2, "text-generation");

        // Give agent1 some reputation via kernel
        _updateReputation(agent1, 100 * ONE_USDC, false);

        bytes32 textGenHash = keccak256(abi.encodePacked("text-generation"));

        // Query with high reputation threshold - only agent1 should match
        address[] memory results = registry.queryAgentsByService(textGenHash, 1000, 0, 10);

        assertEq(results.length, 1);
        assertEq(results[0], agent1);
    }

    function testQueryAgentsByServiceRespectsPagination() external {
        _registerAgent(agent1, "text-generation");
        _registerAgent(agent2, "text-generation");
        _registerAgent(agent3, "text-generation");

        bytes32 textGenHash = keccak256(abi.encodePacked("text-generation"));

        // Get first page (limit 2)
        address[] memory page1 = registry.queryAgentsByService(textGenHash, 0, 0, 2);
        assertEq(page1.length, 2);

        // Get second page (offset 2, limit 2)
        address[] memory page2 = registry.queryAgentsByService(textGenHash, 0, 2, 2);
        assertEq(page2.length, 1);
    }

    function testQueryAgentsByServiceExcludesInactive() external {
        _registerAgent(agent1, "text-generation");
        _registerAgent(agent2, "text-generation");

        // Deactivate agent2
        vm.prank(agent2);
        registry.setActiveStatus(false);

        bytes32 textGenHash = keccak256(abi.encodePacked("text-generation"));
        address[] memory results = registry.queryAgentsByService(textGenHash, 0, 0, 10);

        assertEq(results.length, 1);
        assertEq(results[0], agent1);
    }

    function testQueryAgentsByServiceReturnsEmptyForNoMatch() external {
        _registerAgent(agent1, "text-generation");

        bytes32 codeReviewHash = keccak256(abi.encodePacked("code-review"));
        address[] memory results = registry.queryAgentsByService(codeReviewHash, 0, 0, 10);

        assertEq(results.length, 0);
    }

    function testQueryAgentsByServiceRejectsLimitZero() external {
        _registerAgent(agent1, "text-generation");
        _registerAgent(agent2, "text-generation");
        _registerAgent(agent3, "text-generation");

        bytes32 textGenHash = keccak256(abi.encodePacked("text-generation"));

        // SECURITY: limit=0 is now rejected, must be 1-100
        vm.expectRevert("Limit must be 1-100");
        registry.queryAgentsByService(textGenHash, 0, 0, 0);
    }

    // ============================================
    // REPUTATION UPDATE TESTS
    // ============================================

    function testUpdateReputationOnSettlementSuccess() external {
        _registerAgent(agent1, "text-generation");

        bytes32 txId = keccak256("tx1");
        uint256 txAmount = 100 * ONE_USDC;

        vm.prank(address(kernel));
        registry.updateReputationOnSettlement(agent1, txId, txAmount, false);

        IAgentRegistry.AgentProfile memory profile = registry.getAgent(agent1);
        assertEq(profile.totalTransactions, 1);
        assertEq(profile.disputedTransactions, 0);
        assertEq(profile.totalVolumeUSDC, txAmount);
        assertGt(profile.reputationScore, 0);
    }

    function testUpdateReputationOnSettlementWithDispute() external {
        _registerAgent(agent1, "text-generation");

        bytes32 txId = keccak256("tx1");
        uint256 txAmount = 100 * ONE_USDC;

        vm.prank(address(kernel));
        registry.updateReputationOnSettlement(agent1, txId, txAmount, true);

        IAgentRegistry.AgentProfile memory profile = registry.getAgent(agent1);
        assertEq(profile.totalTransactions, 1);
        assertEq(profile.disputedTransactions, 1);
        assertEq(profile.totalVolumeUSDC, txAmount);
    }

    function testUpdateReputationEmitsEvents() external {
        _registerAgent(agent1, "text-generation");

        bytes32 txId = keccak256("tx1");

        vm.expectEmit(true, true, false, false);
        emit ReputationUpdated(agent1, 0, 0, txId, 0); // We don't check newScore exactly

        vm.expectEmit(true, true, false, false);
        emit TransactionProcessed(txId, agent1);

        vm.prank(address(kernel));
        registry.updateReputationOnSettlement(agent1, txId, 100 * ONE_USDC, false);
    }

    function testUpdateReputationRejectsNonKernel() external {
        _registerAgent(agent1, "text-generation");

        vm.prank(nonAgent);
        vm.expectRevert("Only ACTPKernel");
        registry.updateReputationOnSettlement(agent1, keccak256("tx1"), ONE_USDC, false);
    }

    function testUpdateReputationRejectsZeroAddress() external {
        vm.prank(address(kernel));
        vm.expectRevert("Zero address");
        registry.updateReputationOnSettlement(address(0), keccak256("tx1"), ONE_USDC, false);
    }

    function testUpdateReputationRejectsNonRegisteredAgent() external {
        vm.prank(address(kernel));
        vm.expectRevert("Agent not registered");
        registry.updateReputationOnSettlement(nonAgent, keccak256("tx1"), ONE_USDC, false);
    }

    function testUpdateReputationRejectsDuplicateTxId() external {
        _registerAgent(agent1, "text-generation");

        bytes32 txId = keccak256("tx1");

        vm.prank(address(kernel));
        registry.updateReputationOnSettlement(agent1, txId, ONE_USDC, false);

        vm.prank(address(kernel));
        vm.expectRevert("Transaction already processed");
        registry.updateReputationOnSettlement(agent1, txId, ONE_USDC, false);
    }

    // ============================================
    // REPUTATION FORMULA TESTS
    // ============================================

    function testReputationFormulaSuccessRateComponent() external {
        _registerAgent(agent1, "text-generation");
        _registerAgent(agent2, "text-generation");

        // Agent1: 10 transactions, 0 disputes = 100% success rate
        for (uint i = 0; i < 10; i++) {
            vm.prank(address(kernel));
            registry.updateReputationOnSettlement(agent1, keccak256(abi.encodePacked("tx1_", i)), ONE_USDC, false);
        }

        // Agent2: 10 transactions, 5 disputes = 50% success rate
        for (uint i = 0; i < 10; i++) {
            vm.prank(address(kernel));
            registry.updateReputationOnSettlement(agent2, keccak256(abi.encodePacked("tx2_", i)), ONE_USDC, i < 5);
        }

        IAgentRegistry.AgentProfile memory profile1 = registry.getAgent(agent1);
        IAgentRegistry.AgentProfile memory profile2 = registry.getAgent(agent2);

        // Agent1 should have higher reputation (same volume, better success rate)
        assertGt(profile1.reputationScore, profile2.reputationScore);
    }

    function testReputationFormulaVolumeComponent() external {
        _registerAgent(agent1, "text-generation");
        _registerAgent(agent2, "text-generation");

        // Agent1: $10 volume (logVolume = 2500)
        vm.prank(address(kernel));
        registry.updateReputationOnSettlement(agent1, keccak256("tx1"), 10 * ONE_USDC, false);

        // Agent2: $10,000 volume (logVolume = 10000)
        vm.prank(address(kernel));
        registry.updateReputationOnSettlement(agent2, keccak256("tx2"), 10_000 * ONE_USDC, false);

        IAgentRegistry.AgentProfile memory profile1 = registry.getAgent(agent1);
        IAgentRegistry.AgentProfile memory profile2 = registry.getAgent(agent2);

        // Agent2 should have higher reputation (same success rate, higher volume)
        assertGt(profile2.reputationScore, profile1.reputationScore);
    }

    function testReputationVolumeTiers() external {
        // SECURITY [M-4 FIX]: Volume tiers increased 10x for Sybil resistance
        // New tiers: <$100 = 0, $100-$1K = 2500, $1K-$10K = 5000, $10K-$100K = 7500, $100K+ = 10000

        AgentRegistry tempRegistry = new AgentRegistry(address(kernel));

        // $50 volume (tier 0 - below $100)
        address a1 = address(0x1001);
        IAgentRegistry.ServiceDescriptor[] memory s = _createSingleService("test");
        vm.prank(a1);
        tempRegistry.registerAgent("https://a.com", s);
        vm.prank(address(kernel));
        tempRegistry.updateReputationOnSettlement(a1, keccak256("t1"), 50 * ONE_USDC, false);
        uint256 score1 = tempRegistry.getAgent(a1).reputationScore;

        // $500 volume (tier 2500 - $100-$1K range)
        address a2 = address(0x1002);
        vm.prank(a2);
        tempRegistry.registerAgent("https://b.com", s);
        vm.prank(address(kernel));
        tempRegistry.updateReputationOnSettlement(a2, keccak256("t2"), 500 * ONE_USDC, false);
        uint256 score2 = tempRegistry.getAgent(a2).reputationScore;

        // $5000 volume (tier 5000 - $1K-$10K range)
        address a3 = address(0x1003);
        vm.prank(a3);
        tempRegistry.registerAgent("https://c.com", s);
        vm.prank(address(kernel));
        tempRegistry.updateReputationOnSettlement(a3, keccak256("t3"), 5000 * ONE_USDC, false);
        uint256 score3 = tempRegistry.getAgent(a3).reputationScore;

        // $50,000 volume (tier 7500 - $10K-$100K range)
        address a4 = address(0x1004);
        vm.prank(a4);
        tempRegistry.registerAgent("https://d.com", s);
        vm.prank(address(kernel));
        tempRegistry.updateReputationOnSettlement(a4, keccak256("t4"), 50000 * ONE_USDC, false);
        uint256 score4 = tempRegistry.getAgent(a4).reputationScore;

        // $150,000 volume (tier 10000 - $100K+ range)
        address a5 = address(0x1005);
        vm.prank(a5);
        tempRegistry.registerAgent("https://e.com", s);
        vm.prank(address(kernel));
        tempRegistry.updateReputationOnSettlement(a5, keccak256("t5"), 150000 * ONE_USDC, false);
        uint256 score5 = tempRegistry.getAgent(a5).reputationScore;

        // Each tier should produce higher score
        assertLt(score1, score2);
        assertLt(score2, score3);
        assertLt(score3, score4);
        assertLt(score4, score5);
    }

    function testReputationMaxScore10000() external {
        _registerAgent(agent1, "text-generation");

        // SECURITY [M-4 FIX]: Max reputation = 100% success (7000) + max volume tier (3000) = 10000
        // Max volume tier now requires $100K+ (was $10K+)
        // Give $100,000+ volume with 0 disputes
        vm.prank(address(kernel));
        registry.updateReputationOnSettlement(agent1, keccak256("tx1"), 100_000 * ONE_USDC, false);

        IAgentRegistry.AgentProfile memory profile = registry.getAgent(agent1);

        // Score should be exactly 10000 (max)
        assertEq(profile.reputationScore, 10000);
    }

    // ============================================
    // GET SERVICE DESCRIPTORS TESTS
    // ============================================

    function testGetServiceDescriptors() external {
        IAgentRegistry.ServiceDescriptor[] memory services = new IAgentRegistry.ServiceDescriptor[](2);
        services[0] = IAgentRegistry.ServiceDescriptor({
            serviceTypeHash: keccak256(abi.encodePacked("text-generation")),
            serviceType: "text-generation",
            schemaURI: "ipfs://schema1",
            minPrice: 1 * ONE_USDC,
            maxPrice: 100 * ONE_USDC,
            avgCompletionTime: 60,
            metadataCID: "Qm..."
        });
        services[1] = IAgentRegistry.ServiceDescriptor({
            serviceTypeHash: keccak256(abi.encodePacked("code-review")),
            serviceType: "code-review",
            schemaURI: "ipfs://schema2",
            minPrice: 5 * ONE_USDC,
            maxPrice: 500 * ONE_USDC,
            avgCompletionTime: 3600,
            metadataCID: "Qm..."
        });

        vm.prank(agent1);
        registry.registerAgent("https://agent1.example.com", services);

        IAgentRegistry.ServiceDescriptor[] memory descriptors = registry.getServiceDescriptors(agent1);

        assertEq(descriptors.length, 2);
        assertEq(descriptors[0].serviceType, "text-generation");
        assertEq(descriptors[0].minPrice, 1 * ONE_USDC);
        assertEq(descriptors[1].serviceType, "code-review");
        assertEq(descriptors[1].avgCompletionTime, 3600);
    }

    function testGetServiceDescriptorsReturnsEmptyForNonRegistered() external {
        IAgentRegistry.ServiceDescriptor[] memory descriptors = registry.getServiceDescriptors(nonAgent);
        assertEq(descriptors.length, 0);
    }

    // ============================================
    // SUPPORTS SERVICE TESTS
    // ============================================

    function testSupportsServiceReturnsTrue() external {
        _registerAgent(agent1, "text-generation");

        assertTrue(registry.supportsService(agent1, keccak256(abi.encodePacked("text-generation"))));
    }

    function testSupportsServiceReturnsFalse() external {
        _registerAgent(agent1, "text-generation");

        assertFalse(registry.supportsService(agent1, keccak256(abi.encodePacked("code-review"))));
    }

    function testSupportsServiceReturnsFalseForNonRegistered() external {
        assertFalse(registry.supportsService(nonAgent, keccak256(abi.encodePacked("text-generation"))));
    }

    // ============================================
    // FUZZ TESTS
    // ============================================

    function testFuzzRegisterAgentWithValidEndpoint(string calldata endpoint) external {
        vm.assume(bytes(endpoint).length > 0);
        vm.assume(bytes(endpoint).length <= 256);

        IAgentRegistry.ServiceDescriptor[] memory services = _createSingleService("text-generation");

        vm.prank(agent1);
        registry.registerAgent(endpoint, services);

        assertEq(registry.getAgent(agent1).endpoint, endpoint);
    }

    function testFuzzReputationNeverExceeds10000(uint256 txAmount, uint8 numDisputes, uint8 numTotal) external {
        vm.assume(numTotal > 0);
        vm.assume(numTotal <= 100); // Limit iterations
        vm.assume(numDisputes <= numTotal);
        vm.assume(txAmount > 0);
        vm.assume(txAmount <= 1_000_000 * ONE_USDC); // Max $1M per tx

        _registerAgent(agent1, "text-generation");

        for (uint i = 0; i < numTotal; i++) {
            bool disputed = i < numDisputes;
            vm.prank(address(kernel));
            registry.updateReputationOnSettlement(
                agent1,
                keccak256(abi.encodePacked("tx", i)),
                txAmount,
                disputed
            );
        }

        IAgentRegistry.AgentProfile memory profile = registry.getAgent(agent1);
        assertLe(profile.reputationScore, 10000);
    }

    // ============================================
    // HELPER FUNCTIONS
    // ============================================

    function _createSingleService(string memory serviceType) internal pure returns (IAgentRegistry.ServiceDescriptor[] memory) {
        IAgentRegistry.ServiceDescriptor[] memory services = new IAgentRegistry.ServiceDescriptor[](1);
        services[0] = IAgentRegistry.ServiceDescriptor({
            serviceTypeHash: keccak256(abi.encodePacked(serviceType)),
            serviceType: serviceType,
            schemaURI: "",
            minPrice: 0,
            maxPrice: 0,
            avgCompletionTime: 0,
            metadataCID: ""
        });
        return services;
    }

    function _registerAgent(address agent, string memory serviceType) internal {
        IAgentRegistry.ServiceDescriptor[] memory services = _createSingleService(serviceType);
        vm.prank(agent);
        registry.registerAgent("https://example.com", services);
    }

    function _updateReputation(address agent, uint256 amount, bool disputed) internal {
        bytes32 txId = keccak256(abi.encodePacked("rep_update_", agent, block.timestamp));
        vm.prank(address(kernel));
        registry.updateReputationOnSettlement(agent, txId, amount, disputed);
    }

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
}
