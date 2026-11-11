// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ACTPKernel} from "../../src/ACTPKernel.sol";
import {EscrowVault} from "../../src/escrow/EscrowVault.sol";
import {FeeSplitVault} from "../../src/escrow/FeeSplitVault.sol";
import {IACTPKernel} from "../../src/interfaces/IACTPKernel.sol";
import {IEscrowValidator} from "../../src/interfaces/IEscrowValidator.sol";
import {IFeeSplitVault} from "../../src/interfaces/IFeeSplitVault.sol";
import {CompositeMediator} from "../../src/CompositeMediator.sol";
import {ArchiveTreasury} from "../../src/treasury/ArchiveTreasury.sol";
import {BlacklistUSDC} from "../audit/F17F59_FeeAccounting.t.sol";

/// @notice Three independent stacks on one token, every kernel action applied to all three:
///         A = kernel + EscrowVault, D = kernel + FeeSplitVault in profile PAYOUT_ONLY,
///         B = kernel + FeeSplitVault in profile BOTH_AFTER_DISPUTE.
///         Each stack has its own requesters, providers, integrator, paid mediator, fee recipient and
///         archive; balances are compared between those per-stack addresses, never on a shared one.
///         Expected fees are recomputed here from the fee rules, not read from the vault's quotes.
contract EscrowSplitHandler is Test {
    uint256 internal constant A = 0;
    uint256 internal constant D = 1;
    uint256 internal constant B = 2;
    uint256 internal constant SLOTS = 4;
    uint256 internal constant COMMITTED_SLOT = 3; // kept in COMMITTED for the requester penalty cancel
    uint256 public constant DEPOSIT = 1000e6;
    uint256 public constant FUNDING = 2 * DEPOSIT;
    uint256 internal constant P = 100; // protocol fee bps locked by every transaction here
    uint256 internal constant MIN_FEE = 50_000;

    // Action kinds counted in `succeeded[kind][stack]`.
    uint256 internal constant MILESTONE = 0;
    uint256 internal constant RETRY_FEE = 1;
    uint256 internal constant EXIT = 2; // + mode, 8 modes
    uint256 internal constant REQUESTER_CANCEL = 10;
    uint256 internal constant TOGGLE_INTEGRATOR = 11;
    uint256 internal constant TOGGLE_FEES = 12;
    uint256 internal constant TOGGLE_ARCHIVE = 13;
    uint256 public constant KINDS = 14;
    uint256 public constant EXIT_MODES = 8;

    BlacklistUSDC public token;
    ACTPKernel[3] public kernels;
    address[3] public vaults;
    CompositeMediator[3] internal mediators;
    ArchiveTreasury[3] public archives;
    address[3] public fees;
    address[3] public integrators;
    address[3] public paidMediators;
    address[SLOTS][3] public requesters;
    address[SLOTS][3] public providers;
    bytes32[SLOTS][3] public ids;
    uint16[SLOTS] public bps = [100, 1000, 300, 100];
    uint16[6] internal splits = [0, 2500, 4000, 5000, 9999, 10000];
    uint256[SLOTS] internal deadlines;

    // Expectations, per slot (the same for every stack because actions are mirrored).
    uint256[SLOTS] internal gross; // cumulative gross on the provider side
    uint256[SLOTS] internal charged; // cumulative kernel fee
    uint256[SLOTS] public net; // cumulative amount the kernel passes to payoutToProvider
    uint256[SLOTS] public refunded; // cumulative refund after the escrow was disputed

    uint256[3][14] public succeeded;
    // withdrawalCount[stack][0 = integrator, 1 = protocol][0 = paid, 1 = blocked, 2 = inapplicable]
    uint256[3][2][3] public withdrawalCount;
    uint256 public unexpectedWithdrawals;

    modifier onlySelf() {
        require(msg.sender == address(this), "self only");
        _;
    }

    constructor() {
        token = new BlacklistUSDC();
        for (uint256 s; s < 3; s++) _deploy(s);
        vm.warp(vm.getBlockTimestamp() + 2 days + 1);
        for (uint256 i; i < SLOTS; i++) {
            deadlines[i] = vm.getBlockTimestamp() + (i == COMMITTED_SLOT ? 1 hours : (10 + 10 * i) * 1 days);
            for (uint256 s; s < 3; s++) _open(s, i);
        }
    }

    function _deploy(uint256 s) internal {
        fees[s] = address(uint160(0xFEE0 + s));
        integrators[s] = address(uint160(0x1A70 + s));
        paidMediators[s] = address(uint160(0x5ED0 + s));
        ACTPKernel kernel = new ACTPKernel(address(this), address(this), fees[s], address(0), address(token), 1 hours);
        kernels[s] = kernel;
        vaults[s] = s == A
            ? address(new EscrowVault(address(token), address(kernel)))
            : address(new FeeSplitVault(address(token), address(kernel)));
        kernel.approveEscrowVault(vaults[s], true);
        archives[s] = new ArchiveTreasury(address(token), address(kernel), address(this));
        kernel.setArchiveTreasury(address(archives[s]));
        mediators[s] = new CompositeMediator(IACTPKernel(address(kernel)));
        mediators[s].initialize(address(this)); // the handler stands in for the tier system
        kernel.approveMediator(address(mediators[s]), true);
        kernel.approveMediator(paidMediators[s], true);
    }

    function _open(uint256 s, uint256 i) internal {
        address requester = address(uint160(0x10000 * (s + 1) + 0x100 * i + 1));
        address provider = address(uint160(0x10000 * (s + 1) + 0x100 * i + 2));
        requesters[s][i] = requester;
        providers[s][i] = provider;
        token.mint(requester, FUNDING);
        vm.prank(requester);
        bytes32 id = kernels[s].createTransaction(
            provider, requester, DEPOSIT, deadlines[i], 1 hours, keccak256("split"), bytes32(0), 0, 0
        );
        ids[s][i] = id;
        if (s != A) {
            vm.prank(provider);
            IFeeSplitVault(vaults[s]).setIntegratorApproval(integrators[s], bps[i]);
            vm.prank(requester);
            IFeeSplitVault(vaults[s]).setEscrowTerms(
                id,
                integrators[s],
                bps[i],
                s == D ? IFeeSplitVault.FeeProfile.PAYOUT_ONLY : IFeeSplitVault.FeeProfile.BOTH_AFTER_DISPUTE
            );
        }
        vm.startPrank(requester);
        token.approve(vaults[s], type(uint256).max);
        kernels[s].linkEscrow(id, vaults[s], id);
        vm.stopPrank();
        if (i != COMMITTED_SLOT) {
            vm.prank(provider);
            kernels[s].transitionState(id, IACTPKernel.State.IN_PROGRESS, "");
        }
    }

    // =====================================================================
    // Shared kernel actions, mirrored on the three stacks
    // =====================================================================

    function milestone(uint256 slotSeed, uint256 amountSeed) external {
        uint256 i = slotSeed % COMMITTED_SLOT;
        uint256 amount = 1 + amountSeed % DEPOSIT;
        bool refOk;
        for (uint256 s; s < 3; s++) {
            try this.doMilestone(s, i, amount) {
                succeeded[MILESTONE][s]++;
                if (s == A) refOk = true;
            } catch {}
        }
        if (refOk) _expectProvider(i, amount);
    }

    function doMilestone(uint256 s, uint256 i, uint256 amount) external onlySelf {
        vm.prank(requesters[s][i]);
        kernels[s].releaseMilestone(ids[s][i], amount);
    }

    function retryFee(uint256 slotSeed) external {
        uint256 i = slotSeed % SLOTS;
        for (uint256 s; s < 3; s++) {
            try kernels[s].retryPlatformFee(ids[s][i]) {
                succeeded[RETRY_FEE][s]++;
            } catch {}
        }
    }

    /// @dev Modes: 0 provider cancel, 1 stalled recovery, 2 settle, 3-5 dispute ruling 0/1/2 through
    ///      CompositeMediator, 6 explicit-proof settle with a paid mediator, 7 explicit-proof cancel.
    function exit(uint256 slotSeed, uint256 modeSeed, uint256 splitSeed) external {
        uint256 i = slotSeed % COMMITTED_SLOT;
        uint256 mode = modeSeed % EXIT_MODES;
        uint16 splitBps = splits[splitSeed % splits.length];
        if (kernels[A].getTransaction(ids[A][i]).state != IACTPKernel.State.IN_PROGRESS) return;
        if (mode == 1 && vm.getBlockTimestamp() < deadlines[i] + 1 hours) vm.warp(deadlines[i] + 1 hours);

        bool refOk;
        for (uint256 s; s < 3; s++) {
            try this.doExit(s, i, mode, splitBps) {
                succeeded[EXIT + mode][s]++;
                if (s == A) refOk = true;
            } catch {}
        }
        if (!refOk) return;

        uint256 principal = DEPOSIT - gross[i];
        if (mode == 2 || mode == 3) {
            _expectProvider(i, principal);
        } else if (mode == 4) {
            refunded[i] += principal;
        } else if (mode == 5) {
            uint256 providerAmount = (principal * splitBps) / 10_000;
            _expectProvider(i, providerAmount);
            refunded[i] += principal - providerAmount;
        } else if (mode == 6) {
            refunded[i] += principal - principal / 10;
        } else if (mode == 7) {
            _expectProvider(i, principal / 3);
            refunded[i] += principal - principal / 3;
        }
    }

    function doExit(uint256 s, uint256 i, uint256 mode, uint16 splitBps) external onlySelf {
        ACTPKernel kernel = kernels[s];
        bytes32 id = ids[s][i];
        address requester = requesters[s][i];
        address provider = providers[s][i];
        if (mode == 0) {
            vm.prank(provider);
            kernel.transitionState(id, IACTPKernel.State.CANCELLED, "");
            return;
        }
        if (mode == 1) {
            kernel.recoverStalledInProgress(id);
            return;
        }
        vm.prank(provider);
        kernel.transitionState(id, IACTPKernel.State.DELIVERED, abi.encode(1 hours, keccak256("result")));
        if (mode == 2) {
            vm.prank(requester);
            kernel.transitionState(id, IACTPKernel.State.SETTLED, "");
            return;
        }
        vm.prank(requester);
        kernel.transitionState(id, IACTPKernel.State.DISPUTED, "");
        if (mode < 6) {
            uint8 ruling = uint8(mode - 3);
            mediators[s].resolve(id, ruling, ruling == 2 ? splitBps : 0);
            return;
        }
        uint256 principal = kernel.escrowPrincipal(id);
        if (mode == 6) {
            uint256 paid = principal / 10;
            uint256 requesterAmount = principal == 0 ? 1 : principal - paid;
            kernel.transitionState(
                id, IACTPKernel.State.SETTLED, abi.encode(requesterAmount, uint256(0), paidMediators[s], paid, true)
            );
        } else {
            uint256 providerAmount = principal / 3;
            uint256 requesterAmount = principal == 0 ? 1 : principal - providerAmount;
            kernel.transitionState(id, IACTPKernel.State.CANCELLED, abi.encode(requesterAmount, providerAmount));
        }
    }

    function requesterCancelFromCommitted() external {
        uint256 i = COMMITTED_SLOT;
        if (kernels[A].getTransaction(ids[A][i]).state != IACTPKernel.State.COMMITTED) return;
        if (vm.getBlockTimestamp() < deadlines[i]) vm.warp(deadlines[i]);
        bool refOk;
        for (uint256 s; s < 3; s++) {
            vm.prank(requesters[s][i]);
            try kernels[s].transitionState(ids[s][i], IACTPKernel.State.CANCELLED, "") {
                succeeded[REQUESTER_CANCEL][s]++;
                if (s == A) refOk = true;
            } catch {}
        }
        if (refOk) _expectProvider(i, (DEPOSIT * 500) / 10_000); // the 5% requester penalty
    }

    function toggleIntegratorBlock(bool blocked) external {
        for (uint256 s; s < 3; s++) {
            token.setBlocked(integrators[s], blocked);
            succeeded[TOGGLE_INTEGRATOR][s]++;
        }
    }

    function toggleFeeRecipientBlock(bool blocked) external {
        for (uint256 s; s < 3; s++) {
            token.setBlocked(fees[s], blocked);
            succeeded[TOGGLE_FEES][s]++;
        }
    }

    function toggleArchiveBlock(bool blocked) external {
        for (uint256 s; s < 3; s++) {
            token.setBlocked(address(archives[s]), blocked);
            succeeded[TOGGLE_ARCHIVE][s]++;
        }
    }

    // =====================================================================
    // Credit withdrawals: not mirrored. Credits exist only where a push failed, and refund-side
    // credits only in stack B, so the expected outcome is computed per stack. Stack A has no
    // withdrawal functions and is never called.
    // =====================================================================

    function withdrawIntegratorCredit() external {
        for (uint256 s = D; s <= B; s++) {
            IFeeSplitVault vault = IFeeSplitVault(vaults[s]);
            address integrator = integrators[s];
            uint256 credit = vault.integratorCredit(integrator);
            uint256 expected = credit == 0 ? 2 : (token.blocked(integrator) ? 1 : 0);
            uint256 balance = token.balanceOf(integrator);
            uint256 total = vault.totalIntegratorCredit();
            uint256 vaultBalance = token.balanceOf(address(vault));
            bool ok;
            try vault.withdrawIntegratorCredit(integrator) returns (uint256 paid) {
                ok = expected == 0 && paid == credit && token.balanceOf(integrator) == balance + credit
                    && vault.integratorCredit(integrator) == 0 && vault.totalIntegratorCredit() == total - credit
                    && token.balanceOf(address(vault)) == vaultBalance - credit;
            } catch {
                ok = expected != 0 && token.balanceOf(integrator) == balance
                    && vault.integratorCredit(integrator) == credit && vault.totalIntegratorCredit() == total
                    && token.balanceOf(address(vault)) == vaultBalance;
            }
            if (ok) withdrawalCount[s][0][expected]++;
            else unexpectedWithdrawals++;
        }
    }

    function withdrawProtocolCredit() external {
        for (uint256 s = D; s <= B; s++) {
            IFeeSplitVault vault = IFeeSplitVault(vaults[s]);
            address recipient = fees[s];
            uint256 credit = vault.protocolCredit();
            uint256 expected = credit == 0 ? 2 : (token.blocked(recipient) ? 1 : 0);
            uint256 balance = token.balanceOf(recipient);
            uint256 vaultBalance = token.balanceOf(address(vault));
            bool ok;
            try vault.withdrawProtocolCredit() returns (uint256 paid) {
                ok = expected == 0 && paid == credit && token.balanceOf(recipient) == balance + credit
                    && vault.protocolCredit() == 0 && token.balanceOf(address(vault)) == vaultBalance - credit;
            } catch {
                ok = expected != 0 && token.balanceOf(recipient) == balance && vault.protocolCredit() == credit
                    && token.balanceOf(address(vault)) == vaultBalance;
            }
            if (ok) withdrawalCount[s][1][expected]++;
            else unexpectedWithdrawals++;
        }
    }

    // =====================================================================
    // Independent expectations
    // =====================================================================

    /// @dev The kernel's cumulative fee: max(bps of cumulative gross, MIN_FEE) clamped to the gross,
    ///      the rise charged to this fragment and clamped to it.
    function _expectProvider(uint256 i, uint256 amount) internal {
        if (amount == 0) return;
        uint256 target = ((gross[i] + amount) * P) / 10_000;
        if (target < MIN_FEE) target = MIN_FEE;
        if (target > gross[i] + amount) target = gross[i] + amount;
        uint256 fee = target > charged[i] ? target - charged[i] : 0;
        if (fee > amount) fee = amount;
        gross[i] += amount;
        charged[i] += fee;
        net[i] += amount - fee;
    }

    /// @dev Provider-side rule: min(floor(N*b/(10000-p)), floor(D*b/10000)).
    function integratorProviderSide(uint256 i) public view returns (uint256 target) {
        target = (net[i] * bps[i]) / (10_000 - P);
        uint256 cap = (DEPOSIT * bps[i]) / 10_000;
        if (target > cap) target = cap;
    }

    /// @dev Refund-side rule for a disputed escrow in profile B.
    function refundFees(uint256 i) public view returns (uint256 protocolFee, uint256 integratorFee) {
        protocolFee = (refunded[i] * P) / 10_000;
        integratorFee = (refunded[i] * (bps[i] < P ? bps[i] : P)) / 10_000;
    }

    // =====================================================================
    // Observations
    // =====================================================================

    function requesterBalance(uint256 s, uint256 i) public view returns (uint256) {
        return token.balanceOf(requesters[s][i]);
    }

    function providerBalance(uint256 s, uint256 i) public view returns (uint256) {
        return token.balanceOf(providers[s][i]);
    }

    function integratorCredit(uint256 s) public view returns (uint256) {
        return s == A ? 0 : IFeeSplitVault(vaults[s]).integratorCredit(integrators[s]);
    }

    function protocolCredit(uint256 s) public view returns (uint256) {
        return s == A ? 0 : IFeeSplitVault(vaults[s]).protocolCredit();
    }

    function integratorBalance(uint256 s) public view returns (uint256) {
        return token.balanceOf(integrators[s]);
    }

    function feesBalance(uint256 s) public view returns (uint256) {
        return token.balanceOf(fees[s]);
    }

    function archiveBalance(uint256 s) public view returns (uint256) {
        return token.balanceOf(address(archives[s]));
    }

    function _providers(uint256 s) internal view returns (uint256 total) {
        for (uint256 i; i < SLOTS; i++) total += providerBalance(s, i);
    }

    function _sameOutsideFees(uint256 s, uint256 t, string memory what) internal view {
        require(archiveBalance(s) == archiveBalance(t), string.concat(what, ": archive"));
        require(
            token.balanceOf(address(kernels[s])) == token.balanceOf(address(kernels[t])), string.concat(what, ": kernel")
        );
        require(
            token.balanceOf(paidMediators[s]) == token.balanceOf(paidMediators[t]), string.concat(what, ": mediator")
        );
        for (uint256 i; i < SLOTS; i++) {
            require(
                IEscrowValidator(vaults[s]).bondBalance(ids[s][i]) == IEscrowValidator(vaults[t]).bondBalance(ids[t][i]),
                string.concat(what, ": bond")
            );
            require(
                IEscrowValidator(vaults[s]).remaining(ids[s][i]) == IEscrowValidator(vaults[t]).remaining(ids[t][i]),
                string.concat(what, ": remaining")
            );
        }
    }

    /// @dev INV-32: every unit minted to a stack is with one of that stack's known addresses.
    function assertSplitConservation() external view {
        for (uint256 s; s < 3; s++) {
            uint256 total = integratorBalance(s) + feesBalance(s) + archiveBalance(s)
                + token.balanceOf(address(kernels[s])) + token.balanceOf(paidMediators[s]) + token.balanceOf(vaults[s]);
            for (uint256 i; i < SLOTS; i++) total += requesterBalance(s, i) + providerBalance(s, i);
            require(total == SLOTS * FUNDING, "INV-32 conservation");
        }
    }

    /// @dev INV-33: profile PAYOUT_ONLY equals EscrowVault on kernel fee recipient, archive, kernel,
    ///      requesters, mediator and bonds; provider + integrator (+credit) equals the plain provider.
    function assertDefaultProfileIdentical() external view {
        _sameOutsideFees(D, A, "INV-33");
        require(feesBalance(D) == feesBalance(A), "INV-33 fee recipient");
        require(protocolCredit(D) == 0, "INV-33 protocol credit");
        for (uint256 i; i < SLOTS; i++) {
            require(requesterBalance(D, i) == requesterBalance(A, i), "INV-33 requester");
        }
        require(_providers(D) + integratorBalance(D) + integratorCredit(D) == _providers(A), "INV-33 provider side");
    }

    /// @dev INV-34: profile BOTH_AFTER_DISPUTE equals PAYOUT_ONLY except for the exact post-dispute
    ///      refund fees. Undisputed escrows have `refunded == 0`, so their requesters are equal.
    function assertBothProfileDelta() external view {
        _sameOutsideFees(B, D, "INV-34");
        uint256 protocolFees;
        uint256 integratorFees;
        for (uint256 i; i < SLOTS; i++) {
            (uint256 protocolFee, uint256 integratorFee) = refundFees(i);
            require(providerBalance(B, i) == providerBalance(D, i), "INV-34 provider");
            require(
                requesterBalance(B, i) + protocolFee + integratorFee == requesterBalance(D, i), "INV-34 requester"
            );
            require(integratorFee <= protocolFee, "INV-34 refund-side cap");
            protocolFees += protocolFee;
            integratorFees += integratorFee;
        }
        require(feesBalance(B) + protocolCredit(B) == feesBalance(D) + protocolFees, "INV-34 protocol refund fee");
        require(
            integratorBalance(B) + integratorCredit(B) == integratorBalance(D) + integratorCredit(D) + integratorFees,
            "INV-34 integrator refund fee"
        );
    }

    /// @dev INV-35: per escrow, what the provider gave up equals the provider-side rule.
    function assertProviderSideRule() external view {
        uint256 total;
        for (uint256 i; i < SLOTS; i++) {
            uint256 expected = integratorProviderSide(i);
            require(providerBalance(A, i) - providerBalance(D, i) == expected, "INV-35 rule (D)");
            require(providerBalance(A, i) - providerBalance(B, i) == expected, "INV-35 rule (B)");
            total += expected;
        }
        require(integratorBalance(D) + integratorCredit(D) == total, "INV-35 integrator total");
    }

    /// @dev INV-36: equality, the handler makes no donations.
    function assertVaultSolvency() external view {
        for (uint256 s = D; s <= B; s++) {
            IFeeSplitVault vault = IFeeSplitVault(vaults[s]);
            uint256 locked;
            uint256 bonds;
            for (uint256 i; i < SLOTS; i++) {
                locked += vault.remaining(ids[s][i]);
                bonds += vault.bondBalance(ids[s][i]);
            }
            require(vault.totalLocked() == locked, "INV-36 totalLocked");
            require(vault.totalBonds() == bonds, "INV-36 totalBonds");
            require(vault.totalIntegratorCredit() == integratorCredit(s), "INV-36 totalIntegratorCredit");
            require(
                token.balanceOf(address(vault)) == locked + bonds + integratorCredit(s) + vault.protocolCredit(),
                "INV-36 solvency"
            );
        }
    }

    /// @dev A revert swallowed in one stack cannot hide a divergence.
    function assertActionsMirrored() external view {
        for (uint256 kind; kind < KINDS; kind++) {
            require(
                succeeded[kind][A] == succeeded[kind][D] && succeeded[kind][A] == succeeded[kind][B], "actions mirrored"
            );
        }
        for (uint256 i; i < SLOTS; i++) {
            IACTPKernel.State state = kernels[A].getTransaction(ids[A][i]).state;
            require(
                kernels[D].getTransaction(ids[D][i]).state == state && kernels[B].getTransaction(ids[B][i]).state == state,
                "states mirrored"
            );
        }
    }

    function assertWithdrawalsAsExpected() external view {
        require(unexpectedWithdrawals == 0, "unexpected withdrawal outcome");
    }

    function assertAll() external view {
        this.assertSplitConservation();
        this.assertDefaultProfileIdentical();
        this.assertBothProfileDelta();
        this.assertProviderSideRule();
        this.assertVaultSolvency();
        this.assertActionsMirrored();
        this.assertWithdrawalsAsExpected();
    }
}

contract EscrowSplitVerification is Test {
    uint256 internal constant A = 0;
    uint256 internal constant D = 1;
    uint256 internal constant B = 2;
    uint256 internal constant ONE = 1e6;
    uint256 internal constant START = 1000e6; // requester balance after funding: FUNDING - DEPOSIT

    EscrowSplitHandler internal handler;

    function setUp() public {
        handler = new EscrowSplitHandler();
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.milestone.selector;
        selectors[1] = handler.retryFee.selector;
        selectors[2] = handler.exit.selector;
        selectors[3] = handler.requesterCancelFromCommitted.selector;
        selectors[4] = handler.toggleIntegratorBlock.selector;
        selectors[5] = handler.toggleFeeRecipientBlock.selector;
        selectors[6] = handler.toggleArchiveBlock.selector;
        selectors[7] = handler.withdrawIntegratorCredit.selector;
        selectors[8] = handler.withdrawProtocolCredit.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_SplitConservation() public view {
        handler.assertSplitConservation();
    }

    function invariant_DefaultProfileIdentical() public view {
        handler.assertDefaultProfileIdentical();
    }

    function invariant_BothProfileDelta() public view {
        handler.assertBothProfileDelta();
    }

    function invariant_ProviderSideRule() public view {
        handler.assertProviderSideRule();
    }

    function invariant_VaultSolvency() public view {
        handler.assertVaultSolvency();
    }

    function invariant_ActionsMirrored() public view {
        handler.assertActionsMirrored();
    }

    function invariant_WithdrawalsAsExpected() public view {
        handler.assertWithdrawalsAsExpected();
    }

    function _each(EscrowSplitHandler h, uint256 kind, uint256 expected, string memory what) internal view {
        for (uint256 s; s < 3; s++) assertEq(h.succeeded(kind, s), expected, what);
    }

    /// @dev Every path runs in every stack with exact per-path counters; A3, A7, A9 and A16 amounts
    ///      are exact; settlement and finalization succeed with a blocked integrator and a blocked
    ///      fee recipient.
    function test_DeterministicSplitPathsAndCounters() external {
        // Every exit kind, after a milestone and a fee retry, plus the penalty cancel and the toggles.
        for (uint256 mode; mode < 8; mode++) {
            EscrowSplitHandler h = new EscrowSplitHandler();
            h.milestone(0, 250 * ONE - 1);
            h.retryFee(0);
            h.toggleArchiveBlock(mode % 2 == 0);
            h.exit(0, mode, 2);
            h.requesterCancelFromCommitted();
            h.toggleIntegratorBlock(false);
            h.toggleFeeRecipientBlock(false);
            _each(h, 0, 1, "milestone ran once in every stack");
            _each(h, 1, 1, "retryFee ran once in every stack");
            _each(h, 2 + mode, 1, "exit ran once in every stack");
            _each(h, 10, 1, "requester cancel ran once in every stack");
            _each(h, 11, 1, "integrator toggle");
            _each(h, 12, 1, "fee recipient toggle");
            _each(h, 13, 1, "archive toggle");
            h.assertAll();
            emit log_named_uint("P3.exit-mode", mode);
        }

        // A3: settle 1,000 at 100 bps.
        EscrowSplitHandler a3 = new EscrowSplitHandler();
        a3.exit(0, 2, 0);
        assertEq(a3.providerBalance(A, 0), 990 * ONE, "A3 plain provider");
        for (uint256 s = D; s <= B; s++) {
            assertEq(a3.providerBalance(s, 0), 980 * ONE, "A3 provider");
            assertEq(a3.integratorBalance(s), 10 * ONE, "A3 platform");
        }
        for (uint256 s; s < 3; s++) {
            assertEq(a3.feesBalance(s), 9_990_000, "A3 kernel fee");
            assertEq(a3.archiveBalance(s), 10_000, "A3 archive");
            assertEq(a3.requesterBalance(s, 0), START, "A3 requester");
        }
        a3.assertAll();

        // A7: dispute split, requester 600 / provider 400.
        EscrowSplitHandler a7 = new EscrowSplitHandler();
        a7.exit(0, 5, 2);
        assertEq(a7.requesterBalance(A, 0), START + 600 * ONE, "A7 plain requester");
        assertEq(a7.providerBalance(A, 0), 396 * ONE, "A7 plain provider");
        assertEq(a7.requesterBalance(D, 0), START + 600 * ONE, "A7 D requester");
        assertEq(a7.integratorBalance(D), 4 * ONE, "A7 D platform");
        assertEq(a7.feesBalance(D), 3_996_000, "A7 D fee recipient");
        assertEq(a7.requesterBalance(B, 0), START + 588 * ONE, "A7 B requester");
        assertEq(a7.integratorBalance(B), 10 * ONE, "A7 B platform");
        assertEq(a7.feesBalance(B), 3_996_000 + 6 * ONE, "A7 B kernel fee plus vault protocol fee");
        for (uint256 s = D; s <= B; s++) assertEq(a7.providerBalance(s, 0), 392 * ONE, "A7 provider");
        a7.assertAll();

        // A9: requester wins. Then liveness with blocked recipients, and the withdrawals.
        EscrowSplitHandler h3 = new EscrowSplitHandler();
        h3.exit(0, 4, 0);
        assertEq(h3.requesterBalance(A, 0), START + 1000 * ONE, "A9 plain requester");
        assertEq(h3.requesterBalance(D, 0), START + 1000 * ONE, "A9 D requester");
        assertEq(h3.integratorBalance(D) + h3.feesBalance(D), 0, "A9 D no fee");
        assertEq(h3.requesterBalance(B, 0), START + 980 * ONE, "A9 B requester");
        assertEq(h3.integratorBalance(B), 10 * ONE, "A9 B platform");
        assertEq(h3.feesBalance(B), 10 * ONE, "A9 B vault protocol fee");

        // A16: fee recipient blocked, 1000 bps slot: finalization succeeds, the fee is credited.
        h3.toggleFeeRecipientBlock(true);
        h3.exit(1, 4, 0);
        _each(h3, 2 + 4, 2, "finalization succeeds with a blocked fee recipient");
        assertEq(h3.requesterBalance(B, 1), START + 980 * ONE, "A16 requester");
        assertEq(h3.protocolCredit(B), 10 * ONE, "A16 protocol fee credited");
        assertEq(h3.feesBalance(B), 10 * ONE, "A16 nothing pushed");
        assertEq(h3.integratorBalance(B), 20 * ONE, "A16 platform capped at the protocol rate");
        h3.withdrawProtocolCredit(); // still blocked in B, nothing to withdraw in D
        assertEq(h3.withdrawalCount(B, 1, 1), 1, "blocked protocol withdrawal reverts");
        h3.toggleFeeRecipientBlock(false);
        h3.withdrawProtocolCredit();
        assertEq(h3.withdrawalCount(B, 1, 0), 1, "protocol credit withdrawn in B");
        assertEq(h3.withdrawalCount(D, 1, 2), 2, "no protocol credit in D");
        assertEq(h3.feesBalance(B), 20 * ONE, "A17 protocol credit paid to the fee recipient");

        // A15: integrator blocked. Settlement succeeds, the provider-side share is credited.
        h3.toggleIntegratorBlock(true);
        h3.exit(2, 2, 0);
        _each(h3, 2 + 2, 1, "settlement succeeds with a blocked integrator");
        assertEq(h3.integratorCredit(D), 30 * ONE, "A15 D credit");
        assertEq(h3.integratorCredit(B), 30 * ONE, "A15 B credit");
        assertEq(h3.providerBalance(D, 2), 960 * ONE, "A15 provider paid");
        h3.withdrawIntegratorCredit();
        assertEq(h3.withdrawalCount(D, 0, 1) + h3.withdrawalCount(B, 0, 1), 2, "blocked integrator withdrawal reverts");
        h3.toggleIntegratorBlock(false);
        h3.withdrawIntegratorCredit();
        assertEq(h3.withdrawalCount(D, 0, 0), 1, "provider-side credit withdrawn in D");
        assertEq(h3.withdrawalCount(B, 0, 0), 1, "provider-side credit withdrawn in B");
        assertEq(h3.integratorBalance(D), 30 * ONE);
        assertEq(h3.integratorBalance(B), 50 * ONE);
        h3.assertAll();

        // Refund-side integrator credit exists only in B.
        EscrowSplitHandler h4 = new EscrowSplitHandler();
        h4.toggleIntegratorBlock(true);
        h4.exit(0, 4, 0);
        assertEq(h4.integratorCredit(B), 10 * ONE, "refund-side credit in B");
        assertEq(h4.integratorCredit(D), 0, "no refund-side credit in D");
        h4.toggleIntegratorBlock(false);
        h4.withdrawIntegratorCredit();
        assertEq(h4.withdrawalCount(B, 0, 0), 1, "refund-side credit withdrawn in B");
        assertEq(h4.withdrawalCount(D, 0, 2), 1, "inapplicable in D");
        assertEq(h4.integratorBalance(B), 10 * ONE);
        h4.assertAll();
    }

    /// @dev INV-37: an unapproved integrator and an over-limit rate revert at linkEscrow with
    ///      "Integrator not approved"; no balance changes.
    function test_ConsentRejections() external {
        for (uint256 s = D; s <= B; s++) {
            ACTPKernel kernel = handler.kernels(s);
            IFeeSplitVault vault = IFeeSplitVault(handler.vaults(s));
            BlacklistUSDC token = handler.token();
            address requester = handler.requesters(s, 0);
            address provider = handler.providers(s, 0); // approved the stack's integrator at 100 bps
            address integrator = handler.integrators(s);
            address unapproved = address(0x0BAD1);

            for (uint256 c; c < 2; c++) {
                vm.prank(requester);
                bytes32 id = kernel.createTransaction(
                    provider, requester, 100 * ONE, block.timestamp + 1 days, 1 hours, keccak256("consent"), bytes32(0), 0, 0
                );
                uint256 balance = token.balanceOf(requester);
                uint256 vaultBalance = token.balanceOf(address(vault));
                vm.startPrank(requester);
                if (c == 0) vault.setEscrowTerms(id, unapproved, 1, IFeeSplitVault.FeeProfile.PAYOUT_ONLY);
                else vault.setEscrowTerms(id, integrator, 101, IFeeSplitVault.FeeProfile.PAYOUT_ONLY);
                vm.expectRevert("Integrator not approved");
                kernel.linkEscrow(id, address(vault), id);
                vm.stopPrank();
                assertEq(token.balanceOf(requester), balance, "requester balance unchanged");
                assertEq(token.balanceOf(address(vault)), vaultBalance, "vault balance unchanged");
                assertEq(uint8(kernel.getTransaction(id).state), uint8(IACTPKernel.State.INITIATED));
            }
        }
    }

    /// @dev INV-39: an escrow that was never disputed pays no refund fee in either profile.
    function test_RefundFeeOnlyAfterDispute() external {
        handler.exit(0, 0, 0); // provider cancel
        handler.exit(2, 1, 0); // stalled recovery
        handler.requesterCancelFromCommitted(); // penalty cancel: the refund is pre-dispute
        for (uint256 s; s < 3; s++) {
            assertEq(handler.requesterBalance(s, 0), START + 1000 * ONE, "provider cancel refunds everything");
            assertEq(handler.requesterBalance(s, 2), START + 1000 * ONE, "recovery refunds everything");
            assertEq(handler.requesterBalance(s, 3), START + 950 * ONE, "penalty cancel refund is free");
        }
        assertEq(handler.feesBalance(B), handler.feesBalance(A), "no vault protocol fee");
        assertEq(handler.protocolCredit(B), 0);
        (uint256 protocolFee, uint256 integratorFee) = handler.refundFees(0);
        assertEq(protocolFee + integratorFee, 0);
        handler.assertAll();
    }

    /// @dev DM-10: on the refund side the integrator rate is min(b, p).
    function test_RefundSideCap() external {
        assertEq(handler.bps(1), 1000);
        handler.exit(1, 4, 0); // requester wins a 1,000 dispute, b = 1000
        uint256 refund = handler.refunded(1);
        assertEq(refund, 1000 * ONE);
        uint256 integratorRefundFee = handler.integratorBalance(B);
        uint256 protocolRefundFee = handler.feesBalance(B) - handler.feesBalance(D);
        assertEq(handler.requesterBalance(B, 1), START + 980 * ONE, "requester");
        assertEq(integratorRefundFee, 10 * ONE, "integrator refund fee");
        assertEq(protocolRefundFee, 10 * ONE, "vault protocol fee");
        assertEq(integratorRefundFee, protocolRefundFee);
        assertLt(integratorRefundFee, (refund * handler.bps(1)) / 10_000);
        handler.assertAll();
    }
}
