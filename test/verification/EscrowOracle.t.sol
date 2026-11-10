// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DisputeTestBase} from "../helpers/DisputeTestBase.sol";
import {IACTPKernel} from "../../src/interfaces/IACTPKernel.sol";

contract EscrowOracleHandler is DisputeTestBase {
    struct Row {
        bytes32 txId;
        bytes32 disputeId;
        address payer;
        address worker;
        address depositor;
        uint256 payerBefore;
        uint256 workerBefore;
        uint8 first;
        bool overridden;
    }

    Row[2] internal rows;
    uint256[12] public succeeded;
    uint256 public touched;
    bool internal firstWriterFailed;
    bool internal callFailed;
    bool internal retryFailed;
    bool internal callbackFailed;
    uint256 internal constant AMOUNT = 100_000e6;

    constructor() {
        _setUpStack();
        for (uint256 i; i < 2; i++) _open(i);
    }

    function _open(uint256 i) internal {
        Row storage r = rows[i];
        r.payer = address(uint160(0x1010 + i * 16));
        r.worker = address(uint160(0x1011 + i * 16));
        r.depositor = address(uint160(0xA100 + i));
        usdc.mint(r.payer, 1_000_000e6);
        usdc.mint(r.worker, 1_000_000e6);
        usdc.mint(r.depositor, 1_000_000e6);
        vm.prank(r.payer);
        r.txId = kernel.createTransaction(r.worker, r.payer, AMOUNT,
            vm.getBlockTimestamp() + 30 days, 1 hours, keccak256("oracle"), bytes32(0), 0, 0);
        vm.startPrank(r.payer);
        usdc.approve(address(escrow), type(uint256).max);
        kernel.linkEscrow(r.txId, address(escrow), r.txId);
        vm.stopPrank();
        vm.startPrank(r.worker);
        kernel.transitionState(r.txId, IACTPKernel.State.IN_PROGRESS, "");
        kernel.transitionState(r.txId, IACTPKernel.State.DELIVERED, abi.encode(1 hours, keccak256("result")));
        vm.stopPrank();
        vm.prank(r.payer);
        kernel.transitionState(r.txId, IACTPKernel.State.DISPUTED, "");
        r.disputeId = bondEscalation.openDispute(r.txId);
        vm.startPrank(r.depositor);
        usdc.approve(address(bondEscalation), type(uint256).max);
        bondEscalation.proposeDirectly(r.disputeId, i == 0 ? 1 : 0, 0);
        bondEscalation.escalateToUMA(r.disputeId, EVIDENCE_CID, REASONING_CID);
        vm.stopPrank();
        r.payerBefore = usdc.balanceOf(r.payer);
        r.workerBefore = usdc.balanceOf(r.worker);
    }

    function _restoreMediator() internal {
        if (!kernel.approvedMediators(address(compositeMediator))) {
            vm.warp(vm.getBlockTimestamp() + 2 days + 1);
            kernel.approveMediator(address(compositeMediator), true);
        }
        vm.warp(vm.getBlockTimestamp() + 2 days + 1);
    }

    function resolve(uint256 seed, bool defer) external {
        uint256 i = seed % 2;
        Row storage r = rows[i];
        if (r.first != 0) return;
        _restoreMediator();
        if (defer) kernel.approveMediator(address(compositeMediator), false);
        r.first = 1;
        try oov3.mockResolve(bondEscalation.disputeToAssertion(r.disputeId), i == 0) {} catch {
            callFailed = true;
            return;
        }
        bool pending = bondEscalation.mediatorRetryPending(r.disputeId);
        IACTPKernel.State state = kernel.getTransaction(r.txId).state;
        if (defer) {
            if (pending && state == IACTPKernel.State.DISPUTED) succeeded[7]++;
            else callbackFailed = true;
        } else {
            if (!pending && state == IACTPKernel.State.SETTLED) succeeded[6]++;
            else callbackFailed = true;
        }
        succeeded[0]++;
        touched |= 1 << i;
    }

    function retry(uint256 seed) external {
        Row storage r = rows[seed % 2];
        if (!bondEscalation.mediatorRetryPending(r.disputeId) || r.overridden) return;
        _restoreMediator();
        try bondEscalation.retryMediatorResolution(r.disputeId) {
            if (!bondEscalation.mediatorRetryPending(r.disputeId)
                && kernel.getTransaction(r.txId).state == IACTPKernel.State.SETTLED) succeeded[1]++;
            else retryFailed = true;
        } catch {
            callFailed = true;
        }
    }

    function claim(uint256 seed) external {
        Row storage r = rows[seed % 2];
        if (r.first == 0) return;
        vm.prank(r.depositor);
        try bondEscalation.claimEscalationRefund(r.disputeId) {
            succeeded[2]++;
        } catch {}
    }

    function duplicate(uint256 seed) external {
        uint256 i = seed % 2;
        Row storage r = rows[i];
        if (r.first == 0) return;
        try oov3.mockResolve(bondEscalation.disputeToAssertion(r.disputeId), i != 0) {
            succeeded[3]++;
        } catch {
            callFailed = true;
        }
    }

    function _protectedOutcome(Row storage r) internal view returns (bytes32) {
        (, uint8 ruling, uint16 split,,,,,,, bool resolved,,,,) = bondEscalation.disputes(r.disputeId);
        bytes32 state = keccak256(abi.encode(kernel.getTransaction(r.txId), ruling, split, resolved,
            bondEscalation.mediatorRetryPending(r.disputeId)));
        return keccak256(abi.encode(state, usdc.balanceOf(r.payer), usdc.balanceOf(r.worker),
            usdc.balanceOf(r.depositor), escrow.remaining(r.txId), escrow.bondBalance(r.txId)));
    }

    function _lateRejected(Row storage r, bool staleCall) internal returns (bool) {
        IACTPKernel.State beforeState = kernel.getTransaction(r.txId).state;
        bool accepted;
        bytes memory failure;
        if (staleCall) {
            try bondEscalation.forceResolveStale(r.disputeId) {
                accepted = true;
            } catch (bytes memory reason) {
                failure = reason;
            }
        } else {
            try bondEscalation.syncExternalResolution(r.disputeId) {
                accepted = true;
            } catch (bytes memory reason) {
                failure = reason;
            }
        }
        if (accepted && beforeState == IACTPKernel.State.SETTLED) {
            emit log_named_uint("P1.accepted-late-after-settlement", 1);
        }
        return !accepted && keccak256(failure)
            == keccak256(abi.encodeWithSignature("Error(string)", "Already resolved"));
    }

    function stale(uint256 seed) external {
        uint256 i = seed % 2;
        Row storage r = rows[i];
        if (r.first == 2 || r.overridden) return;
        _restoreMediator();
        vm.warp(vm.getBlockTimestamp() + 61 days);
        if (r.first == 1) {
            bytes32 before = _protectedOutcome(r);
            uint256 window = kernel.getTransaction(r.txId).state == IACTPKernel.State.DISPUTED ? 0 : 1;
            if (_lateRejected(r, true)) succeeded[8 + window]++;
            else firstWriterFailed = true;
            if (_lateRejected(r, false)) succeeded[10 + window]++;
            else firstWriterFailed = true;
            if (_protectedOutcome(r) != before) firstWriterFailed = true;
            return;
        }
        r.first = 2;
        try bondEscalation.forceResolveStale(r.disputeId) {
            if (kernel.getTransaction(r.txId).state == IACTPKernel.State.CANCELLED) succeeded[4]++;
            else callFailed = true;
        } catch {
            callFailed = true;
        }
        touched |= 1 << i;
    }

    function trustedOverrideControl(uint256 seed) external {
        Row storage r = rows[seed % 2];
        require(bondEscalation.mediatorRetryPending(r.disputeId), "Expected deferred callback");
        r.overridden = true;
        kernel.transitionState(r.txId, IACTPKernel.State.CANCELLED, abi.encode(AMOUNT, uint256(0)));
        bool retrySucceeded;
        try bondEscalation.retryMediatorResolution(r.disputeId) {
            retrySucceeded = true;
        } catch {}
        require(!retrySucceeded && bondEscalation.mediatorRetryPending(r.disputeId), "Override retry semantics");
        succeeded[5]++;
    }

    function assertProperty() external view {
        require(!firstWriterFailed, "P1 first-writer guard");
        require(!callFailed, "P1 unexpected call failure");
        for (uint256 i; i < 2; i++) {
            Row storage r = rows[i];
            if (r.overridden) continue;
            (, uint8 ruling, uint16 split,,,,,,, bool resolved,,,,) = bondEscalation.disputes(r.disputeId);
            if (r.first == 0) {
                require(!resolved, "P1 unexpected resolution");
                continue;
            }
            uint8 expected = r.first == 2 ? 2 : (i == 0 ? 0 : 1);
            require(resolved && ruling == expected, "P1 oracle/refund coupling");
            require(split == (r.first == 2 ? 5000 : 0), "P1 split mutation");
            IACTPKernel.State state = kernel.getTransaction(r.txId).state;
            if (state == IACTPKernel.State.DISPUTED) {
                require(usdc.balanceOf(r.worker) == r.workerBefore, "P1 deferred provider payment");
                require(usdc.balanceOf(r.payer) == r.payerBefore, "P1 deferred requester payment");
                continue;
            }
            uint256 providerGross = expected == 0 ? AMOUNT : (expected == 2 ? AMOUNT / 2 : 0);
            uint256 providerNet = providerGross - providerGross / 100;
            uint256 requesterNet = AMOUNT - providerGross;
            if (expected == 0) providerNet += AMOUNT / 20;
            else requesterNet += AMOUNT / 20;
            require(usdc.balanceOf(r.worker) == r.workerBefore + providerNet, "P1 provider award");
            require(usdc.balanceOf(r.payer) == r.payerBefore + requesterNet, "P1 requester award");
            require(escrow.remaining(r.txId) == 0 && escrow.bondBalance(r.txId) == 0, "P1 payout completion");
        }
        require(!retryFailed, "P1 retry incomplete");
        require(!callbackFailed, "P1 callback completion");
    }
}

contract EscrowOracleVerification is DisputeTestBase {
    EscrowOracleHandler internal handler;

    function setUp() public {
        handler = new EscrowOracleHandler();
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.resolve.selector;
        selectors[1] = handler.retry.selector;
        selectors[2] = handler.claim.selector;
        selectors[3] = handler.duplicate.selector;
        selectors[4] = handler.stale.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_OracleAwardUnaffected() public view {
        handler.assertProperty();
    }

    function test_DeterministicOracleAndRetry() external {
        handler.resolve(0, true);
        handler.assertProperty();
        handler.stale(0);
        handler.assertProperty();
        handler.retry(0);
        handler.assertProperty();
        handler.stale(0);
        handler.assertProperty();
        handler.claim(0);
        handler.claim(0);
        handler.duplicate(0);
        handler.resolve(1, false);
        handler.assertProperty();
        handler.stale(1);
        handler.assertProperty();
        handler.claim(1);
        handler.duplicate(1);
        handler.assertProperty();
        assertEq(handler.touched(), 3);
        assertEq(handler.succeeded(0), 2);
        assertEq(handler.succeeded(1), 1);
        assertEq(handler.succeeded(2), 2);
        assertEq(handler.succeeded(3), 2);
        assertEq(handler.succeeded(6), 1);
        assertEq(handler.succeeded(7), 1);
        assertEq(handler.succeeded(8), 1);
        assertEq(handler.succeeded(9), 2);
        assertEq(handler.succeeded(10), 1);
        assertEq(handler.succeeded(11), 2);
        emit log_named_uint("P1.immediate-success", handler.succeeded(6));
        emit log_named_uint("P1.observed-deferral", handler.succeeded(7));
        emit log_named_uint("P1.stale-deferred-rejected", handler.succeeded(8));
        emit log_named_uint("P1.stale-completed-rejected", handler.succeeded(9));
        emit log_named_uint("P1.sync-deferred-rejected", handler.succeeded(10));
        emit log_named_uint("P1.sync-completed-rejected", handler.succeeded(11));
        emit log_named_uint("P1.callbacks", handler.succeeded(0));
        emit log_named_uint("P1.deferred-retries", handler.succeeded(1));
        emit log_named_uint("P1.refunds", handler.succeeded(2));
        emit log_named_uint("P1.duplicate-callbacks", handler.succeeded(3));
    }

    function test_DeterministicStaleThenLateOracle() external {
        handler.stale(0);
        handler.duplicate(0);
        handler.claim(0);
        handler.stale(1);
        handler.duplicate(1);
        handler.claim(1);
        handler.assertProperty();
        assertEq(handler.touched(), 3);
        assertEq(handler.succeeded(4), 2);
        assertEq(handler.succeeded(3), 2);
        assertEq(handler.succeeded(2), 2);
        emit log_named_uint("P1.stale-exits", handler.succeeded(4));
    }

    function test_TrustedPostCallbackOverrideIsExplicitlyExcluded() external {
        handler.resolve(0, true);
        handler.trustedOverrideControl(0);
        assertEq(handler.succeeded(5), 1);
        emit log_named_uint("P1.excluded-trusted-overrides", handler.succeeded(5));
    }
}
