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
 *  AgenticOS Organism - Identity Registry (AIP-7 §2.2)
 *  ERC-1056 Compatible DID Registry
 */

import {IAGIRAILSIdentityRegistry} from "../interfaces/IAGIRAILSIdentityRegistry.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title AGIRAILSIdentityRegistry
 * @notice ERC-1056 compatible DID registry for AGIRAILS ecosystem
 * @dev Implements standard EthereumDIDRegistry interface for decentralized identifiers
 *
 * Architecture:
 * - Identity: Any Ethereum address (EOA or contract)
 * - Owner: Controller of the identity (defaults to identity itself)
 * - Delegates: Temporary permissions for specific operations
 * - Attributes: Key-value pairs with optional expiration
 *
 * Security Properties:
 * - Owner authorization required for all state changes
 * - Signed operations enable meta-transactions (gasless)
 * - Nonces prevent replay attacks (incremented per signed operation)
 * - Changed blocks enable efficient event filtering
 * - No admin backdoors (fully decentralized)
 *
 * Gas Optimization:
 * - Minimal storage slots per identity
 * - Event-based data storage (not storage)
 * - No loops or unbounded operations
 *
 * @custom:security-contact security@agirails.io
 */
contract AGIRAILSIdentityRegistry is IAGIRAILSIdentityRegistry {
    // ========== STATE VARIABLES ==========

    /// @notice Owner mapping: identity => owner address (address(0) = self-owned)
    mapping(address => address) public owners;

    /// @notice Delegate validity: identity => delegateType => delegate => expirationTimestamp
    mapping(address => mapping(bytes32 => mapping(address => uint256))) public delegates;

    /// @notice Block number of last change for each identity (for event filtering)
    mapping(address => uint256) public changed;

    /// @notice Nonce for signed operations (prevents replay attacks)
    mapping(address => uint256) public nonce;

    // ========== CONSTANTS ==========

    /// @dev EIP-191 signed data prefix
    bytes1 private constant EIP191_PREFIX = 0x19;
    bytes1 private constant EIP191_VERSION = 0x00;

    // ========== MODIFIERS ==========

    /**
     * @dev Verify caller is authorized to act on behalf of identity
     * @param identity Identity to check authorization for
     */
    modifier onlyOwner(address identity) {
        require(identityOwner(identity) == msg.sender, "Not authorized");
        _;
    }

    // ========== OWNER MANAGEMENT ==========

    /**
     * @inheritdoc IAGIRAILSIdentityRegistry
     * @dev Returns identity itself if no explicit owner is set (default behavior)
     */
    function identityOwner(address identity) public view override returns (address) {
        address owner = owners[identity];
        if (owner != address(0)) {
            return owner;
        }
        return identity;
    }

    /**
     * @inheritdoc IAGIRAILSIdentityRegistry
     * @dev Direct call requires msg.sender to be current owner
     */
    function changeOwner(address identity, address newOwner) external override onlyOwner(identity) {
        _changeOwner(identity, newOwner);
    }

    /**
     * @inheritdoc IAGIRAILSIdentityRegistry
     * @dev Meta-transaction variant with signature verification
     */
    function changeOwnerSigned(
        address identity,
        uint8 sigV,
        bytes32 sigR,
        bytes32 sigS,
        address newOwner
    ) external override {
        bytes32 hash = keccak256(
            abi.encodePacked(
                EIP191_PREFIX,
                EIP191_VERSION,
                address(this),
                nonce[identityOwner(identity)],
                identity,
                "changeOwner",
                newOwner
            )
        );
        _checkSignature(identity, sigV, sigR, sigS, hash);
        _changeOwner(identity, newOwner);
    }

    /**
     * @dev Internal function to change owner and emit event
     * @param identity Identity to modify
     * @param newOwner New owner address
     */
    function _changeOwner(address identity, address newOwner) internal {
        uint256 previousChange = changed[identity];
        owners[identity] = newOwner;
        changed[identity] = block.number;
        emit DIDOwnerChanged(identity, newOwner, previousChange);
    }

    // ========== DELEGATE MANAGEMENT ==========

    /**
     * @inheritdoc IAGIRAILSIdentityRegistry
     * @dev Sets delegate validity to block.timestamp + validity seconds
     */
    function addDelegate(
        address identity,
        bytes32 delegateType,
        address delegate,
        uint256 validity
    ) external override onlyOwner(identity) {
        _addDelegate(identity, delegateType, delegate, validity);
    }

    /**
     * @inheritdoc IAGIRAILSIdentityRegistry
     * @dev Meta-transaction variant with signature verification
     */
    function addDelegateSigned(
        address identity,
        uint8 sigV,
        bytes32 sigR,
        bytes32 sigS,
        bytes32 delegateType,
        address delegate,
        uint256 validity
    ) external override {
        bytes32 hash = keccak256(
            abi.encodePacked(
                EIP191_PREFIX,
                EIP191_VERSION,
                address(this),
                nonce[identityOwner(identity)],
                identity,
                "addDelegate",
                delegateType,
                delegate,
                validity
            )
        );
        _checkSignature(identity, sigV, sigR, sigS, hash);
        _addDelegate(identity, delegateType, delegate, validity);
    }

    /**
     * @dev Internal function to add delegate and emit event
     * @param identity Identity to modify
     * @param delegateType Type of delegation
     * @param delegate Address to grant delegation
     * @param validity Duration in seconds
     */
    function _addDelegate(
        address identity,
        bytes32 delegateType,
        address delegate,
        uint256 validity
    ) internal {
        require(delegate != address(0), "Invalid delegate");
        require(validity > 0, "Invalid validity");

        uint256 validTo = block.timestamp + validity;
        delegates[identity][delegateType][delegate] = validTo;

        uint256 previousChange = changed[identity];
        changed[identity] = block.number;

        emit DIDDelegateChanged(identity, delegateType, delegate, validTo, previousChange);
    }

    /**
     * @inheritdoc IAGIRAILSIdentityRegistry
     * @dev Sets delegate validity to 0 (immediate revocation)
     */
    function revokeDelegate(
        address identity,
        bytes32 delegateType,
        address delegate
    ) external override onlyOwner(identity) {
        _revokeDelegate(identity, delegateType, delegate);
    }

    /**
     * @inheritdoc IAGIRAILSIdentityRegistry
     * @dev Meta-transaction variant with signature verification
     */
    function revokeDelegateSigned(
        address identity,
        uint8 sigV,
        bytes32 sigR,
        bytes32 sigS,
        bytes32 delegateType,
        address delegate
    ) external override {
        bytes32 hash = keccak256(
            abi.encodePacked(
                EIP191_PREFIX,
                EIP191_VERSION,
                address(this),
                nonce[identityOwner(identity)],
                identity,
                "revokeDelegate",
                delegateType,
                delegate
            )
        );
        _checkSignature(identity, sigV, sigR, sigS, hash);
        _revokeDelegate(identity, delegateType, delegate);
    }

    /**
     * @dev Internal function to revoke delegate and emit event
     * @param identity Identity to modify
     * @param delegateType Type of delegation to revoke
     * @param delegate Address to revoke delegation from
     */
    function _revokeDelegate(
        address identity,
        bytes32 delegateType,
        address delegate
    ) internal {
        // Set to current timestamp (expired)
        delegates[identity][delegateType][delegate] = block.timestamp;

        uint256 previousChange = changed[identity];
        changed[identity] = block.number;

        emit DIDDelegateChanged(identity, delegateType, delegate, block.timestamp, previousChange);
    }

    /**
     * @inheritdoc IAGIRAILSIdentityRegistry
     * @dev Checks if delegation exists and hasn't expired
     */
    function validDelegate(
        address identity,
        bytes32 delegateType,
        address delegate
    ) external view override returns (bool) {
        uint256 validity = delegates[identity][delegateType][delegate];
        return validity > block.timestamp;
    }

    // ========== ATTRIBUTE MANAGEMENT ==========

    /**
     * @inheritdoc IAGIRAILSIdentityRegistry
     * @dev Attributes are stored in events only (not contract storage)
     */
    function setAttribute(
        address identity,
        bytes32 name,
        bytes calldata value,
        uint256 validity
    ) external override onlyOwner(identity) {
        _setAttribute(identity, name, value, validity);
    }

    /**
     * @inheritdoc IAGIRAILSIdentityRegistry
     * @dev Meta-transaction variant with signature verification
     */
    function setAttributeSigned(
        address identity,
        uint8 sigV,
        bytes32 sigR,
        bytes32 sigS,
        bytes32 name,
        bytes calldata value,
        uint256 validity
    ) external override {
        bytes32 hash = keccak256(
            abi.encodePacked(
                EIP191_PREFIX,
                EIP191_VERSION,
                address(this),
                nonce[identityOwner(identity)],
                identity,
                "setAttribute",
                name,
                value,
                validity
            )
        );
        _checkSignature(identity, sigV, sigR, sigS, hash);
        _setAttribute(identity, name, value, validity);
    }

    /**
     * @dev Internal function to set attribute and emit event
     * @param identity Identity to modify
     * @param name Attribute name
     * @param value Attribute value
     * @param validity Duration in seconds (0 = permanent)
     */
    function _setAttribute(
        address identity,
        bytes32 name,
        bytes calldata value,
        uint256 validity
    ) internal {
        uint256 validTo;
        if (validity > 0) {
            validTo = block.timestamp + validity;
        } else {
            validTo = 0; // Permanent attribute
        }

        uint256 previousChange = changed[identity];
        changed[identity] = block.number;

        emit DIDAttributeChanged(identity, name, value, validTo, previousChange);
    }

    /**
     * @inheritdoc IAGIRAILSIdentityRegistry
     * @dev Revokes by emitting event with validTo = 0
     */
    function revokeAttribute(
        address identity,
        bytes32 name,
        bytes calldata value
    ) external override onlyOwner(identity) {
        _revokeAttribute(identity, name, value);
    }

    /**
     * @inheritdoc IAGIRAILSIdentityRegistry
     * @dev Meta-transaction variant with signature verification
     */
    function revokeAttributeSigned(
        address identity,
        uint8 sigV,
        bytes32 sigR,
        bytes32 sigS,
        bytes32 name,
        bytes calldata value
    ) external override {
        bytes32 hash = keccak256(
            abi.encodePacked(
                EIP191_PREFIX,
                EIP191_VERSION,
                address(this),
                nonce[identityOwner(identity)],
                identity,
                "revokeAttribute",
                name,
                value
            )
        );
        _checkSignature(identity, sigV, sigR, sigS, hash);
        _revokeAttribute(identity, name, value);
    }

    /**
     * @dev Internal function to revoke attribute and emit event
     * @param identity Identity to modify
     * @param name Attribute name
     * @param value Attribute value (must match for revocation)
     */
    function _revokeAttribute(
        address identity,
        bytes32 name,
        bytes calldata value
    ) internal {
        uint256 previousChange = changed[identity];
        changed[identity] = block.number;

        // validTo = 0 signals revocation
        emit DIDAttributeChanged(identity, name, value, 0, previousChange);
    }

    // ========== SIGNATURE VERIFICATION ==========

    /**
     * @dev Verify ECDSA signature and increment nonce
     * @param identity Identity being operated on
     * @param sigV Signature V component
     * @param sigR Signature R component
     * @param sigS Signature S component
     * @param hash Message hash that was signed
     *
     * Security: Uses OpenZeppelin ECDSA library to prevent signature malleability attacks.
     * The ECDSA.recover function validates that the s value is in the lower half order
     * and v is either 27 or 28, rejecting malleable signatures.
     */
    function _checkSignature(
        address identity,
        uint8 sigV,
        bytes32 sigR,
        bytes32 sigS,
        bytes32 hash
    ) internal {
        address owner = identityOwner(identity);

        // Use OpenZeppelin ECDSA for signature malleability protection
        address signer = ECDSA.recover(hash, sigV, sigR, sigS);

        require(signer == owner, "Invalid signature");

        // Increment nonce to prevent replay attacks
        nonce[owner]++;
    }
}
