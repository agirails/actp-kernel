// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IOptimisticOracleV3} from "../../src/interfaces/IOptimisticOracleV3.sol";

/// @notice Minimal callback surface that BondEscalation exposes to UMA's OOV3.
/// @dev    Defined here so the harness can drive resolution/dispute callbacks AS the
///         MockOOV3 (msg.sender == MockOOV3), satisfying BondEscalation's
///         `require(msg.sender == UMA_OOV3, "Only UMA")` guard.
interface IUMACallbackRecipient {
    function assertionResolvedCallback(bytes32 assertionId, bool assertedTruthfully) external;
    function assertionDisputedCallback(bytes32 assertionId) external;
}

/// @title MockOOV3 — Foundry mock of UMA Optimistic Oracle V3.
/// @notice Unit-test double for BondEscalation Tier-2 (UMA escalation). It performs a REAL
///         `transferFrom` of the bond so that solvency assertions in tests reflect the
///         on-chain reality (UMA holds the escalation bond once asserted). Resolution and
///         dispute outcomes are driven explicitly by the test harness via `mockResolve` /
///         `mockDispute`, which fire the assertion's `callbackRecipient` callbacks AS this
///         contract — exactly how the real OOV3 notifies a `callbackRecipient`.
/// @dev    Not for production use. The DVM, escalation-manager and bond-burn economics are
///         intentionally stubbed; only the integration surface BondEscalation depends on is
///         modelled faithfully (assertTruth bond custody + callback dispatch).
contract MockOOV3 is IOptimisticOracleV3 {
    /// @dev Stable, non-zero default identifier. Mirrors Base mainnet OOV3 == "ASSERT_TRUTH".
    bytes32 public constant DEFAULT_IDENTIFIER = bytes32("ASSERT_TRUTH");

    /// @dev Minimum bond surfaced via `getMinimumBond` — $500 in 6-decimal USDC units.
    uint256 public constant MIN_BOND = 500_000_000;

    /// @notice Stored assertion record. Captures everything a test (or callback) might inspect.
    struct Assertion {
        bytes claim;
        address asserter;
        address callbackRecipient;
        IERC20 currency;
        uint256 bond;
        bool exists;
        bool settled;
        bool result;
    }

    /// @dev assertionId => assertion record.
    mapping(bytes32 => Assertion) public assertions;

    /// @dev Monotonic nonce making each assertionId deterministic and unique.
    uint256 public nonce;

    /// @dev Optional default currency, settable for test convenience (zero by default).
    IERC20 internal _defaultCurrency;

    event AssertionMade(bytes32 indexed assertionId, address indexed asserter, uint256 bond);
    event MockResolved(bytes32 indexed assertionId, bool assertedTruthfully);
    event MockDisputed(bytes32 indexed assertionId);

    // ---------------------------------------------------------------------------------------
    // IOptimisticOracleV3
    // ---------------------------------------------------------------------------------------

    /// @inheritdoc IOptimisticOracleV3
    /// @dev Actually pulls the bond from `msg.sender` (the asserter — BondEscalation) into this
    ///      mock so downstream solvency checks are realistic. Returns a deterministic id.
    function assertTruth(
        bytes memory claim,
        address asserter,
        address callbackRecipient,
        address, /* escalationManager */
        uint64, /* liveness */
        IERC20 currency,
        uint256 bond,
        bytes32, /* identifier */
        bytes32 /* domainId */
    ) external override returns (bytes32 assertionId) {
        // Realistic bond custody: UMA holds the bond once an assertion is made.
        require(currency.transferFrom(msg.sender, address(this), bond), "MockOOV3: bond transfer failed");

        assertionId = keccak256(abi.encode(claim, asserter, nonce));
        nonce++;

        assertions[assertionId] = Assertion({
            claim: claim,
            asserter: asserter,
            callbackRecipient: callbackRecipient,
            currency: currency,
            bond: bond,
            exists: true,
            settled: false,
            result: false
        });

        emit AssertionMade(assertionId, asserter, bond);
    }

    /// @inheritdoc IOptimisticOracleV3
    function defaultIdentifier() external pure override returns (bytes32) {
        return DEFAULT_IDENTIFIER;
    }

    /// @inheritdoc IOptimisticOracleV3
    function getMinimumBond(address /* currency */ ) external pure override returns (uint256) {
        return MIN_BOND;
    }

    /// @inheritdoc IOptimisticOracleV3
    /// @dev No-op in the mock; resolution is driven explicitly via `mockResolve`.
    function settleAssertion(bytes32 assertionId) external override {
        Assertion storage a = assertions[assertionId];
        require(a.exists, "MockOOV3: unknown assertion");
        a.settled = true;
    }

    /// @inheritdoc IOptimisticOracleV3
    /// @dev No-op stub; the mock does not model the DVM escalation path.
    function disputeAssertion(bytes32 assertionId, address /* disputer */ ) external view override {
        require(assertions[assertionId].exists, "MockOOV3: unknown assertion");
    }

    /// @inheritdoc IOptimisticOracleV3
    function settleAndGetAssertionResult(bytes32 assertionId) external override returns (bool) {
        Assertion storage a = assertions[assertionId];
        require(a.exists, "MockOOV3: unknown assertion");
        a.settled = true;
        return a.result;
    }

    /// @inheritdoc IOptimisticOracleV3
    function getAssertionResult(bytes32 assertionId) external view override returns (bool) {
        Assertion storage a = assertions[assertionId];
        require(a.settled, "MockOOV3: not settled");
        return a.result;
    }

    /// @inheritdoc IOptimisticOracleV3
    function defaultCurrency() external view override returns (IERC20) {
        return _defaultCurrency;
    }

    /// @inheritdoc IOptimisticOracleV3
    /// @dev 50% burn (1e18 fixed-point) — a sensible non-zero stub matching UMA defaults.
    function burnedBondPercentage() external pure override returns (uint256) {
        return 5e17;
    }

    // ---------------------------------------------------------------------------------------
    // Test-only helpers (NOT part of IOptimisticOracleV3)
    // ---------------------------------------------------------------------------------------

    /// @notice Sets the currency returned by `defaultCurrency()` (test convenience).
    function setDefaultCurrency(IERC20 currency) external {
        _defaultCurrency = currency;
    }

    /// @notice Drives an assertion to a resolved state, firing the recipient callback AS this mock.
    /// @dev Because the callback originates from address(this) == MockOOV3, BondEscalation's
    ///      `require(msg.sender == UMA_OOV3)` guard passes. Marks the assertion settled.
    /// @param assertionId The assertion to resolve.
    /// @param assertedTruthfully The boolean outcome delivered to the callback.
    function mockResolve(bytes32 assertionId, bool assertedTruthfully) external {
        Assertion storage a = assertions[assertionId];
        require(a.exists, "MockOOV3: unknown assertion");
        a.settled = true;
        a.result = assertedTruthfully;

        if (a.callbackRecipient != address(0)) {
            IUMACallbackRecipient(a.callbackRecipient).assertionResolvedCallback(
                assertionId, assertedTruthfully
            );
        }

        emit MockResolved(assertionId, assertedTruthfully);
    }

    /// @notice Drives an assertion to a disputed state, firing the dispute callback AS this mock.
    /// @param assertionId The assertion to dispute.
    function mockDispute(bytes32 assertionId) external {
        Assertion storage a = assertions[assertionId];
        require(a.exists, "MockOOV3: unknown assertion");

        if (a.callbackRecipient != address(0)) {
            IUMACallbackRecipient(a.callbackRecipient).assertionDisputedCallback(assertionId);
        }

        emit MockDisputed(assertionId);
    }
}
