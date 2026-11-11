// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ACTPKernel} from "../../src/ACTPKernel.sol";
import {CompositeMediator} from "../../src/CompositeMediator.sol";
import {BondEscalation} from "../../src/BondEscalation.sol";
import {EscrowVault} from "../../src/escrow/EscrowVault.sol";
import {FeeSplitVault} from "../../src/escrow/FeeSplitVault.sol";
import {ArchiveTreasury} from "../../src/treasury/ArchiveTreasury.sol";
import {IFeeSplitVault} from "../../src/interfaces/IFeeSplitVault.sol";
import {IACTPKernel} from "../../src/interfaces/IACTPKernel.sol";
import {ICompositeMediator} from "../../src/interfaces/ICompositeMediator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockOOV3} from "../mocks/MockOOV3.sol";
import {BlacklistUSDC} from "../audit/F17F59_FeeAccounting.t.sol";

/// @title FeeSplitTestBase — candidate kernel with the real resolver stack of this revision, both
///        vaults, an archive treasury and a blockable token.
/// @notice Disputes are resolved through BondEscalation + CompositeMediator (`_rule`, `_forceStale`),
///         not through an admin shortcut, unless a row needs an explicit-amount proof.
abstract contract FeeSplitTestBase is Test {
    uint256 internal constant ONE = 1_000_000;
    IFeeSplitVault.FeeProfile internal constant PAYOUT_ONLY = IFeeSplitVault.FeeProfile.PAYOUT_ONLY;
    IFeeSplitVault.FeeProfile internal constant BOTH = IFeeSplitVault.FeeProfile.BOTH_AFTER_DISPUTE;

    IERC20 internal usdc;
    ACTPKernel internal kernel;
    EscrowVault internal plain;
    FeeSplitVault internal vault;
    ArchiveTreasury internal archive;
    CompositeMediator internal mediator;
    BondEscalation internal bondEscalation;

    address internal feeRecipient = address(0xFEE);
    address internal requester = address(0xA11CE);
    address internal provider = address(0xB0B);
    address internal integrator = address(0x1A7E);
    address internal keeper = address(0x4EE9);
    address internal paidMediator = address(0x33ED);
    address internal stranger = address(0xBAD);

    /// @dev Expected outcome of one escrow. Amounts are what each party received out of the escrow;
    ///      dispute bonds are separate (net flow per party).
    struct Exp {
        uint256 deposit;
        uint256 requester;
        uint256 provider;
        uint256 platform; // integrator entitlement, pushed or credited
        uint256 platformCredited;
        uint256 kernelFee; // fee recipient share plus archive share, charged by the kernel
        uint256 archive;
        uint256 vaultProtocolFee; // refund-side protocol fee, pushed or credited
        uint256 protocolCredited;
        uint256 mediator;
        int256 requesterBond;
        int256 providerBond;
    }

    struct Bal {
        uint256 requester;
        uint256 provider;
        uint256 integrator;
        uint256 feeRecipient;
        uint256 archive;
        uint256 mediator;
        uint256 integratorCredit;
        uint256 protocolCredit;
    }

    // ----- token hooks: a blockable test token here, real USDC on a mainnet fork -----

    function _token() internal virtual returns (address) {
        return address(new BlacklistUSDC());
    }

    function _mint(address to, uint256 amount) internal virtual {
        BlacklistUSDC(address(usdc)).mint(to, amount);
    }

    function _setBlocked(address who, bool blocked) internal virtual {
        BlacklistUSDC(address(usdc)).setBlocked(who, blocked);
    }

    function _setUpStack() internal {
        usdc = IERC20(_token());
        kernel = new ACTPKernel(address(this), address(this), feeRecipient, address(0), address(usdc), 1 hours);
        plain = new EscrowVault(address(usdc), address(kernel));
        vault = new FeeSplitVault(address(usdc), address(kernel));
        kernel.approveEscrowVault(address(plain), true);
        kernel.approveEscrowVault(address(vault), true);
        archive = new ArchiveTreasury(address(usdc), address(kernel), address(this));
        kernel.setArchiveTreasury(address(archive));

        mediator = new CompositeMediator(IACTPKernel(address(kernel)));
        address[2] memory fixedEvaluators = [makeAddr("fixed0"), makeAddr("fixed1")];
        address[] memory rotatingPool = new address[](1);
        rotatingPool[0] = makeAddr("rotating0");
        bondEscalation = new BondEscalation(
            IACTPKernel(address(kernel)),
            IERC20(address(usdc)),
            ICompositeMediator(address(mediator)),
            address(this),
            fixedEvaluators,
            rotatingPool,
            address(new MockOOV3())
        );
        mediator.initialize(address(bondEscalation));
        kernel.approveMediator(address(mediator), true);
        kernel.approveMediator(paidMediator, true);
        vm.warp(block.timestamp + 2 days + 1);

        _fundActors();
        vm.prank(keeper);
        usdc.approve(address(bondEscalation), type(uint256).max);

        _approveIntegrator(100);
    }

    function _fundActors() internal {
        _mint(requester, 10_000_000 * ONE);
        _mint(provider, 1_000_000 * ONE);
        _mint(keeper, 1_000_000 * ONE);
    }

    // ----- consent and funding -----

    function _approveIntegrator(uint16 maxBps) internal {
        vm.prank(provider);
        vault.setIntegratorApproval(integrator, maxBps);
    }

    function _create(uint256 amount) internal returns (bytes32 txId) {
        vm.prank(requester);
        txId = kernel.createTransaction(
            provider, requester, amount, block.timestamp + 30 days, 1 hours, keccak256("svc"), bytes32(0), 0, 0
        );
    }

    function _terms(bytes32 escrowId, uint16 bps, IFeeSplitVault.FeeProfile profile) internal {
        vm.prank(requester);
        vault.setEscrowTerms(escrowId, integrator, bps, profile);
    }

    function _link(bytes32 txId, address escrowVault) internal {
        uint256 amount = kernel.getTransaction(txId).amount;
        vm.startPrank(requester);
        usdc.approve(escrowVault, amount);
        kernel.linkEscrow(txId, escrowVault, txId);
        vm.stopPrank();
    }

    /// @dev Funded escrow in the FeeSplitVault; `bps == 0` registers no terms.
    function _open(uint256 amount, uint16 bps, IFeeSplitVault.FeeProfile profile) internal returns (bytes32 txId) {
        txId = _create(amount);
        if (bps > 0) _terms(txId, bps, profile);
        _link(txId, address(vault));
    }

    function _openPlain(uint256 amount) internal returns (bytes32 txId) {
        txId = _create(amount);
        _link(txId, address(plain));
    }

    // ----- lifecycle -----

    function _start(bytes32 txId) internal {
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");
    }

    function _deliver(bytes32 txId) internal {
        _start(txId);
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(uint256(2 days), keccak256("result")));
    }

    function _settle(bytes32 txId) internal {
        vm.prank(requester);
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, "");
    }

    function _deliverAndSettle(bytes32 txId) internal {
        _deliver(txId);
        _settle(txId);
    }

    function _milestone(bytes32 txId, uint256 amount) internal {
        vm.prank(requester);
        kernel.releaseMilestone(txId, amount);
    }

    /// @dev Delivers and opens the dispute as `who`, paying the kernel's entry bond.
    function _deliverAndDispute(bytes32 txId, address who) internal {
        _deliver(txId);
        _dispute(txId, who);
    }

    function _dispute(bytes32 txId, address who) internal {
        IACTPKernel.TransactionView memory t = kernel.getTransaction(txId);
        uint256 bond = (t.amount * t.disputeBondBpsLocked) / 10_000;
        if (bond < ONE) bond = ONE;
        vm.startPrank(who);
        usdc.approve(t.escrowContract, bond);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");
        vm.stopPrank();
    }

    /// @dev Tier-1 ruling finalized unchallenged: BondEscalation -> CompositeMediator -> kernel.
    function _rule(bytes32 txId, uint8 ruling, uint16 splitBps) internal {
        vm.startPrank(keeper);
        bytes32 disputeId = bondEscalation.openDispute(txId);
        bondEscalation.proposeDirectly(disputeId, ruling, splitBps);
        vm.warp(block.timestamp + 8 hours + 1);
        bondEscalation.finalize(disputeId);
        vm.stopPrank();
    }

    /// @dev Forced 50/50 after 30 days, exit via CANCELLED.
    function _forceStale(bytes32 txId) internal {
        vm.startPrank(keeper);
        bytes32 disputeId = bondEscalation.openDispute(txId);
        vm.warp(block.timestamp + 30 days + 1);
        bondEscalation.forceResolveStale(disputeId);
        vm.stopPrank();
    }

    // ----- accounting -----

    function _snap() internal view returns (Bal memory b) {
        b.requester = usdc.balanceOf(requester);
        b.provider = usdc.balanceOf(provider);
        b.integrator = usdc.balanceOf(integrator);
        b.feeRecipient = usdc.balanceOf(feeRecipient);
        b.archive = address(archive) == address(0) ? 0 : usdc.balanceOf(address(archive));
        b.mediator = usdc.balanceOf(paidMediator);
        b.integratorCredit = vault.integratorCredit(integrator);
        b.protocolCredit = vault.protocolCredit();
    }

    /// @dev `before` is taken before the escrow is funded. Asserts every column of a row, conservation,
    ///      and that the kernel holds nothing.
    function _assertOutcome(Bal memory before, Exp memory x, string memory label) internal view {
        Bal memory a = _snap();
        assertEq(
            int256(a.requester) - int256(before.requester),
            int256(x.requester) - int256(x.deposit) + x.requesterBond,
            string.concat(label, ": requester")
        );
        assertEq(
            int256(a.provider) - int256(before.provider),
            int256(x.provider) + x.providerBond,
            string.concat(label, ": provider")
        );
        assertEq(a.integrator - before.integrator, x.platform - x.platformCredited, string.concat(label, ": platform paid"));
        assertEq(
            a.integratorCredit - before.integratorCredit, x.platformCredited, string.concat(label, ": platform credited")
        );
        // Without an archive treasury the kernel pays its whole fee to the fee recipient.
        uint256 archiveShare = address(archive) == address(0) ? 0 : x.archive;
        assertEq(a.archive - before.archive, archiveShare, string.concat(label, ": archive"));
        assertEq(
            a.feeRecipient - before.feeRecipient,
            x.kernelFee - archiveShare + x.vaultProtocolFee - x.protocolCredited,
            string.concat(label, ": fee recipient")
        );
        assertEq(a.protocolCredit - before.protocolCredit, x.protocolCredited, string.concat(label, ": protocol credited"));
        assertEq(a.mediator - before.mediator, x.mediator, string.concat(label, ": mediator"));
        assertEq(
            x.requester + x.provider + x.platform + x.kernelFee + x.vaultProtocolFee + x.mediator,
            x.deposit,
            string.concat(label, ": row sums to the deposit")
        );
        assertEq(usdc.balanceOf(address(kernel)), 0, string.concat(label, ": kernel holds nothing"));
        _assertSolvent(label);
    }

    /// @dev Equality, not >=: the tests make no donations.
    function _assertSolvent(string memory label) internal view {
        assertEq(
            usdc.balanceOf(address(vault)),
            vault.totalLocked() + vault.totalBonds() + vault.totalIntegratorCredit() + vault.protocolCredit(),
            string.concat(label, ": vault solvency")
        );
    }

    // ----- rows shared by the kernel, fork and acceptance suites -----

    function _exp(uint256 deposit) internal pure returns (Exp memory x) {
        x.deposit = deposit;
    }

    function _name(string memory row, IFeeSplitVault.FeeProfile profile) internal pure returns (string memory) {
        return string.concat(row, profile == BOTH ? " (B)" : " (D)");
    }

    /// @dev 1,000 settled at 100 bps: the row shared by A3, A4, A8 and A15.
    function _settled1000() internal pure returns (Exp memory x) {
        x.deposit = 1000 * ONE;
        x.provider = 980 * ONE;
        x.platform = 10 * ONE;
        x.kernelFee = 10 * ONE;
        x.archive = 10_000;
    }

    function _a7Row(IFeeSplitVault.FeeProfile profile) internal pure returns (Exp memory x) {
        x.deposit = 1000 * ONE;
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

    function _a9Row(IFeeSplitVault.FeeProfile profile) internal pure returns (Exp memory x) {
        x.deposit = 1000 * ONE;
        if (profile == BOTH) {
            x.requester = 980 * ONE;
            x.platform = 10 * ONE;
            x.vaultProtocolFee = 10 * ONE;
        } else {
            x.requester = 1000 * ONE;
        }
    }

    function _a25Row() internal pure returns (Exp memory x) {
        x.deposit = 1000 * ONE;
        x.requester = 490 * ONE;
        x.provider = 445 * ONE;
        x.platform = 55 * ONE; // 50 provider side + 5 refund side
        x.kernelFee = 5 * ONE;
        x.archive = 5_000;
        x.vaultProtocolFee = 5 * ONE;
    }

    function _a3(IFeeSplitVault.FeeProfile profile) internal {
        Bal memory b = _snap();
        bytes32 txId = _open(1000 * ONE, 100, profile);
        _deliverAndSettle(txId);
        _assertOutcome(b, _settled1000(), _name("A3", profile));
    }

    function _a7(IFeeSplitVault.FeeProfile profile) internal {
        Bal memory b = _snap();
        bytes32 txId = _open(1000 * ONE, 100, profile);
        _deliverAndDispute(txId, requester);
        _rule(txId, 2, 4000);
        _assertOutcome(b, _a7Row(profile), _name("A7", profile));
    }

    function _a9(IFeeSplitVault.FeeProfile profile, uint16 bps) internal returns (bytes32 txId) {
        Bal memory b = _snap();
        txId = _open(1000 * ONE, bps, profile);
        _deliverAndDispute(txId, requester);
        _rule(txId, 1, 0);
        _assertOutcome(b, _a9Row(profile), _name("A9", profile));
    }

    function _a12(IFeeSplitVault.FeeProfile profile) internal {
        Bal memory b = _snap();
        bytes32 txId = _open(1000 * ONE, 100, profile);
        vm.warp(block.timestamp + 30 days);
        vm.prank(requester);
        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, "");
        Exp memory x = _exp(1000 * ONE);
        x.requester = 950 * ONE;
        x.provider = 49 * ONE;
        x.platform = 500_000;
        x.kernelFee = 500_000;
        x.archive = 500;
        _assertOutcome(b, x, _name("A12", profile));
    }

    function _state(bytes32 escrowId) internal view returns (IFeeSplitVault.TermsState state) {
        (,,, state,,,) = vault.lockedTerms(escrowId);
    }
}
