// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {FeeSplitVault} from "../src/escrow/FeeSplitVault.sol";
import {EscrowVault} from "../src/escrow/EscrowVault.sol";
import {IFeeSplitVault} from "../src/interfaces/IFeeSplitVault.sol";
import {IEscrowValidator} from "../src/interfaces/IEscrowValidator.sol";
import {BlacklistUSDC} from "./audit/F17F59_FeeAccounting.t.sol";

/// @notice Stands in for the kernel: forwards the kernel-only vault calls and answers
///         `getTransaction` / `feeRecipient` with whatever the test configures, including failing,
///         short and malformed answers.
contract FakeKernel {
    enum Mode { OK, REVERT, SHORT }

    Mode public mode;
    bool public feeRecipientReverts;
    address internal _feeRecipient;
    mapping(bytes32 => uint256[23]) internal _views;

    function setMode(Mode m) external {
        mode = m;
    }

    function setFeeRecipient(address r, bool reverts) external {
        _feeRecipient = r;
        feeRecipientReverts = reverts;
    }

    function setTx(bytes32 id, address requester, address provider, uint256 amount, address escrowContract, bytes32 escrowId, uint256 p)
        external
    {
        uint256[23] storage w = _views[id];
        w[0] = uint256(id);
        w[1] = uint256(uint160(requester));
        w[2] = uint256(uint160(provider));
        w[4] = amount;
        w[9] = uint256(uint160(escrowContract));
        w[10] = uint256(escrowId);
        w[14] = p;
    }

    function setWord(bytes32 id, uint256 index, uint256 value) external {
        _views[id][index] = value;
    }

    function word(bytes32 id, uint256 index) external view returns (uint256) {
        return _views[id][index];
    }

    function getTransaction(bytes32 id) external view {
        if (mode == Mode.REVERT) revert("Tx missing");
        uint256[23] memory w = _views[id];
        uint256 size = mode == Mode.SHORT ? 20 * 32 : 23 * 32;
        assembly {
            return(w, size)
        }
    }

    function feeRecipient() external view returns (address) {
        require(!feeRecipientReverts, "no recipient");
        return _feeRecipient;
    }

    function createEscrow(IEscrowValidator v, bytes32 id, address requester, address provider, uint256 amount) external {
        v.createEscrow(id, requester, provider, amount);
    }

    function payoutToProvider(IEscrowValidator v, bytes32 id, uint256 amount) external returns (uint256) {
        return v.payoutToProvider(id, amount);
    }

    function refundToRequester(IEscrowValidator v, bytes32 id, uint256 amount) external returns (uint256) {
        return v.refundToRequester(id, amount);
    }

    function payout(IEscrowValidator v, bytes32 id, address recipient, uint256 amount) external returns (uint256) {
        return v.payout(id, recipient, amount);
    }

    function depositBond(IEscrowValidator v, bytes32 id, address from, uint256 amount) external {
        v.depositBond(id, from, amount);
    }

    function releaseBond(IEscrowValidator v, bytes32 id, address recipient, uint256 amount) external {
        v.releaseBond(id, recipient, amount);
    }
}

/// @title FeeSplitVaultTest — the vault alone, driven by a fake kernel.
contract FeeSplitVaultTest is Test {
    uint256 internal constant ONE = 1_000_000;
    IFeeSplitVault.FeeProfile internal constant PAYOUT_ONLY = IFeeSplitVault.FeeProfile.PAYOUT_ONLY;
    IFeeSplitVault.FeeProfile internal constant BOTH = IFeeSplitVault.FeeProfile.BOTH_AFTER_DISPUTE;

    BlacklistUSDC internal usdc;
    FakeKernel internal fake;
    FeeSplitVault internal vault;
    EscrowVault internal plain;

    address internal feeRecipient = address(0xFEE);
    address internal requester = address(0xA11CE);
    address internal provider = address(0xB0B);
    address internal integrator = address(0x1A7E);
    address internal stranger = address(0xBAD);
    uint256 internal nextId = 1;

    event EscrowDisputed(bytes32 indexed escrowId);
    event TermsVoided(bytes32 indexed escrowId);
    event TermsConfirmed(bytes32 indexed escrowId, uint16 protocolBps);

    function setUp() public {
        usdc = new BlacklistUSDC();
        fake = new FakeKernel();
        fake.setFeeRecipient(feeRecipient, false);
        vault = new FeeSplitVault(address(usdc), address(fake));
        plain = new EscrowVault(address(usdc), address(fake));
        usdc.mint(requester, type(uint128).max);
        vm.startPrank(requester);
        usdc.approve(address(vault), type(uint256).max);
        usdc.approve(address(plain), type(uint256).max);
        vm.stopPrank();
        vm.prank(provider);
        vault.setIntegratorApproval(integrator, 1000);
    }

    function _id() internal returns (bytes32 id) {
        id = bytes32(nextId++);
    }

    /// @dev Creates an escrow the way linkEscrow does: the kernel view shows no vault during
    ///      createEscrow and the vault and id afterwards.
    function _open(uint256 amount, uint16 bps, IFeeSplitVault.FeeProfile profile, uint256 p) internal returns (bytes32 id) {
        id = _id();
        fake.setTx(id, requester, provider, amount, address(0), id, p);
        if (bps > 0) {
            vm.prank(requester);
            vault.setEscrowTerms(id, integrator, bps, profile);
        }
        fake.createEscrow(vault, id, requester, provider, amount);
        fake.setTx(id, requester, provider, amount, address(vault), id, p);
    }

    function _dispute(bytes32 id) internal {
        fake.depositBond(vault, id, requester, ONE);
    }

    function _state(bytes32 id) internal view returns (IFeeSplitVault.TermsState state) {
        (,,, state,,,) = vault.lockedTerms(id);
    }

    function _assertSolvent() internal view {
        assertEq(
            usdc.balanceOf(address(vault)),
            vault.totalLocked() + vault.totalBonds() + vault.totalIntegratorCredit() + vault.protocolCredit(),
            "vault solvency"
        );
    }

    // =====================================================================
    // Provider side
    // =====================================================================

    /// @dev Any fragment sequence: the integrator total equals
    ///      min(floor(N*b/(10000-p)), floor(D*b/10000)) after every fragment.
    function testFuzz_ProviderSide_MatchesRule(uint256 deposit, uint16 b, uint16 p, uint256[5] memory fragments) public {
        deposit = bound(deposit, 1, 1e15);
        b = uint16(bound(b, 1, 1000));
        p = uint16(bound(p, 1, 500));
        bytes32 id = _open(deposit, b, PAYOUT_ONLY, p);
        uint256 n;
        for (uint256 i; i < fragments.length && n < deposit; i++) {
            uint256 amount = bound(fragments[i], 1, deposit - n);
            (uint256 quotedProvider, uint256 quotedIntegrator) = vault.quotePayout(id, amount);
            assertEq(fake.payoutToProvider(vault, id, amount), amount, "returns the full amount");
            n += amount;
            uint256 target = (n * b) / (10_000 - p);
            uint256 cap = (deposit * b) / 10_000;
            if (target > cap) target = cap;
            assertEq(usdc.balanceOf(integrator), target, "integrator total follows the rule");
            assertEq(usdc.balanceOf(provider) + usdc.balanceOf(integrator), n, "split sums to what the kernel paid");
            assertEq(quotedProvider + quotedIntegrator, amount);
            _assertSolvent();
        }
        assertEq(vault.totalLocked(), deposit - n);
    }

    function test_QuotePayout_MatchesActual() public {
        bytes32 id = _open(1000 * ONE, 100, PAYOUT_ONLY, 100);
        (uint256 qp, uint256 qi) = vault.quotePayout(id, 247_500_000); // still PENDING_CONFIRM: rate read live
        assertEq(qp, 245 * ONE);
        assertEq(qi, 2_500_000);
        fake.payoutToProvider(vault, id, 247_500_000);
        assertEq(usdc.balanceOf(provider), qp);
        assertEq(usdc.balanceOf(integrator), qi);
        (qp, qi) = vault.quotePayout(id, 742_500_000);
        assertEq(qi, 7_500_000);
        // No terms: nothing to the integrator.
        bytes32 none = _open(1000 * ONE, 0, PAYOUT_ONLY, 100);
        (qp, qi) = vault.quotePayout(none, 990 * ONE);
        assertEq(qp, 990 * ONE);
        assertEq(qi, 0);
    }

    // =====================================================================
    // Kernel view decoding
    // =====================================================================

    function test_KernelViewProbe_ShortOrFailing_VoidsNotReverts() public {
        // Failing getTransaction at the first provider payout.
        bytes32 id = _open(1000 * ONE, 100, PAYOUT_ONLY, 100);
        fake.setMode(FakeKernel.Mode.REVERT);
        (bool ok,,,,,,) = vault.kernelViewProbe(id);
        assertFalse(ok);
        vm.expectEmit(true, false, false, false, address(vault));
        emit TermsVoided(id);
        assertEq(fake.payoutToProvider(vault, id, 400 * ONE), 400 * ONE);
        assertEq(usdc.balanceOf(provider), 400 * ONE, "plain behavior");
        assertEq(usdc.balanceOf(integrator), 0);
        assertEq(uint8(_state(id)), uint8(IFeeSplitVault.TermsState.VOID));
        // Void is final, even when the kernel answers again.
        fake.setMode(FakeKernel.Mode.OK);
        fake.payoutToProvider(vault, id, 590 * ONE);
        assertEq(usdc.balanceOf(provider), 990 * ONE);
        assertEq(usdc.balanceOf(integrator), 0);

        // Short answer (20 words) at the first post-dispute refund.
        id = _open(1000 * ONE, 100, BOTH, 100);
        _dispute(id);
        fake.setMode(FakeKernel.Mode.SHORT);
        (ok,,,,,,) = vault.kernelViewProbe(id);
        assertFalse(ok);
        uint256 before = usdc.balanceOf(requester);
        assertEq(fake.refundToRequester(vault, id, 1000 * ONE), 1000 * ONE);
        assertEq(usdc.balanceOf(requester) - before, 1000 * ONE, "full refund");
        assertEq(usdc.balanceOf(feeRecipient), 0);
        assertEq(uint8(_state(id)), uint8(IFeeSplitVault.TermsState.VOID));
        fake.setMode(FakeKernel.Mode.OK);

        // createEscrow with terms needs a readable transaction.
        id = _id();
        vm.prank(requester);
        vault.setEscrowTerms(id, integrator, 100, PAYOUT_ONLY);
        fake.setTx(id, requester, provider, ONE, address(0), id, 100);
        fake.setMode(FakeKernel.Mode.REVERT);
        vm.expectRevert("Terms need txId escrowId");
        fake.createEscrow(vault, id, requester, provider, ONE);
    }

    /// @dev A successful answer of full length that is not this escrow's transaction, or not a
    ///      well-formed one, always ends in VOID: never CONFIRMED, never a revert or a division by zero.
    function test_ReadTx_MalformedSuccessfulReturn_Voids() public {
        for (uint256 c; c < 9; c++) {
            bytes32 id = _open(1000 * ONE, 100, BOTH, 100);
            if (c == 0) fake.setWord(id, 1, fake.word(id, 1) | (1 << 160)); // dirty requester word
            else if (c == 1) fake.setWord(id, 2, fake.word(id, 2) | (1 << 255)); // dirty provider word
            else if (c == 2) fake.setWord(id, 9, fake.word(id, 9) | (1 << 160)); // dirty vault word
            else if (c == 3) fake.setWord(id, 14, 0); // p = 0
            else if (c == 4) fake.setWord(id, 14, 501); // p above the kernel cap
            else if (c == 5) fake.setWord(id, 14, 10_000); // would divide by zero
            else if (c == 6) fake.setWord(id, 10, uint256(keccak256("other id")));
            else if (c == 7) fake.setWord(id, 1, uint256(uint160(stranger)));
            else fake.setWord(id, 2, uint256(uint160(stranger)));

            uint256 providerBefore = usdc.balanceOf(provider);
            assertEq(fake.payoutToProvider(vault, id, 100 * ONE), 100 * ONE);
            assertEq(usdc.balanceOf(provider) - providerBefore, 100 * ONE);
            assertEq(uint8(_state(id)), uint8(IFeeSplitVault.TermsState.VOID));

            _dispute(id);
            uint256 requesterBefore = usdc.balanceOf(requester);
            fake.refundToRequester(vault, id, 900 * ONE);
            assertEq(usdc.balanceOf(requester) - requesterBefore, 900 * ONE);
        }
        assertEq(usdc.balanceOf(integrator), 0);
        assertEq(usdc.balanceOf(feeRecipient), 0);

        // A vault word that names another vault voids as well.
        bytes32 other = _open(1000 * ONE, 100, PAYOUT_ONLY, 100);
        fake.setWord(other, 9, uint256(uint160(address(plain))));
        fake.payoutToProvider(vault, other, ONE);
        assertEq(uint8(_state(other)), uint8(IFeeSplitVault.TermsState.VOID));

        // The well-formed answer confirms and reports the same fields through the probe.
        bytes32 good = _open(1000 * ONE, 100, PAYOUT_ONLY, 250);
        (bool ok, address r, address pr, uint256 amount, address ec, bytes32 eid, uint16 p) = vault.kernelViewProbe(good);
        assertTrue(ok);
        assertEq(r, requester);
        assertEq(pr, provider);
        assertEq(amount, 1000 * ONE);
        assertEq(ec, address(vault));
        assertEq(eid, good);
        assertEq(p, 250);
        vm.expectEmit(true, false, false, true, address(vault));
        emit TermsConfirmed(good, 250);
        fake.payoutToProvider(vault, good, ONE);
        assertEq(uint8(_state(good)), uint8(IFeeSplitVault.TermsState.CONFIRMED));
    }

    // =====================================================================
    // Bonds and the disputed flag
    // =====================================================================

    function test_DepositBond_SetsDisputedOnce() public {
        bytes32 id = _open(1000 * ONE, 100, BOTH, 100);
        (,,,,, bool disputed,) = vault.lockedTerms(id);
        assertFalse(disputed);

        vm.recordLogs();
        fake.depositBond(vault, id, requester, ONE);
        fake.depositBond(vault, id, requester, 2 * ONE);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 count;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == IFeeSplitVault.EscrowDisputed.selector) count++;
        }
        assertEq(count, 1, "EscrowDisputed once");
        (,,,,, disputed,) = vault.lockedTerms(id);
        assertTrue(disputed);
        assertEq(vault.bondBalance(id), 3 * ONE);
        assertEq(vault.totalBonds(), 3 * ONE);
    }

    function test_Bonds_Unchanged() public {
        bytes32 id = _open(1000 * ONE, 100, BOTH, 100);
        vm.expectRevert("Amount zero");
        fake.depositBond(vault, id, requester, 0);
        vm.expectRevert("Zero address");
        fake.depositBond(vault, id, address(0), ONE);

        fake.depositBond(vault, id, requester, 50 * ONE);
        assertEq(vault.remaining(id), 1000 * ONE, "a bond is not escrow principal");
        assertEq(vault.bondBalances(id), 50 * ONE);
        assertEq(vault.totalLocked(), 1000 * ONE);

        vm.expectRevert("Zero recipient");
        fake.releaseBond(vault, id, address(0), ONE);
        vm.expectRevert("Amount zero");
        fake.releaseBond(vault, id, provider, 0);
        vm.expectRevert("Insufficient bond");
        fake.releaseBond(vault, id, provider, 50 * ONE + 1);

        fake.releaseBond(vault, id, provider, 50 * ONE);
        assertEq(usdc.balanceOf(provider), 50 * ONE, "the whole bond, no fee");
        assertEq(usdc.balanceOf(integrator), 0);
        assertEq(vault.bondBalance(id), 0);
        assertEq(vault.totalBonds(), 0);
        _assertSolvent();
    }

    function test_Payout_NoFeeLogic() public {
        bytes32 id = _open(1000 * ONE, 1000, BOTH, 100);
        _dispute(id);
        vm.expectRevert("Zero recipient");
        fake.payout(vault, id, address(0), ONE);
        assertEq(fake.payout(vault, id, stranger, 100 * ONE), 100 * ONE);
        assertEq(usdc.balanceOf(stranger), 100 * ONE, "the full amount");
        assertEq(usdc.balanceOf(integrator), 0);
        assertEq(usdc.balanceOf(feeRecipient), 0);
        assertEq(uint8(_state(id)), uint8(IFeeSplitVault.TermsState.PENDING_CONFIRM), "no kernel read");
        (uint256 a, uint256 b, uint256 c, uint256 d, uint256 e) = vault.splitState(id);
        assertEq(a + b + c + d + e, 0);
        assertEq(vault.remaining(id), 900 * ONE);
    }

    // =====================================================================
    // Consent and registration
    // =====================================================================

    function test_Cap_Above1000_Reverts() public {
        assertEq(vault.MAX_INTEGRATOR_BPS(), 1000);
        vm.startPrank(provider);
        vm.expectRevert("Bps above cap");
        vault.setIntegratorApproval(integrator, 1001);
        vault.setIntegratorApproval(integrator, 1000);
        vm.stopPrank();
        assertEq(vault.integratorMaxBps(provider, integrator), 1000);

        vm.startPrank(requester);
        vm.expectRevert("Bps above cap");
        vault.setEscrowTerms(bytes32(uint256(77)), integrator, 1001, PAYOUT_ONLY);
        vm.expectRevert("Bps zero");
        vault.setEscrowTerms(bytes32(uint256(77)), integrator, 0, PAYOUT_ONLY);
        vm.expectRevert("Invalid escrow ID");
        vault.setEscrowTerms(bytes32(0), integrator, 100, PAYOUT_ONLY);
        vault.setEscrowTerms(bytes32(uint256(77)), integrator, 1000, PAYOUT_ONLY);
        vm.stopPrank();
    }

    function test_InvalidIntegrator_Reverts() public {
        address[5] memory bad = [address(0), requester, address(vault), address(fake), address(usdc)];
        for (uint256 i; i < bad.length; i++) {
            vm.startPrank(requester);
            vm.expectRevert("Invalid integrator");
            vault.setEscrowTerms(bytes32(uint256(77)), bad[i], 100, PAYOUT_ONLY);
            vm.expectRevert("Invalid integrator");
            vault.setIntegratorApproval(bad[i], 100);
            vm.stopPrank();
        }
        // The provider cannot be its own integrator: rejected when the escrow is created.
        bytes32 id = _id();
        fake.setTx(id, requester, provider, ONE, address(0), id, 100);
        vm.prank(requester);
        vault.setEscrowTerms(id, provider, 100, PAYOUT_ONLY);
        vm.expectRevert("Invalid integrator");
        fake.createEscrow(vault, id, requester, provider, ONE);
    }

    function test_PendingTerms_KeyedByRequester_OthersIgnored() public {
        bytes32 id = _id();
        fake.setTx(id, requester, provider, 1000 * ONE, address(0), id, 100);
        // A stranger registers terms for the requester's escrow id.
        vm.prank(stranger);
        vault.setEscrowTerms(id, integrator, 1000, BOTH);
        (address i, uint16 bps,) = vault.pendingTerms(stranger, id);
        assertEq(i, integrator);
        assertEq(bps, 1000);
        (i,,) = vault.pendingTerms(requester, id);
        assertEq(i, address(0));

        fake.createEscrow(vault, id, requester, provider, 1000 * ONE);
        assertEq(uint8(_state(id)), uint8(IFeeSplitVault.TermsState.NONE), "the stranger's terms are ignored");
        fake.payoutToProvider(vault, id, 990 * ONE);
        assertEq(usdc.balanceOf(provider), 990 * ONE);
        assertEq(usdc.balanceOf(integrator), 0);

        // Terms can no longer be registered for a used id; the requester can replace and clear its own.
        vm.prank(requester);
        vm.expectRevert("Escrow ID used");
        vault.setEscrowTerms(id, integrator, 100, PAYOUT_ONLY);
        bytes32 next = _id();
        vm.startPrank(requester);
        vm.expectRevert("No terms");
        vault.clearEscrowTerms(next);
        vault.setEscrowTerms(next, integrator, 100, PAYOUT_ONLY);
        vault.setEscrowTerms(next, integrator, 200, BOTH);
        IFeeSplitVault.FeeProfile profile;
        (i, bps, profile) = vault.pendingTerms(requester, next);
        assertEq(bps, 200);
        assertEq(uint8(profile), uint8(BOTH));
        vault.clearEscrowTerms(next);
        (i,,) = vault.pendingTerms(requester, next);
        assertEq(i, address(0));
        vm.stopPrank();
    }

    function test_CreateEscrow_ConsumesPendingAndLocks() public {
        bytes32 id = _open(1000 * ONE, 300, BOTH, 100);
        (address i,,) = vault.pendingTerms(requester, id);
        assertEq(i, address(0), "pending record consumed");
        (address li, uint16 bps, IFeeSplitVault.FeeProfile profile, IFeeSplitVault.TermsState state, uint16 p, bool disputed, bool used) =
            vault.lockedTerms(id);
        assertEq(li, integrator);
        assertEq(bps, 300);
        assertEq(uint8(profile), uint8(BOTH));
        assertEq(uint8(state), uint8(IFeeSplitVault.TermsState.PENDING_CONFIRM));
        assertEq(p, 0);
        assertFalse(disputed);
        assertTrue(used);

        // Early check: the transaction named by escrowId must match parties and amount and be unlinked.
        bytes32 bad = _id();
        vm.prank(requester);
        vault.setEscrowTerms(bad, integrator, 100, PAYOUT_ONLY);
        fake.setTx(bad, requester, provider, 2 * ONE, address(0), bad, 100);
        vm.expectRevert("Terms need txId escrowId");
        fake.createEscrow(vault, bad, requester, provider, ONE); // amount differs
        fake.setTx(bad, requester, provider, ONE, address(plain), bad, 100);
        vm.expectRevert("Terms need txId escrowId");
        fake.createEscrow(vault, bad, requester, provider, ONE); // already linked elsewhere
        fake.setTx(bad, stranger, provider, ONE, address(0), bad, 100);
        vm.expectRevert("Terms need txId escrowId");
        fake.createEscrow(vault, bad, requester, provider, ONE); // another requester's transaction
    }

    function test_EscrowIdReplay_Reverts() public {
        bytes32 id = _open(100 * ONE, 0, PAYOUT_ONLY, 100);
        vm.expectRevert("Escrow exists");
        fake.createEscrow(vault, id, requester, provider, 100 * ONE);
        fake.payoutToProvider(vault, id, 100 * ONE); // completes and deletes the record
        (,, uint256 amount,,) = vault.escrows(id);
        assertEq(amount, 0);
        vm.expectRevert("Escrow ID used");
        fake.createEscrow(vault, id, requester, provider, 100 * ONE);
    }

    function test_OnlyKernel_AllMutators() public {
        bytes32 id = _open(100 * ONE, 100, BOTH, 100);
        vm.startPrank(stranger);
        vm.expectRevert("Only kernel");
        vault.createEscrow(bytes32(uint256(99)), requester, provider, ONE);
        vm.expectRevert("Only kernel");
        vault.payoutToProvider(id, ONE);
        vm.expectRevert("Only kernel");
        vault.refundToRequester(id, ONE);
        vm.expectRevert("Only kernel");
        vault.payout(id, stranger, ONE);
        vm.expectRevert("Only kernel");
        vault.depositBond(id, requester, ONE);
        vm.expectRevert("Only kernel");
        vault.releaseBond(id, stranger, ONE);
        vm.stopPrank();
    }

    // =====================================================================
    // EscrowVault compatibility
    // =====================================================================

    function test_EscrowsGetter_TupleMatchesEscrowVault() public {
        bytes32 id = _open(1000 * ONE, 100, PAYOUT_ONLY, 100);
        fake.createEscrow(plain, id, requester, provider, 1000 * ONE);
        fake.payout(vault, id, stranger, 10 * ONE);
        fake.payout(plain, id, stranger, 10 * ONE);
        fake.depositBond(vault, id, requester, ONE);
        fake.depositBond(plain, id, requester, ONE);

        string[6] memory getters =
            ["escrows(bytes32)", "bondBalances(bytes32)", "remaining(bytes32)", "bondBalance(bytes32)", "token()", "kernel()"];
        for (uint256 i; i < getters.length; i++) {
            bytes memory call = i < 4 ? abi.encodeWithSignature(getters[i], id) : abi.encodeWithSignature(getters[i]);
            (bool okA, bytes memory a) = address(plain).staticcall(call);
            (bool okB, bytes memory b) = address(vault).staticcall(call);
            assertTrue(okA && okB);
            assertEq(a, b, getters[i]);
        }
        (address r, address pr, uint256 amount, uint256 released, bool active) = vault.escrows(id);
        assertEq(r, requester);
        assertEq(pr, provider);
        assertEq(amount, 1000 * ONE);
        assertEq(released, 10 * ONE);
        assertTrue(active);

        (bool isActive, uint256 escrowAmount) = vault.verifyEscrow(id, requester, provider, 1000 * ONE);
        (bool isActivePlain, uint256 escrowAmountPlain) = plain.verifyEscrow(id, requester, provider, 1000 * ONE);
        assertTrue(isActive && isActivePlain);
        assertEq(escrowAmount, escrowAmountPlain);
        (isActive,) = vault.verifyEscrow(id, stranger, provider, 1000 * ONE);
        assertFalse(isActive);
        (isActive,) = vault.verifyEscrow(id, requester, provider, 1000 * ONE + 1);
        assertFalse(isActive);
        assertEq(vault.remaining(bytes32(uint256(999))), 0);
    }

    function test_EscrowVaultSemantics_Reverts() public {
        vm.expectRevert("Zero address");
        new FeeSplitVault(address(0), address(fake));
        vm.expectRevert("Zero address");
        new FeeSplitVault(address(usdc), address(0));
        vm.expectRevert("Token and kernel must differ");
        new FeeSplitVault(address(usdc), address(usdc));

        bytes32 id = _id();
        vm.expectRevert("Zero address");
        fake.createEscrow(vault, id, address(0), provider, ONE);
        vm.expectRevert("Zero address");
        fake.createEscrow(vault, id, requester, address(0), ONE);
        vm.expectRevert("Amount zero");
        fake.createEscrow(vault, id, requester, provider, 0);
        vm.expectRevert("Escrow missing");
        fake.payoutToProvider(vault, id, ONE);
        vm.expectRevert("Escrow missing");
        fake.refundToRequester(vault, id, ONE);
        vm.expectRevert("Escrow inactive");
        fake.payout(vault, id, stranger, ONE);

        id = _open(100 * ONE, 100, BOTH, 100);
        vm.expectRevert("Amount zero");
        fake.payoutToProvider(vault, id, 0);
        vm.expectRevert("Insufficient escrow");
        fake.refundToRequester(vault, id, 100 * ONE + 1);
    }

    // =====================================================================
    // Refund side
    // =====================================================================

    function test_PreviewDisputeRefund_MatchesRule() public view {
        (uint256 r, uint256 pf, uint256 i) = vault.previewDisputeRefund(1000 * ONE, 100, 100);
        assertEq(r, 980 * ONE);
        assertEq(pf, 10 * ONE);
        assertEq(i, 10 * ONE);
        (r, pf, i) = vault.previewDisputeRefund(1000 * ONE, 100, 1000); // refund side capped at p
        assertEq(r, 980 * ONE);
        assertEq(i, 10 * ONE);
        (r, pf, i) = vault.previewDisputeRefund(1000 * ONE, 200, 100); // b below p
        assertEq(r, 970 * ONE);
        assertEq(pf, 20 * ONE);
        assertEq(i, 10 * ONE);
        (r, pf, i) = vault.previewDisputeRefund(600 * ONE, 100, 100);
        assertEq(r, 588 * ONE);
        (r, pf, i) = vault.previewDisputeRefund(999_999_901, 100, 100);
        assertEq(r, 979_999_903);
        assertEq(pf, 9_999_999);
        assertEq(i, 9_999_999);
        (r, pf, i) = vault.previewDisputeRefund(1000 * ONE, 100, 0);
        assertEq(r, 990 * ONE);
        assertEq(i, 0);
    }

    function test_PreviewDisputeRefund_RejectsBadRates() public {
        vm.expectRevert("Bad protocol bps");
        vault.previewDisputeRefund(ONE, 0, 100);
        vm.expectRevert("Bad protocol bps");
        vault.previewDisputeRefund(ONE, 501, 100);
        vm.expectRevert("Bps above cap");
        vault.previewDisputeRefund(ONE, 100, 1001);
    }

    /// @dev A single post-dispute refund of at least 2 units: both fees equal their floors, and the
    ///      integrator never receives more than the protocol.
    function testFuzz_RefundSide_SingleRefund_Exact(uint256 deposit, uint256 refund, uint16 b, uint16 p) public {
        deposit = bound(deposit, 2, 1e15);
        refund = bound(refund, 2, deposit);
        b = uint16(bound(b, 1, 1000));
        p = uint16(bound(p, 1, 500));
        bytes32 id = _open(deposit, b, BOTH, p);
        _dispute(id);
        (uint256 qr, uint256 qp, uint256 qi) = vault.quoteRefund(id, refund);
        uint256 before = usdc.balanceOf(requester);
        assertEq(fake.refundToRequester(vault, id, refund), refund, "returns the full amount");

        uint256 protocolFee = (refund * p) / 10_000;
        uint256 integratorFee = (refund * (b < p ? b : p)) / 10_000;
        assertEq(usdc.balanceOf(feeRecipient), protocolFee, "protocol fee equals its floor");
        assertEq(usdc.balanceOf(integrator), integratorFee, "integrator fee equals its floor");
        assertEq(usdc.balanceOf(requester) - before, refund - protocolFee - integratorFee);
        assertLe(integratorFee, protocolFee, "refund-side cap");
        assertEq(qr, refund - protocolFee - integratorFee);
        assertEq(qp, protocolFee);
        assertEq(qi, integratorFee);
        _assertSolvent();
    }

    /// @dev Arbitrary fragment sequences (not reachable through the kernel): each fee stays between
    ///      floor - 1 and floor of the cumulative refund, never above.
    function testFuzz_RefundSide_Fragments_BoundedDeficit(uint256 deposit, uint16 b, uint16 p, uint256[8] memory fragments)
        public
    {
        deposit = bound(deposit, 1, 1e12);
        b = uint16(bound(b, 1, 1000));
        p = uint16(bound(p, 1, 500));
        bytes32 id = _open(deposit, b, BOTH, p);
        _dispute(id);
        uint256 start = usdc.balanceOf(requester);
        uint256 total;
        for (uint256 i; i < fragments.length && total < deposit; i++) {
            // Small fragments are where the floors can step together.
            uint256 amount = bound(fragments[i], 1, i % 2 == 0 ? 3 : deposit - total);
            if (amount > deposit - total) amount = deposit - total;
            fake.refundToRequester(vault, id, amount);
            total += amount;
            uint256 protocolFloor = (total * p) / 10_000;
            uint256 integratorFloor = (total * (b < p ? b : p)) / 10_000;
            uint256 protocolFee = usdc.balanceOf(feeRecipient);
            uint256 integratorFee = usdc.balanceOf(integrator);
            assertLe(protocolFee, protocolFloor, "protocol fee never above its floor");
            assertLe(integratorFee, integratorFloor, "integrator fee never above its floor");
            assertGe(protocolFee + 1, protocolFloor, "protocol fee at most one unit below");
            assertGe(integratorFee + 1, integratorFloor, "integrator fee at most one unit below");
            assertEq(usdc.balanceOf(requester) - start + protocolFee + integratorFee, total, "nothing lost");
        }
    }

    function test_RefundSide_OneUnit_IntegratorGivesWayFirst() public {
        // p = b = 500: both floors step at 20 units. Refund 19, then 1.
        bytes32 id = _open(100, 500, BOTH, 500);
        _dispute(id);
        fake.refundToRequester(vault, id, 19);
        assertEq(usdc.balanceOf(feeRecipient) + usdc.balanceOf(integrator), 0);
        uint256 before = usdc.balanceOf(requester);
        fake.refundToRequester(vault, id, 1);
        assertEq(usdc.balanceOf(feeRecipient), 1, "the protocol fee is taken");
        assertEq(usdc.balanceOf(integrator), 0, "the integrator fee gives way");
        assertEq(usdc.balanceOf(requester), before);
        fake.refundToRequester(vault, id, 5); // the next refund catches up
        assertEq(usdc.balanceOf(integrator), 1);
        assertEq(usdc.balanceOf(feeRecipient), 1);
        assertEq(usdc.balanceOf(requester) - before, 4);
    }

    function test_ProtocolFee_RecipientUnavailable_Credits() public {
        // feeRecipient() reverts: the fee is credited, the refund goes through.
        fake.setFeeRecipient(feeRecipient, true);
        bytes32 id = _open(1000 * ONE, 100, BOTH, 100);
        _dispute(id);
        fake.refundToRequester(vault, id, 500 * ONE);
        assertEq(vault.protocolCredit(), 5 * ONE);
        // feeRecipient() returns zero.
        fake.setFeeRecipient(address(0), false);
        fake.refundToRequester(vault, id, 500 * ONE);
        assertEq(vault.protocolCredit(), 10 * ONE);
        assertEq(usdc.balanceOf(integrator), 10 * ONE);
        _assertSolvent();

        vm.expectRevert("Fee recipient unavailable");
        vault.withdrawProtocolCredit();
        fake.setFeeRecipient(feeRecipient, true);
        vm.expectRevert("Fee recipient unavailable");
        vault.withdrawProtocolCredit();
        assertEq(vault.protocolCredit(), 10 * ONE, "a reverted withdrawal changes nothing");

        fake.setFeeRecipient(feeRecipient, false);
        vm.prank(stranger);
        vault.withdrawProtocolCredit();
        assertEq(usdc.balanceOf(feeRecipient), 10 * ONE);
        assertEq(vault.protocolCredit(), 0);
        _assertSolvent();
    }

    // =====================================================================
    // Several escrows, one integrator
    // =====================================================================

    function test_MultiEscrow_SharedIntegrator_CountersAndBalances() public {
        bytes32 a = _open(1000 * ONE, 100, PAYOUT_ONLY, 100);
        bytes32 b = _open(2000 * ONE, 200, BOTH, 100);
        bytes32 c = _open(500 * ONE, 100, BOTH, 100);
        assertEq(vault.totalLocked(), 3500 * ONE);

        // a: first half pushed.
        fake.payoutToProvider(vault, a, 495 * ONE);
        _check(5 * ONE, 0, 0, 3005 * ONE);

        // Integrator blocked: b's whole provider side is credited, and completes while a is live.
        usdc.setBlocked(integrator, true);
        fake.payoutToProvider(vault, b, 1980 * ONE);
        fake.payout(vault, b, feeRecipient, 20 * ONE);
        _check(5 * ONE, 40 * ONE, 0, 1005 * ONE);
        (,, uint256 amount,,) = vault.escrows(b);
        assertEq(amount, 0, "b completed");

        // a: second half credited.
        fake.payoutToProvider(vault, a, 495 * ONE);
        _check(5 * ONE, 45 * ONE, 0, 510 * ONE);

        // c: disputed refund with the integrator blocked and the fee recipient blocked.
        usdc.setBlocked(feeRecipient, true);
        _dispute(c);
        fake.refundToRequester(vault, c, 500 * ONE);
        fake.releaseBond(vault, c, requester, ONE);
        _check(5 * ONE, 50 * ONE, 5 * ONE, 10 * ONE);

        // Unblocked: a later push succeeds while the old credit stays until withdrawn.
        usdc.setBlocked(integrator, false);
        bytes32 d = _open(1000 * ONE, 100, PAYOUT_ONLY, 100);
        fake.payoutToProvider(vault, d, 990 * ONE);
        _check(15 * ONE, 50 * ONE, 5 * ONE, 20 * ONE);

        vm.prank(stranger);
        vault.withdrawIntegratorCredit(integrator);
        _check(65 * ONE, 0, 5 * ONE, 20 * ONE);

        // The kernel's own fee legs finish a and d; the protocol credit is still owed.
        fake.payout(vault, a, stranger, 10 * ONE);
        fake.payout(vault, d, stranger, 10 * ONE);
        _check(65 * ONE, 0, 5 * ONE, 0);
        assertEq(usdc.balanceOf(address(vault)), 5 * ONE);
        usdc.setBlocked(feeRecipient, false);
        vault.withdrawProtocolCredit();
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    function _check(uint256 paid, uint256 credit, uint256 protocolCredit, uint256 locked) internal view {
        assertEq(usdc.balanceOf(integrator), paid, "integrator balance");
        assertEq(vault.integratorCredit(integrator), credit, "integrator credit");
        assertEq(vault.totalIntegratorCredit(), credit, "aggregate credit");
        assertEq(vault.protocolCredit(), protocolCredit, "protocol credit");
        assertEq(vault.totalLocked(), locked, "total locked");
        _assertSolvent();
    }
}
