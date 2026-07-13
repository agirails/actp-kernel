// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ACTPKernel} from "../src/ACTPKernel.sol";
import {EscrowVault} from "../src/escrow/EscrowVault.sol";
import {MockUSDC} from "../src/tokens/MockUSDC.sol";
import {IACTPKernel} from "../src/interfaces/IACTPKernel.sol";

/// @title AIP14cKernelGate — dedicated gate for the AIP-14c v2 kernel ABI surface.
/// @notice Pins the AIP-14c kernel changes so a regression trips here:
///   - 64-byte DELIVERED proof: empty/32-byte rejection, window boundaries {0,MIN-1,MIN,MAX,MAX+1},
///     zero-resultHash rejection, and resultHash storage in the view tuple.
///   - createTransaction gained `agreementHash` (7th arg): storage + view + event parity.
///   - kernelVersion() identity, and the pre-v2 8-arg createTransaction selector no longer resolves.
///   - terminal money-path conservation: a SETTLED transaction drains the escrow to zero (no residue).
contract AIP14cKernelGate is Test {
    ACTPKernel internal kernel;
    MockUSDC internal usdc;
    EscrowVault internal escrow;

    address internal admin = address(this);
    address internal feeCollector = address(0xFEE);
    address internal requester = address(0x1);
    address internal provider = address(0x2);

    uint256 internal constant ONE_USDC = 1_000_000;
    uint256 internal constant AMT = 1_000 * ONE_USDC; // $1000

    // Mirror of IACTPKernel.TransactionCreated (AIP-14c: trailing agreementHash).
    event TransactionCreated(
        bytes32 indexed transactionId,
        address indexed requester,
        address indexed provider,
        uint256 amount,
        bytes32 serviceHash,
        uint256 deadline,
        uint256 timestamp,
        uint256 agentId,
        bytes32 agreementHash
    );

    function setUp() public {
        usdc = new MockUSDC();
        kernel = new ACTPKernel(admin, admin, feeCollector, address(0), address(usdc), 1 hours);
        escrow = new EscrowVault(address(usdc), address(kernel));
        kernel.approveEscrowVault(address(escrow), true);
        usdc.mint(requester, 10_000_000 * ONE_USDC);
        usdc.mint(provider, 10_000_000 * ONE_USDC);
    }

    /// create (INITIATED) → linkEscrow (COMMITTED) → IN_PROGRESS; ready for a DELIVERED transition.
    function _inProgress(bytes32 agreementHash) internal returns (bytes32 txId) {
        vm.prank(requester);
        txId = kernel.createTransaction(
            provider, requester, AMT, block.timestamp + 30 days, 2 days, keccak256("svc"), agreementHash, 0, 0
        );
        vm.startPrank(requester);
        usdc.approve(address(escrow), type(uint256).max);
        kernel.linkEscrow(txId, address(escrow), txId);
        vm.stopPrank();
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");
    }

    function _deliverExpectRevert(bytes32 txId, bytes memory proof, bytes memory reason) internal {
        vm.prank(provider);
        vm.expectRevert(reason);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, proof);
    }

    // ── kernelVersion identity ────────────────────────────────────────────────
    function testKernelVersion() external view {
        assertEq(kernel.kernelVersion(), keccak256("ACTP_KERNEL_V2_AIP14C_REV2"), "kernelVersion pinned");
    }

    // ── DELIVERED proof gate: only the 64-byte (window,resultHash) tuple is accepted ──
    function testDeliveredRejectsEmptyProof() external {
        _deliverExpectRevert(_inProgress(bytes32(0)), "", "Delivery proof must be (window,resultHash)");
    }

    function testDeliveredRejects32ByteProof() external {
        _deliverExpectRevert(
            _inProgress(bytes32(0)), abi.encode(uint256(2 days)), "Delivery proof must be (window,resultHash)"
        );
    }

    function testDeliveredRejectsZeroResultHash() external {
        _deliverExpectRevert(
            _inProgress(bytes32(0)), abi.encode(uint256(2 days), bytes32(0)), "resultHash required"
        );
    }

    // ── window boundaries {0, MIN-1, MIN, MAX, MAX+1} ─────────────────────────
    function testDeliveredWindowZeroReverts() external {
        _deliverExpectRevert(
            _inProgress(bytes32(0)), abi.encode(uint256(0), keccak256("r")), "Dispute window too short"
        );
    }

    function testDeliveredWindowBelowMinReverts() external {
        _deliverExpectRevert(
            _inProgress(bytes32(0)),
            abi.encode(kernel.MIN_DISPUTE_WINDOW() - 1, keccak256("r")),
            "Dispute window too short"
        );
    }

    function testDeliveredWindowAtMinAccepted() external {
        bytes32 txId = _inProgress(bytes32(0));
        uint256 t = block.timestamp;
        uint256 minWindow = kernel.MIN_DISPUTE_WINDOW();
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(minWindow, keccak256("r")));
        assertEq(kernel.getTransaction(txId).disputeWindow, t + minWindow, "window at MIN accepted");
    }

    function testDeliveredWindowAtMaxAccepted() external {
        bytes32 txId = _inProgress(bytes32(0));
        uint256 t = block.timestamp;
        uint256 maxWindow = kernel.MAX_DISPUTE_WINDOW();
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(maxWindow, keccak256("r")));
        assertEq(kernel.getTransaction(txId).disputeWindow, t + maxWindow, "window at MAX accepted");
    }

    function testDeliveredWindowAboveMaxReverts() external {
        _deliverExpectRevert(
            _inProgress(bytes32(0)),
            abi.encode(kernel.MAX_DISPUTE_WINDOW() + 1, keccak256("r")),
            "Dispute window too long"
        );
    }

    // ── resultHash storage + view tuple ───────────────────────────────────────
    function testDeliveredStoresResultHash() external {
        bytes32 txId = _inProgress(bytes32(0));
        bytes32 rh = keccak256("the-deliverable");
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(uint256(2 days), rh));
        assertEq(kernel.getTransaction(txId).resultHash, rh, "resultHash stored + surfaced in the view tuple");
    }

    // ── agreementHash storage / view / event parity ───────────────────────────
    function testCreateStoresAndEmitsAgreementHash() external {
        bytes32 ah = keccak256("request+input+SLA");
        // event parity: requester+provider topics + full data (incl. trailing agreementHash); tx id unchecked.
        vm.expectEmit(false, true, true, true);
        emit TransactionCreated(
            bytes32(0), requester, provider, AMT, keccak256("svc"), block.timestamp + 30 days, block.timestamp, 0, ah
        );
        vm.prank(requester);
        bytes32 txId = kernel.createTransaction(
            provider, requester, AMT, block.timestamp + 30 days, 2 days, keccak256("svc"), ah, 0, 0
        );
        // storage/view parity
        assertEq(kernel.getTransaction(txId).agreementHash, ah, "agreementHash stored + surfaced in the view tuple");
    }

    function testAgreementHashZeroIsPermittedOnChain() external {
        // agreementHash == 0 is legal at the kernel level (the "no automatic AI ruling" signal is an
        // OFF-CHAIN evaluator rule per AIP-14c D3, not a kernel guard).
        bytes32 txId = _inProgress(bytes32(0));
        assertEq(kernel.getTransaction(txId).agreementHash, bytes32(0), "agreementHash 0 stored, not rejected on-chain");
    }

    // ── the pre-v2 8-arg createTransaction selector must no longer resolve ─────
    function testOldCreateTransactionSelectorRejected() external {
        bytes4 oldSel =
            bytes4(keccak256("createTransaction(address,address,uint256,uint256,uint256,bytes32,uint256,uint256)"));
        bytes memory data = abi.encodeWithSelector(
            oldSel, provider, requester, AMT, block.timestamp + 30 days, uint256(2 days), keccak256("svc"), uint256(0), uint256(0)
        );
        vm.prank(requester);
        (bool ok,) = address(kernel).call(data);
        assertFalse(ok, "pre-v2 8-arg createTransaction selector must not resolve on the v2 kernel");
    }

    // ── terminal money-path conservation: SETTLED drains the escrow to zero ────
    function testSettleDrainsEscrowToZero() external {
        bytes32 txId = _inProgress(bytes32(0));
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(uint256(2 days), keccak256("r")));
        vm.prank(requester);
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, "");
        assertEq(escrow.remaining(txId), 0, "conservation: escrow fully drained on SETTLED (provider net + fee)");
        assertEq(usdc.balanceOf(address(kernel)), 0, "conservation: no fee dust stranded on the kernel");
    }
}
