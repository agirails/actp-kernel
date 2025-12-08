// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {AGIRAILSIdentityRegistry} from "../../src/identity/AGIRAILSIdentityRegistry.sol";
import {IAGIRAILSIdentityRegistry} from "../../src/interfaces/IAGIRAILSIdentityRegistry.sol";

/**
 * @title AGIRAILSIdentityRegistry Test Suite
 * @notice Comprehensive tests for ERC-1056 compatible DID registry
 */
contract AGIRAILSIdentityRegistryTest is Test {
    AGIRAILSIdentityRegistry public registry;

    // Test accounts
    address public alice;
    uint256 public aliceKey;
    address public bob;
    uint256 public bobKey;
    address public charlie;
    uint256 public charlieKey;
    address public delegate;

    // Test data
    bytes32 public constant DELEGATE_TYPE_VERIKEY = keccak256("veriKey");
    bytes32 public constant DELEGATE_TYPE_SIGAUTH = keccak256("sigAuth");
    bytes32 public constant ATTR_NAME_ENDPOINT = keccak256("did/svc/AgentService");
    bytes public constant ATTR_VALUE_ENDPOINT = "https://agent.example.com/api";

    // Events for testing
    event DIDOwnerChanged(address indexed identity, address owner, uint256 previousChange);
    event DIDDelegateChanged(
        address indexed identity,
        bytes32 delegateType,
        address delegate,
        uint256 validTo,
        uint256 previousChange
    );
    event DIDAttributeChanged(
        address indexed identity,
        bytes32 name,
        bytes value,
        uint256 validTo,
        uint256 previousChange
    );

    function setUp() public {
        // Deploy registry
        registry = new AGIRAILSIdentityRegistry();

        // Create test accounts
        (alice, aliceKey) = makeAddrAndKey("alice");
        (bob, bobKey) = makeAddrAndKey("bob");
        (charlie, charlieKey) = makeAddrAndKey("charlie");
        delegate = makeAddr("delegate");

        // Fund accounts
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(charlie, 100 ether);
    }

    // ========== OWNER MANAGEMENT TESTS ==========

    function test_IdentityOwner_DefaultsSelfOwned() public {
        // Fresh identity should be self-owned
        assertEq(registry.identityOwner(alice), alice);
        assertEq(registry.identityOwner(bob), bob);
    }

    function test_ChangeOwner_Success() public {
        vm.prank(alice);

        vm.expectEmit(true, false, false, true);
        emit DIDOwnerChanged(alice, bob, 0);

        registry.changeOwner(alice, bob);

        assertEq(registry.identityOwner(alice), bob);
        assertEq(registry.owners(alice), bob);
        assertEq(registry.changed(alice), block.number);
    }

    function test_ChangeOwner_RevertIfNotOwner() public {
        vm.prank(bob);
        vm.expectRevert("Not authorized");
        registry.changeOwner(alice, bob);
    }

    function test_ChangeOwner_AfterTransfer() public {
        // Alice transfers ownership to Bob
        vm.prank(alice);
        registry.changeOwner(alice, bob);

        // Bob can now change owner
        vm.prank(bob);
        registry.changeOwner(alice, charlie);

        assertEq(registry.identityOwner(alice), charlie);
    }

    function test_ChangeOwner_AliceCannotChangeAfterTransfer() public {
        // Alice transfers ownership to Bob
        vm.prank(alice);
        registry.changeOwner(alice, bob);

        // Alice can no longer change owner
        vm.prank(alice);
        vm.expectRevert("Not authorized");
        registry.changeOwner(alice, charlie);
    }

    function test_ChangeOwnerSigned_Success() public {
        uint256 currentNonce = registry.nonce(alice);

        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0x19),
                bytes1(0x00),
                address(registry),
                currentNonce,
                alice,
                "changeOwner",
                bob
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, hash);

        vm.expectEmit(true, false, false, true);
        emit DIDOwnerChanged(alice, bob, 0);

        registry.changeOwnerSigned(alice, v, r, s, bob);

        assertEq(registry.identityOwner(alice), bob);
        assertEq(registry.nonce(alice), currentNonce + 1);
    }

    function test_ChangeOwnerSigned_RevertIfInvalidSignature() public {
        uint256 currentNonce = registry.nonce(alice);

        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0x19),
                bytes1(0x00),
                address(registry),
                currentNonce,
                alice,
                "changeOwner",
                bob
            )
        );

        // Sign with wrong key (Bob's instead of Alice's)
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobKey, hash);

        vm.expectRevert("Invalid signature");
        registry.changeOwnerSigned(alice, v, r, s, bob);
    }

    function test_ChangeOwnerSigned_RevertIfReplayAttack() public {
        uint256 currentNonce = registry.nonce(alice);

        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0x19),
                bytes1(0x00),
                address(registry),
                currentNonce,
                alice,
                "changeOwner",
                bob
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, hash);

        // First call succeeds
        registry.changeOwnerSigned(alice, v, r, s, bob);

        // Second call with same signature should fail (nonce changed)
        vm.expectRevert("Invalid signature");
        registry.changeOwnerSigned(alice, v, r, s, bob);
    }

    // ========== DELEGATE MANAGEMENT TESTS ==========

    function test_AddDelegate_Success() public {
        uint256 validity = 1 days;
        uint256 expectedValidTo = block.timestamp + validity;

        vm.prank(alice);

        vm.expectEmit(true, false, false, false);
        emit DIDDelegateChanged(alice, DELEGATE_TYPE_VERIKEY, delegate, expectedValidTo, 0);

        registry.addDelegate(alice, DELEGATE_TYPE_VERIKEY, delegate, validity);

        assertEq(registry.delegates(alice, DELEGATE_TYPE_VERIKEY, delegate), expectedValidTo);
        assertTrue(registry.validDelegate(alice, DELEGATE_TYPE_VERIKEY, delegate));
        assertEq(registry.changed(alice), block.number);
    }

    function test_AddDelegate_RevertIfNotOwner() public {
        vm.prank(bob);
        vm.expectRevert("Not authorized");
        registry.addDelegate(alice, DELEGATE_TYPE_VERIKEY, delegate, 1 days);
    }

    function test_AddDelegate_RevertIfZeroAddress() public {
        vm.prank(alice);
        vm.expectRevert("Invalid delegate");
        registry.addDelegate(alice, DELEGATE_TYPE_VERIKEY, address(0), 1 days);
    }

    function test_AddDelegate_RevertIfZeroValidity() public {
        vm.prank(alice);
        vm.expectRevert("Invalid validity");
        registry.addDelegate(alice, DELEGATE_TYPE_VERIKEY, delegate, 0);
    }

    function test_AddDelegate_MultipleDelegateTypes() public {
        vm.startPrank(alice);

        registry.addDelegate(alice, DELEGATE_TYPE_VERIKEY, delegate, 1 days);
        registry.addDelegate(alice, DELEGATE_TYPE_SIGAUTH, delegate, 2 days);

        vm.stopPrank();

        assertTrue(registry.validDelegate(alice, DELEGATE_TYPE_VERIKEY, delegate));
        assertTrue(registry.validDelegate(alice, DELEGATE_TYPE_SIGAUTH, delegate));
    }

    function test_ValidDelegate_ExpiresAfterValidity() public {
        vm.prank(alice);
        registry.addDelegate(alice, DELEGATE_TYPE_VERIKEY, delegate, 1 hours);

        // Valid now
        assertTrue(registry.validDelegate(alice, DELEGATE_TYPE_VERIKEY, delegate));

        // Warp to just before expiration
        vm.warp(block.timestamp + 1 hours - 1);
        assertTrue(registry.validDelegate(alice, DELEGATE_TYPE_VERIKEY, delegate));

        // Warp to expiration
        vm.warp(block.timestamp + 2);
        assertFalse(registry.validDelegate(alice, DELEGATE_TYPE_VERIKEY, delegate));
    }

    function test_RevokeDelegate_Success() public {
        // Add delegate first
        vm.startPrank(alice);
        registry.addDelegate(alice, DELEGATE_TYPE_VERIKEY, delegate, 1 days);
        assertTrue(registry.validDelegate(alice, DELEGATE_TYPE_VERIKEY, delegate));

        // Revoke delegate
        vm.expectEmit(true, false, false, false);
        emit DIDDelegateChanged(alice, DELEGATE_TYPE_VERIKEY, delegate, block.timestamp, block.number);

        registry.revokeDelegate(alice, DELEGATE_TYPE_VERIKEY, delegate);
        vm.stopPrank();

        assertFalse(registry.validDelegate(alice, DELEGATE_TYPE_VERIKEY, delegate));
        assertEq(registry.delegates(alice, DELEGATE_TYPE_VERIKEY, delegate), block.timestamp);
    }

    function test_AddDelegateSigned_Success() public {
        uint256 validity = 1 days;
        uint256 currentNonce = registry.nonce(alice);

        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0x19),
                bytes1(0x00),
                address(registry),
                currentNonce,
                alice,
                "addDelegate",
                DELEGATE_TYPE_VERIKEY,
                delegate,
                validity
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, hash);

        registry.addDelegateSigned(alice, v, r, s, DELEGATE_TYPE_VERIKEY, delegate, validity);

        assertTrue(registry.validDelegate(alice, DELEGATE_TYPE_VERIKEY, delegate));
        assertEq(registry.nonce(alice), currentNonce + 1);
    }

    function test_RevokeDelegateSigned_Success() public {
        // Add delegate first
        vm.prank(alice);
        registry.addDelegate(alice, DELEGATE_TYPE_VERIKEY, delegate, 1 days);

        uint256 currentNonce = registry.nonce(alice);

        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0x19),
                bytes1(0x00),
                address(registry),
                currentNonce,
                alice,
                "revokeDelegate",
                DELEGATE_TYPE_VERIKEY,
                delegate
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, hash);

        registry.revokeDelegateSigned(alice, v, r, s, DELEGATE_TYPE_VERIKEY, delegate);

        assertFalse(registry.validDelegate(alice, DELEGATE_TYPE_VERIKEY, delegate));
        assertEq(registry.nonce(alice), currentNonce + 1);
    }

    // ========== ATTRIBUTE MANAGEMENT TESTS ==========

    function test_SetAttribute_Success() public {
        uint256 validity = 1 days;
        uint256 expectedValidTo = block.timestamp + validity;

        vm.prank(alice);

        vm.expectEmit(true, false, false, false);
        emit DIDAttributeChanged(alice, ATTR_NAME_ENDPOINT, ATTR_VALUE_ENDPOINT, expectedValidTo, 0);

        registry.setAttribute(alice, ATTR_NAME_ENDPOINT, ATTR_VALUE_ENDPOINT, validity);

        assertEq(registry.changed(alice), block.number);
    }

    function test_SetAttribute_PermanentAttribute() public {
        vm.prank(alice);

        vm.expectEmit(true, false, false, false);
        emit DIDAttributeChanged(alice, ATTR_NAME_ENDPOINT, ATTR_VALUE_ENDPOINT, 0, 0);

        registry.setAttribute(alice, ATTR_NAME_ENDPOINT, ATTR_VALUE_ENDPOINT, 0);
    }

    function test_SetAttribute_RevertIfNotOwner() public {
        vm.prank(bob);
        vm.expectRevert("Not authorized");
        registry.setAttribute(alice, ATTR_NAME_ENDPOINT, ATTR_VALUE_ENDPOINT, 1 days);
    }

    function test_RevokeAttribute_Success() public {
        // Set attribute first
        vm.startPrank(alice);
        registry.setAttribute(alice, ATTR_NAME_ENDPOINT, ATTR_VALUE_ENDPOINT, 1 days);

        // Revoke attribute
        vm.expectEmit(true, false, false, false);
        emit DIDAttributeChanged(alice, ATTR_NAME_ENDPOINT, ATTR_VALUE_ENDPOINT, 0, block.number);

        registry.revokeAttribute(alice, ATTR_NAME_ENDPOINT, ATTR_VALUE_ENDPOINT);
        vm.stopPrank();
    }

    function test_SetAttributeSigned_Success() public {
        uint256 validity = 1 days;
        uint256 currentNonce = registry.nonce(alice);

        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0x19),
                bytes1(0x00),
                address(registry),
                currentNonce,
                alice,
                "setAttribute",
                ATTR_NAME_ENDPOINT,
                ATTR_VALUE_ENDPOINT,
                validity
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, hash);

        vm.expectEmit(true, false, false, false);
        emit DIDAttributeChanged(alice, ATTR_NAME_ENDPOINT, ATTR_VALUE_ENDPOINT, block.timestamp + validity, 0);

        registry.setAttributeSigned(alice, v, r, s, ATTR_NAME_ENDPOINT, ATTR_VALUE_ENDPOINT, validity);

        assertEq(registry.nonce(alice), currentNonce + 1);
    }

    function test_RevokeAttributeSigned_Success() public {
        // Set attribute first
        vm.prank(alice);
        registry.setAttribute(alice, ATTR_NAME_ENDPOINT, ATTR_VALUE_ENDPOINT, 1 days);

        uint256 currentNonce = registry.nonce(alice);

        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0x19),
                bytes1(0x00),
                address(registry),
                currentNonce,
                alice,
                "revokeAttribute",
                ATTR_NAME_ENDPOINT,
                ATTR_VALUE_ENDPOINT
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, hash);

        registry.revokeAttributeSigned(alice, v, r, s, ATTR_NAME_ENDPOINT, ATTR_VALUE_ENDPOINT);

        assertEq(registry.nonce(alice), currentNonce + 1);
    }

    // ========== STATE QUERY TESTS ==========

    function test_Changed_UpdatesOnEveryOperation() public {
        assertEq(registry.changed(alice), 0);

        // Alice performs operations on her own identity
        vm.startPrank(alice);

        // Add delegate - will execute at current block (1)
        registry.addDelegate(alice, DELEGATE_TYPE_VERIKEY, delegate, 1 days);
        uint256 changeBlock1 = registry.changed(alice);

        // Roll to next block and set attribute
        vm.roll(2);
        registry.setAttribute(alice, ATTR_NAME_ENDPOINT, ATTR_VALUE_ENDPOINT, 1 days);
        uint256 changeBlock2 = registry.changed(alice);

        // Roll to next block and change owner
        vm.roll(3);
        registry.changeOwner(alice, bob);
        uint256 changeBlock3 = registry.changed(alice);

        vm.stopPrank();

        // Verify each operation updated the changed block monotonically
        assertTrue(changeBlock3 > changeBlock2, "Third change should be after second");
        assertTrue(changeBlock2 > changeBlock1, "Second change should be after first");
    }

    function test_Nonce_IncrementsOnSignedOperations() public {
        assertEq(registry.nonce(alice), 0);

        // Add delegate signed (Alice is still owner)
        bytes32 hash1 = keccak256(
            abi.encodePacked(
                bytes1(0x19), bytes1(0x00), address(registry), uint256(0),
                alice, "addDelegate", DELEGATE_TYPE_VERIKEY, delegate, uint256(1 days)
            )
        );
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(aliceKey, hash1);
        registry.addDelegateSigned(alice, v1, r1, s1, DELEGATE_TYPE_VERIKEY, delegate, 1 days);
        assertEq(registry.nonce(alice), 1);

        // Set attribute signed (Alice is still owner)
        bytes32 hash2 = keccak256(
            abi.encodePacked(
                bytes1(0x19), bytes1(0x00), address(registry), uint256(1),
                alice, "setAttribute", ATTR_NAME_ENDPOINT, ATTR_VALUE_ENDPOINT, uint256(1 days)
            )
        );
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(aliceKey, hash2);
        registry.setAttributeSigned(alice, v2, r2, s2, ATTR_NAME_ENDPOINT, ATTR_VALUE_ENDPOINT, 1 days);
        assertEq(registry.nonce(alice), 2);
    }

    // ========== INTEGRATION TESTS ==========

    function test_Integration_FullDIDLifecycle() public {
        // 1. Alice creates identity (self-owned by default)
        assertEq(registry.identityOwner(alice), alice);

        // 2. Alice adds service endpoint attribute
        vm.prank(alice);
        registry.setAttribute(alice, ATTR_NAME_ENDPOINT, ATTR_VALUE_ENDPOINT, 0);

        // 3. Alice adds verification key delegate
        vm.prank(alice);
        registry.addDelegate(alice, DELEGATE_TYPE_VERIKEY, delegate, 365 days);
        assertTrue(registry.validDelegate(alice, DELEGATE_TYPE_VERIKEY, delegate));

        // 4. Alice transfers ownership to Bob (key rotation scenario)
        vm.prank(alice);
        registry.changeOwner(alice, bob);
        assertEq(registry.identityOwner(alice), bob);

        // 5. Bob (new owner) revokes old delegate
        vm.prank(bob);
        registry.revokeDelegate(alice, DELEGATE_TYPE_VERIKEY, delegate);
        assertFalse(registry.validDelegate(alice, DELEGATE_TYPE_VERIKEY, delegate));

        // 6. Bob updates endpoint
        bytes memory newEndpoint = "https://new-agent.example.com/api";
        vm.prank(bob);
        registry.setAttribute(alice, ATTR_NAME_ENDPOINT, newEndpoint, 30 days);

        // Verify final state
        assertEq(registry.identityOwner(alice), bob);
        assertFalse(registry.validDelegate(alice, DELEGATE_TYPE_VERIKEY, delegate));
        assertTrue(registry.changed(alice) > 0);
    }

    function test_Integration_MetaTransactionGaslessOperations() public {
        // Simulate relayer calling signed operations on behalf of Alice
        address relayer = makeAddr("relayer");
        vm.deal(relayer, 100 ether);

        // Alice signs change owner operation (off-chain)
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0x19), bytes1(0x00), address(registry), uint256(0),
                alice, "changeOwner", bob
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, hash);

        // Relayer submits transaction (pays gas)
        vm.prank(relayer);
        registry.changeOwnerSigned(alice, v, r, s, bob);

        // Verify ownership changed without Alice paying gas
        assertEq(registry.identityOwner(alice), bob);
    }

    // ========== GAS BENCHMARKING ==========

    function test_Gas_ChangeOwner() public {
        vm.prank(alice);
        registry.changeOwner(alice, bob);
    }

    function test_Gas_AddDelegate() public {
        vm.prank(alice);
        registry.addDelegate(alice, DELEGATE_TYPE_VERIKEY, delegate, 365 days);
    }

    function test_Gas_SetAttribute() public {
        vm.prank(alice);
        registry.setAttribute(alice, ATTR_NAME_ENDPOINT, ATTR_VALUE_ENDPOINT, 365 days);
    }
}
