// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IOptimisticOracleV3 — canonical UMA Optimistic Oracle V3 interface.
/// @notice Vendored subset of UMA's OptimisticOracleV3 used by the AIP-14b three-tier
///         dispute system (Tier 3 escalation). On Base mainnet the canonical deployment is
///         `0x2aBf1Bd76655de80eDB3086114315Eec75AF500c`.
/// @dev    IMPORTANT: the `identifier` argument to `assertTruth` MUST be one the live UMA
///         `IdentifierWhitelist` accepts, resolved at runtime via `finder()` — NEVER hardcoded.
///         Do NOT blindly forward `defaultIdentifier()`: UMA governance can retire an identifier
///         from the Finder-resolved `IdentifierWhitelist` while `defaultIdentifier()` still returns
///         the retired value. Verified on Base mainnet 2026-07-03: `defaultIdentifier()==ASSERT_TRUTH`
///         but `isIdentifierSupported(ASSERT_TRUTH)==false` (migrated to `ASSERT_TRUTH2`), so a naive
///         `defaultIdentifier()` forward reverts `"Unsupported identifier"`. Callers must pick the
///         first candidate the live whitelist accepts (see `BondEscalation._resolveWhitelistedIdentifier`).
///         Likewise the bond is derived at runtime from `getMinimumBond` (R6): `escalateToUMA`
///         posts `max(UMA_BOND, getMinimumBond(USDC))`, so a UMA min-bond raise adapts instead of
///         reverting. The `currency` is fixed to the protocol's USDC by design (single settlement
///         asset), not read from `defaultCurrency()`.
/// @dev    Signature for `assertTruth` matches AIP-14b §8.4 exactly (9 args).
interface IOptimisticOracleV3 {
    /// @notice Asserts a truth claim about the world, opening a challenge window.
    /// @param claim The ANSI-encoded statement being asserted as true.
    /// @param asserter The address that will receive the bond back on a truthful, undisputed assertion.
    /// @param callbackRecipient Contract notified via `assertionResolvedCallback` / `assertionDisputedCallback` (zero for none).
    /// @param escalationManager Optional escalation manager governing dispute arbitration (zero for the default).
    /// @param liveness The challenge window in seconds during which the assertion can be disputed.
    /// @param currency The ERC-20 used to post the bond.
    /// @dev   `currency` is `address` in UMA's literal on-chain ABI; `IERC20` here is an
    ///        ABI-identical convenience type (encodes as `address`, same selector 0x6457c979).
    ///        Future readers must not assume the on-chain ABI literally declares `IERC20`.
    /// @param bond The bond amount, denominated in `currency`.
    /// @param identifier The price identifier UMA's DVM resolves disputes under — read via `defaultIdentifier()`.
    /// @param domainId Optional domain grouping for assertions (zero for none).
    /// @return assertionId The unique id of the newly created assertion.
    function assertTruth(
        bytes memory claim,
        address asserter,
        address callbackRecipient,
        address escalationManager,
        uint64 liveness,
        IERC20 currency,
        uint256 bond,
        bytes32 identifier,
        bytes32 domainId
    ) external returns (bytes32 assertionId);

    /// @notice The default price identifier used for disputes — `"ASSERT_TRUTH"` on Base mainnet.
    /// @dev    This may be RETIRED from the live IdentifierWhitelist even though it is still returned
    ///         here — do not forward it to `assertTruth` without a whitelist-membership check.
    function defaultIdentifier() external view returns (bytes32);

    /// @notice The UMA Finder that resolves peripheral registries (IdentifierWhitelist, etc.).
    /// @dev    Used to reach the live `IdentifierWhitelist` for a runtime `isIdentifierSupported`
    ///         check before asserting (AIP-14b identifier-rotation fix).
    function finder() external view returns (address);

    /// @notice The minimum bond required when asserting with the given `currency`.
    function getMinimumBond(address currency) external view returns (uint256);

    /// @notice Resolves an assertion after its liveness window (or after a dispute is arbitrated).
    function settleAssertion(bytes32 assertionId) external;

    /// @notice Disputes an open assertion, posting a matching bond and escalating to the DVM.
    function disputeAssertion(bytes32 assertionId, address disputer) external;

    /// @notice Settles the assertion if needed and returns its boolean result.
    /// @return Whether the assertion resolved truthfully.
    function settleAndGetAssertionResult(bytes32 assertionId) external returns (bool);

    /// @notice Returns a settled assertion's boolean result; reverts if not yet settled.
    /// @return Whether the assertion resolved truthfully.
    function getAssertionResult(bytes32 assertionId) external view returns (bool);

    /// @notice The default bond currency for assertions on this deployment.
    function defaultCurrency() external view returns (IERC20);

    /// @notice The percentage of a losing party's bond that is burned, expressed in 1e18 fixed point.
    function burnedBondPercentage() external view returns (uint256);
}

/// @title IUMAFinder — minimal UMA Finder surface used to resolve peripheral registries.
/// @dev   `interfaceName` is the raw `bytes32(string)` of the registry name, e.g.
///        `bytes32("IdentifierWhitelist")` — UMA does NOT hash the name.
interface IUMAFinder {
    function getImplementationAddress(bytes32 interfaceName) external view returns (address);
}

/// @title IUMAIdentifierWhitelist — minimal UMA IdentifierWhitelist surface.
/// @dev   `assertTruth` reverts `"Unsupported identifier"` unless the identifier is supported here.
interface IUMAIdentifierWhitelist {
    function isIdentifierSupported(bytes32 identifier) external view returns (bool);
}
