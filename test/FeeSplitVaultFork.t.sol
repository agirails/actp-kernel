// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {FeeSplitTestBase} from "./helpers/FeeSplitTestBase.sol";
import {ACTPKernel} from "../src/ACTPKernel.sol";
import {CompositeMediator} from "../src/CompositeMediator.sol";
import {BondEscalation} from "../src/BondEscalation.sol";
import {EscrowVault} from "../src/escrow/EscrowVault.sol";
import {FeeSplitVault} from "../src/escrow/FeeSplitVault.sol";
import {ArchiveTreasury} from "../src/treasury/ArchiveTreasury.sol";
import {IFeeSplitVault} from "../src/interfaces/IFeeSplitVault.sol";
import {IACTPKernel} from "../src/interfaces/IACTPKernel.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IFiatToken {
    function blacklister() external view returns (address);
    function blacklist(address account) external;
    function unBlacklist(address account) external;
    function isBlacklisted(address account) external view returns (bool);
}

/// @dev True when `name` is set to something other than the .env.example placeholder.
abstract contract ForkEnv is FeeSplitTestBase {
    function _configured(string memory name) internal view returns (bool) {
        string memory value = vm.envOr(name, string(""));
        return bytes(value).length > 0 && keccak256(bytes(value)) != keccak256("https://YOUR_GATEWAY");
    }
}

/// @title FeeSplitVaultForkMainnet — real USDC behavior only (plan step 4a).
/// @notice Deploys the candidate kernel, both vaults and the resolver stack of this revision onto a
///         Base mainnet fork and runs A3, A9 (B), A12, A15, A16 and A17 with real USDC blacklisting.
///         The live mainnet v1 kernel is not used: it is unsupported.
/// @dev    Runs when BASE_MAINNET_RPC is set; without it every test skips. A skip is not a pass.
contract FeeSplitVaultForkMainnet is ForkEnv {
    address internal constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    bool internal active;

    function setUp() public {
        if (!_configured("BASE_MAINNET_RPC")) return;
        vm.createSelectFork(vm.envString("BASE_MAINNET_RPC"));
        feeRecipient = makeAddr("fsv fee recipient");
        requester = makeAddr("fsv requester");
        provider = makeAddr("fsv provider");
        integrator = makeAddr("fsv integrator");
        keeper = makeAddr("fsv keeper");
        paidMediator = makeAddr("fsv paid mediator");
        stranger = makeAddr("fsv stranger");
        _setUpStack();
        active = true;
    }

    modifier onFork() {
        if (!active) {
            vm.skip(true, "BASE_MAINNET_RPC not set");
            return;
        }
        _;
    }

    function _token() internal pure override returns (address) {
        return BASE_USDC;
    }

    function _mint(address to, uint256 amount) internal override {
        deal(BASE_USDC, to, amount);
    }

    function _setBlocked(address who, bool blocked) internal override {
        vm.prank(IFiatToken(BASE_USDC).blacklister());
        if (blocked) IFiatToken(BASE_USDC).blacklist(who);
        else IFiatToken(BASE_USDC).unBlacklist(who);
        assertEq(IFiatToken(BASE_USDC).isBlacklisted(who), blocked);
    }

    function test_Mainnet_A3_Settle() public onFork {
        _a3(PAYOUT_ONLY);
        _a3(BOTH);
    }

    function test_Mainnet_A9_RequesterWins_Both() public onFork {
        _a9(BOTH, 100);
    }

    function test_Mainnet_A12_RequesterCancelsAfterDeadline_Penalty() public onFork {
        _a12(PAYOUT_ONLY);
    }

    function test_Mainnet_A15_IntegratorBlacklisted_Credited() public onFork {
        _setBlocked(integrator, true);

        Bal memory b = _snap();
        bytes32 txId = _open(1000 * ONE, 100, PAYOUT_ONLY);
        _deliverAndSettle(txId);
        Exp memory x = _settled1000();
        x.platformCredited = 10 * ONE;
        _assertOutcome(b, x, "A15 as A3");

        b = _snap();
        txId = _open(1000 * ONE, 100, BOTH);
        _deliverAndDispute(txId, requester);
        _rule(txId, 1, 0);
        x = _a9Row(BOTH);
        x.platformCredited = 10 * ONE;
        _assertOutcome(b, x, "A15 as B-A9");
    }

    function test_Mainnet_A16_FeeRecipientBlacklisted_FinalizationSucceeds() public onFork {
        _setBlocked(feeRecipient, true);
        Bal memory b = _snap();
        bytes32 txId = _open(1000 * ONE, 100, BOTH);
        _deliverAndDispute(txId, requester);
        _rule(txId, 1, 0);
        assertEq(uint8(kernel.getTransaction(txId).state), uint8(IACTPKernel.State.SETTLED));
        Exp memory x = _a9Row(BOTH);
        x.protocolCredited = 10 * ONE;
        _assertOutcome(b, x, "A16");
    }

    function test_Mainnet_A17_UnblockAndWithdraw() public onFork {
        _setBlocked(integrator, true);
        _setBlocked(feeRecipient, true);
        bytes32 txId = _open(1000 * ONE, 100, BOTH);
        _deliverAndDispute(txId, requester);
        _rule(txId, 1, 0);
        assertEq(vault.integratorCredit(integrator), 10 * ONE);
        assertEq(vault.protocolCredit(), 10 * ONE);

        // Still blacklisted: the withdrawals revert and change nothing.
        vm.expectRevert();
        vault.withdrawIntegratorCredit(integrator);
        vm.expectRevert();
        vault.withdrawProtocolCredit();
        assertEq(vault.totalIntegratorCredit(), 10 * ONE);
        assertEq(vault.protocolCredit(), 10 * ONE);

        _setBlocked(integrator, false);
        _setBlocked(feeRecipient, false);
        uint256 integratorBefore = usdc.balanceOf(integrator);
        uint256 feeBefore = usdc.balanceOf(feeRecipient);
        vm.startPrank(stranger);
        vault.withdrawIntegratorCredit(integrator);
        vault.withdrawProtocolCredit();
        vm.stopPrank();
        assertEq(usdc.balanceOf(integrator) - integratorBefore, 10 * ONE, "to the integrator only");
        assertEq(usdc.balanceOf(feeRecipient) - feeBefore, 10 * ONE, "to the fee recipient only");
        assertEq(usdc.balanceOf(stranger), 0);
        assertEq(usdc.balanceOf(address(vault)), 0);
        _assertSolvent("A17");
    }
}

/// @notice Tests that run against an already deployed candidate stack: plan step 4b (basics) and the
///         step 12 FORK set. They touch the stack only through its addresses and through cheatcodes
///         (`vm.prank` of the stack's own admin and pauser, `vm.warp`, `vm.mockCallRevert`), so the
///         same bodies run on a fork of the Phase B deployment and on a stack deployed in the test.
abstract contract FeeSplitDeployedSuite is ForkEnv {
    bool internal active;
    bool internal deployed; // bound to an existing deployment: fund actors with `deal`
    string internal skipReason;
    bytes32 internal probeTx;

    function _mint(address to, uint256 amount) internal override {
        if (deployed) deal(address(usdc), to, amount);
        else super._mint(to, amount);
    }

    modifier onStack() {
        if (!active) {
            vm.skip(true, skipReason);
            return;
        }
        _;
    }

    function _admin() internal {
        vm.prank(kernel.admin());
    }

    /// @dev A transfer of the token to `who` reverts until the mocks are cleared. The Sepolia token is
    ///      a mintable mock that cannot block a recipient, so a failed push can only be simulated.
    function _mockBlocked(address who) internal {
        vm.mockCallRevert(address(usdc), abi.encodeWithSelector(IERC20.transfer.selector, who), "blocked");
    }
}

abstract contract FeeSplitDeployedBasics is FeeSplitDeployedSuite {
    function test_Fork_A3_Settle() public onStack {
        _a3(PAYOUT_ONLY);
        _a3(BOTH);
    }

    function test_Fork_A7_Split600_400_Both() public onStack {
        _a7(BOTH);
    }

    function test_Fork_A9_RequesterWins_Both() public onStack {
        _a9(BOTH, 100);
    }

    /// @dev The vault's decoding of the kernel view, field by field, on a real transaction.
    function test_Fork_KernelViewProbe_MatchesGetTransaction() public onStack {
        bytes32 txId = probeTx;
        if (txId == bytes32(0)) txId = _open(1000 * ONE, 100, BOTH);
        IACTPKernel.TransactionView memory t = kernel.getTransaction(txId);
        (bool ok, address r, address p, uint256 amount, address escrowContract, bytes32 escrowId, uint16 protocolBps) =
            vault.kernelViewProbe(txId);
        assertTrue(ok, "probe ok");
        assertEq(r, t.requester);
        assertEq(p, t.provider);
        assertEq(amount, t.amount);
        assertEq(escrowContract, t.escrowContract);
        assertEq(escrowId, t.escrowId);
        assertEq(protocolBps, t.platformFeeBpsLocked);
    }
}

/// @notice The step 12 FORK set: rows that cannot be shown live on Base Sepolia.
abstract contract FeeSplitDeployedForkSet is FeeSplitDeployedSuite {
    /// @dev (1) A15, A16, A17. Reason for FORK: the Sepolia token cannot make a transfer fail.
    function test_ForkSet1_A15_A16_A17_FailedPushes_Credits_Withdrawals() public onStack {
        uint256 integratorCredit = vault.integratorCredit(integrator);
        uint256 protocolCredit = vault.protocolCredit();

        // A15: integrator push fails, as A3 and as B-A9.
        _mockBlocked(integrator);
        Bal memory b = _snap();
        bytes32 txId = _open(1000 * ONE, 100, PAYOUT_ONLY);
        _deliverAndSettle(txId);
        Exp memory x = _settled1000();
        x.platformCredited = 10 * ONE;
        _assertOutcome(b, x, "A15 as A3");

        b = _snap();
        txId = _open(1000 * ONE, 100, BOTH);
        _deliverAndDispute(txId, requester);
        _rule(txId, 1, 0);
        x = _a9Row(BOTH);
        x.platformCredited = 10 * ONE;
        _assertOutcome(b, x, "A15 as B-A9");
        vm.clearMockedCalls();

        // A16: fee recipient push fails; finalization succeeds.
        address recipient = kernel.feeRecipient();
        _mockBlocked(recipient);
        b = _snap();
        txId = _open(1000 * ONE, 100, BOTH);
        _deliverAndDispute(txId, requester);
        _rule(txId, 1, 0);
        assertEq(uint8(kernel.getTransaction(txId).state), uint8(IACTPKernel.State.SETTLED));
        x = _a9Row(BOTH);
        x.protocolCredited = 10 * ONE;
        _assertOutcome(b, x, "A16");

        // A17: while the push still fails the withdrawal reverts and changes nothing.
        vm.expectRevert();
        vault.withdrawProtocolCredit();
        assertEq(vault.protocolCredit() - protocolCredit, 10 * ONE);
        vm.clearMockedCalls();

        uint256 integratorBefore = usdc.balanceOf(integrator);
        uint256 recipientBefore = usdc.balanceOf(recipient);
        vm.startPrank(stranger);
        vault.withdrawIntegratorCredit(integrator);
        vault.withdrawProtocolCredit();
        vm.stopPrank();
        assertEq(usdc.balanceOf(integrator) - integratorBefore, integratorCredit + 20 * ONE, "to the integrator only");
        assertEq(usdc.balanceOf(recipient) - recipientBefore, protocolCredit + 10 * ONE, "to the fee recipient only");
        assertEq(usdc.balanceOf(stranger), 0);
        assertEq(vault.integratorCredit(integrator), 0);
        assertEq(vault.protocolCredit(), 0);
    }

    /// @dev (2) A25. Reason for FORK: forceResolveStale needs 30 days after the dispute opened.
    function test_ForkSet2_A25_ForcedSplit_BondReturned() public onStack {
        _approveIntegrator(1000);
        Bal memory b = _snap();
        bytes32 txId = _open(1000 * ONE, 1000, BOTH);
        _deliverAndDispute(txId, requester);
        _forceStale(txId);
        assertEq(uint8(kernel.getTransaction(txId).state), uint8(IACTPKernel.State.CANCELLED));
        _assertOutcome(b, _a25Row(), "A25");
    }

    /// @dev (3) Resolution while the kernel is paused. Reason for FORK: needs a pause of the shared kernel.
    function test_ForkSet3_ResolveWhilePaused_SameAmounts() public onStack {
        _a7(BOTH); // unpaused reference row

        Bal memory b = _snap();
        bytes32 txId = _open(1000 * ONE, 100, BOTH);
        _deliverAndDispute(txId, requester);
        vm.prank(kernel.pauser());
        kernel.pause();
        _rule(txId, 2, 4000);
        assertTrue(kernel.paused(), "resolved while paused");
        vm.prank(kernel.pauser());
        kernel.unpause();
        _assertOutcome(b, _a7Row(BOTH), "A7 (B) while paused");
    }

    /// @dev (4) Emergency revocation rehearsal. Reason for FORK: needs the kernel paused for the 2-day
    ///      timelock. Order: pause, counters, schedule, wait, execute, unpause. An in-flight escrow
    ///      exits through a pause-exempt path first; credits stay withdrawable afterwards.
    function test_ForkSet4_EmergencyRevocationRehearsal() public onStack {
        uint256 lockedBefore = vault.totalLocked();
        uint256 bondsBefore = vault.totalBonds();
        emit log_named_uint("totalLocked before the rehearsal (the live procedure needs 0)", lockedBefore);
        emit log_named_uint("totalBonds before the rehearsal (the live procedure needs 0)", bondsBefore);

        // A credit from a failed integrator push, left unwithdrawn.
        _mockBlocked(integrator);
        bytes32 settled = _open(1000 * ONE, 100, PAYOUT_ONLY);
        _deliverAndSettle(settled);
        vm.clearMockedCalls();
        uint256 credit = vault.integratorCredit(integrator);
        assertGe(credit, 10 * ONE);

        // An in-flight disputed escrow, and a transaction that is not linked yet.
        Bal memory b = _snap();
        bytes32 inFlight = _open(1000 * ONE, 100, BOTH);
        _deliverAndDispute(inFlight, requester);
        bytes32 unlinked = _create(1000 * ONE);

        // (1) pause
        vm.prank(kernel.pauser());
        kernel.pause();
        // (2) counters are not back to where they were: the party exits through a pause-exempt path
        assertEq(vault.totalLocked(), lockedBefore + 1000 * ONE);
        assertEq(vault.totalBonds(), bondsBefore + 50 * ONE);
        address recipient = kernel.feeRecipient();
        _mockBlocked(recipient); // the protocol fee of this exit becomes a credit
        _rule(inFlight, 1, 0);
        vm.clearMockedCalls();
        Exp memory x = _a9Row(BOTH);
        x.protocolCredited = 10 * ONE;
        _assertOutcome(b, x, "in-flight exit under pause");
        assertEq(vault.totalLocked(), lockedBefore, "the in-flight escrow left the vault");
        assertEq(vault.totalBonds(), bondsBefore);
        // (3) schedule
        _admin();
        kernel.scheduleEscrowVaultRevocation(address(vault));
        // (4) stay paused for the timelock: nothing can be linked into the vault
        vm.startPrank(requester);
        usdc.approve(address(vault), 1000 * ONE);
        vm.expectRevert("Kernel paused");
        kernel.linkEscrow(unlinked, address(vault), unlinked);
        vm.stopPrank();
        vm.warp(block.timestamp + 2 days);
        // (5) execute, permissionless
        vm.prank(stranger);
        kernel.executeEscrowVaultRevocation(address(vault));
        assertFalse(kernel.approvedEscrowVaults(address(vault)));
        assertEq(vault.totalLocked(), lockedBefore, "nothing was funded during the window");
        // (6) unpause
        vm.prank(kernel.pauser());
        kernel.unpause();
        vm.prank(requester);
        vm.expectRevert("Escrow not approved");
        kernel.linkEscrow(unlinked, address(vault), unlinked);

        // Credits do not need the kernel's approval of the vault.
        uint256 integratorBefore = usdc.balanceOf(integrator);
        uint256 recipientBefore = usdc.balanceOf(recipient);
        uint256 protocolCredit = vault.protocolCredit();
        vault.withdrawIntegratorCredit(integrator);
        vault.withdrawProtocolCredit();
        assertEq(usdc.balanceOf(integrator) - integratorBefore, credit);
        assertEq(usdc.balanceOf(recipient) - recipientBefore, protocolCredit);
        assertGe(protocolCredit, 10 * ONE);
    }

    /// @dev (5) The vault uses the rate the transaction locked, not the live one. Reason for FORK:
    ///      needs the 2-day economic-parameter timelock on the shared kernel.
    function test_ForkSet5_LockedProtocolRate_AfterFeeChange() public onStack {
        uint256 locked = kernel.platformFeeBps();
        uint16 changed = locked == 200 ? 300 : 200;
        bytes32 txId = _create(1000 * ONE); // locks the current rate

        (,,, bool pending) = kernel.getPendingEconomicParams();
        if (pending) {
            _admin();
            kernel.cancelEconomicParamsUpdate();
        }
        uint16 penalty = kernel.requesterPenaltyBps();
        _admin();
        kernel.scheduleEconomicParams(changed, penalty);
        vm.warp(block.timestamp + 2 days);
        kernel.executeEconomicParamsUpdate();
        assertEq(kernel.platformFeeBps(), changed);

        _terms(txId, 100, PAYOUT_ONLY);
        _link(txId, address(vault));
        _start(txId);
        uint256 before = usdc.balanceOf(integrator);
        _milestone(txId, 500 * ONE);
        uint256 providerSide = 500 * ONE - (500 * ONE * locked) / 10_000;
        assertEq(usdc.balanceOf(integrator) - before, (providerSide * 100) / (10_000 - locked), "locked rate");
        (,,,, uint16 protocolBps,,) = vault.lockedTerms(txId);
        assertEq(protocolBps, locked);
        assertTrue((providerSide * 100) / (10_000 - changed) != (providerSide * 100) / (10_000 - locked), "rates differ");
    }
}

/// @dev Binds the suites to the Phase B deployment on a Base Sepolia fork. Addresses come from the
///      environment (`foundry.toml` grants no read access to deployments/base-sepolia.json):
///      FEESPLIT_FORK_KERNEL, FEESPLIT_FORK_VAULT, FEESPLIT_FORK_PLAIN_VAULT, FEESPLIT_FORK_MEDIATOR,
///      FEESPLIT_FORK_BOND, and optionally FEESPLIT_FORK_BLOCK and FEESPLIT_FORK_PROBE_TX.
///      Without BASE_SEPOLIA_RPC or FEESPLIT_FORK_KERNEL every test skips. A skip is not a pass.
abstract contract SepoliaForkStack is FeeSplitDeployedSuite {
    function setUp() public {
        if (!_configured("BASE_SEPOLIA_RPC")) {
            skipReason = "BASE_SEPOLIA_RPC not set";
            return;
        }
        if (!_configured("FEESPLIT_FORK_KERNEL")) {
            skipReason = "FEESPLIT_FORK_KERNEL not set: the candidate stack is not deployed on Base Sepolia";
            return;
        }
        uint256 forkBlock = vm.envOr("FEESPLIT_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(vm.envString("BASE_SEPOLIA_RPC"));
        else vm.createSelectFork(vm.envString("BASE_SEPOLIA_RPC"), forkBlock);
        emit log_named_uint("fork block", block.number);

        kernel = ACTPKernel(vm.envAddress("FEESPLIT_FORK_KERNEL"));
        vault = FeeSplitVault(vm.envAddress("FEESPLIT_FORK_VAULT"));
        plain = EscrowVault(vm.envAddress("FEESPLIT_FORK_PLAIN_VAULT"));
        mediator = CompositeMediator(vm.envAddress("FEESPLIT_FORK_MEDIATOR"));
        bondEscalation = BondEscalation(vm.envAddress("FEESPLIT_FORK_BOND"));
        probeTx = vm.envOr("FEESPLIT_FORK_PROBE_TX", bytes32(0));
        require(vault.kernel() == address(kernel), "vault is not this kernel's");
        require(address(bondEscalation.compositeMediator()) == address(mediator), "bond is not this mediator's");
        usdc = IERC20(address(kernel.USDC()));
        archive = ArchiveTreasury(kernel.archiveTreasury());
        feeRecipient = kernel.feeRecipient();
        deployed = true;

        requester = makeAddr("fsv fork requester");
        provider = makeAddr("fsv fork provider");
        integrator = makeAddr("fsv fork integrator");
        keeper = makeAddr("fsv fork keeper");
        stranger = makeAddr("fsv fork stranger");
        _fundActors();
        vm.prank(keeper);
        usdc.approve(address(bondEscalation), type(uint256).max);
        _approveIntegrator(100);
        active = true;
    }
}

contract FeeSplitVaultForkSepolia is SepoliaForkStack, FeeSplitDeployedBasics {}

contract FeeSplitVaultForkSepoliaAcceptance is SepoliaForkStack, FeeSplitDeployedForkSet {}

/// @notice The same bodies against a stack deployed in the test, so that the fork suites are known to
///         work before the Phase B deployment exists. Not fork evidence.
contract FeeSplitVaultAcceptanceLocal is FeeSplitDeployedBasics, FeeSplitDeployedForkSet {
    function setUp() public {
        _setUpStack();
        active = true;
    }
}
