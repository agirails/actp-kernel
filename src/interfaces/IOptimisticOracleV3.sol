// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IOptimisticOracleV3 — canonical UMA Optimistic Oracle V3 interface.
/// @notice Vendored subset of UMA's OptimisticOracleV3 used by the AIP-14b three-tier
///         dispute system (Tier 3 escalation). On Base mainnet the canonical deployment is
///         `0x2aBf1Bd76655de80eDB3086114315Eec75AF500c`.
/// @dev    IMPORTANT: the `identifier` argument to `assertTruth` MUST be read at runtime via
///         `defaultIdentifier()` — it is `"ASSERT_TRUTH"` on Base mainnet (verified on-chain
///         2026-06-21) but MUST NEVER be hardcoded. Reading it keeps the integration correct if
///         UMA governance ever rotates the default identifier or if we deploy on another chain.
///         Likewise, bond/currency should be derived from `getMinimumBond` / `defaultCurrency`
///         rather than assumed.
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
    /// @dev    Always read this rather than hardcoding the identifier.
    function defaultIdentifier() external view returns (bytes32);

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
