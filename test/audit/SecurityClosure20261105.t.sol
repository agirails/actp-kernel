// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {DisputeTestBase} from "../helpers/DisputeTestBase.sol";
import {Test} from "forge-std/Test.sol";
import {ACTPKernel} from "../../src/ACTPKernel.sol";
import {IACTPKernel} from "../../src/interfaces/IACTPKernel.sol";
import {AGIRAILSIdentityRegistry} from "../../src/identity/AGIRAILSIdentityRegistry.sol";
import {AgentRegistry} from "../../src/registry/AgentRegistry.sol";
import {IAgentRegistry} from "../../src/interfaces/IAgentRegistry.sol";
import {EscrowVault} from "../../src/escrow/EscrowVault.sol";
import {MockUSDC} from "../../src/tokens/MockUSDC.sol";
import {ArchiveTreasury} from "../../src/treasury/ArchiveTreasury.sol";
import {DeployKernelV2} from "../../script/DeployKernelV2.s.sol";
import {DeployBaseMainnet} from "../../script/DeployBaseMainnet.s.sol";
import {CompositeMediator} from "../../src/CompositeMediator.sol";
import {BondEscalation} from "../../src/BondEscalation.sol";
import {ICompositeMediator} from "../../src/interfaces/ICompositeMediator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockOOV3} from "../mocks/MockOOV3.sol";
import {BlacklistUSDC} from "./F17F59_FeeAccounting.t.sol";

contract SecurityClosureUMA is DisputeTestBase {
    uint256 constant AMOUNT = 100_000 * 1e6;

    function setUp() public {
        _setUpStack();
    }

    function _openedLarge(uint8 proposed, bool second)
        internal
        returns (bytes32 txId, bytes32 disputeId)
    {
        vm.prank(requester);
        txId = kernel.createTransaction(
            provider,
            requester,
            AMOUNT,
            block.timestamp + 30 days,
            1 hours,
            keccak256("service"),
            bytes32(0),
            0,
            0
        );
        vm.startPrank(requester);
        usdc.approve(address(escrow), type(uint256).max);
        kernel.linkEscrow(txId, address(escrow), txId);
        vm.stopPrank();
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");
        vm.prank(provider);
        kernel.transitionState(
            txId, IACTPKernel.State.DELIVERED, abi.encode(1 hours, keccak256("result"))
        );
        vm.prank(requester);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");
        disputeId = bondEscalation.openDispute(txId);
        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), type(uint256).max);
        bondEscalation.proposeDirectly(disputeId, proposed, proposed == 2 ? 4000 : 0);
        vm.stopPrank();
        if (second) {
            vm.startPrank(rando);
            usdc.approve(address(bondEscalation), type(uint256).max);
            bondEscalation.challenge(disputeId, 2, 6000);
            vm.stopPrank();
        }
        vm.startPrank(keeper);
        bondEscalation.escalateToUMA(disputeId, EVIDENCE_CID, REASONING_CID);
        vm.stopPrank();
    }

    function _verifyMissingWinner(bool truth, bool second, bool splitOnly, bool defer) internal {
        (bytes32 txId, bytes32 disputeId) = _openedLarge(splitOnly ? 2 : (truth ? 1 : 0), second);
        uint256 rb = usdc.balanceOf(requester);
        uint256 pb = usdc.balanceOf(provider);
        bytes memory callData = abi.encodeWithSelector(
            compositeMediator.resolve.selector, txId, truth ? uint8(0) : uint8(1), uint16(0)
        );
        if (defer) {
            vm.mockCallRevert(address(compositeMediator), callData, abi.encode("temporary failure"));
        }
        oov3.mockResolve(bondEscalation.disputeToAssertion(disputeId), truth);
        (, uint8 ruling, uint16 splitBps,,,,,,, bool resolved, bool winnerPaid,,,) =
            bondEscalation.disputes(disputeId);
        assertTrue(resolved);
        assertEq(ruling, truth ? 0 : 1, "oracle verdict preserved");
        assertEq(splitBps, 0, "oracle clean win never converted to split");
        assertFalse(winnerPaid);
        if (defer) {
            assertTrue(bondEscalation.mediatorRetryPending(disputeId));
            vm.clearMockedCalls();
            bondEscalation.retryMediatorResolution(disputeId);
            assertFalse(bondEscalation.mediatorRetryPending(disputeId));
        }
        assertEq(uint8(kernel.getTransaction(txId).state), uint8(IACTPKernel.State.SETTLED));
        uint256 entry = AMOUNT * 500 / 10000;
        assertEq(usdc.balanceOf(requester) - rb, truth ? 0 : AMOUNT + entry, "requester award");
        assertEq(
            usdc.balanceOf(provider) - pb, truth ? AMOUNT * 99 / 100 + entry : 0, "provider award"
        );
        assertEq(escrow.remaining(txId), 0);
        oov3.mockResolve(bondEscalation.disputeToAssertion(disputeId), !truth);
        assertEq(
            usdc.balanceOf(requester) - rb, truth ? 0 : AMOUNT + entry, "late callback is inert"
        );
        uint256 kb = usdc.balanceOf(keeper);
        vm.prank(keeper);
        bondEscalation.claimEscalationRefund(disputeId);
        assertEq(usdc.balanceOf(keeper) - kb, 500e6, "sole/first depositor refund");
        vm.prank(keeper);
        vm.expectRevert("Nothing to claim");
        bondEscalation.claimEscalationRefund(disputeId);
        if (second) {
            uint256 b = usdc.balanceOf(rando);
            vm.prank(rando);
            bondEscalation.claimEscalationRefund(disputeId);
            assertEq(usdc.balanceOf(rando) - b, 500e6, "second depositor refund");
        }
        assertEq(usdc.balanceOf(address(bondEscalation)), 0, "pool fully refunded");
    }

    function test_TrueWithoutProviderProposer() external {
        _verifyMissingWinner(true, false, false, false);
    }

    function test_FalseWithoutRequesterProposer() external {
        _verifyMissingWinner(false, false, false, false);
    }

    function test_TrueSplitOnlyMultipleDepositors() external {
        _verifyMissingWinner(true, true, true, false);
    }

    function test_FalseSplitOnlyMultipleDepositors() external {
        _verifyMissingWinner(false, true, true, false);
    }

    function test_DeferredTruePreservesVerdictAndRefund() external {
        _verifyMissingWinner(true, true, false, true);
    }

    function test_DeferredFalsePreservesVerdictAndRefund() external {
        _verifyMissingWinner(false, true, false, true);
    }

    function test_RefundsCannotConsumeAnotherDisputePool() external {
        (, bytes32 first) = _openedLarge(1, false);
        (bytes32 secondTx, bytes32 second) = _openedLarge(0, false);
        oov3.mockResolve(bondEscalation.disputeToAssertion(first), true);
        vm.prank(keeper);
        bondEscalation.claimEscalationRefund(first);
        assertEq(usdc.balanceOf(address(bondEscalation)), 500e6, "second dispute fully backed");
        assertEq(uint8(kernel.getTransaction(secondTx).state), uint8(IACTPKernel.State.DISPUTED));
        oov3.mockResolve(bondEscalation.disputeToAssertion(second), false);
        vm.prank(keeper);
        bondEscalation.claimEscalationRefund(second);
        assertEq(usdc.balanceOf(address(bondEscalation)), 0);
    }
}

contract SecurityClosureIdentity is Test {
    AGIRAILSIdentityRegistry registry;
    address alice;
    uint256 aliceKey;
    address bob = address(0xB0B);
    address delegate = address(0xD1);
    bytes32 constant KIND = keccak256("sigAuth");
    bytes32 constant NAME = keccak256("endpoint");
    bytes constant VALUE = "https://agent.example";

    function setUp() public {
        registry = new AGIRAILSIdentityRegistry();
        (alice, aliceKey) = makeAddrAndKey("owner");
    }

    function _digest(uint8 op, uint256 n) internal view returns (bytes32) {
        bytes memory args;
        if (op == 0) args = abi.encodePacked("changeOwner", delegate);
        else if (op == 1) args = abi.encodePacked("addDelegate", KIND, delegate, uint256(1 days));
        else if (op == 2) args = abi.encodePacked("revokeDelegate", KIND, delegate);
        else if (op == 3) args = abi.encodePacked("setAttribute", NAME, VALUE, uint256(1 days));
        else args = abi.encodePacked("revokeAttribute", NAME, VALUE);
        return
            keccak256(abi.encodePacked(bytes1(0x19), bytes1(0), address(registry), n, alice, args));
    }

    function _invoke(uint8 op, uint8 v, bytes32 r, bytes32 s) internal {
        if (op == 0) registry.changeOwnerSigned(alice, v, r, s, delegate);
        else if (op == 1) registry.addDelegateSigned(alice, v, r, s, KIND, delegate, 1 days);
        else if (op == 2) registry.revokeDelegateSigned(alice, v, r, s, KIND, delegate);
        else if (op == 3) registry.setAttributeSigned(alice, v, r, s, NAME, VALUE, 1 days);
        else registry.revokeAttributeSigned(alice, v, r, s, NAME, VALUE);
    }

    function _roundTrip(uint8 op, bool signedReturn) internal {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, _digest(op, registry.nonce(alice)));
        vm.prank(alice);
        registry.changeOwner(alice, bob);
        if (signedReturn) {
            uint256 pk = 0xB0B;
            address signer = vm.addr(pk);
            vm.prank(bob);
            registry.changeOwner(alice, signer);
            bytes32 h = keccak256(
                abi.encodePacked(
                    bytes1(0x19),
                    bytes1(0),
                    address(registry),
                    registry.nonce(signer),
                    alice,
                    "changeOwner",
                    alice
                )
            );
            (uint8 rv, bytes32 rr, bytes32 rs) = vm.sign(pk, h);
            registry.changeOwnerSigned(alice, rv, rr, rs, alice);
            assertEq(registry.nonce(signer), 1, "signed outgoing owner nonce consumed once");
        } else {
            vm.prank(bob);
            registry.changeOwner(alice, alice);
        }
        vm.expectRevert("Invalid signature");
        _invoke(op, v, r, s);
        uint256 n = registry.nonce(alice);
        (v, r, s) = vm.sign(aliceKey, _digest(op, n));
        _invoke(op, v, r, s);
        assertEq(registry.nonce(alice), n + 1, "fresh signed operation still works");
        if (op == 0) assertEq(registry.identityOwner(alice), delegate);
        if (op == 1) assertTrue(registry.validDelegate(alice, KIND, delegate));
    }

    function test_StaleOwnerTransferRejected() external {
        _roundTrip(0, false);
    }

    function test_StaleDelegateAddRejected() external {
        _roundTrip(1, false);
    }

    function test_StaleDelegateRevokeRejected() external {
        _roundTrip(2, false);
    }

    function test_StaleAttributeSetRejected() external {
        _roundTrip(3, false);
    }

    function test_StaleAttributeRevokeRejected() external {
        _roundTrip(4, false);
    }

    function test_MixedSignedReturnCannotReviveSignature() external {
        _roundTrip(1, true);
    }

    function test_InvalidOwnerTransferDoesNotConsumeNonce() external {
        vm.prank(alice);
        vm.expectRevert("Zero address owner - identity is self-owned by default");
        registry.changeOwner(alice, address(0));
        assertEq(registry.nonce(alice), 0);
        vm.prank(bob);
        vm.expectRevert("Not authorized");
        registry.changeOwner(alice, bob);
        assertEq(registry.nonce(alice), 0);
    }
}

contract SecurityClosureReputation is DisputeTestBase {
    AgentRegistry registry;

    function setUp() public {
        _setUpStack();
        registry = new AgentRegistry(address(kernel));
        kernel.scheduleAgentRegistryUpdate(address(registry));
        vm.warp(vm.getBlockTimestamp() + 2 days + 1);
        kernel.executeAgentRegistryUpdate();
    }

    function _services() internal pure returns (IAgentRegistry.ServiceDescriptor[] memory a) {
        a = new IAgentRegistry.ServiceDescriptor[](1);
        a[0] = IAgentRegistry.ServiceDescriptor(
            keccak256("text-generation"), "text-generation", "", 0, 0, 0, ""
        );
    }

    function test_DeregisteredStalledProviderStillAccountable() external {
        vm.prank(provider);
        registry.registerAgent("https://agent.example", _services());
        vm.prank(requester);
        bytes32 txId = kernel.createTransaction(
            provider,
            requester,
            TRANSACTION_AMOUNT,
            block.timestamp + 1 hours,
            1 hours,
            keccak256("stalled"),
            bytes32(0),
            0,
            0
        );
        vm.startPrank(requester);
        usdc.approve(address(escrow), type(uint256).max);
        kernel.linkEscrow(txId, address(escrow), txId);
        vm.stopPrank();
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");
        vm.prank(provider);
        registry.deregisterAgent();
        uint256 beforeBalance = usdc.balanceOf(requester);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        kernel.recoverStalledInProgress(txId);
        assertEq(usdc.balanceOf(requester) - beforeBalance, TRANSACTION_AMOUNT);
        assertEq(
            kernel.reputationProcessedBy(txId),
            address(registry),
            "fault recorded while deregistered"
        );
        IAgentRegistry.AgentProfile memory p = registry.getAgent(provider);
        assertEq(p.registeredAt, 0);
        assertEq(p.totalTransactions, 1);
        assertEq(p.disputedTransactions, 1);
        assertEq(p.totalVolumeUSDC, TRANSACTION_AMOUNT);
        vm.prank(provider);
        registry.registerAgent("https://agent.example/new", _services());
        p = registry.getAgent(provider);
        assertEq(p.totalTransactions, 1);
        assertEq(p.disputedTransactions, 1);
        vm.prank(address(kernel));
        vm.expectRevert("Transaction already processed");
        registry.updateReputationOnSettlement(provider, txId, TRANSACTION_AMOUNT, true);
    }

    function test_NeverRegisteredStillRejected() external {
        vm.prank(address(kernel));
        vm.expectRevert("Agent not registered");
        registry.updateReputationOnSettlement(provider, keccak256("unknown"), 1e6, true);
    }
}

contract SecurityClosureFees is Test {
    ACTPKernel kernel;
    EscrowVault escrow;
    BlacklistUSDC usdc;
    address requester = address(0x1);
    address provider = address(0x2);
    address feeCollector = address(0xFEE);

    function setUp() public {
        usdc = new BlacklistUSDC();
        kernel = new ACTPKernel(
            address(this), address(this), feeCollector, address(0), address(usdc), 1 hours
        );
        escrow = new EscrowVault(address(usdc), address(kernel));
        kernel.approveEscrowVault(address(escrow), true);
        usdc.mint(requester, 1_000_000_000);
    }

    function _milestone(uint256 amount, uint256 milestone) internal returns (bytes32 txId) {
        vm.prank(requester);
        txId = kernel.createTransaction(
            provider,
            requester,
            amount,
            block.timestamp + 30 days,
            1 hours,
            keccak256("fees"),
            bytes32(0),
            0,
            0
        );
        vm.startPrank(requester);
        usdc.approve(address(escrow), type(uint256).max);
        kernel.linkEscrow(txId, address(escrow), txId);
        vm.stopPrank();
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");
        usdc.setBlocked(feeCollector, true);
        vm.prank(requester);
        kernel.releaseMilestone(txId, milestone);
    }

    function _dispute(bytes32 txId) internal {
        vm.prank(provider);
        kernel.transitionState(
            txId, IACTPKernel.State.DELIVERED, abi.encode(1 hours, keccak256("result"))
        );
        vm.prank(requester);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");
    }

    function test_ReservedFeeCannotBecomeSecondMilestone() external {
        bytes32 txId = _milestone(100_000, 60_000);
        vm.prank(requester);
        vm.expectRevert("Insufficient escrow");
        kernel.releaseMilestone(txId, 90_000);
        vm.prank(requester);
        kernel.releaseMilestone(txId, 40_000);
        assertEq(usdc.balanceOf(provider), 50_000);
        assertEq(escrow.remaining(txId), 50_000);
    }

    function test_ProviderCancellationRefundExcludesReservedFee() external {
        bytes32 txId = _milestone(100_000, 60_000);
        uint256 b = usdc.balanceOf(requester);
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, "");
        assertEq(usdc.balanceOf(requester) - b, 40_000, "refund is unpaid principal only");
        assertEq(escrow.remaining(txId), 50_000, "fee remains reserved");
    }

    function test_StalledRecoveryRefundExcludesReservedFee() external {
        bytes32 txId = _milestone(100_000, 60_000);
        uint256 b = usdc.balanceOf(requester);
        vm.warp(vm.getBlockTimestamp() + 30 days + 1 hours);
        kernel.recoverStalledInProgress(txId);
        assertEq(usdc.balanceOf(requester) - b, 40_000, "recovery is unpaid principal only");
        assertEq(escrow.remaining(txId), 50_000);
    }

    function test_DisputedRequesterAwardExcludesReservedFee() external {
        bytes32 txId = _milestone(100_000, 60_000);
        _dispute(txId);
        uint256 b = usdc.balanceOf(requester);
        kernel.transitionState(
            txId, IACTPKernel.State.SETTLED, abi.encode(uint256(40_000), uint256(0), true)
        );
        assertEq(usdc.balanceOf(requester) - b, 40_000 + 1e6, "principal plus entry bond only");
        uint256 p = usdc.balanceOf(provider);
        usdc.setBlocked(feeCollector, false);
        kernel.releaseEscrow(txId);
        assertEq(usdc.balanceOf(provider), p, "requester-only award fee retry cannot pay provider");
        assertEq(usdc.balanceOf(feeCollector), 50_000);
        assertEq(escrow.remaining(txId), 0);
    }

    function test_MediatorSplitUsesPrincipalExcludingReservedFee() external {
        bytes32 txId = _milestone(100_000, 60_000);
        CompositeMediator mediator = new CompositeMediator(IACTPKernel(address(kernel)));
        mediator.initialize(address(this));
        kernel.approveMediator(address(mediator), true);
        vm.warp(vm.getBlockTimestamp() + 2 days + 1);
        _dispute(txId);
        uint256 rb = usdc.balanceOf(requester);
        uint256 pb = usdc.balanceOf(provider);
        mediator.resolve(txId, 2, 5000);
        assertEq(usdc.balanceOf(requester) - rb, 20_000 + 1e6);
        assertEq(usdc.balanceOf(provider) - pb, 20_000);
        assertEq(escrow.remaining(txId), 50_000);
    }

    function _resolveWithMediator(bytes32 txId, uint8 ruling) internal {
        CompositeMediator mediator = new CompositeMediator(IACTPKernel(address(kernel)));
        mediator.initialize(address(this));
        kernel.approveMediator(address(mediator), true);
        vm.warp(vm.getBlockTimestamp() + 2 days + 1);
        _dispute(txId);
        mediator.resolve(txId, ruling, ruling == 2 ? 5000 : 0);
    }

    function test_ZeroPrincipalReservedFeeBothCleanAwardsAndSplit() external {
        for (uint8 ruling; ruling < 3; ruling++) {
            bytes32 txId = _milestone(100_000, 100_000);
            _resolveWithMediator(txId, ruling);
            assertEq(kernel.escrowPrincipal(txId), 0);
            assertEq(escrow.remaining(txId), 50_000);
            assertEq(
                uint8(kernel.getTransaction(txId).state),
                uint8(ruling == 2 ? IACTPKernel.State.CANCELLED : IACTPKernel.State.SETTLED)
            );
            uint256 p = usdc.balanceOf(provider);
            uint256 r = usdc.balanceOf(requester);
            usdc.setBlocked(feeCollector, false);
            vm.prank(address(0xBAD));
            kernel.retryPlatformFee(txId);
            kernel.retryPlatformFee(txId);
            assertEq(usdc.balanceOf(provider), p);
            assertEq(usdc.balanceOf(requester), r);
            assertEq(escrow.remaining(txId), 0);
        }
        assertEq(usdc.balanceOf(feeCollector), 150_000);
    }

    function test_ZeroPrincipalCancellationAndRecoveryRemainLive() external {
        bytes32 cancel = _milestone(100_000, 100_000);
        vm.prank(provider);
        kernel.transitionState(cancel, IACTPKernel.State.CANCELLED, "");
        bytes32 recover = _milestone(100_000, 100_000);
        vm.warp(vm.getBlockTimestamp() + 30 days + 1 hours);
        kernel.pause();
        kernel.recoverStalledInProgress(recover);
        assertEq(kernel.escrowPrincipal(cancel), 0);
        assertEq(kernel.escrowPrincipal(recover), 0);
        usdc.setBlocked(feeCollector, false);
        kernel.retryPlatformFee(cancel);
        kernel.retryPlatformFee(recover);
        assertEq(usdc.balanceOf(feeCollector), 100_000);
        assertEq(escrow.remaining(cancel) + escrow.remaining(recover), 0);
    }

    function test_ZeroPrincipalForceStaleResolvesAndRefundsBond() external {
        bytes32 txId = _milestone(100_000, 100_000);
        CompositeMediator mediator = new CompositeMediator(IACTPKernel(address(kernel)));
        address[2] memory fixedEvals = [address(0xE1), address(0xE2)];
        address[] memory rotating = new address[](1);
        rotating[0] = address(0xE3);
        BondEscalation bond = new BondEscalation(
            IACTPKernel(address(kernel)),
            IERC20(address(usdc)),
            ICompositeMediator(address(mediator)),
            address(this),
            fixedEvals,
            rotating,
            address(new MockOOV3())
        );
        mediator.initialize(address(bond));
        kernel.approveMediator(address(mediator), true);
        vm.warp(vm.getBlockTimestamp() + 2 days + 1);
        _dispute(txId);
        bytes32 disputeId = bond.openDispute(txId);
        (,,,,,,,,,,,, uint256 disputePrincipal,) = bond.disputes(disputeId);
        assertEq(disputePrincipal, 0, "tier-one sizing excludes fee debt");
        vm.warp(vm.getBlockTimestamp() + 30 days + 1);
        uint256 r = usdc.balanceOf(requester);
        bond.forceResolveStale(disputeId);
        assertEq(uint8(kernel.getTransaction(txId).state), uint8(IACTPKernel.State.CANCELLED));
        assertEq(usdc.balanceOf(requester) - r, 1e6, "entry bond returned even with zero principal");
        assertEq(escrow.remaining(txId), 50_000);
    }

    function test_FeeRetryWhileActiveAndPausedOnlyMovesFee() external {
        bytes32 txId = _milestone(100_000, 60_000);
        IACTPKernel.TransactionView memory beforeTxn = kernel.getTransaction(txId);
        uint256 p = usdc.balanceOf(provider);
        uint256 r = usdc.balanceOf(requester);
        usdc.setBlocked(feeCollector, false);
        kernel.pause();
        vm.prank(address(0xBAD));
        kernel.retryPlatformFee(txId);
        kernel.retryPlatformFee(txId);
        assertEq(kernel.escrowPrincipal(txId), 40_000);
        assertEq(escrow.remaining(txId), 40_000);
        assertEq(usdc.balanceOf(provider), p);
        assertEq(usdc.balanceOf(requester), r);
        assertEq(usdc.balanceOf(feeCollector), 50_000);
        assertEq(kernel.reputationProcessedBy(txId), address(0));
        assertEq(uint8(kernel.getTransaction(txId).state), uint8(beforeTxn.state));
        assertEq(kernel.getTransaction(txId).updatedAt, beforeTxn.updatedAt);
    }

    function test_FeeRetryRejectsRevokedVault() external {
        bytes32 txId = _milestone(100_000, 60_000);
        kernel.scheduleEscrowVaultRevocation(address(escrow));
        vm.warp(vm.getBlockTimestamp() + 2 days + 1);
        kernel.executeEscrowVaultRevocation(address(escrow));
        vm.expectRevert("Vault not approved");
        kernel.retryPlatformFee(txId);
        assertEq(kernel.escrowPrincipal(txId), 40_000);
    }

    function test_PaidMediatorAndFeeInclusiveProofBoundary() external {
        bytes32 txId = _milestone(100_000, 60_000);
        address mediator = address(0x444);
        kernel.approveMediator(mediator, true);
        vm.warp(vm.getBlockTimestamp() + 2 days + 1);
        _dispute(txId);
        vm.expectRevert("Distribute all");
        kernel.transitionState(
            txId,
            IACTPKernel.State.SETTLED,
            abi.encode(uint256(40_000), uint256(40_000), mediator, uint256(10_000), true)
        );
        kernel.transitionState(
            txId,
            IACTPKernel.State.SETTLED,
            abi.encode(uint256(10_000), uint256(20_000), mediator, uint256(10_000), true)
        );
        assertEq(usdc.balanceOf(mediator), 10_000);
        assertEq(escrow.remaining(txId), 50_000);
        assertEq(kernel.escrowPrincipal(txId), 0);
    }

    function test_ArchiveOutflowReducesReservedDebtExactly() external {
        ArchiveTreasury archive = new ArchiveTreasury(address(usdc), address(kernel), address(this));
        kernel.setArchiveTreasury(address(archive));
        bytes32 txId = _milestone(6e6, 3e6);
        assertEq(usdc.balanceOf(address(archive)), 50);
        assertEq(escrow.remaining(txId), 3e6 + 49_950);
        assertEq(kernel.escrowPrincipal(txId), 3e6);
        vm.prank(requester);
        kernel.releaseMilestone(txId, 3e6);
        assertEq(kernel.escrowPrincipal(txId), 0);
        uint256 p = usdc.balanceOf(provider);
        kernel.retryPlatformFee(txId);
        kernel.retryPlatformFee(txId);
        assertEq(
            usdc.balanceOf(address(archive)), 60, "failed retries never reallocate treasury debt"
        );
        usdc.setBlocked(feeCollector, false);
        kernel.retryPlatformFee(txId);
        assertEq(usdc.balanceOf(provider), p);
        assertEq(usdc.balanceOf(address(archive)), 60, "archive slice charged once");
        assertEq(usdc.balanceOf(feeCollector), 59_940, "treasury debt remains owed to treasury");
        assertEq(escrow.remaining(txId), 0);
    }

    function test_SettledFeeRetryDoesNotRepeatArchiveAllocation() external {
        ArchiveTreasury archive = new ArchiveTreasury(address(usdc), address(kernel), address(this));
        kernel.setArchiveTreasury(address(archive));
        bytes32 txId = _milestone(6e6, 3e6);
        vm.prank(provider);
        kernel.transitionState(
            txId, IACTPKernel.State.DELIVERED, abi.encode(1 hours, keccak256("result"))
        );
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1);
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, "");
        kernel.releaseEscrow(txId);
        kernel.releaseEscrow(txId);
        assertEq(usdc.balanceOf(address(archive)), 60);
        usdc.setBlocked(feeCollector, false);
        kernel.releaseEscrow(txId);
        assertEq(usdc.balanceOf(address(archive)), 60);
        assertEq(usdc.balanceOf(feeCollector), 59_940);
        assertEq(usdc.balanceOf(provider), 6e6 - 60_000);
        assertEq(escrow.remaining(txId), 0);
    }

    function testFuzz_FeeDebtConservedAcrossTerminalPaths(
        uint96 amountSeed,
        uint16 fragmentSeed,
        uint8 exitSeed
    ) external {
        uint256 amount = bound(amountSeed, 100_000, 100e6);
        uint256 fragment = bound(fragmentSeed, 1, amount);
        uint256 exit = bound(exitSeed, 0, 4);
        bytes32 txId = _milestone(amount, fragment);
        uint256 principal = amount - fragment;
        if (exit == 0) {
            if (principal > 0) {
                vm.prank(requester);
                kernel.releaseMilestone(txId, principal);
            }
            vm.prank(provider);
            kernel.transitionState(txId, IACTPKernel.State.CANCELLED, "");
        } else if (exit == 1) {
            vm.prank(provider);
            kernel.transitionState(txId, IACTPKernel.State.CANCELLED, "");
        } else if (exit == 2) {
            vm.warp(vm.getBlockTimestamp() + 30 days + 1 hours);
            kernel.recoverStalledInProgress(txId);
        } else {
            _dispute(txId);
            uint256 award = principal == 0 ? 1 : principal;
            kernel.transitionState(
                txId,
                IACTPKernel.State.SETTLED,
                abi.encode(exit == 3 ? 0 : award, exit == 3 ? award : 0, exit != 3)
            );
        }
        assertEq(kernel.escrowPrincipal(txId), 0);
        uint256 p = usdc.balanceOf(provider);
        uint256 r = usdc.balanceOf(requester);
        usdc.setBlocked(feeCollector, false);
        kernel.retryPlatformFee(txId);
        kernel.retryPlatformFee(txId);
        assertEq(usdc.balanceOf(provider), p);
        assertEq(usdc.balanceOf(requester), r);
        assertEq(escrow.remaining(txId), 0);
        assertEq(
            p + r + usdc.balanceOf(feeCollector), 1_000_000_000, "complete escrow/bond conservation"
        );
    }
}

contract SecurityClosureDeployment is Test {
    uint256 constant KEY = 1; // public local fixture only
    address safe = address(0x5AFE);

    function _env(address admin) internal returns (address deployer) {
        deployer = vm.addr(KEY);
        vm.deal(deployer, 10 ether);
        vm.etch(safe, hex"00");
        vm.setEnv("PRIVATE_KEY", "1");
        vm.setEnv("KERNEL_ADMIN", vm.toString(admin));
        vm.setEnv("KERNEL_PAUSER", vm.toString(admin));
        vm.setEnv("KERNEL_FEE_RECIPIENT", vm.toString(admin));
        vm.setEnv("TREASURY_ADDRESS", vm.toString(admin));
        vm.setEnv("ARCHIVE_UPLOADER", vm.toString(admin));
        vm.setEnv("DEPLOY_ARCHIVE", "true");
        vm.setEnv("DEPLOY_REGISTRY", "false");
        vm.setEnv("RECOVERY_GRACE", "3600");
        vm.setEnv("USDC_ADDRESS", vm.toString(address(new MockUSDC())));
    }

    function _v2(address admin) internal {
        vm.chainId(31337);
        address deployer = _env(admin);
        address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 2);
        new DeployKernelV2().run();
        assertEq(
            ArchiveTreasury(predicted).owner(), admin, "archive deployer hands ownership to admin"
        );
    }

    // vm.setEnv is process-wide: keep all conflicting configurations in one test so
    // the default parallel suite cannot interleave their environment writes/reads.
    function test_DeploymentOwnershipScenarios() external {
        _v2(safe);
        _v2(vm.addr(KEY));
        vm.chainId(8453);
        address deployer = _env(safe);
        address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 3);
        new DeployBaseMainnet().run();
        assertEq(ArchiveTreasury(predicted).owner(), safe, "mainnet script handoff from deployer");
    }
}
