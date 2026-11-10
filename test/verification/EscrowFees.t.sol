// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ACTPKernel} from "../../src/ACTPKernel.sol";
import {EscrowVault} from "../../src/escrow/EscrowVault.sol";
import {IACTPKernel} from "../../src/interfaces/IACTPKernel.sol";
import {CompositeMediator} from "../../src/CompositeMediator.sol";
import {ArchiveTreasury} from "../../src/treasury/ArchiveTreasury.sol";
import {BlacklistUSDC} from "../audit/F17F59_FeeAccounting.t.sol";

contract EscrowFeeHandler is Test {
    struct SinkBalances {
        uint256 archive;
        uint256 collector;
        uint256 kernel;
    }

    ACTPKernel internal kernel;
    EscrowVault internal vault;
    CompositeMediator internal mediator;
    BlacklistUSDC internal token;
    ArchiveTreasury internal archive;
    uint256[2] internal gross;
    uint256[2] internal charged;
    bytes32[2] internal ids;
    address[2] internal payers;
    address[2] internal workers;
    address[2] internal paidMediators;
    uint256[15] public succeeded;
    uint256 public touched;
    address internal constant FEES = address(0xFEED);
    uint256 internal constant FUNDING = 100e6;
    uint256 internal constant DEPOSIT = 10e6;

    constructor() {
        token = new BlacklistUSDC();
        kernel = new ACTPKernel(address(this), address(this), FEES, address(0), address(token), 1 hours);
        vault = new EscrowVault(address(token), address(kernel));
        kernel.approveEscrowVault(address(vault), true);
        archive = new ArchiveTreasury(address(token), address(kernel), address(this));
        kernel.setArchiveTreasury(address(archive));
        mediator = new CompositeMediator(IACTPKernel(address(kernel)));
        mediator.initialize(address(this));
        kernel.approveMediator(address(mediator), true);
        for (uint256 i; i < 2; i++) {
            paidMediators[i] = address(uint160(0x5000 + i));
            kernel.approveMediator(paidMediators[i], true);
        }
        vm.warp(vm.getBlockTimestamp() + 2 days + 1);
        token.setBlocked(FEES, true);
        for (uint256 i; i < 2; i++) _open(i);
    }

    function _open(uint256 i) internal {
        payers[i] = address(uint160(0x2000 + i * 16));
        workers[i] = address(uint160(0x2001 + i * 16));
        token.mint(payers[i], FUNDING);
        vm.prank(payers[i]);
        ids[i] = kernel.createTransaction(workers[i], payers[i], DEPOSIT,
            vm.getBlockTimestamp() + 30 days, 1 hours, keccak256("fees"), bytes32(0), 0, 0);
        vm.startPrank(payers[i]);
        token.approve(address(vault), type(uint256).max);
        kernel.linkEscrow(ids[i], address(vault), ids[i]);
        vm.stopPrank();
        vm.prank(workers[i]);
        kernel.transitionState(ids[i], IACTPKernel.State.IN_PROGRESS, "");
        vm.prank(payers[i]);
        kernel.releaseMilestone(ids[i], 2e6);
        gross[i] = 2e6;
        charged[i] = 50_000;
    }

    function _feeEnvironment(bool healthy, bool archiveHealthy) internal {
        token.setBlocked(FEES, !healthy);
        token.setBlocked(address(archive), !archiveHealthy);
    }

    function _sinkBalances() internal view returns (SinkBalances memory) {
        return SinkBalances(token.balanceOf(address(archive)), token.balanceOf(FEES), token.balanceOf(address(kernel)));
    }

    function _expectProvider(uint256 i, uint256 amount, SinkBalances memory before) internal {
        if (amount == 0) return;
        uint256 target = (gross[i] + amount) / 100;
        if (target < 50_000) target = 50_000;
        if (target > gross[i] + amount) target = gross[i] + amount;
        uint256 fee = target > charged[i] ? target - charged[i] : 0;
        if (fee > amount) fee = amount;
        gross[i] += amount;
        charged[i] += fee;
        if (fee > 0) {
            succeeded[10]++;
            SinkBalances memory observed = _sinkBalances();
            if (observed.collector > before.collector) succeeded[11]++;
            if (observed.archive > before.archive) succeeded[12]++;
            if (fee / 1000 > 0 && observed.archive == before.archive
                && observed.collector >= before.collector && observed.collector - before.collector == fee) succeeded[13]++;
            if (observed.kernel > before.kernel) succeeded[14]++;
        }
    }

    function milestone(uint256 seed, uint256 amountSeed, bool healthy, bool archiveHealthy) external {
        uint256 i = seed % 2;
        if (kernel.getTransaction(ids[i]).state != IACTPKernel.State.IN_PROGRESS) return;
        uint256 amount = 1 + amountSeed % (9e6);
        _feeEnvironment(healthy, archiveHealthy);
        SinkBalances memory before = _sinkBalances();
        vm.prank(payers[i]);
        try kernel.releaseMilestone(ids[i], amount) {
            _expectProvider(i, amount, before);
            succeeded[0]++;
            touched |= 1 << i;
        } catch {
            succeeded[1]++;
        }
    }

    function retryFee(uint256 seed, bool healthy) external {
        uint256 i = seed % 2;
        token.setBlocked(FEES, !healthy);
        uint256 before = token.balanceOf(FEES);
        kernel.retryPlatformFee(ids[i]);
        succeeded[2]++;
        if (token.balanceOf(FEES) > before) succeeded[3]++;
    }

    function exit(uint256 seed, uint256 modeSeed, bool healthy, bool archiveHealthy) external {
        uint256 i = seed % 2;
        uint256 mode = modeSeed % 6;
        bytes32 id = ids[i];
        IACTPKernel.TransactionView memory t = kernel.getTransaction(id);
        if (t.state != IACTPKernel.State.IN_PROGRESS) return;
        _feeEnvironment(healthy, archiveHealthy);
        SinkBalances memory before = _sinkBalances();
        uint256 providerGross;
        if (mode == 0) {
            vm.prank(workers[i]);
            kernel.transitionState(id, IACTPKernel.State.CANCELLED, "");
        } else if (mode == 1) {
            vm.warp(t.deadline + kernel.recoveryGrace());
            kernel.recoverStalledInProgress(id);
        } else {
            if (vm.getBlockTimestamp() > t.deadline) return;
            vm.prank(workers[i]);
            kernel.transitionState(id, IACTPKernel.State.DELIVERED, abi.encode(1 hours, keccak256("result")));
            vm.prank(payers[i]);
            kernel.transitionState(id, IACTPKernel.State.DISPUTED, "");
            if (mode < 5) {
                uint8 ruling = uint8(mode - 2);
                providerGross = ruling == 0 ? DEPOSIT - gross[i] : (ruling == 2 ? (DEPOSIT - gross[i]) / 2 : 0);
                mediator.resolve(id, ruling, ruling == 2 ? 5000 : 0);
            } else {
                uint256 principal = kernel.escrowPrincipal(id);
                uint256 paid = principal / 10;
                uint256 requesterAmount = principal - paid;
                if (principal == 0) requesterAmount = 1;
                kernel.transitionState(id, IACTPKernel.State.SETTLED,
                    abi.encode(requesterAmount, uint256(0), paidMediators[i], paid, true));
            }
        }
        _expectProvider(i, providerGross, before);
        succeeded[4 + mode]++;
        touched |= 1 << i;
    }

    function assertProperty() external view {
        uint256 accounted = token.balanceOf(FEES) + token.balanceOf(address(archive))
            + token.balanceOf(address(kernel));
        for (uint256 i; i < 2; i++) {
            uint256 distributions = token.balanceOf(payers[i]) + token.balanceOf(workers[i])
                + token.balanceOf(paidMediators[i]) + vault.bondBalance(ids[i]) - (FUNDING - DEPOSIT);
            require(distributions <= DEPOSIT - charged[i], "P2 reserved fee spent");
            accounted += distributions + vault.remaining(ids[i]);
        }
        require(accounted == 2 * DEPOSIT, "P2 escrow conservation");
    }
}

contract EscrowFeeVerification is Test {
    EscrowFeeHandler internal handler;

    function setUp() public {
        handler = new EscrowFeeHandler();
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.milestone.selector;
        selectors[1] = handler.retryFee.selector;
        selectors[2] = handler.exit.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_FeeDebtCannotFundParticipants() public view {
        handler.assertProperty();
    }

    function test_DeterministicFeePathsAndCounters() external {
        for (uint256 mode; mode < 6; mode++) {
            for (uint256 scenario; scenario < 4; scenario++) {
                EscrowFeeHandler h = new EscrowFeeHandler();
                bool healthy = scenario % 2 == 0;
                bool archiveHealthy = scenario < 2;
                h.milestone(0, 8_999_999, healthy, archiveHealthy);
                h.assertProperty();
                h.milestone(0, 3_499_999, healthy, archiveHealthy);
                h.assertProperty();
                h.retryFee(0, false);
                h.exit(0, mode, healthy, archiveHealthy);
                h.assertProperty();
                h.exit(1, 0, false, true);
                h.retryFee(0, true);
                h.retryFee(0, true);
                h.retryFee(1, true);
                h.assertProperty();
                assertEq(h.touched(), 3);
                assertEq(h.succeeded(0), 1);
                assertEq(h.succeeded(1), 1);
                assertEq(h.succeeded(2), 4);
                assertEq(h.succeeded(3), 2);
                assertGt(h.succeeded(4 + mode), 0);
                uint256 expected = mode == 2 || mode == 4 ? 2 : 1;
                assertEq(h.succeeded(10), expected);
                if (archiveHealthy) {
                    require(h.succeeded(12) == expected, "P2 archive forwarding");
                    assertEq(h.succeeded(13), 0);
                    assertEq(h.succeeded(14), 0);
                } else if (healthy) {
                    require(h.succeeded(13) == expected, "P2 archive fallback");
                    assertEq(h.succeeded(12), 0);
                    assertEq(h.succeeded(14), 0);
                } else {
                    require(h.succeeded(14) == expected, "P2 retained fee");
                    assertEq(h.succeeded(12), 0);
                    assertEq(h.succeeded(13), 0);
                }
                assertEq(h.succeeded(11), healthy ? expected : 0);
                emit log_named_uint("P2.exit-mode", mode);
                emit log_named_uint("P2.fee-scenario", scenario);
                emit log_named_uint("P2.fresh-charges", h.succeeded(10));
                emit log_named_uint("P2.fee-recipient-credits", h.succeeded(11));
                emit log_named_uint("P2.archive-forwarded", h.succeeded(12));
                emit log_named_uint("P2.archive-fallback", h.succeeded(13));
                emit log_named_uint("P2.kernel-retained-fee", h.succeeded(14));
            }
        }
    }
}
