// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ACTPKernel.sol";
import "../src/tokens/MockUSDC.sol";
import "../src/escrow/EscrowVault.sol";

/// @title ResolverAuthTest — P0-4: DISPUTED → SETTLED/CANCELLED resolver-auth symmetry + timelock.
/// @notice Verifies the P0-3 change at BOTH kernel locations:
///         - `_enforceAuthorization` (the SETTLED path)
///         - `_handleCancellation`   (the CANCELLED/split path)
///         Resolver set = {admin} ∪ {approved mediator past its 2-day timelock}. Per decision G1
///         (AIP14B-DECISIONS.md) the pauser is NOT a resolver.
///
///         SYMMETRY (verified by mutation 2026-06-21): site 1 (_enforceAuthorization) gates BOTH
///         SETTLED and CANCELLED; site 2 (_handleCancellation) is the additional CANCELLED-path check.
///         Reverting site 1 to admin-only fails BOTH TimelockedMediator tests; reverting site 2 fails
///         only CanCancel. Either way, deleting a P0-3 edit makes >=1 test fail — both must allow the
///         mediator or the CANCELLED/split resolution breaks.
contract ResolverAuthTest is Test {
    using stdStorage for StdStorage;

    ACTPKernel kernel;
    MockUSDC usdc;
    EscrowVault escrow;

    address admin = address(this);
    address pauser = address(0xFA053);
    address requester = address(0x1);
    address provider = address(0x2);
    address mediatorAddr = address(0x3);
    address rando = address(0xBAD);
    address feeCollector = address(0xFEE);

    uint256 constant ONE_USDC = 1_000_000;
    uint256 constant TRANSACTION_AMOUNT = 1_000 * ONE_USDC;

    function setUp() external {
        usdc = new MockUSDC();
        kernel = new ACTPKernel(admin, pauser, feeCollector, address(0), address(usdc), 1 hours);
        escrow = new EscrowVault(address(usdc), address(kernel));
        kernel.approveEscrowVault(address(escrow), true);
        usdc.mint(requester, 100_000 * ONE_USDC);
        usdc.mint(provider, 100_000 * ONE_USDC);
    }

    // ----- valid full-distribution proofs (sender is what we vary; proof is always valid) -----
    function _settleProof() internal pure returns (bytes memory) {
        // all to provider, providerAtFault = false
        return abi.encode(uint256(0), TRANSACTION_AMOUNT, false);
    }

    function _cancelProof() internal pure returns (bytes memory) {
        // all refunded to requester (128-byte legacy form, matches AIP14 cancel tests)
        return abi.encode(TRANSACTION_AMOUNT, uint256(0), address(0), uint256(0));
    }

    // =========================================================================
    // HAPPY PATH — admin (always a resolver, INV-6)
    // =========================================================================

    function test_Admin_CanSettle() external {
        bytes32 txId = _disputed();
        vm.warp(block.timestamp + 2 days + 1);
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, _settleProof());
        assertEq(uint8(kernel.getTransaction(txId).state), uint8(IACTPKernel.State.SETTLED));
    }

    function test_Admin_CanCancel() external {
        bytes32 txId = _disputed();
        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, _cancelProof());
        assertEq(uint8(kernel.getTransaction(txId).state), uint8(IACTPKernel.State.CANCELLED));
    }

    // =========================================================================
    // HAPPY PATH — approved + timelocked mediator (the SYMMETRY proof)
    // =========================================================================

    function test_TimelockedMediator_CanSettle() external {
        bytes32 txId = _disputed();
        kernel.approveMediator(mediatorAddr, true); // mediatorApprovedAt = now + 2 days
        vm.warp(block.timestamp + 2 days + 1); // past the timelock
        vm.prank(mediatorAddr);
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, _settleProof());
        assertEq(uint8(kernel.getTransaction(txId).state), uint8(IACTPKernel.State.SETTLED));
    }

    function test_TimelockedMediator_CanCancel() external {
        bytes32 txId = _disputed();
        kernel.approveMediator(mediatorAddr, true);
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(mediatorAddr);
        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, _cancelProof());
        assertEq(uint8(kernel.getTransaction(txId).state), uint8(IACTPKernel.State.CANCELLED));
    }

    // =========================================================================
    // REVERTS — non-resolvers rejected at BOTH locations
    // =========================================================================

    /// @notice Mediator approved but timelock not yet elapsed → rejected.
    function test_PreTimelockMediator_Reverts() external {
        bytes32 txId = _disputed();
        kernel.approveMediator(mediatorAddr, true); // approvedAt = now + 2 days
        // no warp: timelock active
        vm.prank(mediatorAddr);
        vm.expectRevert("Resolver only");
        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, _cancelProof());
    }

    /// @notice Random address cannot settle (location 1). Warp removes any timing confound.
    function test_Random_Reverts_Settle() external {
        bytes32 txId = _disputed();
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(rando);
        vm.expectRevert("Resolver only");
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, _settleProof());
    }

    /// @notice Random address cannot cancel (location 2).
    function test_Random_Reverts_Cancel() external {
        bytes32 txId = _disputed();
        vm.prank(rando);
        vm.expectRevert("Resolver only");
        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, _cancelProof());
    }

    /// @notice G1 decision: the pauser is intentionally NOT a resolver.
    function test_Pauser_NotResolver_Reverts() external {
        bytes32 txId = _disputed();
        vm.prank(pauser);
        vm.expectRevert("Resolver only");
        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, _cancelProof());
    }

    /// @notice A revoked mediator (approvedMediators == false) is rejected.
    function test_RevokedMediator_Reverts() external {
        bytes32 txId = _disputed();
        kernel.approveMediator(mediatorAddr, true);
        vm.warp(block.timestamp + 2 days + 1);
        kernel.approveMediator(mediatorAddr, false); // revoke
        vm.prank(mediatorAddr);
        vm.expectRevert("Resolver only");
        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, _cancelProof());
    }

    /// @notice SAFETY BELT (`approvedAt != 0`): an inconsistent (approved == true, approvedAt == 0)
    ///         state — reachable only via a storage/migration path — must still be rejected.
    ///         Without the `approvedAt != 0` guard this would pass (block.timestamp >= 0 is always true).
    function test_InconsistentApprovedState_Reverts_SafetyBelt() external {
        bytes32 txId = _disputed();
        kernel.approveMediator(mediatorAddr, true); // approved == true, approvedAt = now + 2 days
        // Force the abnormal state: zero the timelock while keeping approved == true.
        stdstore.target(address(kernel)).sig("mediatorApprovedAt(address)").with_key(mediatorAddr).checked_write(
            uint256(0)
        );
        assertEq(kernel.mediatorApprovedAt(mediatorAddr), 0);
        assertTrue(kernel.approvedMediators(mediatorAddr));
        vm.warp(block.timestamp + 2 days + 1); // even past the would-be timelock, the approvedAt==0 guard blocks
        vm.prank(mediatorAddr);
        vm.expectRevert("Resolver only");
        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, _cancelProof());
    }

    // =========================================================================
    // helper: create a transaction and drive it to DISPUTED
    // =========================================================================
    function _disputed() internal returns (bytes32 txId) {
        vm.prank(requester);
        txId = kernel.createTransaction(
            provider, requester, TRANSACTION_AMOUNT, block.timestamp + 30 days, 2 days, keccak256("service"), bytes32(0), 0, 0
        );

        vm.startPrank(requester);
        usdc.approve(address(escrow), TRANSACTION_AMOUNT);
        kernel.linkEscrow(txId, address(escrow), txId);
        vm.stopPrank();

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(10 days, keccak256("result")));

        uint256 bond = (TRANSACTION_AMOUNT * kernel.disputeBondBps()) / kernel.MAX_BPS();
        vm.startPrank(requester);
        usdc.approve(address(escrow), bond);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");
        vm.stopPrank();
    }
}
