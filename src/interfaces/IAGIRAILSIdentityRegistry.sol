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
 *  AgenticOS Organism - Identity Registry Interface (AIP-7 §2.2)
 *  ERC-1056 Compatible DID Registry
 */

/**
 * @title IAGIRAILSIdentityRegistry
 * @notice ERC-1056 compatible DID registry for AGIRAILS ecosystem
 * @dev Implements standard EthereumDIDRegistry interface for decentralized identifiers
 *
 * Key Concepts:
 * - Identity: Ethereum address (can be EOA or contract)
 * - Owner: Address authorized to manage the identity (defaults to identity itself)
 * - Delegate: Address granted specific permissions for limited time
 * - Attribute: Key-value metadata with optional expiration
 *
 * Security Model:
 * - Only owner can modify identity (change owner, add delegates, set attributes)
 * - Signed operations allow meta-transactions (gasless operations)
 * - Nonces prevent replay attacks
 * - Changed blocks enable event filtering/pruning
 */
interface IAGIRAILSIdentityRegistry {
    // ========== EVENTS (ERC-1056 Standard) ==========

    /**
     * @notice Emitted when identity ownership changes
     * @param identity Identity address being modified
     * @param owner New owner address
     * @param previousChange Block number of previous change (for event filtering)
     */
    event DIDOwnerChanged(
        address indexed identity,
        address owner,
        uint256 previousChange
    );

    /**
     * @notice Emitted when delegate is added or validity extended
     * @param identity Identity address being modified
     * @param delegateType Type of delegation (e.g., "veriKey", "sigAuth")
     * @param delegate Address being granted delegation
     * @param validTo Block timestamp when delegation expires
     * @param previousChange Block number of previous change
     */
    event DIDDelegateChanged(
        address indexed identity,
        bytes32 delegateType,
        address delegate,
        uint256 validTo,
        uint256 previousChange
    );

    /**
     * @notice Emitted when attribute is set or modified
     * @param identity Identity address being modified
     * @param name Attribute name/key
     * @param value Attribute value (arbitrary bytes)
     * @param validTo Block timestamp when attribute expires (0 = permanent)
     * @param previousChange Block number of previous change
     */
    event DIDAttributeChanged(
        address indexed identity,
        bytes32 name,
        bytes value,
        uint256 validTo,
        uint256 previousChange
    );

    // ========== OWNER MANAGEMENT ==========

    /**
     * @notice Get current owner of an identity
     * @dev Returns identity itself if no explicit owner is set
     * @param identity Identity address to query
     * @return owner Current owner address
     */
    function identityOwner(address identity) external view returns (address owner);

    /**
     * @notice Change owner of identity (direct call)
     * @dev Only callable by current owner
     * @param identity Identity address to modify
     * @param newOwner New owner address
     */
    function changeOwner(address identity, address newOwner) external;

    /**
     * @notice Change owner of identity (signed authorization)
     * @dev Allows meta-transaction for gasless ownership transfer
     * @param identity Identity address to modify
     * @param sigV ECDSA signature V component
     * @param sigR ECDSA signature R component
     * @param sigS ECDSA signature S component
     * @param newOwner New owner address
     */
    function changeOwnerSigned(
        address identity,
        uint8 sigV,
        bytes32 sigR,
        bytes32 sigS,
        address newOwner
    ) external;

    // ========== DELEGATE MANAGEMENT ==========

    /**
     * @notice Add delegate with specific permissions for limited time
     * @dev Only callable by current owner
     * @param identity Identity address to modify
     * @param delegateType Type of delegation (e.g., keccak256("veriKey"))
     * @param delegate Address to grant delegation
     * @param validity Duration in seconds (added to current block.timestamp)
     */
    function addDelegate(
        address identity,
        bytes32 delegateType,
        address delegate,
        uint256 validity
    ) external;

    /**
     * @notice Add delegate (signed authorization)
     * @dev Allows meta-transaction for gasless delegation
     * @param identity Identity address to modify
     * @param sigV ECDSA signature V component
     * @param sigR ECDSA signature R component
     * @param sigS ECDSA signature S component
     * @param delegateType Type of delegation
     * @param delegate Address to grant delegation
     * @param validity Duration in seconds
     */
    function addDelegateSigned(
        address identity,
        uint8 sigV,
        bytes32 sigR,
        bytes32 sigS,
        bytes32 delegateType,
        address delegate,
        uint256 validity
    ) external;

    /**
     * @notice Revoke delegate immediately
     * @dev Only callable by current owner
     * @param identity Identity address to modify
     * @param delegateType Type of delegation to revoke
     * @param delegate Address to revoke delegation from
     */
    function revokeDelegate(
        address identity,
        bytes32 delegateType,
        address delegate
    ) external;

    /**
     * @notice Revoke delegate (signed authorization)
     * @dev Allows meta-transaction for gasless revocation
     * @param identity Identity address to modify
     * @param sigV ECDSA signature V component
     * @param sigR ECDSA signature R component
     * @param sigS ECDSA signature S component
     * @param delegateType Type of delegation to revoke
     * @param delegate Address to revoke delegation from
     */
    function revokeDelegateSigned(
        address identity,
        uint8 sigV,
        bytes32 sigR,
        bytes32 sigS,
        bytes32 delegateType,
        address delegate
    ) external;

    /**
     * @notice Check if delegate is currently valid
     * @param identity Identity address to query
     * @param delegateType Type of delegation to check
     * @param delegate Address to check delegation for
     * @return valid True if delegation is currently active
     */
    function validDelegate(
        address identity,
        bytes32 delegateType,
        address delegate
    ) external view returns (bool valid);

    // ========== ATTRIBUTE MANAGEMENT ==========

    /**
     * @notice Set attribute with optional expiration
     * @dev Only callable by current owner
     * @param identity Identity address to modify
     * @param name Attribute name/key
     * @param value Attribute value (arbitrary bytes)
     * @param validity Duration in seconds (0 = permanent)
     */
    function setAttribute(
        address identity,
        bytes32 name,
        bytes calldata value,
        uint256 validity
    ) external;

    /**
     * @notice Set attribute (signed authorization)
     * @dev Allows meta-transaction for gasless attribute updates
     * @param identity Identity address to modify
     * @param sigV ECDSA signature V component
     * @param sigR ECDSA signature R component
     * @param sigS ECDSA signature S component
     * @param name Attribute name/key
     * @param value Attribute value (arbitrary bytes)
     * @param validity Duration in seconds (0 = permanent)
     */
    function setAttributeSigned(
        address identity,
        uint8 sigV,
        bytes32 sigR,
        bytes32 sigS,
        bytes32 name,
        bytes calldata value,
        uint256 validity
    ) external;

    /**
     * @notice Revoke attribute immediately
     * @dev Only callable by current owner
     * @param identity Identity address to modify
     * @param name Attribute name/key to revoke
     * @param value Attribute value (must match for revocation)
     */
    function revokeAttribute(
        address identity,
        bytes32 name,
        bytes calldata value
    ) external;

    /**
     * @notice Revoke attribute (signed authorization)
     * @dev Allows meta-transaction for gasless attribute revocation
     * @param identity Identity address to modify
     * @param sigV ECDSA signature V component
     * @param sigR ECDSA signature R component
     * @param sigS ECDSA signature S component
     * @param name Attribute name/key to revoke
     * @param value Attribute value (must match for revocation)
     */
    function revokeAttributeSigned(
        address identity,
        uint8 sigV,
        bytes32 sigR,
        bytes32 sigS,
        bytes32 name,
        bytes calldata value
    ) external;

    // ========== STATE QUERY ==========

    /**
     * @notice Get block number of last change for identity
     * @dev Used for efficient event filtering (query events > changed[identity])
     * @param identity Identity address to query
     * @return blockNumber Last change block number
     */
    function changed(address identity) external view returns (uint256 blockNumber);

    /**
     * @notice Get current nonce for signed operations
     * @dev Incremented after each signed operation to prevent replay attacks
     * @param identity Identity address to query
     * @return currentNonce Current nonce value
     */
    function nonce(address identity) external view returns (uint256 currentNonce);

    /**
     * @notice Get delegate validity expiration timestamp
     * @param identity Identity address to query
     * @param delegateType Type of delegation
     * @param delegate Delegate address
     * @return validTo Expiration timestamp (0 = never valid)
     */
    function delegates(
        address identity,
        bytes32 delegateType,
        address delegate
    ) external view returns (uint256 validTo);

    /**
     * @notice Get current owner address
     * @param identity Identity address to query
     * @return owner Registered owner (address(0) = identity is self-owned)
     */
    function owners(address identity) external view returns (address owner);
}
