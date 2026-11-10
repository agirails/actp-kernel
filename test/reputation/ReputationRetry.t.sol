// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DisputeTestBase} from "../helpers/DisputeTestBase.sol";
import {IACTPKernel} from "../../src/interfaces/IACTPKernel.sol";
import {IAgentRegistry} from "../../src/interfaces/IAgentRegistry.sol";
import {AgentRegistry} from "../../src/registry/AgentRegistry.sol";

interface ReputationRetryAPI {
    function retryReputation(bytes32 transactionId) external;
}

contract NestedReputationRegistry {
    address internal immutable kernel;
    bool public nestedSucceeded;
    uint256 public calls;

    constructor(address kernel_) {
        kernel = kernel_;
    }

    function updateReputationOnSettlement(address, bytes32 txId, uint256, bool) external {
        require(msg.sender == kernel, "Only kernel");
        (nestedSucceeded,) = kernel.call(abi.encodeCall(ReputationRetryAPI.retryReputation, (txId)));
        calls++;
    }
}

contract GasBurningReputationRegistry {
    function updateReputationOnSettlement(address, bytes32, uint256, bool) external pure {
        assembly { for { } 1 { } { } }
    }
}

contract ReputationRetryTest is DisputeTestBase {
    AgentRegistry internal registry;

    function setUp() public {
        _setUpStack();
        registry = new AgentRegistry(address(kernel));
        _install(address(registry));
        _register(registry);
    }

    function _install(address next) internal {
        kernel.scheduleAgentRegistryUpdate(next);
        vm.warp(vm.getBlockTimestamp() + 2 days + 1);
        kernel.executeAgentRegistryUpdate();
    }

    function _register(AgentRegistry next) internal {
        IAgentRegistry.ServiceDescriptor[] memory services = new IAgentRegistry.ServiceDescriptor[](1);
        services[0] = IAgentRegistry.ServiceDescriptor(
            keccak256("text-generation"), "text-generation", "", 0, 0, 0, ""
        );
        vm.prank(provider);
        next.registerAgent("https://retry.example", services);
    }

    function _outage() internal {
        vm.mockCallRevert(
            address(registry),
            abi.encodeWithSelector(IAgentRegistry.updateReputationOnSettlement.selector),
            abi.encode("temporary registry outage")
        );
    }

    function _settled(uint256 width, bool fault) internal returns (bytes32 txId) {
        txId = _createDisputed();
        uint256 r = fault ? TRANSACTION_AMOUNT : 0;
        uint256 p = fault ? 0 : TRANSACTION_AMOUNT;
        bytes memory proof;
        if (width == 64) proof = abi.encode(r, p);
        else if (width == 96) proof = abi.encode(r, p, fault);
        else if (width == 128) proof = abi.encode(r, p, address(0), uint256(0));
        else proof = abi.encode(r, p, address(0), uint256(0), fault);
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, proof);
    }

    function _retry(bytes32 txId) internal {
        ReputationRetryAPI(address(kernel)).retryReputation(txId);
    }

    function _economics(bytes32 txId) internal view returns (bytes32) {
        return keccak256(abi.encode(
            kernel.getTransaction(txId), escrow.remaining(txId), escrow.bondBalance(txId),
            usdc.balanceOf(requester), usdc.balanceOf(provider), usdc.balanceOf(feeCollector),
            usdc.balanceOf(address(kernel)), usdc.balanceOf(address(escrow))
        ));
    }

    function _assertHistory(AgentRegistry target, bytes32 txId, bool fault) internal view {
        IAgentRegistry.AgentProfile memory profile = target.getAgent(provider);
        assertEq(profile.totalTransactions, 1);
        assertEq(profile.disputedTransactions, fault ? 1 : 0, "retry must preserve final fault");
        assertEq(profile.totalVolumeUSDC, TRANSACTION_AMOUNT);
        assertEq(kernel.reputationProcessedBy(txId), address(target));
    }

    function test_ExistingReleaseRetryPreservesCleanWin() external {
        _outage();
        bytes32 txId = _settled(96, false);
        assertEq(kernel.reputationProcessedBy(txId), address(0));
        vm.clearMockedCalls();
        bytes32 before = _economics(txId);
        kernel.releaseEscrow(txId);
        _assertHistory(registry, txId, false);
        assertEq(_economics(txId), before);
    }

    function test_ImmediateCleanHistoryControl() external {
        bytes32 txId = _settled(96, false);
        _assertHistory(registry, txId, false);
    }

    function test_ImmediateFaultHistoryControl() external {
        bytes32 txId = _settled(160, true);
        _assertHistory(registry, txId, true);
    }

    function test_ExplicitWidthsPreserveBothFaultOutcomes() external {
        for (uint256 width = 96; width <= 160; width += 64) {
            for (uint256 choice; choice < 2; choice++) {
                AgentRegistry next = new AgentRegistry(address(kernel));
                _install(address(next));
                _register(next);
                registry = next;
                _outage();
                bytes32 txId = _settled(width, choice == 1);
                vm.clearMockedCalls();
                bytes32 before = _economics(txId);
                kernel.pause();
                vm.prank(address(0xBEEF));
                _retry(txId);
                _retry(txId);
                kernel.unpause();
                _assertHistory(next, txId, choice == 1);
                assertEq(_economics(txId), before);
            }
        }
    }

    function test_LegacyWidthsRetainImplicitFault() external {
        for (uint256 width = 64; width <= 128; width += 64) {
            AgentRegistry next = new AgentRegistry(address(kernel));
            _install(address(next));
            _register(next);
            registry = next;
            _outage();
            bytes32 txId = _settled(width, true);
            vm.clearMockedCalls();
            _retry(txId);
            _assertHistory(next, txId, true);
        }
    }

    function _inProgress() internal returns (bytes32 txId) {
        vm.prank(requester);
        txId = kernel.createTransaction(provider, requester, TRANSACTION_AMOUNT,
            vm.getBlockTimestamp() + 1 hours, 1 hours, keccak256("stalled"), bytes32(0), 0, 0);
        vm.startPrank(requester);
        usdc.approve(address(escrow), type(uint256).max);
        kernel.linkEscrow(txId, address(escrow), txId);
        vm.stopPrank();
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");
    }

    function test_StalledOutageRestorationAllowsThirdPartyRetry() external {
        bytes32 txId = _inProgress();
        _outage();
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        kernel.recoverStalledInProgress(txId);
        assertEq(kernel.reputationProcessedBy(txId), address(0));
        vm.clearMockedCalls();
        bytes32 before = _economics(txId);
        kernel.pause();
        vm.prank(address(0xBEEF));
        _retry(txId);
        _retry(txId);
        _assertHistory(registry, txId, true);
        assertEq(_economics(txId), before);
    }

    function test_LateRegistrationPreservesCleanHistory() external {
        AgentRegistry next = new AgentRegistry(address(kernel));
        _install(address(next));
        bytes32 txId = _settled(160, false);
        assertEq(kernel.reputationProcessedBy(txId), address(0));
        _retry(txId);
        assertEq(kernel.reputationProcessedBy(txId), address(0));
        _register(next);
        _retry(txId);
        _assertHistory(next, txId, false);
    }

    function test_NoRegistryThenInstallCanRetry() external {
        _setUpStack();
        bytes32 txId = _settled(96, false);
        _retry(txId);
        assertEq(kernel.reputationProcessedBy(txId), address(0));
        AgentRegistry next = new AgentRegistry(address(kernel));
        _install(address(next));
        _register(next);
        _retry(txId);
        _assertHistory(next, txId, false);
    }

    function test_MigrationDoesNotReplaySuccessfulHistory() external {
        bytes32 txId = _settled(96, false);
        AgentRegistry next = new AgentRegistry(address(kernel));
        _install(address(next));
        _register(next);
        _retry(txId);
        kernel.releaseEscrow(txId);
        _assertHistory(registry, txId, false);
        assertEq(next.getAgent(provider).totalTransactions, 0);
    }

    function test_CodeLessRegistryCannotBlockSettlementOrLaterRetry() external {
        _install(address(0xCAFE));
        bytes32 txId = _settled(96, false);
        assertEq(uint256(kernel.getTransaction(txId).state), uint256(IACTPKernel.State.SETTLED));
        assertEq(kernel.reputationProcessedBy(txId), address(0));
        _install(address(registry));
        _retry(txId);
        _assertHistory(registry, txId, false);
    }

    function test_UnknownAndNonterminalOutcomesReject() external {
        vm.expectRevert("Tx missing");
        _retry(bytes32(0));
        bytes32 txId = _inProgress();
        vm.expectRevert("No reputation outcome");
        _retry(txId);
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, "");
        vm.expectRevert("No reputation outcome");
        _retry(txId);
    }

    function _reject(bytes32 txId) internal {
        vm.expectRevert("No reputation outcome");
        _retry(txId);
    }

    function test_AllNonterminalStatesReject() external {
        vm.prank(requester);
        bytes32 txId = kernel.createTransaction(provider, requester, TRANSACTION_AMOUNT,
            vm.getBlockTimestamp() + 10 days, 1 hours, keccak256("states"), bytes32(0), 0, 0);
        _reject(txId);
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.QUOTED, abi.encode(keccak256("quote")));
        _reject(txId);
        vm.startPrank(requester);
        usdc.approve(address(escrow), type(uint256).max);
        kernel.linkEscrow(txId, address(escrow), txId);
        vm.stopPrank();
        _reject(txId);
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");
        _reject(txId);
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(1 hours, keccak256("result")));
        _reject(txId);
        vm.prank(requester);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");
        _reject(txId);
    }

    function test_RegistryOutOfGasCannotBlockRecovery() external {
        _install(address(new GasBurningReputationRegistry()));
        bytes32 txId = _inProgress();
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        kernel.recoverStalledInProgress(txId);
        assertEq(kernel.reputationProcessedBy(txId), address(0));
        _install(address(registry));
        _retry(txId);
        _assertHistory(registry, txId, true);
    }

    function test_ThirdPartyRetriesAdverseHistoryAfterMigration() external {
        bytes32 txId = _inProgress();
        _outage();
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        kernel.recoverStalledInProgress(txId);
        vm.clearMockedCalls();
        AgentRegistry next = new AgentRegistry(address(kernel));
        _install(address(next));
        _register(next);
        bytes32 before = _economics(txId);
        vm.prank(address(0xBEEF));
        _retry(txId);
        _assertHistory(next, txId, true);
        assertEq(_economics(txId), before);
    }

    function test_NeutralDisputedCancellationRejects() external {
        bytes32 txId = _createDisputed();
        kernel.transitionState(txId, IACTPKernel.State.CANCELLED,
            abi.encode(TRANSACTION_AMOUNT, uint256(0)));
        vm.expectRevert("No reputation outcome");
        _retry(txId);
        assertEq(registry.getAgent(provider).totalTransactions, 0);
    }

    function test_ReentrantRegistryCannotNestRetry() external {
        NestedReputationRegistry next = new NestedReputationRegistry(address(kernel));
        _install(address(next));
        bytes32 txId = _settled(96, false);
        assertEq(next.calls(), 1);
        assertFalse(next.nestedSucceeded());
        _retry(txId);
        assertEq(next.calls(), 1);
    }
}
