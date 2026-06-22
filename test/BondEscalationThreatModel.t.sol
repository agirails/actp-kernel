// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/DisputeTestBase.sol";
import {AIRuling} from "../src/interfaces/DisputeTypes.sol";
import {IACTPKernel} from "../src/interfaces/IACTPKernel.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// =========================================================================================
// Malicious doubles used by the reentrancy threat tests.
// =========================================================================================

/// @notice A USDC clone whose `transfer` re-enters a configured BondEscalation entrypoint exactly once.
/// @dev    This is the load-bearing reentrancy harness: BondEscalation's payout paths
///         (`finalize` winner push, `claimEscalationRefund` split pull, `assertionResolvedCallback`
///         winner push) all end in `USDC.safeTransfer(...)`. By making that very token call back into
///         BondEscalation, we put the attacker exactly where a missing reentrancy guard would let them
///         double-pay. The token re-enters at most once (a latch) so a SUCCESSFUL re-entry would be
///         observable as a second payout; the `nonReentrant` guard must turn it into a revert instead.
contract ReentrantUSDC {
    string public constant name = "Reentrant USDC";
    string public constant symbol = "rUSDC";
    uint8 public constant decimals = 6;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    // Re-entry configuration.
    address public target; // BondEscalation
    bytes public reenterCalldata; // selector + args to replay on transfer
    bool public armed; // only fire while armed
    bool public fired; // latch — re-enter at most once
    bool public lastReentryReverted; // observability for the test
    bytes public lastReentryReturn;
    // Optional recipient filter: when non-zero, the latch arms ONLY on a transfer whose `to` matches.
    // Lets a test target a SPECIFIC payout frame (e.g. the winner-push transfer) and skip earlier
    // transfers (e.g. the finalization bounty) that would otherwise consume the single-fire latch.
    address public onlyReenterOnTo;

    function mint(address to, uint256 amount) external {
        require(to != address(0), "Zero address");
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        _maybeReenter(to);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "Allowance");
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        _maybeReenter(to);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(to != address(0), "Zero address");
        require(balanceOf[from] >= amount, "Balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }

    // ----- test wiring -----
    function arm(address _target, bytes calldata _data) external {
        target = _target;
        reenterCalldata = _data;
        armed = true;
        fired = false;
        onlyReenterOnTo = address(0); // no recipient filter — fire on the FIRST transfer
    }

    /// @notice Arm re-entry but ONLY on a transfer whose recipient equals `to`. Used to skip an earlier
    ///         transfer (e.g. the finalization bounty) and land the latch on a SPECIFIC payout frame
    ///         (e.g. the winner-push), proving THAT frame is independently re-entrant-safe.
    function armOnTransferTo(address _target, bytes calldata _data, address to) external {
        target = _target;
        reenterCalldata = _data;
        armed = true;
        fired = false;
        onlyReenterOnTo = to;
    }

    function disarm() external {
        armed = false;
    }

    function _maybeReenter(address to) internal {
        if (!armed || fired || target == address(0)) return;
        if (onlyReenterOnTo != address(0) && to != onlyReenterOnTo) return; // wait for the targeted frame
        fired = true; // latch BEFORE the call so we never recurse infinitely
        (bool ok, bytes memory ret) = target.call(reenterCalldata);
        lastReentryReverted = !ok;
        lastReentryReturn = ret;
    }
}

// =========================================================================================
// Threat-model test suite.
// =========================================================================================

/// @title BondEscalationThreatModelTest — targeted adversarial tests (PRD P1-8, INV-16/19, App-B).
/// @notice Complements the stateful invariant suite with deliberate attacks the random fuzzer is
///         unlikely to construct on its own:
///           1. Cross-tier REENTRANCY — a malicious USDC and a malicious winner/OOV3 re-entering during
///              finalize / claimEscalationRefund / assertionResolvedCallback can never double-pay.
///           2. EIP-712 REPLAY — a 2/3 ruling signed for dispute A is rejected for dispute B
///              (cross-dispute) and the same struct hash is rejected against a different verifying
///              contract (cross-contract / domain-separator binding).
///           3. FIRST-RESOLUTION UMA CALLBACK GAS — an end-to-end gas snapshot of the NON-early-return
///              callback path (the heavy one: safeTransfer → compositeMediator.resolve →
///              kernel.transitionState → escrow payout + reputation try/catch). Asserts it fits a
///              reasonable forwarded-callback budget and documents the OOG → forceResolveStale recovery.
contract BondEscalationThreatModelTest is DisputeTestBase {
    uint256 internal constant ESCROW = TRANSACTION_AMOUNT; // 1e9
    uint256 internal constant INITIAL_BOND = 20_000_000; // (1e9 * 200) / 10000 = $20
    uint64 internal constant LIVENESS = 4 hours;
    uint256 internal constant MAX_BOND = 500_000_000;

    // -------- forwarded-callback gas budget (App-B item 2) --------
    // [F-4 AUDIT FIX] The real UMA OptimisticOracleV3 forwards 63/64 of the gas REMAINING at the
    // settleAssertion call site to `callbackRecipient` (EIP-150 "all but one 64th"), NOT a fixed
    // ~100k stipend (the earlier App-B "~100k" note was inaccurate and is corrected here and in the
    // spec/App-B/PRD R13). Consequence: an honest settle caller who provides a normal keeper gas
    // limit forwards FAR more than the heavy first-resolution callback needs (~158k no-registry,
    // up to ~277k with reputation + paid-mediator legs). So the heavy path does NOT structurally
    // OOG under honest provisioning — F-4 is a deliberate-griefing / caller-under-provisioning
    // concern, recoverable via permissionless forceResolveStale at 30 days, hence MEDIUM not HIGH.
    // We assert:
    //   - measured < CALLBACK_GAS_BUDGET (regression ceiling — a future change that balloons it trips here)
    //   - measured < UMA_FORWARD_ENVELOPE_63_64 (the callback FITS the 63/64-of-remaining envelope a
    //     realistically-provisioned keeper forwards — pins that honest settlement does NOT OOG)
    uint256 internal constant CALLBACK_GAS_BUDGET = 600_000;
    // 63/64 of a conservative keeper settle-gas limit (1,000,000) = 984,375 — the floor an honest
    // caller forwards. The heavy callback must fit comfortably under this (it measures ~158k).
    uint256 internal constant UMA_FORWARD_ENVELOPE_63_64 = (1_000_000 * 63) / 64;
    // TIGHT informational regression ceiling (review hardening): the base-stack heavy callback measures
    // ~158k; the worst case with the reputation + paid-mediator legs is ~277k. 300k catches a ~2x
    // regression in the callback while leaving headroom for compiler/gas drift — far tighter than the
    // (directional-fact) 63/64 envelope above, which is intentionally loose.
    uint256 internal constant CALLBACK_GAS_TIGHT_CEILING = 300_000;

    function setUp() external {
        _setUpStack();
    }

    // =====================================================================
    // 1. CROSS-TIER REENTRANCY
    // =====================================================================

    /// @dev Build a complete alternate stack (kernel + escrow + mediator + bondEscalation) wired to a
    ///      ReentrantUSDC, drive ONE dispute to a SPLIT finalize, then have the token re-enter
    ///      `claimEscalationRefund` during the refund payout. The re-entry MUST revert (nonReentrant);
    ///      the depositor receives EXACTLY one share, never two.
    function test_Reentrancy_ClaimRefund_CannotDoublePay() external {
        (
            BondEscalation be,
            ACTPKernel k,
            EscrowVault esc,
            ReentrantUSDC rusdc
        ) = _deployReentrantStack();

        // Drive a fresh dispute on the reentrant stack to a 2/3 split, two depositors.
        bytes32 disputeId = _openOn(be, k, esc, rusdc);

        // keeper proposes split, rando challenges split (different bps) → ruling 2, pool = bond+2*bond.
        _proposeOn(be, rusdc, keeper, disputeId, 2, 5000);
        vm.startPrank(rando);
        rusdc.approve(address(be), type(uint256).max);
        be.challenge(disputeId, 2, 6000);
        vm.stopPrank();

        // Liveness expires → finalize (split: snapshot, no winner push).
        vm.warp(block.timestamp + LIVENESS + 1);
        be.finalize(disputeId);

        // Arm the token: during keeper's refund transfer, re-enter claimEscalationRefund for keeper.
        bytes memory reenter = abi.encodeWithSelector(be.claimEscalationRefund.selector, disputeId);
        vm.prank(keeper); // make keeper the caller context is irrelevant; arm is permissionless
        rusdc.arm(address(be), reenter);

        uint256 keeperBefore = rusdc.balanceOf(keeper);

        // keeper claims. The token re-enters claimEscalationRefund mid-transfer; the nested call must
        // hit ReentrancyGuard and revert (the outer call still succeeds, paying exactly one share).
        vm.prank(keeper);
        be.claimEscalationRefund(disputeId);

        assertTrue(rusdc.fired(), "re-entry path was not exercised");
        assertTrue(rusdc.lastReentryReverted(), "nested claimEscalationRefund must revert (nonReentrant)");

        // keeper's deposit was zeroed before the transfer (CEI), so even a successful re-entry would
        // have found deposits==0; combined with the guard, the payout is provably single.
        assertEq(be.deposits(disputeId, keeper), 0, "deposit must be consumed exactly once");
        uint256 gained = rusdc.balanceOf(keeper) - keeperBefore;
        assertGt(gained, 0, "keeper got a refund");
        assertLe(gained, INITIAL_BOND * 2, "keeper cannot extract more than the whole pool");
    }

    /// @dev Re-enter `finalize` from inside the WINNER-PUSH payout (winner-takes-all ruling 0). The latch
    ///      is armed with a RECIPIENT FILTER on the winner address, so it is consumed by the
    ///      `safeTransfer(winner, payout)` frame — NOT the earlier finalization-bounty transfer. This
    ///      independently proves the winner-push frame is re-entrant-safe (the prior version let the
    ///      bounty transfer eat the single-fire latch, leaving the winner-push frame unexercised).
    ///      The nested finalize must revert (nonReentrant); the winner is paid exactly once.
    function test_Reentrancy_FinalizeWinnerPush_CannotDoublePay() external {
        (
            BondEscalation be,
            ACTPKernel k,
            EscrowVault esc,
            ReentrantUSDC rusdc
        ) = _deployReentrantStack();

        bytes32 disputeId = _openOn(be, k, esc, rusdc);

        // keeper proposes ruling 0 (provider wins), no challenge → keeper is the sole winner.
        _proposeOn(be, rusdc, keeper, disputeId, 0, 0);

        vm.warp(block.timestamp + LIVENESS + 1);

        // A DISTINCT finalizer (keeper2 != winner) so the bounty transfer goes to keeper2 and the
        // winner-push transfer goes to keeper. The recipient filter targets the WINNER (keeper), so the
        // latch is skipped on the bounty transfer (to keeper2) and fires on the winner-push (to keeper).
        address keeper2 = address(0xF1);
        bytes memory reenter = abi.encodeWithSelector(be.finalize.selector, disputeId);
        rusdc.armOnTransferTo(address(be), reenter, keeper);

        uint256 keeperBefore = rusdc.balanceOf(keeper);
        uint256 keeper2Before = rusdc.balanceOf(keeper2);

        vm.prank(keeper2);
        be.finalize(disputeId);

        // The latch fired DURING the winner-push frame (recipient == keeper), and the nested finalize
        // re-entered while the nonReentrant lock was held → it MUST have reverted.
        assertTrue(rusdc.fired(), "winner-push frame was not re-entered (latch never fired)");
        assertTrue(rusdc.lastReentryReverted(), "nested finalize from the WINNER-PUSH frame must revert (nonReentrant)");

        // Dispute resolved exactly once; accumulatedBonds zeroed; winner paid once.
        ( , , , , uint256 accumulated, , , , , bool resolved, bool winnerPaid, , ) = be.disputes(disputeId);
        assertTrue(resolved, "resolved");
        assertTrue(winnerPaid, "winner paid");
        assertEq(accumulated, 0, "pool drained exactly once");

        // Winner got the post-bounty pool exactly once; finalizer got only the bounty. No double-pay.
        uint256 winnerGain = rusdc.balanceOf(keeper) - keeperBefore;
        uint256 finalizerGain = rusdc.balanceOf(keeper2) - keeper2Before;
        assertGt(winnerGain, 0, "winner received the pool");
        assertGt(finalizerGain, 0, "finalizer received the bounty");
        // The pool (gross deposit, 20M) splits into exactly bounty + winner payout — no extra wei minted
        // by a successful re-entry. winnerGain + finalizerGain == grossPool proves single payout.
        assertEq(winnerGain + finalizerGain, INITIAL_BOND, "winner + finalizer == gross pool (paid exactly once)");
    }

    /// @dev Re-entry DURING `assertionResolvedCallback`: the callback ends in
    ///      `USDC.safeTransfer(winner, payout)`. Using the ReentrantUSDC stack, that very transfer
    ///      re-enters the callback (a second `assertionResolvedCallback` for the same assertion) WHILE the
    ///      `nonReentrant` lock is held. A successful re-entry would double-pay the winner; the guard must
    ///      turn it into a revert. This is the genuine cross-tier reentrancy vector (re-entry inside the
    ///      locked frame), not a pre-call no-op.
    function test_Reentrancy_UMACallback_CannotReenter() external {
        (
            BondEscalation be,
            ACTPKernel k,
            EscrowVault esc,
            ReentrantUSDC rusdc
        ) = _deployReentrantStack();

        bytes32 disputeId = _openOn(be, k, esc, rusdc);

        // Drive to the $500 ceiling (alternating rulings), then escalate to the (base) MockOOV3.
        _proposeOn(be, rusdc, keeper, disputeId, 0, 0);
        uint256 bond = INITIAL_BOND;
        uint8 ruling = 0;
        for (uint256 i = 0; i < 6; i++) {
            ruling = ruling == 0 ? 1 : 0;
            bond = bond * 2;
            if (bond > MAX_BOND) bond = MAX_BOND;
            address who = (i % 2 == 0) ? rando : keeper;
            vm.startPrank(who);
            rusdc.approve(address(be), bond);
            be.challenge(disputeId, ruling, 0);
            vm.stopPrank();
        }
        vm.startPrank(keeper);
        rusdc.approve(address(be), MAX_BOND);
        be.escalateToUMA(disputeId, "QmEvidenceCID");
        vm.stopPrank();
        bytes32 assertionId = be.disputeToAssertion(disputeId);

        // Arm the token so the winner-payout transfer (inside the callback) re-enters the callback.
        bytes memory reenter = abi.encodeWithSelector(be.assertionResolvedCallback.selector, assertionId, true);
        rusdc.arm(address(be), reenter);

        // Drive the resolved callback AS the OOV3 (the base mock wired into the reentrant stack). The
        // winner push fires the token re-entry; the nested callback must revert (nonReentrant).
        vm.prank(address(oov3));
        be.assertionResolvedCallback(assertionId, true);

        assertTrue(rusdc.fired(), "re-entry path was not exercised");
        assertTrue(rusdc.lastReentryReverted(), "nested UMA callback must revert (nonReentrant)");

        ( , uint8 finalRuling, , , uint256 accumulated, , , , uint8 tier, bool resolved, , , ) =
            be.disputes(disputeId);
        assertTrue(resolved, "resolved exactly once");
        assertEq(tier, 2, "tier stays at UMA");
        assertEq(finalRuling, 0, "TRUE -> provider wins (ruling 0)");
        assertEq(accumulated, 0, "Tier-1 pool pushed to winner exactly once");
    }

    // =====================================================================
    // 2. EIP-712 REPLAY (cross-dispute + cross-contract)
    // =====================================================================

    /// @dev A valid 2/3-signed ruling for dispute A must NOT verify for a different dispute B: the
    ///      signed struct binds `disputeId`, and `submitAIRuling` requires `ruling.disputeId == disputeId`.
    ///      Replaying A's signatures under B's disputeId is rejected.
    function test_Replay_CrossDispute_Rejected() external {
        bytes32 disputeA = _opened();
        bytes32 disputeB = _opened();

        // Sign a ruling bound to A.
        AIRuling memory rA = _ruling(disputeA, 0, 0);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signRuling(rA, fixed0Pk);
        sigs[1] = _signRuling(rA, fixed1Pk);

        // Attempt to submit A's signed ruling against B's disputeId.
        // (a) Pass A's struct but call on B → require(ruling.disputeId == disputeId) fails.
        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), INITIAL_BOND);
        vm.expectRevert("Mismatched disputeId");
        bondEscalation.submitAIRuling(disputeB, rA, sigs);
        vm.stopPrank();

        // (b) Rebrand the struct to B's id (so the require passes) but keep A's signatures →
        //     the recovered signers no longer match (they signed A's disputeId) → 2/3 fails.
        AIRuling memory rForged = rA;
        rForged.disputeId = disputeB;
        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), INITIAL_BOND);
        vm.expectRevert("Insufficient valid signatures");
        bondEscalation.submitAIRuling(disputeB, rForged, sigs);
        vm.stopPrank();
    }

    /// @dev Cross-CONTRACT replay: a ruling signed against THIS BondEscalation's domain separator must
    ///      not verify against a SECOND BondEscalation deployment (different `verifyingContract` ⇒
    ///      different DOMAIN_SEPARATOR ⇒ different digest ⇒ recovered signers mismatch). Proves the
    ///      EIP-712 domain binds the signature to a single contract instance.
    function test_Replay_CrossContract_Rejected() external {
        // Second BondEscalation with the SAME evaluator set but a different address → different domain.
        address[2] memory fixedEvaluators = [fixed0, fixed1];
        address[] memory rotatingPool = new address[](1);
        rotatingPool[0] = rotating0;
        BondEscalation be2 = new BondEscalation(
            IACTPKernel(address(kernel)),
            IERC20(address(usdc)),
            ICompositeMediator(address(compositeMediator)),
            admin,
            fixedEvaluators,
            rotatingPool,
            address(oov3)
        );

        assertTrue(
            bondEscalation.DOMAIN_SEPARATOR() != be2.DOMAIN_SEPARATOR(),
            "two deployments must have distinct domain separators"
        );

        // Open the SAME txId-derived dispute id on be2 is impossible (txId already disputed→opened on
        // the first contract is fine; openDispute is per-contract). Open a fresh dispute on be2.
        bytes32 txId = _createDisputed();
        vm.prank(keeper);
        bytes32 disputeId = be2.openDispute(txId);

        // Sign the ruling against the FIRST contract's domain (the _signRuling helper uses
        // bondEscalation.DOMAIN_SEPARATOR()), then try to submit on be2.
        AIRuling memory r = _ruling(disputeId, 0, 0);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signRuling(r, fixed0Pk); // signed under contract #1's domain
        sigs[1] = _signRuling(r, fixed1Pk);

        vm.startPrank(keeper);
        usdc.approve(address(be2), INITIAL_BOND);
        vm.expectRevert("Insufficient valid signatures");
        be2.submitAIRuling(disputeId, r, sigs);
        vm.stopPrank();

        // Sanity: the SAME ruling signed under be2's own domain DOES verify (the helper signs under #1,
        // so we sign manually under #2 here).
        bytes[] memory sigs2 = new bytes[](2);
        sigs2[0] = _signRulingForDomain(r, fixed0Pk, be2.DOMAIN_SEPARATOR());
        sigs2[1] = _signRulingForDomain(r, fixed1Pk, be2.DOMAIN_SEPARATOR());
        vm.startPrank(keeper);
        usdc.approve(address(be2), INITIAL_BOND);
        be2.submitAIRuling(disputeId, r, sigs2); // must NOT revert
        vm.stopPrank();
        assertEq(be2.lastProposerForRuling(disputeId, 0), keeper, "correctly-domained sig must land");
    }

    /// @dev Stale-ruling rejection (the EIP-712 freshness bound, §4.8): a validly-signed ruling whose
    ///      `timestamp` is older than RULING_FRESHNESS (1h) is rejected even with two valid signatures —
    ///      so an old-but-validly-signed ruling cannot be replayed/re-submitted later.
    function test_Replay_StaleRuling_Rejected() external {
        bytes32 disputeId = _opened();
        AIRuling memory r = _ruling(disputeId, 0, 0); // timestamp == now
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signRuling(r, fixed0Pk);
        sigs[1] = _signRuling(r, fixed1Pk);

        // Warp > 1h past the ruling timestamp.
        vm.warp(block.timestamp + 1 hours + 1);

        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), INITIAL_BOND);
        vm.expectRevert("Ruling stale");
        bondEscalation.submitAIRuling(disputeId, r, sigs);
        vm.stopPrank();
    }

    // =====================================================================
    // 3. FIRST-RESOLUTION UMA CALLBACK GAS SNAPSHOT (App-B item 2, R13)
    // =====================================================================

    /// @dev Measure the gas of the FIRST-resolution (NON early-return) UMA callback END-TO-END:
    ///      assertionResolvedCallback → safeTransfer(winner) → compositeMediator.resolve →
    ///      kernel.transitionState → escrow payout + reputation try/catch. This is the heavy path
    ///      App-B item 2 warns about; the cheap already-resolved early-return is trivially cheaper.
    ///      We assert it fits CALLBACK_GAS_BUDGET (a bounded forwarded-callback envelope) and document
    ///      the recovery: if a real OOV3 ever forwards LESS than this and the callback OOGs, the dispute
    ///      is NOT stuck — `forceResolveStale` (30-day) and `syncExternalResolution` (admin-resolved in
    ///      kernel) both resolve it without the callback, and UMA's own bond settlement is independent.
    function test_Gas_FirstResolutionUMACallback_FitsBudget() external {
        (bytes32 disputeId, , bytes32 assertionId) = _escalatedToUMA();

        // Resolve via the mock, but measure the gas of the BondEscalation callback itself by invoking
        // it directly AS the OOV3 (msg.sender == oov3) and snapshotting gasleft() across the call.
        vm.prank(address(oov3));
        uint256 gasBefore = gasleft();
        bondEscalation.assertionResolvedCallback(assertionId, true);
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("first-resolution UMA callback gas (end-to-end)", gasUsed);

        // The dispute must have actually resolved on the heavy path (NOT the cheap early-return).
        ( , uint8 ruling, , , uint256 accumulated, , , , , bool resolved, , , ) =
            bondEscalation.disputes(disputeId);
        assertTrue(resolved, "callback took the first-resolution path");
        assertEq(ruling, 0, "TRUE -> ruling 0");
        assertEq(accumulated, 0, "Tier-1 pool pushed to winner");

        assertLt(gasUsed, CALLBACK_GAS_BUDGET, "first-resolution callback exceeds forwarded-callback budget");

        // [F-4 AUDIT FIX] PIN the corrected fact (App-B item 2): the real OOV3 forwards 63/64 of the
        // gas REMAINING at the settle site, so an honestly-provisioned keeper forwards FAR more than
        // this heavy callback needs. We assert the callback FITS comfortably under that 63/64 envelope
        // — i.e. honest settlement does NOT structurally OOG (the earlier "~100k fixed forward, so the
        // heavy path always OOGs" premise was wrong). forceResolveStale stays the backstop for the
        // griefing / under-provisioning case, but is NOT the expected primary route under honest gas.
        assertLt(
            gasUsed,
            UMA_FORWARD_ENVELOPE_63_64,
            "heavy callback must fit the 63/64-of-remaining UMA forward envelope under honest provisioning"
        );

        // Review hardening: a TIGHT informational ceiling near the measured value so a ~2x gas
        // regression in the callback is caught early (the 63/64 envelope above only catches a ~6x
        // blowup). Kept above the ~158k base-stack measurement + the ~277k worst case headroom.
        assertLt(
            gasUsed,
            CALLBACK_GAS_TIGHT_CEILING,
            "heavy callback exceeded the tight 300k regression ceiling (investigate a gas regression)"
        );
    }

    /// @dev Companion: the EARLY-RETURN callback (dispute already resolved locally) is the cheap path
    ///      App-B item 2 calls out as "particularly gas-efficient" — it must be strictly cheaper than the
    ///      first-resolution path and trivially within budget. This pins the asymmetry so a regression
    ///      that makes the no-op path expensive is caught.
    function test_Gas_EarlyReturnUMACallback_IsCheap() external {
        (bytes32 disputeId, bytes32 txId, bytes32 assertionId) = _escalatedToUMA();

        // Force a local resolution first (admin resolves the kernel out of DISPUTED), so the callback
        // takes the graceful-no-op branch. 64-byte proof → CANCELLED.
        uint256 remaining = _remaining(txId);
        bytes memory proof = abi.encode(remaining / 2, remaining - remaining / 2);
        vm.prank(admin);
        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, proof);

        // First callback syncs locally (already-resolved-in-kernel branch). Now it IS resolved.
        oov3.mockResolve(assertionId, true);
        ( , , , , , , , , , bool resolved, , , ) = bondEscalation.disputes(disputeId);
        assertTrue(resolved, "dispute resolved locally");

        // A SECOND callback now takes the cheap `if (d.resolved) return;` early-return. Measure it.
        vm.prank(address(oov3));
        uint256 gasBefore = gasleft();
        bondEscalation.assertionResolvedCallback(assertionId, true);
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("early-return UMA callback gas", gasUsed);
        assertLt(gasUsed, 60_000, "early-return path must be cheap");
    }

    /// @dev Recovery documentation, asserted: if the first-resolution callback could NOT run (modelled
    ///      here by simply never settling the assertion), `forceResolveStale` at 30 days still resolves
    ///      the dispute and frees the Tier-1 bonds — so an OOG in the callback is a liveness inconvenience,
    ///      never stuck funds. This is the R13 recovery path made executable.
    function test_Recovery_ForceStale_WhenCallbackNeverRuns() external {
        (bytes32 disputeId, , ) = _escalatedToUMA();

        // Never settle the UMA assertion. Warp past the 30-day staleness window.
        ( , , , , , , uint64 disputedAt, , , , , , ) = bondEscalation.disputes(disputeId);
        vm.warp(uint256(disputedAt) + 30 days + 1);

        bondEscalation.forceResolveStale(disputeId);

        ( , uint8 ruling, uint16 splitBps, , , , , , , bool resolved, , , ) = bondEscalation.disputes(disputeId);
        assertTrue(resolved, "stale recovery resolves the dispute without the callback");
        assertEq(ruling, 2, "forced 50/50 split on stale");
        assertEq(splitBps, 5000, "forced split bps");

        // Tier-1 bonds remain claimable via the split path → no stuck funds.
        uint256 keeperBefore = usdc.balanceOf(keeper);
        vm.prank(keeper);
        bondEscalation.claimEscalationRefund(disputeId);
        assertGt(usdc.balanceOf(keeper), keeperBefore, "Tier-1 bonds recovered after stale resolution");
    }

    // =====================================================================
    // Helpers
    // =====================================================================

    function _opened() internal returns (bytes32 disputeId) {
        bytes32 txId = _createDisputed();
        disputeId = bondEscalation.openDispute(txId);
    }

    /// @dev EIP-712 signing against an ARBITRARY domain separator (for the cross-contract test).
    function _signRulingForDomain(AIRuling memory ruling, uint256 privKey, bytes32 domainSeparator)
        internal
        pure
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                RULING_TYPEHASH,
                ruling.disputeId,
                ruling.ruling,
                ruling.confidence,
                ruling.splitBps,
                ruling.timestamp,
                ruling.reasoningHash,
                ruling.bundleHash
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Escalate a fresh dispute (on the base stack) all the way to a live UMA assertion (tier 2).
    function _escalatedToUMA() internal returns (bytes32 disputeId, bytes32 txId, bytes32 assertionId) {
        disputeId = _opened();
        ( txId, , , , , , , , , , , , ) = bondEscalation.disputes(disputeId);

        _proposeOn(bondEscalation, usdc, keeper, disputeId, 0, 0);
        uint256 bond = INITIAL_BOND;
        uint8 ruling = 0;
        for (uint256 i = 0; i < 6; i++) {
            ruling = ruling == 0 ? 1 : 0;
            bond = bond * 2;
            if (bond > MAX_BOND) bond = MAX_BOND;
            address who = (i % 2 == 0) ? rando : keeper;
            vm.startPrank(who);
            usdc.approve(address(bondEscalation), bond);
            bondEscalation.challenge(disputeId, ruling, 0);
            vm.stopPrank();
        }
        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), MAX_BOND);
        bondEscalation.escalateToUMA(disputeId, "QmEvidenceCID");
        vm.stopPrank();
        assertionId = bondEscalation.disputeToAssertion(disputeId);
    }

    // -------- alternate-stack builders (for the reentrancy tests) --------

    /// @dev A full stack wired to a ReentrantUSDC so the token can re-enter BondEscalation on transfer.
    function _deployReentrantStack()
        internal
        returns (BondEscalation be, ACTPKernel k, EscrowVault esc, ReentrantUSDC rusdc)
    {
        rusdc = new ReentrantUSDC();
        k = new ACTPKernel(admin, pauser, feeCollector, address(0), address(rusdc));
        esc = new EscrowVault(address(rusdc), address(k));
        k.approveEscrowVault(address(esc), true);

        CompositeMediator cm = new CompositeMediator(IACTPKernel(address(k)));
        address[2] memory fixedEvaluators = [fixed0, fixed1];
        address[] memory rotatingPool = new address[](1);
        rotatingPool[0] = rotating0;
        be = new BondEscalation(
            IACTPKernel(address(k)),
            IERC20(address(rusdc)),
            ICompositeMediator(address(cm)),
            admin,
            fixedEvaluators,
            rotatingPool,
            address(oov3)
        );
        cm.initialize(address(be));
        k.approveMediator(address(cm), true);
        vm.warp(block.timestamp + 2 days + 1);

        // Fund actors on the reentrant token.
        rusdc.mint(requester, 1_000_000 * ONE_USDC);
        rusdc.mint(provider, 1_000_000 * ONE_USDC);
        rusdc.mint(keeper, 1_000_000 * ONE_USDC);
        rusdc.mint(rando, 1_000_000 * ONE_USDC);
    }

    /// @dev Drive a fresh kernel tx to DISPUTED on an arbitrary stack, then openDispute on `be`.
    function _openOn(BondEscalation be, ACTPKernel k, EscrowVault esc, ReentrantUSDC token)
        internal
        returns (bytes32 disputeId)
    {
        bytes32 txId = _createDisputedOn(k, esc, IERC20(address(token)));
        disputeId = be.openDispute(txId);
    }

    /// @dev Generic _createDisputed against an explicit kernel/escrow/token (the alt stacks).
    function _createDisputedOn(ACTPKernel k, EscrowVault esc, IERC20 token) internal returns (bytes32 txId) {
        vm.prank(requester);
        txId = k.createTransaction(
            provider, requester, TRANSACTION_AMOUNT, block.timestamp + 60 days, 2 days, keccak256("service"), 0, 0
        );

        vm.startPrank(requester);
        token.approve(address(esc), TRANSACTION_AMOUNT);
        k.linkEscrow(txId, address(esc), txId);
        vm.stopPrank();

        vm.prank(provider);
        k.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");
        vm.prank(provider);
        k.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(10 days));

        uint256 bond = (TRANSACTION_AMOUNT * k.disputeBondBps()) / k.MAX_BPS();
        vm.startPrank(requester);
        token.approve(address(esc), bond);
        k.transitionState(txId, IACTPKernel.State.DISPUTED, "");
        vm.stopPrank();
    }

    function _proposeOn(BondEscalation be, MockUSDC token, address who, bytes32 disputeId, uint8 ruling, uint16 splitBps)
        internal
    {
        vm.startPrank(who);
        token.approve(address(be), type(uint256).max);
        be.proposeDirectly(disputeId, ruling, splitBps);
        vm.stopPrank();
    }

    function _proposeOn(
        BondEscalation be,
        ReentrantUSDC token,
        address who,
        bytes32 disputeId,
        uint8 ruling,
        uint16 splitBps
    ) internal {
        vm.startPrank(who);
        token.approve(address(be), type(uint256).max);
        be.proposeDirectly(disputeId, ruling, splitBps);
        vm.stopPrank();
    }
}
