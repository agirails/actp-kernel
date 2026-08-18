// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/ACTPKernel.sol";
import "../../src/tokens/MockUSDC.sol";
import "../../src/escrow/EscrowVault.sol";
import {IACTPKernel} from "../../src/interfaces/IACTPKernel.sol";

/// @notice ERC20 that REVERTS a transfer to a blacklisted address — models a fee-recipient/token
///         incompatibility (e.g. a real-USDC blacklist) so the platform-fee payout strands in escrow.
contract BlacklistUSDC {
    string public constant name = "Blacklist USDC";
    string public constant symbol = "bUSDC";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public blocked;
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    function setBlocked(address a, bool b) external { blocked[a] = b; }
    function mint(address to, uint256 amount) external { totalSupply += amount; balanceOf[to] += amount; emit Transfer(address(0), to, amount); }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; emit Approval(msg.sender, s, a); return true; }
    function transfer(address to, uint256 a) external returns (bool) { _t(msg.sender, to, a); return true; }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        require(al >= a, "Allowance");
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        _t(f, to, a); return true;
    }
    function _t(address f, address to, uint256 a) internal {
        require(to != address(0), "Zero address");
        require(!blocked[to], "USDC: recipient blocked"); // the strand trigger
        require(balanceOf[f] >= a, "Balance");
        balanceOf[f] -= a; balanceOf[to] += a;
        emit Transfer(f, to, a);
    }
}

/// @title F17F59_FeeAccounting — regression for the two deferred economic findings, now landed.
/// F59: milestone fragmentation must not multiply the MIN_FEE floor (aggregate fee accounting).
/// F17: a stranded platform fee must NOT be repriced/re-paid to the provider on a releaseEscrow retry.
contract F17F59_FeeAccounting is Test {
    ACTPKernel internal kernel;
    EscrowVault internal escrow;

    address internal requester = address(0x1);
    address internal provider = address(0x2);
    address internal feeCollector = address(0xFEE);

    uint256 internal constant MIN_FEE = 50_000; // $0.05

    // ── F59: real MockUSDC ──
    MockUSDC internal usdc;

    function setUp() external {
        usdc = new MockUSDC();
        kernel = new ACTPKernel(address(this), address(this), feeCollector, address(0), address(usdc), 1 hours);
        escrow = new EscrowVault(address(usdc), address(kernel));
        kernel.approveEscrowVault(address(escrow), true);
        usdc.mint(requester, 1_000_000_000);
    }

    function _mkInProgress(bytes32 salt, uint256 amount) internal returns (bytes32 txId) {
        vm.prank(requester);
        txId = kernel.createTransaction(provider, requester, amount, block.timestamp + 30 days, 1 hours, keccak256("svc"), bytes32(0), 0, 0);
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.QUOTED, "");
        vm.startPrank(requester);
        usdc.approve(address(escrow), amount);
        kernel.linkEscrow(txId, address(escrow), salt);
        vm.stopPrank();
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");
    }

    // ── F59: two half-milestone releases split IDENTICALLY to one full release (floor once) ──
    function test_F59_FragmentationDoesNotMultiplyFloor() external {
        // $6 escrow: a $3 fragment's bps fee (30k) is below MIN_FEE (50k) → the floor would trigger
        // per-fragment under the old per-payout accounting.
        uint256 ESCROW = 6_000_000;

        // Partition A — single full release.
        uint256 pA0 = usdc.balanceOf(provider);
        uint256 fA0 = usdc.balanceOf(feeCollector);
        bytes32 a = _mkInProgress(keccak256("A"), ESCROW);
        vm.prank(requester);
        kernel.releaseMilestone(a, ESCROW);
        uint256 provA = usdc.balanceOf(provider) - pA0;
        uint256 feeA = usdc.balanceOf(feeCollector) - fA0;

        // Partition B — two half releases (the fragmentation attack).
        uint256 pB0 = usdc.balanceOf(provider);
        uint256 fB0 = usdc.balanceOf(feeCollector);
        bytes32 b = _mkInProgress(keccak256("B"), ESCROW);
        vm.prank(requester);
        kernel.releaseMilestone(b, ESCROW / 2);
        vm.prank(requester);
        kernel.releaseMilestone(b, ESCROW / 2);
        uint256 provB = usdc.balanceOf(provider) - pB0;
        uint256 feeB = usdc.balanceOf(feeCollector) - fB0;

        // The invariant: economically-equivalent partitions pay the provider and the platform the same.
        assertEq(provB, provA, "F59: fragmented provider net == single-release net");
        assertEq(feeB, feeA, "F59: fragmented fee == single-release fee");
        // Floor charged ONCE: total fee == max(bps*ESCROW, MIN_FEE) = 60000, NOT 2*50000 (old bug).
        assertEq(feeA, 60_000, "aggregate fee = max(bps*gross, MIN_FEE), floor once");
        assertEq(provA, ESCROW - 60_000, "provider net = gross - aggregate fee");
        // Solvency: nothing created/destroyed across the two fragments.
        assertEq(provB + feeB, ESCROW, "conservation across fragments");
    }

    // ── F59: a sub-floor micro-transaction is unchanged by fragmentation (whole amount is fee) ──
    function test_F59_SubFloorMicroMilestoneUnchanged() external {
        uint256 ESCROW = 80_000; // < 2*MIN_FEE; bps fee tiny → floor clamps to gross
        uint256 p0 = usdc.balanceOf(provider);
        uint256 f0 = usdc.balanceOf(feeCollector);
        bytes32 t = _mkInProgress(keccak256("micro"), ESCROW);
        vm.prank(requester);
        kernel.releaseMilestone(t, 40_000);
        vm.prank(requester);
        kernel.releaseMilestone(t, 40_000);
        uint256 prov = usdc.balanceOf(provider) - p0;
        uint256 fee = usdc.balanceOf(feeCollector) - f0;
        // Whole escrow is fee (each fragment below the floor; aggregate floor 50k clamps to 80k gross).
        assertEq(fee, 50_000, "aggregate floor charged once, not per-fragment");
        assertEq(prov, ESCROW - 50_000, "provider gets the remainder above the single floor");
        assertEq(prov + fee, ESCROW, "conservation");
    }
}

/// @notice F17 needs a token that strands the fee payout — separate suite with BlacklistUSDC.
contract F17_StrandedFee is Test {
    ACTPKernel internal kernel;
    EscrowVault internal escrow;
    BlacklistUSDC internal usdc;

    address internal requester = address(0x1);
    address internal provider = address(0x2);
    address internal feeCollector = address(0xFEE);

    function setUp() external {
        usdc = new BlacklistUSDC();
        kernel = new ACTPKernel(address(this), address(this), feeCollector, address(0), address(usdc), 1 hours);
        escrow = new EscrowVault(address(usdc), address(kernel));
        kernel.approveEscrowVault(address(escrow), true);
        usdc.mint(requester, 1_000_000_000);
    }

    function _settledWithStrandedFee(uint256 amount) internal returns (bytes32 txId) {
        vm.prank(requester);
        txId = kernel.createTransaction(provider, requester, amount, block.timestamp + 30 days, 1 hours, keccak256("svc"), bytes32(0), 0, 0);
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.QUOTED, "");
        vm.startPrank(requester);
        usdc.approve(address(escrow), amount);
        kernel.linkEscrow(txId, address(escrow), txId); // escrowId == txId (ACTP convention)
        vm.stopPrank();
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(uint256(1 hours), keccak256("result")));
        // Block the feeRecipient so the fee payout strands in escrow during settlement.
        usdc.setBlocked(feeCollector, true);
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, "");
    }

    function test_F17_StrandedFeeNotRepricedToProvider() external {
        uint256 ESCROW = 6_000_000; // fee = 60000
        bytes32 txId = _settledWithStrandedFee(ESCROW);

        // Provider got net; the 60000 fee stranded in escrow (feeRecipient blocked).
        uint256 provAfterSettle = usdc.balanceOf(provider);
        uint256 stranded = escrow.remaining(txId);
        assertEq(stranded, 60_000, "fee stranded in escrow");
        assertEq(provAfterSettle, ESCROW - 60_000, "provider paid net only");

        // F17: a permissionless releaseEscrow RETRY must NOT re-pay the provider from the stranded fee.
        kernel.releaseEscrow(txId);
        assertEq(usdc.balanceOf(provider), provAfterSettle, "F17: provider NOT re-paid the stranded fee");
        assertEq(escrow.remaining(txId), 60_000, "fee still stranded (feeRecipient still blocked)");

        // Once the feeRecipient is healthy, the fee routes to it (never to the provider).
        usdc.setBlocked(feeCollector, false);
        kernel.releaseEscrow(txId);
        assertEq(usdc.balanceOf(provider), provAfterSettle, "F17: provider still not paid the fee");
        assertEq(usdc.balanceOf(feeCollector), 60_000, "stranded fee recovered to the fee recipient");
        assertEq(escrow.remaining(txId), 0, "escrow fully drained to the correct sink");
    }

    // ── F17 on the DISPUTED settlement path (escrowProviderPaid must be set there too) ──
    function test_F17_DisputedStrandedFeeNotRepriced() external {
        uint256 amount = 6_000_000;
        vm.prank(requester);
        bytes32 txId = kernel.createTransaction(provider, requester, amount, block.timestamp + 30 days, 1 hours, keccak256("svc"), bytes32(0), 0, 0);
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.QUOTED, "");
        vm.startPrank(requester);
        usdc.approve(address(escrow), type(uint256).max);
        kernel.linkEscrow(txId, address(escrow), txId);
        vm.stopPrank();
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(uint256(1 hours), keccak256("result")));
        // Requester opens a dispute.
        vm.prank(requester);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");

        // Admin (this contract) settles all-to-provider; feeRecipient blocked → the fee strands.
        usdc.setBlocked(feeCollector, true);
        uint256 rem = escrow.remaining(txId);
        bytes memory proof = abi.encode(uint256(0), rem, false); // requester 0, provider rem, providerAtFault false
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, proof);

        uint256 provAfter = usdc.balanceOf(provider);
        assertGt(escrow.remaining(txId), 0, "fee stranded on the disputed settlement");

        // F17: retry must route the stranded fee to the fee sink, never re-pay the provider.
        kernel.releaseEscrow(txId);
        assertEq(usdc.balanceOf(provider), provAfter, "F17 disputed: provider NOT re-paid the stranded fee");

        usdc.setBlocked(feeCollector, false);
        kernel.releaseEscrow(txId);
        assertEq(usdc.balanceOf(provider), provAfter, "F17 disputed: provider still not paid the fee");
        assertGt(usdc.balanceOf(feeCollector), 0, "stranded fee recovered to the fee recipient");
        assertEq(escrow.remaining(txId), 0, "escrow drained to the correct sink");
    }

    // ── BUG 2 (adversarial-verify edge): a fee stranded DURING a milestone must not be repriced to
    //    the provider at final settle — the settle pays only the unpaid principal. ──
    function test_F17_MilestoneStrandedFeeNotRepricedAtSettle() external {
        uint256 ESCROW = 100_000; // $0.10; a $0.06 milestone's bps fee is below MIN_FEE → floor
        vm.prank(requester);
        bytes32 txId = kernel.createTransaction(provider, requester, ESCROW, block.timestamp + 30 days, 1 hours, keccak256("svc"), bytes32(0), 0, 0);
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.QUOTED, "");
        vm.startPrank(requester);
        usdc.approve(address(escrow), type(uint256).max);
        kernel.linkEscrow(txId, address(escrow), txId);
        vm.stopPrank();
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");

        // Milestone release with a BLOCKED feeRecipient → the 50k floor fee strands in escrow.
        usdc.setBlocked(feeCollector, true);
        vm.prank(requester);
        kernel.releaseMilestone(txId, 60_000); // fee 50000 strands, provider nets 10000

        // Deliver + settle. The stranded milestone fee must NOT be paid to the provider.
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(uint256(1 hours), keccak256("result")));
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, "");

        // Provider got: 10000 (milestone net) + 40000 (unpaid principal at settle) = 50000. NOT 100000.
        assertEq(usdc.balanceOf(provider), 50_000, "BUG2: provider paid only principal, not the stranded fee");
        assertEq(escrow.remaining(txId), 50_000, "the stranded fee stays in escrow (feeRecipient blocked)");

        // Once healthy, the whole 50k fee routes to the fee recipient — never the provider.
        usdc.setBlocked(feeCollector, false);
        kernel.releaseEscrow(txId);
        assertEq(usdc.balanceOf(provider), 50_000, "BUG2: provider still 50000 (no fee leak)");
        assertEq(usdc.balanceOf(feeCollector), 50_000, "aggregate fee recovered to the fee recipient");
        assertEq(escrow.remaining(txId), 0, "escrow drained; total split = 50000 provider + 50000 fee");
    }
}
