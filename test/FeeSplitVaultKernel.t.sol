// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {FeeSplitTestBase} from "./helpers/FeeSplitTestBase.sol";
import {IFeeSplitVault} from "../src/interfaces/IFeeSplitVault.sol";
import {IACTPKernel} from "../src/interfaces/IACTPKernel.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title FeeSplitVaultKernelTest — FeeSplitVault against the real kernel and resolver stack.
/// @notice One test per acceptance row (A1-A25); every column of the row is asserted to the
///         micro-USDC for each profile the row lists. Expected amounts are written out from the fee
///         rules, never read back from the vault's quote functions.
contract FeeSplitVaultKernelTest is FeeSplitTestBase {
    uint256 internal constant K = 1000 * ONE;

    event TermsVoided(bytes32 indexed escrowId);
    event IntegratorCreditWithdrawn(address indexed integrator, uint256 amount);
    event ProtocolCreditWithdrawn(address indexed recipient, uint256 amount);

    function setUp() public {
        _setUpStack();
    }

    function _exp(uint256 deposit) internal pure returns (Exp memory x) {
        x.deposit = deposit;
    }

    /// @dev 1,000 settled at 100 bps: the row shared by A3, A4, A8 and A15.
    function _settled1000() internal pure returns (Exp memory x) {
        x.deposit = K;
        x.provider = 980 * ONE;
        x.platform = 10 * ONE;
        x.kernelFee = 10 * ONE;
        x.archive = 10_000;
    }

    function _name(string memory row, IFeeSplitVault.FeeProfile profile) internal pure returns (string memory) {
        return string.concat(row, profile == BOTH ? " (B)" : " (D)");
    }

    // =====================================================================
    // Acceptance rows
    // =====================================================================

    function test_A1_PlainVaultControl() public {
        Bal memory b = _snap();
        bytes32 txId = _openPlain(K);
        _deliverAndSettle(txId);
        Exp memory x = _exp(K);
        x.provider = 990 * ONE;
        x.kernelFee = 10 * ONE;
        x.archive = 10_000;
        _assertOutcome(b, x, "A1");
    }

    function test_A2_NoTerms_Settle() public {
        Bal memory b = _snap();
        bytes32 txId = _open(K, 0, PAYOUT_ONLY);
        _deliverAndSettle(txId);
        Exp memory x = _exp(K);
        x.provider = 990 * ONE;
        x.kernelFee = 10 * ONE;
        x.archive = 10_000;
        _assertOutcome(b, x, "A2");
        (address i, uint16 bps,, IFeeSplitVault.TermsState state,,, bool used) = vault.lockedTerms(txId);
        assertEq(i, address(0));
        assertEq(bps, 0);
        assertEq(uint8(state), uint8(IFeeSplitVault.TermsState.NONE));
        assertTrue(used);
    }

    function test_A3_Settle() public {
        _a3(PAYOUT_ONLY);
        _a3(BOTH);
    }

    function _a3(IFeeSplitVault.FeeProfile profile) internal {
        Bal memory b = _snap();
        bytes32 txId = _open(K, 100, profile);
        _deliverAndSettle(txId);
        _assertOutcome(b, _settled1000(), _name("A3", profile));
    }

    function test_A4_Milestones_250_250_500() public {
        _a4(PAYOUT_ONLY);
        _a4(BOTH);
    }

    function _a4(IFeeSplitVault.FeeProfile profile) internal {
        Bal memory b = _snap();
        bytes32 txId = _open(K, 100, profile);
        _start(txId);
        _milestone(txId, 250 * ONE);
        assertEq(usdc.balanceOf(integrator) - b.integrator, 2_500_000, "A4: platform after 250");
        assertEq(usdc.balanceOf(provider) - b.provider, 245 * ONE, "A4: provider after 250");
        _milestone(txId, 250 * ONE);
        assertEq(usdc.balanceOf(integrator) - b.integrator, 5 * ONE, "A4: platform after 500");
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(uint256(2 days), keccak256("result")));
        _settle(txId);
        _assertOutcome(b, _settled1000(), _name("A4", profile));
    }

    function test_A5_Milestones_ThirdsAndTail() public {
        Bal memory b = _snap();
        bytes32 txId = _open(K, 100, PAYOUT_ONLY);
        _start(txId);
        _milestone(txId, 333_333_333);
        assertEq(usdc.balanceOf(provider) - b.provider, 326_666_667, "A5: provider 1");
        assertEq(usdc.balanceOf(integrator) - b.integrator, 3_333_333, "A5: platform 1");
        _milestone(txId, 333_333_333);
        assertEq(usdc.balanceOf(provider) - b.provider, 653_333_334, "A5: provider 2");
        assertEq(usdc.balanceOf(integrator) - b.integrator, 6_666_666, "A5: platform 2");
        _milestone(txId, 333_333_333);
        assertEq(usdc.balanceOf(provider) - b.provider, 980 * ONE, "A5: provider 3");
        // Transient +1 unit after fragment 3 (3.333334); the final total absorbs it.
        assertEq(usdc.balanceOf(integrator) - b.integrator, 10 * ONE, "A5: platform 3");
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(uint256(2 days), keccak256("result")));
        _settle(txId); // tail 0.000001: all of it is kernel fee
        Exp memory x = _settled1000();
        x.archive = 9_999; // three archive slices of floor(3.333333 * 0.1%); the 1-unit tail has none
        _assertOutcome(b, x, "A5");
    }

    function test_A6_Split5050_Default() public {
        _a6(PAYOUT_ONLY);
    }

    function test_A6_Split5050_Both() public {
        _a6(BOTH);
    }

    function _a6(IFeeSplitVault.FeeProfile profile) internal {
        Bal memory b = _snap();
        bytes32 txId = _open(K, 100, profile);
        _deliverAndDispute(txId, requester);
        _rule(txId, 2, 5000);
        Exp memory x = _exp(K);
        x.provider = 490 * ONE;
        x.kernelFee = 5 * ONE;
        x.archive = 5_000;
        if (profile == BOTH) {
            x.requester = 490 * ONE;
            x.platform = 10 * ONE;
            x.vaultProtocolFee = 5 * ONE;
        } else {
            x.requester = 500 * ONE;
            x.platform = 5 * ONE;
        }
        _assertOutcome(b, x, _name("A6", profile));
    }

    function test_A7_Split600_400_Default() public {
        _a7(PAYOUT_ONLY);
    }

    function test_A7_Split600_400_Both() public {
        _a7(BOTH);
    }

    function _a7(IFeeSplitVault.FeeProfile profile) internal {
        Bal memory b = _snap();
        bytes32 txId = _open(K, 100, profile);
        _deliverAndDispute(txId, requester);
        _rule(txId, 2, 4000);
        _assertOutcome(b, _a7Row(profile), _name("A7", profile));
    }

    function _a7Row(IFeeSplitVault.FeeProfile profile) internal pure returns (Exp memory x) {
        x.deposit = K;
        x.provider = 392 * ONE;
        x.kernelFee = 4 * ONE;
        x.archive = 4_000;
        if (profile == BOTH) {
            x.requester = 588 * ONE;
            x.platform = 10 * ONE;
            x.vaultProtocolFee = 6 * ONE;
        } else {
            x.requester = 600 * ONE;
            x.platform = 4 * ONE;
        }
    }

    function test_A8_ProviderWins() public {
        _a8(PAYOUT_ONLY);
        _a8(BOTH);
    }

    function _a8(IFeeSplitVault.FeeProfile profile) internal {
        Bal memory b = _snap();
        bytes32 txId = _open(K, 100, profile);
        _deliverAndDispute(txId, requester);
        _rule(txId, 0, 0);
        Exp memory x = _settled1000();
        x.requesterBond = -int256(50 * ONE); // the losing disputer's bond goes to the provider
        x.providerBond = int256(50 * ONE);
        _assertOutcome(b, x, _name("A8", profile));
    }

    function test_A9_RequesterWins_Default() public {
        _a9(PAYOUT_ONLY, 100);
    }

    function test_A9_RequesterWins_Both() public {
        _a9(BOTH, 100);
    }

    function _a9(IFeeSplitVault.FeeProfile profile, uint16 bps) internal returns (bytes32 txId) {
        Bal memory b = _snap();
        txId = _open(K, bps, profile);
        _deliverAndDispute(txId, requester);
        _rule(txId, 1, 0);
        _assertOutcome(b, _a9Row(profile), _name("A9", profile));
    }

    function _a9Row(IFeeSplitVault.FeeProfile profile) internal pure returns (Exp memory x) {
        x.deposit = K;
        if (profile == BOTH) {
            x.requester = 980 * ONE;
            x.platform = 10 * ONE;
            x.vaultProtocolFee = 10 * ONE;
        } else {
            x.requester = K;
        }
    }

    function test_A10_RoundingUnit_Default() public {
        _a10(PAYOUT_ONLY);
    }

    function test_A10_RoundingUnit_Both() public {
        _a10(BOTH);
    }

    function _a10(IFeeSplitVault.FeeProfile profile) internal {
        Bal memory b = _snap();
        bytes32 txId = _open(2 * K, 100, profile);
        _deliverAndDispute(txId, requester);
        // Explicit-amount proof: the resolver stack cannot express it, so the admin resolves.
        kernel.transitionState(
            txId, IACTPKernel.State.SETTLED, abi.encode(uint256(999_999_901), uint256(1_000_000_099), true)
        );
        Exp memory x = _exp(2 * K);
        x.provider = 980_000_098;
        x.kernelFee = 10 * ONE;
        x.archive = 10_000;
        if (profile == BOTH) {
            x.requester = 979_999_903;
            x.platform = 20 * ONE;
            x.vaultProtocolFee = 9_999_999;
        } else {
            x.requester = 999_999_901;
            x.platform = 10_000_001; // the documented +1 unit over 1% of gross
        }
        _assertOutcome(b, x, _name("A10", profile));
    }

    function test_A11_ProviderCancelsAtCommitted() public {
        _a11(PAYOUT_ONLY);
        _a11(BOTH);
    }

    function _a11(IFeeSplitVault.FeeProfile profile) internal {
        Bal memory b = _snap();
        bytes32 txId = _open(K, 100, profile);
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, "");
        Exp memory x = _exp(K);
        x.requester = K;
        _assertOutcome(b, x, _name("A11", profile));
    }

    function test_A12_RequesterCancelsAfterDeadline_Penalty() public {
        _a12(PAYOUT_ONLY);
        _a12(BOTH);
    }

    function _a12(IFeeSplitVault.FeeProfile profile) internal {
        Bal memory b = _snap();
        bytes32 txId = _open(K, 100, profile);
        vm.warp(block.timestamp + 30 days);
        vm.prank(requester);
        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, "");
        Exp memory x = _exp(K);
        x.requester = 950 * ONE;
        x.provider = 49 * ONE;
        x.platform = 500_000;
        x.kernelFee = 500_000;
        x.archive = 500;
        _assertOutcome(b, x, _name("A12", profile));
    }

    function test_A13_StalledRecovery() public {
        _a13(PAYOUT_ONLY);
        _a13(BOTH);
    }

    function _a13(IFeeSplitVault.FeeProfile profile) internal {
        Bal memory b = _snap();
        bytes32 txId = _open(K, 100, profile);
        _start(txId);
        vm.warp(block.timestamp + 30 days + 1 hours);
        vm.prank(stranger);
        kernel.recoverStalledInProgress(txId);
        Exp memory x = _exp(K);
        x.requester = K;
        _assertOutcome(b, x, _name("A13", profile));
    }

    function test_A14_MediatorPaid_Default() public {
        _a14(PAYOUT_ONLY);
    }

    function test_A14_MediatorPaid_Both() public {
        _a14(BOTH);
    }

    function _a14(IFeeSplitVault.FeeProfile profile) internal {
        Bal memory b = _snap();
        bytes32 txId = _open(K, 100, profile);
        _deliverAndDispute(txId, requester);
        kernel.transitionState(
            txId, IACTPKernel.State.SETTLED, abi.encode(900 * ONE, uint256(0), paidMediator, 100 * ONE, true)
        );
        Exp memory x = _exp(K);
        x.mediator = 100 * ONE;
        if (profile == BOTH) {
            x.requester = 882 * ONE;
            x.platform = 9 * ONE;
            x.vaultProtocolFee = 9 * ONE;
        } else {
            x.requester = 900 * ONE;
        }
        _assertOutcome(b, x, _name("A14", profile));
    }

    function test_A15_IntegratorBlocked_Credited() public {
        usdc.setBlocked(integrator, true);

        Bal memory b = _snap();
        bytes32 txId = _open(K, 100, PAYOUT_ONLY);
        _deliverAndSettle(txId);
        Exp memory x = _settled1000();
        x.platformCredited = 10 * ONE;
        _assertOutcome(b, x, "A15 as A3");

        b = _snap();
        txId = _open(K, 100, BOTH);
        _deliverAndDispute(txId, requester);
        _rule(txId, 1, 0);
        x = _a9Row(BOTH);
        x.platformCredited = 10 * ONE;
        _assertOutcome(b, x, "A15 as B-A9");

        assertEq(vault.integratorCredit(integrator), 20 * ONE);
        assertEq(vault.totalIntegratorCredit(), 20 * ONE);
        assertEq(usdc.balanceOf(integrator), 0);
    }

    function test_A16_FeeRecipientBlocked_FinalizationSucceeds_Credits() public {
        usdc.setBlocked(feeRecipient, true);
        Bal memory b = _snap();
        bytes32 txId = _open(K, 100, BOTH);
        _deliverAndDispute(txId, requester);
        _rule(txId, 1, 0); // must not revert
        assertEq(uint8(kernel.getTransaction(txId).state), uint8(IACTPKernel.State.SETTLED));
        Exp memory x = _a9Row(BOTH);
        x.protocolCredited = 10 * ONE;
        _assertOutcome(b, x, "A16");
        assertEq(vault.protocolCredit(), 10 * ONE);
    }

    function test_A17_Withdrawals_FixedRecipients() public {
        usdc.setBlocked(integrator, true);
        usdc.setBlocked(feeRecipient, true);
        bytes32 txId = _open(K, 100, BOTH);
        _deliverAndDispute(txId, requester);
        _rule(txId, 1, 0);
        assertEq(vault.integratorCredit(integrator), 10 * ONE);
        assertEq(vault.protocolCredit(), 10 * ONE);

        usdc.setBlocked(integrator, false);
        usdc.setBlocked(feeRecipient, false);
        // The protocol credit follows the kernel's CURRENT fee recipient.
        address newRecipient = address(0xFEE2);
        kernel.updateFeeRecipient(newRecipient);

        vm.expectEmit(true, false, false, true, address(vault));
        emit IntegratorCreditWithdrawn(integrator, 10 * ONE);
        vm.prank(stranger);
        assertEq(vault.withdrawIntegratorCredit(integrator), 10 * ONE);
        assertEq(usdc.balanceOf(integrator), 10 * ONE, "to the integrator only");
        assertEq(usdc.balanceOf(stranger), 0);

        vm.expectEmit(true, false, false, true, address(vault));
        emit ProtocolCreditWithdrawn(newRecipient, 10 * ONE);
        vm.prank(stranger);
        assertEq(vault.withdrawProtocolCredit(), 10 * ONE);
        assertEq(usdc.balanceOf(newRecipient), 10 * ONE, "to the current fee recipient only");
        assertEq(usdc.balanceOf(feeRecipient), 0);
        assertEq(usdc.balanceOf(stranger), 0);

        assertEq(vault.integratorCredit(integrator), 0);
        assertEq(vault.totalIntegratorCredit(), 0);
        assertEq(vault.protocolCredit(), 0);
        assertEq(usdc.balanceOf(address(vault)), 0);

        vm.expectRevert("No credit");
        vault.withdrawIntegratorCredit(integrator);
        vm.expectRevert("No credit");
        vault.withdrawProtocolCredit();
    }

    function test_A18_200Bps() public {
        _approveIntegrator(200);

        Bal memory b = _snap();
        bytes32 txId = _open(K, 200, BOTH);
        _deliverAndSettle(txId);
        Exp memory x = _exp(K);
        x.provider = 970 * ONE;
        x.platform = 20 * ONE;
        x.kernelFee = 10 * ONE;
        x.archive = 10_000;
        _assertOutcome(b, x, "A18 settle");

        // Requester wins: the refund side is capped at the protocol rate, not 200 bps.
        _a9(BOTH, 200);
    }

    function test_A19_OneUsdc() public {
        Bal memory b = _snap();
        bytes32 txId = _open(ONE, 100, BOTH);
        _deliverAndSettle(txId);
        Exp memory x = _exp(ONE);
        x.provider = 940_405;
        x.platform = 9_595;
        x.kernelFee = 50_000; // MIN_FEE
        x.archive = 50;
        _assertOutcome(b, x, "A19 settle");

        b = _snap();
        txId = _open(ONE, 100, PAYOUT_ONLY);
        _deliverAndDispute(txId, requester);
        _rule(txId, 1, 0);
        x = _exp(ONE);
        x.requester = ONE;
        _assertOutcome(b, x, "A19 D-win");

        b = _snap();
        txId = _open(ONE, 100, BOTH);
        _deliverAndDispute(txId, requester);
        _rule(txId, 1, 0);
        x = _exp(ONE);
        x.requester = 980_000;
        x.platform = 10_000;
        x.vaultProtocolFee = 10_000;
        _assertOutcome(b, x, "A19 B-win");
    }

    function test_A20_MinFeeBoundary() public {
        Bal memory b = _snap();
        bytes32 txId = _open(5 * ONE, 100, PAYOUT_ONLY);
        _deliverAndSettle(txId);
        Exp memory x = _exp(5 * ONE);
        x.provider = 4_900_000;
        x.platform = 50_000;
        x.kernelFee = 50_000;
        x.archive = 50;
        _assertOutcome(b, x, "A20");
    }

    function test_A21_TenCents() public {
        Bal memory b = _snap();
        bytes32 txId = _open(100_000, 100, BOTH);
        _deliverAndSettle(txId);
        Exp memory x = _exp(100_000);
        x.provider = 49_495;
        x.platform = 505;
        x.kernelFee = 50_000;
        x.archive = 50;
        _assertOutcome(b, x, "A21 settle");

        b = _snap();
        txId = _open(100_000, 100, BOTH);
        _deliverAndDispute(txId, requester);
        _rule(txId, 1, 0);
        x = _exp(100_000);
        x.requester = 98_000;
        x.platform = 1_000;
        x.vaultProtocolFee = 1_000;
        _assertOutcome(b, x, "A21 B-win");
    }

    function test_A22_MinTransactionAmount() public {
        Bal memory b = _snap();
        bytes32 txId = _open(50_000, 100, BOTH);
        _deliverAndSettle(txId);
        Exp memory x = _exp(50_000);
        x.kernelFee = 50_000; // the whole escrow is the kernel's minimum fee
        x.archive = 50;
        _assertOutcome(b, x, "A22");
        // The provider side never moved, so the terms were never needed.
        assertEq(uint8(_state(txId)), uint8(IFeeSplitVault.TermsState.PENDING_CONFIRM));
    }

    function test_A23_TermsNeedTxIdEscrowId() public {
        bytes32 txId = _create(K);
        bytes32 notATx = keccak256("not a transaction id");
        uint256 balance = usdc.balanceOf(requester);
        vm.startPrank(requester);
        vault.setEscrowTerms(notATx, integrator, 100, PAYOUT_ONLY);
        usdc.approve(address(vault), K);
        vm.expectRevert("Terms need txId escrowId");
        kernel.linkEscrow(txId, address(vault), notATx);
        vm.stopPrank();
        assertEq(usdc.balanceOf(requester), balance);
        assertEq(vault.totalLocked(), 0);

        // Twin-id variant: behaves exactly as A1.
        Bal memory b = _snap();
        bytes32 escrowId = _openTwin(txId);
        _deliverAndSettle(txId);
        Exp memory x = _exp(K);
        x.provider = 990 * ONE;
        x.kernelFee = 10 * ONE;
        x.archive = 10_000;
        _assertOutcome(b, x, "A23 twin");
        assertEq(uint8(_state(escrowId)), uint8(IFeeSplitVault.TermsState.VOID));
    }

    /// @dev Links `txId` under the id of a second, unlinked transaction with the same parties and
    ///      amount, with terms registered for that id.
    function _openTwin(bytes32 txId) internal returns (bytes32 twinId) {
        uint256 amount = kernel.getTransaction(txId).amount;
        twinId = _create(amount);
        _terms(twinId, 100, BOTH);
        vm.startPrank(requester);
        usdc.approve(address(vault), amount);
        kernel.linkEscrow(txId, address(vault), twinId);
        vm.stopPrank();
    }

    function test_A24_RefundSideCappedAtProtocolRate() public {
        _approveIntegrator(1000);
        Bal memory b = _snap();
        bytes32 txId = _open(K, 1000, BOTH);
        _deliverAndDispute(txId, provider); // the provider opens the dispute and loses
        _rule(txId, 1, 0);
        Exp memory x = _exp(K);
        x.requester = 980 * ONE;
        x.platform = 10 * ONE; // not 100
        x.vaultProtocolFee = 10 * ONE;
        x.requesterBond = int256(50 * ONE);
        x.providerBond = -int256(50 * ONE);
        _assertOutcome(b, x, "A24");
    }

    function test_A25_ForcedSplit_BondReturned_CapHolds() public {
        _approveIntegrator(1000);
        Bal memory b = _snap();
        bytes32 txId = _open(K, 1000, BOTH);
        _deliverAndDispute(txId, requester);
        _forceStale(txId);
        assertEq(uint8(kernel.getTransaction(txId).state), uint8(IACTPKernel.State.CANCELLED));
        Exp memory x = _exp(K);
        x.requester = 490 * ONE;
        x.provider = 445 * ONE;
        x.platform = 55 * ONE; // 50 provider side + 5 refund side
        x.kernelFee = 5 * ONE;
        x.archive = 5_000;
        x.vaultProtocolFee = 5 * ONE;
        _assertOutcome(b, x, "A25"); // bond net zero: returned to the disputer
    }

    // =====================================================================
    // Provider-side rule on the candidate kernel
    // =====================================================================

    /// @dev Cumulative gross >= 5 USDC at p = 100 and no clamped fragment: the integrator total is
    ///      floor(G*b/10000) or exactly one unit above it.
    function testFuzz_ProviderSide_GrossBound_CandidateKernel(uint256 amount, uint16 bps, uint256 f1, uint256 f2, bool settle)
        public
    {
        amount = bound(amount, 10 * ONE, 1_000_000 * ONE);
        bps = uint16(bound(bps, 1, 1000));
        f1 = bound(f1, 5 * ONE, amount - 2);
        f2 = bound(f2, 1, amount - f1 - 1);
        _approveIntegrator(1000);

        uint256 before = usdc.balanceOf(integrator);
        bytes32 txId = _open(amount, bps, PAYOUT_ONLY);
        _start(txId);
        _milestone(txId, f1);
        _milestone(txId, f2);
        uint256 gross = f1 + f2;
        if (settle) {
            vm.prank(provider);
            kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(uint256(2 days), keccak256("result")));
            _settle(txId);
            gross = amount;
        } else {
            vm.warp(block.timestamp + 30 days + 1 hours);
            kernel.recoverStalledInProgress(txId);
        }
        uint256 paid = usdc.balanceOf(integrator) - before;
        uint256 exact = (gross * bps) / 10_000;
        assertGe(paid, exact, "never below b of gross");
        assertLe(paid, exact + 1, "at most one unit above");
        if (settle) assertEq(paid, exact, "the deposit clamp makes a full payout exact");
    }

    function test_ProtocolBpsFromLockedRate() public {
        bytes32 txId = _create(K); // locks p = 100
        kernel.scheduleEconomicParams(200, 500);
        vm.warp(block.timestamp + 2 days);
        kernel.executeEconomicParamsUpdate();
        assertEq(kernel.platformFeeBps(), 200);

        _terms(txId, 100, PAYOUT_ONLY);
        _link(txId, address(vault));
        _start(txId);
        uint256 before = usdc.balanceOf(integrator);
        _milestone(txId, 500 * ONE);
        // N = 495; floor(495 * 100 / 9900) = 5. With the live rate it would be 5.051020.
        assertEq(usdc.balanceOf(integrator) - before, 5 * ONE, "locked rate, not the live one");
        (,,,, uint16 protocolBps,,) = vault.lockedTerms(txId);
        assertEq(protocolBps, 100);

        // A transaction created after the change locks 200.
        bytes32 later = _open(K, 100, PAYOUT_ONLY);
        _start(later);
        before = usdc.balanceOf(integrator);
        _milestone(later, 500 * ONE);
        assertEq(usdc.balanceOf(integrator) - before, 5 * ONE); // N = 490; floor(490 * 100 / 9800)
        (,,,, protocolBps,,) = vault.lockedTerms(later);
        assertEq(protocolBps, 200);
    }

    function test_TwinEscrowId_Voids_BehavesLikePlain() public {
        Bal memory b = _snap();
        bytes32 txId = _create(K);
        bytes32 twinId = _openTwin(txId);
        assertEq(uint8(_state(twinId)), uint8(IFeeSplitVault.TermsState.PENDING_CONFIRM));
        _deliver(txId);
        vm.expectEmit(true, false, false, false, address(vault));
        emit TermsVoided(twinId);
        _settle(txId);
        Exp memory x = _exp(K);
        x.provider = 990 * ONE;
        x.kernelFee = 10 * ONE;
        x.archive = 10_000;
        _assertOutcome(b, x, "twin");
        assertEq(uint8(_state(twinId)), uint8(IFeeSplitVault.TermsState.VOID));

        // The twin transaction can never be linked here under its own id.
        vm.startPrank(requester);
        usdc.approve(address(vault), K);
        vm.expectRevert("Escrow ID already used");
        kernel.linkEscrow(twinId, address(vault), twinId);
        vm.stopPrank();
    }

    // =====================================================================
    // Refund side
    // =====================================================================

    function test_RefundFeeOnlyAfterDispute() public {
        // Profile B, disputed: fees.
        _a9(BOTH, 100);
        // Profile B, never disputed: free.
        _a11(BOTH);
        // Profile D, disputed: free.
        _a9(PAYOUT_ONLY, 100);
    }

    function test_UndisputedRefund_FreeInBothProfiles() public {
        _a11(PAYOUT_ONLY);
        _a11(BOTH);
        _a13(PAYOUT_ONLY);
        _a13(BOTH);
        _a12(PAYOUT_ONLY);
        _a12(BOTH);
        // Stalled recovery after a milestone: the terms are already confirmed, the refund is still free.
        Bal memory b = _snap();
        bytes32 txId = _open(K, 100, BOTH);
        _start(txId);
        _milestone(txId, 250 * ONE);
        assertEq(uint8(_state(txId)), uint8(IFeeSplitVault.TermsState.CONFIRMED));
        vm.warp(block.timestamp + 30 days + 1 hours);
        kernel.recoverStalledInProgress(txId);
        Exp memory x = _exp(K);
        x.requester = 750 * ONE;
        x.provider = 245 * ONE;
        x.platform = 2_500_000;
        x.kernelFee = 2_500_000;
        x.archive = 2_500;
        _assertOutcome(b, x, "milestone then recovery (B)");
    }

    function test_ResolveDisputeWhilePaused_SameFeesAsTransitionState() public {
        Bal memory b = _snap();
        bytes32 txId = _open(K, 100, BOTH);
        _deliverAndDispute(txId, requester);
        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, abi.encode(600 * ONE, 400 * ONE));
        _assertOutcome(b, _a7Row(BOTH), "unpaused, transitionState");

        b = _snap();
        txId = _open(K, 100, BOTH);
        _deliverAndDispute(txId, requester);
        kernel.pause();
        vm.expectRevert("Kernel paused");
        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, abi.encode(600 * ONE, 400 * ONE));
        _rule(txId, 2, 4000); // CompositeMediator -> resolveDisputeWhilePaused
        kernel.unpause();
        _assertOutcome(b, _a7Row(BOTH), "paused, resolver stack");
    }

    function test_ReleaseEscrowRetry_NoDoubleCharge() public {
        usdc.setBlocked(feeRecipient, true);
        Bal memory b = _snap();
        bytes32 txId = _open(K, 100, PAYOUT_ONLY);
        _deliverAndSettle(txId);
        // The kernel's fee recipient share is reserved in the escrow; the provider side is paid.
        assertEq(usdc.balanceOf(provider) - b.provider, 980 * ONE);
        assertEq(usdc.balanceOf(integrator) - b.integrator, 10 * ONE);
        assertEq(vault.remaining(txId), 9_990_000);

        kernel.releaseEscrow(txId); // still blocked: nothing moves
        assertEq(usdc.balanceOf(provider) - b.provider, 980 * ONE);
        assertEq(usdc.balanceOf(integrator) - b.integrator, 10 * ONE);

        usdc.setBlocked(feeRecipient, false);
        kernel.releaseEscrow(txId);
        _assertOutcome(b, _settled1000(), "after retry");
    }

    function test_RetryPlatformFee_Unaffected() public {
        usdc.setBlocked(feeRecipient, true);
        Bal memory b = _snap();
        bytes32 txId = _open(K, 100, BOTH);
        _deliverAndSettle(txId);
        assertEq(vault.remaining(txId), 9_990_000);
        (uint256 providerSide, uint256 integratorSide,,,) = vault.splitState(txId);
        assertEq(providerSide, 990 * ONE);
        assertEq(integratorSide, 10 * ONE);

        usdc.setBlocked(feeRecipient, false);
        vm.prank(stranger);
        kernel.retryPlatformFee(txId);
        _assertOutcome(b, _settled1000(), "after retryPlatformFee");
        assertEq(vault.remaining(txId), 0);
        assertEq(vault.protocolCredit(), 0, "kernel fee debt is never vault credit");
    }

    // =====================================================================
    // Consent
    // =====================================================================

    function test_Consent_NoApproval_LinkReverts() public {
        address other = address(0x0717E4);
        bytes32 txId = _create(K);
        uint256 balance = usdc.balanceOf(requester);
        vm.startPrank(requester);
        vault.setEscrowTerms(txId, other, 1, PAYOUT_ONLY);
        usdc.approve(address(vault), K);
        vm.expectRevert("Integrator not approved");
        kernel.linkEscrow(txId, address(vault), txId);
        vm.stopPrank();
        assertEq(usdc.balanceOf(requester), balance);
        assertEq(vault.totalLocked(), 0);
    }

    function test_Consent_BpsAboveMax_LinkReverts() public {
        bytes32 txId = _create(K);
        _terms(txId, 101, PAYOUT_ONLY);
        vm.startPrank(requester);
        usdc.approve(address(vault), K);
        vm.expectRevert("Integrator not approved");
        kernel.linkEscrow(txId, address(vault), txId);
        vm.stopPrank();
        assertEq(vault.totalLocked(), 0);
    }

    function test_Consent_RevokeAfterLink_LockedTermsUnchanged() public {
        Bal memory b = _snap();
        bytes32 txId = _open(K, 100, PAYOUT_ONLY);
        _approveIntegrator(0);
        (address i, uint16 bps,,,,,) = vault.lockedTerms(txId);
        assertEq(i, integrator);
        assertEq(bps, 100);
        _deliverAndSettle(txId);
        _assertOutcome(b, _settled1000(), "revoked after link");
    }

    function test_Consent_RevokeBeforeLink_LinkReverts_NoFundsMoved() public {
        bytes32 txId = _create(K);
        _terms(txId, 100, PAYOUT_ONLY);
        _approveIntegrator(0);
        uint256 balance = usdc.balanceOf(requester);
        vm.startPrank(requester);
        usdc.approve(address(vault), K);
        vm.expectRevert("Integrator not approved");
        kernel.linkEscrow(txId, address(vault), txId);
        vm.stopPrank();
        assertEq(usdc.balanceOf(requester), balance);
        assertEq(usdc.balanceOf(address(vault)), 0);
        // The requester can drop the terms and fund a plain-behavior escrow.
        vm.prank(requester);
        vault.clearEscrowTerms(txId);
        _link(txId, address(vault));
        assertEq(uint8(_state(txId)), uint8(IFeeSplitVault.TermsState.NONE));
    }

    function test_Provider_CancelAtCommitted_AfterInspectingTerms_FullRefund_NoFee() public {
        Bal memory b = _snap();
        bytes32 txId = _open(K, 100, BOTH);
        (address i, uint16 bps, IFeeSplitVault.FeeProfile profile, IFeeSplitVault.TermsState state,,,) =
            vault.lockedTerms(txId);
        assertEq(i, integrator);
        assertEq(bps, 100);
        assertEq(uint8(profile), uint8(BOTH));
        assertEq(uint8(state), uint8(IFeeSplitVault.TermsState.PENDING_CONFIRM));
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, "");
        Exp memory x = _exp(K);
        x.requester = K;
        _assertOutcome(b, x, "provider cancel");
    }

    // =====================================================================
    // Events, quotes, counters
    // =====================================================================

    function test_Events_Reconstruct_BothSides() public {
        bytes32 txId = _open(K, 100, BOTH);
        _deliverAndDispute(txId, requester);
        vm.recordLogs();
        _rule(txId, 2, 4000);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (uint256 iSplit, uint256 iReleased, uint256 iRefundSplit, uint256 iRefunded) =
            (type(uint256).max, type(uint256).max, type(uint256).max, type(uint256).max);
        for (uint256 n; n < logs.length; n++) {
            bytes32 t = logs[n].topics[0];
            if (t == IFeeSplitVault.IntegratorFeeSplit.selector) iSplit = n;
            else if (t == IACTPKernel.EscrowReleased.selector) iReleased = n;
            else if (t == IFeeSplitVault.RefundFeeSplit.selector) iRefundSplit = n;
            else if (t == IACTPKernel.EscrowRefunded.selector) iRefunded = n;
        }
        assertLt(iSplit, iReleased, "vault split is logged before the kernel release");
        assertLt(iRefundSplit, iRefunded, "vault refund split is logged before the kernel refund");
        assertEq(logs[iSplit].emitter, address(vault));
        assertEq(logs[iSplit].topics[1], txId, "joined on escrowId");
        assertEq(logs[iRefundSplit].topics[1], txId);

        (uint256 providerSide, uint256 providerAmount, uint256 integratorAmount, bool credited) =
            abi.decode(logs[iSplit].data, (uint256, uint256, uint256, bool));
        (, uint256 released,) = abi.decode(logs[iReleased].data, (address, uint256, uint256));
        assertEq(providerSide, released, "providerSideAmount == EscrowReleased.amount");
        assertEq(providerSide, 396 * ONE);
        assertEq(providerAmount, 392 * ONE);
        assertEq(integratorAmount, 4 * ONE);
        assertFalse(credited);

        (uint256 refundSide, uint256 requesterAmount, uint256 protocolFee, uint256 integratorFee, bool pc, bool ic) =
            abi.decode(logs[iRefundSplit].data, (uint256, uint256, uint256, uint256, bool, bool));
        (, uint256 refunded,) = abi.decode(logs[iRefunded].data, (address, uint256, uint256));
        assertEq(refundSide, refunded, "refundSideAmount == EscrowRefunded.amount");
        assertEq(refundSide, 600 * ONE);
        assertEq(requesterAmount, 588 * ONE);
        assertEq(protocolFee, 6 * ONE);
        assertEq(integratorFee, 6 * ONE);
        assertFalse(pc);
        assertFalse(ic);

        // The locked terms stay readable after completion.
        (address i, uint16 bps,, IFeeSplitVault.TermsState state, uint16 p, bool disputed, bool used) =
            vault.lockedTerms(txId);
        assertEq(i, integrator);
        assertEq(bps, 100);
        assertEq(uint8(state), uint8(IFeeSplitVault.TermsState.CONFIRMED));
        assertEq(p, 100);
        assertTrue(disputed);
        assertTrue(used);
    }

    function test_QuoteRefund_ActualIsFeeFreeUntilDisputed() public {
        bytes32 txId = _open(K, 100, BOTH);
        _deliver(txId);
        (uint256 r, uint256 pf, uint256 i) = vault.quoteRefund(txId, K);
        assertEq(r, K);
        assertEq(pf, 0);
        assertEq(i, 0);
        _dispute(txId, requester);
        (r, pf, i) = vault.quoteRefund(txId, K);
        assertEq(r, 980 * ONE);
        assertEq(pf, 10 * ONE);
        assertEq(i, 10 * ONE);
    }

    function test_QuoteRefundIfDisputed_MatchesActualAfterDispute() public {
        // A7: quote for the gross amount the refund then carries.
        bytes32 txId = _open(K, 100, BOTH);
        _deliver(txId);
        (uint256 r, uint256 pf, uint256 i, bool confirmed) = vault.quoteRefundIfDisputed(txId, 600 * ONE);
        assertEq(r, 588 * ONE);
        assertEq(pf, 6 * ONE);
        assertEq(i, 6 * ONE);
        assertFalse(confirmed, "rate read live while PENDING_CONFIRM");
        Bal memory b = _snap();
        _dispute(txId, requester);
        _rule(txId, 2, 4000);
        assertEq(usdc.balanceOf(requester) - b.requester, r, "A7: quote equals the refund paid");

        // A9.
        txId = _open(K, 100, BOTH);
        _deliver(txId);
        (r, pf, i,) = vault.quoteRefundIfDisputed(txId, K);
        assertEq(r, 980 * ONE);
        assertEq(pf, 10 * ONE);
        assertEq(i, 10 * ONE);
        b = _snap();
        _dispute(txId, requester);
        _rule(txId, 1, 0);
        assertEq(usdc.balanceOf(requester) - b.requester, r, "A9: quote equals the refund paid");

        // 250 milestone, then dispute won by the requester.
        txId = _open(K, 100, BOTH);
        _start(txId);
        _milestone(txId, 250 * ONE);
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(uint256(2 days), keccak256("result")));
        (r, pf, i, confirmed) = vault.quoteRefundIfDisputed(txId, kernel.escrowPrincipal(txId));
        assertEq(r, 735 * ONE);
        assertEq(pf, 7_500_000);
        assertEq(i, 7_500_000);
        assertTrue(confirmed);
        b = _snap();
        _dispute(txId, requester);
        _rule(txId, 1, 0);
        assertEq(usdc.balanceOf(requester) - b.requester, r, "milestone: quote equals the refund paid");

        // Zero fees for PAYOUT_ONLY, no-terms and VOID escrows.
        txId = _open(K, 100, PAYOUT_ONLY);
        (r, pf, i,) = vault.quoteRefundIfDisputed(txId, K);
        assertEq(r, K);
        assertEq(pf + i, 0);
        txId = _open(K, 0, PAYOUT_ONLY);
        (r, pf, i,) = vault.quoteRefundIfDisputed(txId, K);
        assertEq(r, K);
        assertEq(pf + i, 0);
        txId = _create(K);
        bytes32 twinId = _openTwin(txId);
        (r, pf, i, confirmed) = vault.quoteRefundIfDisputed(twinId, K);
        assertEq(r, K, "terms that would be voided quote no fee");
        assertEq(pf + i, 0);
        _start(txId);
        _milestone(txId, ONE);
        assertEq(uint8(_state(twinId)), uint8(IFeeSplitVault.TermsState.VOID));
        (r, pf, i,) = vault.quoteRefundIfDisputed(twinId, 999 * ONE);
        assertEq(r, 999 * ONE);
        assertEq(pf + i, 0);
    }

    function test_SolvencyCounters() public {
        bytes32 txId = _open(K, 100, BOTH);
        assertEq(vault.totalLocked(), K);
        _assertSolvent("funded");
        bytes32 second = _open(400 * ONE, 0, PAYOUT_ONLY);
        assertEq(vault.totalLocked(), 1400 * ONE);

        _deliverAndDispute(txId, requester);
        assertEq(vault.totalBonds(), 50 * ONE);
        assertEq(vault.bondBalance(txId), 50 * ONE);
        _assertSolvent("disputed");

        usdc.setBlocked(integrator, true);
        usdc.setBlocked(feeRecipient, true);
        _rule(txId, 1, 0);
        assertEq(vault.totalBonds(), 0);
        assertEq(vault.totalLocked(), 400 * ONE);
        assertEq(vault.totalIntegratorCredit(), 10 * ONE);
        assertEq(vault.protocolCredit(), 10 * ONE);
        assertEq(usdc.balanceOf(address(vault)), 420 * ONE);
        _assertSolvent("credits");

        _deliverAndSettle(second); // kernel fee recipient share stays reserved in the escrow
        assertEq(vault.totalLocked(), 3_996_000);
        _assertSolvent("reserved kernel fee");
    }

    function test_WithdrawCredits_CountersAfterSuccessAndAfterRevert() public {
        usdc.setBlocked(integrator, true);
        usdc.setBlocked(feeRecipient, true);
        bytes32 txId = _open(K, 100, BOTH);
        _deliverAndDispute(txId, requester);
        _rule(txId, 1, 0);

        // Still blocked: both withdrawals revert and leave every counter unchanged.
        vm.expectRevert();
        vault.withdrawIntegratorCredit(integrator);
        vm.expectRevert();
        vault.withdrawProtocolCredit();
        assertEq(vault.integratorCredit(integrator), 10 * ONE);
        assertEq(vault.totalIntegratorCredit(), 10 * ONE);
        assertEq(vault.protocolCredit(), 10 * ONE);
        _assertSolvent("after reverted withdrawals");

        usdc.setBlocked(integrator, false);
        vault.withdrawIntegratorCredit(integrator);
        assertEq(vault.integratorCredit(integrator), 0);
        assertEq(vault.totalIntegratorCredit(), 0);
        assertEq(vault.protocolCredit(), 10 * ONE);
        _assertSolvent("after integrator withdrawal");

        usdc.setBlocked(feeRecipient, false);
        vault.withdrawProtocolCredit();
        assertEq(vault.protocolCredit(), 0);
        assertEq(usdc.balanceOf(address(vault)), 0);
        _assertSolvent("after protocol withdrawal");
    }

    /// @dev Recorded, not a gate: flag above 120,000 gas extra.
    function test_Gas_PayoutAndRefundDelta() public {
        bytes32 a = _openPlain(K);
        bytes32 d = _open(K, 100, BOTH);
        _deliver(a);
        _deliver(d);
        uint256 g = gasleft();
        _settle(a);
        uint256 plainSettle = g - gasleft();
        g = gasleft();
        _settle(d);
        uint256 splitSettle = g - gasleft();

        a = _openPlain(K);
        d = _open(K, 100, BOTH);
        _deliverAndDispute(a, requester);
        _deliverAndDispute(d, requester);
        bytes memory proof = abi.encode(K, uint256(0), true);
        g = gasleft();
        kernel.transitionState(a, IACTPKernel.State.SETTLED, proof);
        uint256 plainRefund = g - gasleft();
        g = gasleft();
        kernel.transitionState(d, IACTPKernel.State.SETTLED, proof);
        uint256 splitRefund = g - gasleft();

        emit log_named_uint("settle, EscrowVault", plainSettle);
        emit log_named_uint("settle, FeeSplitVault", splitSettle);
        emit log_named_uint("settle, extra gas", splitSettle - plainSettle);
        emit log_named_uint("post-dispute refund, EscrowVault", plainRefund);
        emit log_named_uint("post-dispute refund, FeeSplitVault", splitRefund);
        emit log_named_uint("post-dispute refund, extra gas", splitRefund - plainRefund);
    }

    // =====================================================================
    // Revocation (rollback procedure)
    // =====================================================================

    function test_RevocationWindow_LinkSucceeds_ThenExecuteFreezesPayout() public {
        kernel.scheduleEscrowVaultRevocation(address(vault));
        bytes32 txId = _open(K, 100, PAYOUT_ONLY); // linkEscrow ignores a pending revocation
        _deliver(txId);
        vm.warp(block.timestamp + 2 days);
        vm.prank(stranger);
        kernel.executeEscrowVaultRevocation(address(vault));
        vm.prank(requester);
        vm.expectRevert("Vault not approved");
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, "");
        assertEq(vault.totalLocked(), K, "the escrow is frozen in the vault");
    }

    function test_RevocationUnderPause_LinkReverts_VaultStaysEmpty() public {
        bytes32 txId = _create(K);
        kernel.pause();
        assertEq(vault.totalLocked() + vault.totalBonds(), 0);
        kernel.scheduleEscrowVaultRevocation(address(vault));
        vm.startPrank(requester);
        usdc.approve(address(vault), K);
        vm.expectRevert("Kernel paused");
        kernel.linkEscrow(txId, address(vault), txId);
        vm.stopPrank();
        vm.warp(block.timestamp + 2 days);
        kernel.executeEscrowVaultRevocation(address(vault));
        kernel.unpause();
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(vault.totalLocked(), 0);
        vm.prank(requester);
        vm.expectRevert("Escrow not approved");
        kernel.linkEscrow(txId, address(vault), txId);
    }
}
