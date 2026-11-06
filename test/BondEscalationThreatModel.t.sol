// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/DisputeTestBase.sol";
import {AIRuling} from "../src/interfaces/DisputeTypes.sol";
import {IACTPKernel} from "../src/interfaces/IACTPKernel.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {AgentRegistry} from "../src/registry/AgentRegistry.sol";
import {IAgentRegistry} from "../src/interfaces/IAgentRegistry.sol";
import {ArchiveTreasury} from "../src/treasury/ArchiveTreasury.sol";
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

contract GasModeCounter {
    uint256 public value;
    function increment() external { value++; }
}

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

    // Minimal configuration: preserve the 600k cold-call budget and 300k warm regression
    // ceiling as distinct measurements. Instrumented coverage is not release gas bytecode.
    uint256 internal constant CALLBACK_GAS_BUDGET = 600_000;
    // EIP-150 forwards at most 63/64 of gas REMAINING at the oracle callback callsite.
    // This conditional envelope assumes 1M remains there; it is not a keeper transaction limit.
    // Full configuration (registry + archive + fresh settler) is tested separately under it.
    uint256 internal constant UMA_FORWARD_ENVELOPE_63_64 = (1_000_000 * 63) / 64;
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
        ( , , , , uint256 accumulated, , , , , bool resolved, bool winnerPaid, , ,) = be.disputes(disputeId);
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
        be.escalateToUMA(disputeId, "QmEvidenceCID", "QmReasoningCID");
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

        ( , uint8 finalRuling, , , uint256 accumulated, , , , uint8 tier, bool resolved, , , , ) =
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
        bondEscalation.submitAIRuling(disputeB, rA, EVIDENCE_CID, REASONING_CID, sigs);
        vm.stopPrank();

        // (b) Rebrand the struct to B's id (so the require passes) but keep A's signatures →
        //     the recovered signers no longer match (they signed A's disputeId) → 2/3 fails.
        AIRuling memory rForged = rA;
        rForged.disputeId = disputeB;
        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), INITIAL_BOND);
        vm.expectRevert("Insufficient valid signatures");
        bondEscalation.submitAIRuling(disputeB, rForged, EVIDENCE_CID, REASONING_CID, sigs);
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
        be2.submitAIRuling(disputeId, r, EVIDENCE_CID, REASONING_CID, sigs);
        vm.stopPrank();

        // Sanity: the SAME ruling signed under be2's own domain DOES verify (the helper signs under #1,
        // so we sign manually under #2 here).
        bytes[] memory sigs2 = new bytes[](2);
        sigs2[0] = _signRulingForDomain(r, fixed0Pk, be2.DOMAIN_SEPARATOR());
        sigs2[1] = _signRulingForDomain(r, fixed1Pk, be2.DOMAIN_SEPARATOR());
        vm.startPrank(keeper);
        usdc.approve(address(be2), INITIAL_BOND);
        be2.submitAIRuling(disputeId, r, EVIDENCE_CID, REASONING_CID, sigs2); // must NOT revert
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
        bondEscalation.submitAIRuling(disputeId, r, EVIDENCE_CID, REASONING_CID, sigs);
        vm.stopPrank();
    }

    // =====================================================================
    // 3. FIRST-RESOLUTION UMA CALLBACK GAS SNAPSHOT (App-B item 2, R13)
    // =====================================================================

    struct CallbackState {
        bytes32 disputeId;
        bytes32 txId;
        bytes32 assertionId;
        uint256 pool;
        uint256 entryBond;
        address winner;
        uint256 winnerBalance;
        uint256 providerBalance;
        uint256 requesterBalance;
        uint256 feeBalance;
    }

    function _snapshotCallback(bool truth) internal returns (CallbackState memory s) {
        (s.disputeId, s.txId, s.assertionId) = _escalatedToUMA();
        (, , , , uint256 pool, , , , , , , , ,) = bondEscalation.disputes(s.disputeId);
        s.pool = pool;
        s.entryBond = kernel.getTransaction(s.txId).disputeBond;
        s.winner = bondEscalation.lastProposerForRuling(s.disputeId, truth ? 0 : 1);
        assertTrue(s.winner != address(0), "benchmark must exercise a winning Tier-1 proposer");
        s.winnerBalance = usdc.balanceOf(s.winner);
        s.providerBalance = usdc.balanceOf(provider);
        s.requesterBalance = usdc.balanceOf(requester);
        s.feeBalance = usdc.balanceOf(feeCollector);
    }

    function _assertCallbackComplete(CallbackState memory s, bool truth, uint256 bounty, address archive) internal view {
        (, uint8 ruling, uint16 splitBps, , uint256 pool, , , , , bool resolved, bool winnerPaid, , ,) =
            bondEscalation.disputes(s.disputeId);
        assertTrue(resolved, "first callback must resolve");
        assertEq(ruling, truth ? 0 : 1);
        assertEq(splitBps, 0);
        assertTrue(winnerPaid);
        assertEq(pool, 0);
        assertFalse(bondEscalation.mediatorRetryPending(s.disputeId), "callback deferred escrow resolution");
        assertEq(bondEscalation.pendingSettler(s.disputeId), address(0));
        assertEq(uint8(kernel.getTransaction(s.txId).state), uint8(IACTPKernel.State.SETTLED));
        assertEq(kernel.getTransaction(s.txId).disputeBond, 0);
        assertEq(escrow.remaining(s.txId), 0, "callback left escrow funds");
        assertEq(kernel.escrowPrincipal(s.txId), 0);
        assertEq(escrow.bondBalance(s.txId), 0);
        uint256 fee = truth ? ESCROW / 100 : 0;
        uint256 archiveFee = archive == address(0) ? 0 : fee * 10 / 10000;
        assertEq(usdc.balanceOf(provider) - s.providerBalance, truth ? ESCROW - fee + s.entryBond : 0);
        assertEq(usdc.balanceOf(requester) - s.requesterBalance, truth ? 0 : ESCROW + s.entryBond);
        assertEq(usdc.balanceOf(s.winner) - s.winnerBalance, s.pool - bounty);
        assertEq(usdc.balanceOf(feeCollector) - s.feeBalance, fee - archiveFee);
        if (archive != address(0)) {
            assertEq(usdc.balanceOf(archive), archiveFee);
            assertEq(ArchiveTreasury(archive).totalReceived(), archiveFee);
        }
    }

    /// @dev A runner-mode witness, independent of callback performance. A second SSTORE is dirty
    ///      and warm within one test transaction, or clean in its own isolated transaction.
    function _assertGasMode(bool isolated) internal {
        GasModeCounter counter = new GasModeCounter();
        counter.increment();
        uint256 beforeGas = gasleft();
        counter.increment();
        uint256 used = beforeGas - gasleft();
        assertEq(counter.value(), 2);
        if (isolated) assertGt(used, 20_000, "cold benchmark lost isolated execution");
        else assertLt(used, 10_000, "warm benchmark lost non-isolated execution");
    }

    function _measureMinimalCallback(bool isolated) internal {
        _assertGasMode(isolated);
        CallbackState memory s = _snapshotCallback(true);
        vm.prank(address(oov3));
        uint256 beforeGas = gasleft();
        bondEscalation.assertionResolvedCallback{gas: CALLBACK_GAS_BUDGET}(s.assertionId, true);
        uint256 used = beforeGas - gasleft();
        emit log_named_uint(isolated ? "minimal isolated tx accounting gas" : "minimal warm benchmark gas", used);
        _assertCallbackComplete(s, true, 0, address(0));
        assertLt(used, CALLBACK_GAS_BUDGET, "minimal callback exceeds 600k budget");
        assertLt(used, UMA_FORWARD_ENVELOPE_63_64, "minimal callback exceeds conditional envelope");
        // Coverage uses an instrumented --ir-minimum build, not release benchmark bytecode.
        // The normal forge test CI gate always enforces 300k. Coverage retains the bounded
        // call, runner-mode witness and every complete state/balance assertion above.
        if (!isolated && !vm.isContext(VmSafe.ForgeContext.Coverage)) {
            assertLt(used, CALLBACK_GAS_TIGHT_CEILING, "warm callback exceeds 300k regression ceiling");
        }
    }

    /// @dev Historical warm benchmark. Only this test opts out of isolation.
    /// forge-config: default.isolate = false
    /// forge-config: base_mainnet_fork.isolate = false
    function test_Gas_FirstResolutionUMACallback_FitsBudget() external {
        _measureMinimalCallback(false);
    }

    /// @dev Minimal-config cold callback. The actual call remains capped at the original 600k.
    /// forge-config: default.isolate = true
    /// forge-config: base_mainnet_fork.isolate = true
    function test_Gas_ColdFirstResolutionUMACallback_FitsBudget() external {
        _measureMinimalCallback(true);
    }

    function _measureConfiguredCallback(bool truth) internal {
        _assertGasMode(true);
        AgentRegistry registry = new AgentRegistry(address(kernel));
        kernel.scheduleAgentRegistryUpdate(address(registry));
        vm.warp(vm.getBlockTimestamp() + 2 days + 1);
        kernel.executeAgentRegistryUpdate();
        IAgentRegistry.ServiceDescriptor[] memory services = new IAgentRegistry.ServiceDescriptor[](1);
        services[0] = IAgentRegistry.ServiceDescriptor(
            keccak256("text-generation"), "text-generation", "", 0, 0, 0, ""
        );
        vm.prank(provider);
        registry.registerAgent("https://gas-fixture.example", services);
        ArchiveTreasury archive = new ArchiveTreasury(address(usdc), address(kernel), address(this));
        kernel.setArchiveTreasury(address(archive));
        CallbackState memory s = _snapshotCallback(truth);
        address settler = address(0x7711);
        assertEq(usdc.balanceOf(settler), 0, "settler must exercise a fresh balance write");
        oov3.setCallbackGasLimit(UMA_FORWARD_ENVELOPE_63_64);
        oov3.mockArmResult(s.assertionId, truth);
        vm.prank(settler);
        bondEscalation.settleUMAAssertion(s.disputeId);
        emit log_named_uint(truth ? "full provider-win oracle CALL gas" : "full requester-win oracle CALL gas",
            oov3.callbackGasUsed());
        assertGt(oov3.callbackGasUsed(), 0, "bounded oracle callback was not measured");
        assertEq(oov3.getAssertionResult(s.assertionId), truth);
        uint256 bounty = s.pool / 10;
        assertEq(usdc.balanceOf(settler), bounty);
        _assertCallbackComplete(s, truth, bounty, address(archive));
        assertEq(kernel.reputationProcessedBy(s.txId), address(registry), "150k reputation call failed");
        IAgentRegistry.AgentProfile memory profile = registry.getAgent(provider);
        assertEq(profile.totalTransactions, 1);
        assertEq(profile.disputedTransactions, truth ? 0 : 1);
        assertEq(profile.totalVolumeUSDC, ESCROW);
        vm.prank(address(kernel));
        vm.expectRevert("Transaction already processed");
        registry.updateReputationOnSettlement(provider, s.txId, ESCROW, !truth);
    }

    /// @dev Both production-shaped tests cap the *oracle's nested CALL* at the unchanged EIP-150
    ///      envelope: 984375 if 1M remains at that callsite, not 1M total keeper transaction gas.
    /// forge-config: default.isolate = true
    /// forge-config: base_mainnet_fork.isolate = true
    function test_Gas_ColdConfiguredProviderWin_FitsEnvelope() external {
        _measureConfiguredCallback(true);
    }

    /// forge-config: default.isolate = true
    /// forge-config: base_mainnet_fork.isolate = true
    function test_Gas_ColdConfiguredRequesterWin_FitsEnvelope() external {
        _measureConfiguredCallback(false);
    }

    function _assertCallbackRolledBack(CallbackState memory s) internal view {
        (, , , , uint256 pool, , , , , bool resolved, , , ,) = bondEscalation.disputes(s.disputeId);
        assertFalse(resolved);
        assertEq(pool, s.pool);
        assertFalse(bondEscalation.mediatorRetryPending(s.disputeId));
        assertEq(uint8(kernel.getTransaction(s.txId).state), uint8(IACTPKernel.State.DISPUTED));
        assertEq(kernel.getTransaction(s.txId).disputeBond, s.entryBond);
        assertEq(escrow.remaining(s.txId), ESCROW);
        assertEq(kernel.escrowPrincipal(s.txId), ESCROW);
        assertEq(escrow.bondBalance(s.txId), s.entryBond);
        assertEq(usdc.balanceOf(address(bondEscalation)), s.pool);
        assertEq(usdc.balanceOf(s.winner), s.winnerBalance);
        assertEq(usdc.balanceOf(provider), s.providerBalance);
        assertEq(usdc.balanceOf(requester), s.requesterBalance);
        assertEq(usdc.balanceOf(feeCollector), s.feeBalance);
    }

    /// @dev Underprovisioning can revert atomically or return a supported deferred/fee-debt state.
    ///      Every non-reverted sample must recover to the exact same complete allocation.
    /// forge-config: default.isolate = true
    /// forge-config: base_mainnet_fork.isolate = true
    function test_Gas_ColdCallbackSweep_PreservesRecovery() external {
        _assertGasMode(true);
        CallbackState memory s = _snapshotCallback(true);
        uint256 snapshot = vm.snapshotState();
        uint256 reverted;
        uint256 deferred;
        uint256 completed;
        for (uint256 limit = 50_000; limit <= CALLBACK_GAS_BUDGET; limit += 50_000) {
            assertTrue(vm.revertToState(snapshot));
            vm.prank(address(oov3));
            (bool ok,) = address(bondEscalation).call{gas: limit}(
                abi.encodeWithSelector(bondEscalation.assertionResolvedCallback.selector, s.assertionId, true)
            );
            if (!ok) {
                reverted++;
                _assertCallbackRolledBack(s);
                continue;
            }
            if (bondEscalation.mediatorRetryPending(s.disputeId)) {
                deferred++;
                assertEq(uint8(kernel.getTransaction(s.txId).state), uint8(IACTPKernel.State.DISPUTED));
                assertEq(escrow.remaining(s.txId), ESCROW);
                assertEq(escrow.bondBalance(s.txId), s.entryBond);
                assertEq(usdc.balanceOf(provider), s.providerBalance);
                assertEq(usdc.balanceOf(requester), s.requesterBalance);
                assertEq(usdc.balanceOf(feeCollector), s.feeBalance);
                bondEscalation.retryMediatorResolution(s.disputeId);
            } else {
                completed++;
                assertEq(uint8(kernel.getTransaction(s.txId).state), uint8(IACTPKernel.State.SETTLED));
            }
            kernel.retryPlatformFee(s.txId);
            _assertCallbackComplete(s, true, 0, address(0));
        }
        assertGt(reverted, 0, "sweep must exercise rollback");
        assertGt(completed, 0, "sweep must exercise direct settlement");
        emit log_named_uint("sweep reverted", reverted);
        emit log_named_uint("sweep deferred then recovered", deferred);
        emit log_named_uint("sweep settled", completed);
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
        ( , , , , , , , , , bool resolved, , , ,) = bondEscalation.disputes(disputeId);
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

        // Never settle the UMA assertion. [Apex H2] Tier-2 recovery uses the EXTENDED stale
        // window (30d base + 30d TIER2_STALE_GRACE): the plain 30-day mark reverts so a losing
        // party cannot pre-empt a rightful UMA verdict; a genuinely hung assertion is still
        // recoverable after the grace.
        ( , , , , , , uint64 disputedAt, , , , , , ,) = bondEscalation.disputes(disputeId);
        vm.warp(uint256(disputedAt) + 30 days + 1);
        vm.expectRevert("UMA pending: settle assertion first");
        bondEscalation.forceResolveStale(disputeId);

        vm.warp(uint256(disputedAt) + 60 days + 1);
        bondEscalation.forceResolveStale(disputeId);

        ( , uint8 ruling, uint16 splitBps, , , , , , , bool resolved, , , ,) = bondEscalation.disputes(disputeId);
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
                ruling.bundleHash,
                ruling.evidenceRefHash,
                ruling.reasoningRefHash
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Escalate a fresh dispute (on the base stack) all the way to a live UMA assertion (tier 2).
    function _escalatedToUMA() internal returns (bytes32 disputeId, bytes32 txId, bytes32 assertionId) {
        disputeId = _opened();
        ( txId, , , , , , , , , , , , ,) = bondEscalation.disputes(disputeId);

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
        bondEscalation.escalateToUMA(disputeId, "QmEvidenceCID", "QmReasoningCID");
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
        k = new ACTPKernel(admin, pauser, feeCollector, address(0), address(rusdc), 1 hours);
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
            provider, requester, TRANSACTION_AMOUNT, block.timestamp + 60 days, 1 hours, keccak256("service"), bytes32(0), 0, 0
        );

        vm.startPrank(requester);
        token.approve(address(esc), TRANSACTION_AMOUNT);
        k.linkEscrow(txId, address(esc), txId);
        vm.stopPrank();

        vm.prank(provider);
        k.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");
        vm.prank(provider);
        k.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(10 days, keccak256("result")));

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
