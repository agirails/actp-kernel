// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/ACTPKernel.sol";
import "../../src/tokens/MockUSDC.sol";
import "../../src/escrow/EscrowVault.sol";
import "../../src/registry/AgentRegistry.sol";
import "../../src/treasury/ArchiveTreasury.sol";
import {IACTPKernel} from "../../src/interfaces/IACTPKernel.sol";
import {IAgentRegistry} from "../../src/interfaces/IAgentRegistry.sol";

/// @notice Stub registry that ALWAYS reverts on the ONLY selector the kernel invokes
///         (updateReputationOnSettlement). Deliberately does NOT inherit IAgentRegistry — the kernel
///         only ever calls this one selector on the dispute path, so a full interface is unnecessary
///         and would just add untested surface. Proves the kernel's `try {gas:150000} catch {}`
///         swallows a reverting registry so the dispute still settles (F-7 swallow requirement).
contract RevertingRegistry {
    function updateReputationOnSettlement(address, bytes32, uint256, bool) external pure {
        revert("registry boom");
    }
}

/// @notice Stub registry whose updateReputationOnSettlement BURNS past the 150k gas cap (OOG).
///         The kernel forwards exactly {gas:150000}; this consumes it all, modelling an out-of-gas
///         reputation leg. The catch{} must still swallow it.
contract OOGRegistry {
    function updateReputationOnSettlement(address, bytes32, uint256, bool) external view {
        // Burn well past the 150k forwarded stipend so the sub-call OOGs.
        uint256 i;
        while (gasleft() > 1000) {
            i += 1; // keep the loop non-empty so the optimizer cannot elide it
        }
        require(i == 0, "unreachable"); // never reached; the loop OOGs first
    }
}

/// @notice Stub treasury whose receiveFunds ALWAYS reverts — exercises the kernel's H-1 try/catch
///         fallback that redirects the archive fee to feeRecipient. Only `receiveFunds` is invoked
///         by the kernel, so a full IArchiveTreasury is unnecessary.
contract RevertingTreasury {
    function receiveFunds(uint256) external pure {
        revert("treasury boom");
    }
}

/// @title DisputeMoneyPathCoverage — closes the audit's production-wired money-path coverage gaps.
/// @notice The audit (F-7 + archive-split INFO + #891-893 LOW) flagged that EVERY dispute test wires
///         address(0) for both the AgentRegistry and the ArchiveTreasury, so the production reputation
///         leg, the `_distributeFee` archive split + H-1 fallback, and the CANCELLED-path paid-mediator
///         approval guards are never exercised on a dispute path. This suite wires the REAL contracts.
contract DisputeMoneyPathCoverage is Test {
    ACTPKernel internal kernel;
    MockUSDC internal usdc;
    EscrowVault internal escrow;
    AgentRegistry internal registry;
    ArchiveTreasury internal treasury;

    address internal admin = address(this);
    address internal pauser = address(0xFA053);
    address internal feeCollector = address(0xFEE);
    address internal requester = address(0x1);
    address internal provider = address(0x2);
    address internal mediator = address(0x33ED);
    address internal uploader = address(0x09704D);

    uint256 internal constant ONE_USDC = 1_000_000;
    uint256 internal constant AMT = 1_000 * ONE_USDC; // $1000

    // Mirror events for expectEmit.
    event ReputationUpdated(address indexed agent, uint256 oldScore, uint256 newScore, bytes32 indexed txId, uint256 timestamp);
    event ArchiveTreasuryFailed(bytes32 indexed transactionId, uint256 amount, bytes reason);
    event FundsReceived(address indexed from, uint256 amount);

    // ─────────────────────────────────────────────────────────────────────────
    // Wiring helpers — build a kernel with a chosen registry + treasury.
    // ─────────────────────────────────────────────────────────────────────────
    function _deploy(address registryAddr) internal {
        usdc = new MockUSDC();
        kernel = new ACTPKernel(admin, pauser, feeCollector, registryAddr, address(usdc), 1 hours);
        escrow = new EscrowVault(address(usdc), address(kernel));
        kernel.approveEscrowVault(address(escrow), true);
        usdc.mint(requester, 1_000_000 * ONE_USDC);
        usdc.mint(provider, 1_000_000 * ONE_USDC);
    }

    /// Deploy a kernel (registry=0), then wire a REAL AgentRegistry via the 2-day governance timelock
    /// (the production path — the registry needs the kernel address, which only exists post-deploy).
    function _deployWithRealRegistry() internal {
        _deploy(address(0));
        registry = new AgentRegistry(address(kernel));
        kernel.scheduleAgentRegistryUpdate(address(registry));
        vm.warp(block.timestamp + 2 days + 1);
        kernel.executeAgentRegistryUpdate();
        assertEq(address(kernel.agentRegistry()), address(registry), "registry wired");
    }

    function _registerProvider() internal {
        IAgentRegistry.ServiceDescriptor[] memory services = new IAgentRegistry.ServiceDescriptor[](1);
        services[0] = IAgentRegistry.ServiceDescriptor({
            serviceTypeHash: keccak256(abi.encodePacked("text-generation")),
            serviceType: "text-generation",
            schemaURI: "",
            minPrice: 0,
            maxPrice: 0,
            avgCompletionTime: 0,
            metadataCID: ""
        });
        vm.prank(provider);
        registry.registerAgent("https://provider.example", services);
    }

    /// Drive a fresh tx to DISPUTED.
    function _disputed() internal returns (bytes32 txId) {
        vm.prank(requester);
        txId = kernel.createTransaction(provider, requester, AMT, block.timestamp + 30 days, 2 days, keccak256("svc"), bytes32(0), 0, 0);
        vm.startPrank(requester);
        usdc.approve(address(escrow), type(uint256).max);
        kernel.linkEscrow(txId, address(escrow), txId);
        vm.stopPrank();
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(uint256(10 days), keccak256("result")));
        vm.prank(requester);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");
    }

    // =========================================================================
    // F-7: reputation leg fires once with correct fault attribution.
    // =========================================================================

    /// providerAtFault = TRUE → disputedTransactions increments; reputation leg fires exactly once.
    function test_F7_ReputationLeg_ProviderAtFault_FiresOnce() external {
        _deployWithRealRegistry();
        _registerProvider();

        bytes32 txId = _disputed();

        // All-to-requester SETTLED proof with providerAtFault = true (96-byte SETTLED branch).
        bytes memory proof = abi.encode(AMT, uint256(0), true);

        // Reputation update fires exactly once for the provider on this txId.
        vm.expectEmit(true, false, false, false);
        emit ReputationUpdated(provider, 0, 0, txId, 0);
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, proof);

        IAgentRegistry.AgentProfile memory p = registry.getAgent(provider);
        assertEq(p.totalTransactions, 1, "reputation: total tx counted once");
        assertEq(p.disputedTransactions, 1, "reputation: providerAtFault recorded as a disputed tx");
        assertEq(p.totalVolumeUSDC, AMT, "reputation: volume credited");

        // C-2 dedup: the kernel stamped reputationProcessedBy → a re-process is impossible.
        assertEq(kernel.reputationProcessedBy(txId), address(registry), "C-2: reputation processed-by stamped");
    }

    /// providerAtFault = FALSE (provider wins) → totalTransactions++ but NOT disputedTransactions.
    /// Proves the dispute path passes `providerAtFault`, NOT `wasDisputed` (which is always true here).
    function test_F7_ReputationLeg_ProviderNotAtFault_NoDisputedIncrement() external {
        _deployWithRealRegistry();
        _registerProvider();

        bytes32 txId = _disputed();

        // All-to-provider SETTLED proof with providerAtFault = false (provider wins the dispute).
        bytes memory proof = abi.encode(uint256(0), AMT, false);
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, proof);

        IAgentRegistry.AgentProfile memory p = registry.getAgent(provider);
        assertEq(p.totalTransactions, 1, "reputation: total tx counted once");
        assertEq(
            p.disputedTransactions,
            0,
            "reputation: provider NOT at fault => disputedTransactions stays 0 (providerAtFault, not wasDisputed)"
        );
        assertGt(p.reputationScore, 0, "reputation: a clean (not-at-fault) dispute win still scores");
    }

    /// A REVERTING registry is swallowed: the dispute STILL settles, funds still move.
    function test_F7_RevertingRegistry_IsSwallowed_DisputeStillSettles() external {
        RevertingRegistry rr = new RevertingRegistry();
        _deploy(address(rr));

        bytes32 txId = _disputed();
        uint256 provBefore = usdc.balanceOf(provider);

        // Provider wins; reputation leg WILL revert inside try{} but must be swallowed.
        bytes memory proof = abi.encode(uint256(0), AMT, false);
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, proof);

        assertEq(
            uint8(kernel.getTransaction(txId).state),
            uint8(IACTPKernel.State.SETTLED),
            "dispute settled despite reverting registry (catch{} swallowed)"
        );
        assertGt(usdc.balanceOf(provider), provBefore, "provider paid despite reverting registry");
        assertEq(escrow.remaining(txId), 0, "escrow fully released");
        // C-2 stamp is still written before the external call, so a registry swap cannot re-fire it.
        assertEq(kernel.reputationProcessedBy(txId), address(rr), "C-2 stamp written before the swallowed call");
    }

    /// An OUT-OF-GAS registry (burns past the {gas:150000} cap) is also swallowed.
    function test_F7_OOGRegistry_IsSwallowed_DisputeStillSettles() external {
        OOGRegistry oog = new OOGRegistry();
        _deploy(address(oog));

        bytes32 txId = _disputed();
        uint256 provBefore = usdc.balanceOf(provider);

        bytes memory proof = abi.encode(uint256(0), AMT, false);
        // Forward plenty of gas so ONLY the capped sub-call OOGs, not the whole tx.
        kernel.transitionState{gas: 3_000_000}(txId, IACTPKernel.State.SETTLED, proof);

        assertEq(
            uint8(kernel.getTransaction(txId).state),
            uint8(IACTPKernel.State.SETTLED),
            "dispute settled despite OOG reputation leg (gas-capped + catch{})"
        );
        assertGt(usdc.balanceOf(provider), provBefore, "provider paid despite OOG registry");
    }

    // =========================================================================
    // Archive-split + H-1 treasury-failure fallback on a dispute settlement.
    // =========================================================================

    /// A real ArchiveTreasury receives the 0.1% archive cut of the platform fee on a dispute payout.
    function test_ArchiveSplit_RealTreasury_ReceivesCut_OnDispute() external {
        _deploy(address(0));
        treasury = new ArchiveTreasury(address(usdc), address(kernel), uploader);
        kernel.setArchiveTreasury(address(treasury));

        bytes32 txId = _disputed();

        // Provider wins the full escrow → fee charged → _distributeFee archive split fires.
        // fee = max(1% of $1000 = $10, $0.05) = $10 ; archiveFee = $10 * 10bps / 10000 = $0.01 = 10_000.
        uint256 fee = (AMT * kernel.platformFeeBps()) / kernel.MAX_BPS();
        uint256 expectedArchive = (fee * kernel.ARCHIVE_ALLOCATION_BPS()) / kernel.MAX_BPS();
        assertGt(expectedArchive, 0, "archive cut must be non-zero for a meaningful test");

        bytes memory proof = abi.encode(uint256(0), AMT, false); // all-to-provider
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, proof);

        assertEq(treasury.totalReceived(), expectedArchive, "archive treasury received the 0.1% cut on a dispute settlement");
        assertEq(usdc.balanceOf(address(treasury)), expectedArchive, "treasury holds the archive cut");
        // Remainder of the fee went to the fee recipient.
        assertEq(usdc.balanceOf(feeCollector), fee - expectedArchive, "feeRecipient received the rest of the fee");
    }

    /// H-1 fallback + AIP-14c double-fee fix: a REVERTING treasury must NOT brick settlement. The archive
    /// cut is redirected to feeRecipient, the dispute still settles, and the escrow is FULLY DRAINED — the
    /// treasuryFee is now sized as (totalFee − amount ACTUALLY removed from escrow), so the remainder is
    /// paid from the vault and the FULL fee reaches feeRecipient. NO residue is stranded (the pre-fix bug
    /// double-counted the archive slice, leaving ~$9.99 recoverable via releaseEscrow — asserted gone below).
    function test_ArchiveSplit_H1_TreasuryFailure_RedirectsToFeeRecipient() external {
        _deploy(address(0));
        RevertingTreasury rt = new RevertingTreasury();
        kernel.setArchiveTreasury(address(rt));

        bytes32 txId = _disputed();

        uint256 fee = (AMT * kernel.platformFeeBps()) / kernel.MAX_BPS();
        uint256 expectedArchive = (fee * kernel.ARCHIVE_ALLOCATION_BPS()) / kernel.MAX_BPS();

        // Account for ALL USDC before settlement to prove conservation (no loss anywhere).
        uint256 supplyBefore = usdc.totalSupply();

        bytes memory proof = abi.encode(uint256(0), AMT, false);

        // The H-1 fallback emits ArchiveTreasuryFailed, then redirects the archive cut to feeRecipient.
        vm.expectEmit(true, false, false, false);
        emit ArchiveTreasuryFailed(txId, expectedArchive, "");
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, proof);

        // Dispute settled — a reverting treasury did NOT brick the settlement.
        assertEq(
            uint8(kernel.getTransaction(txId).state),
            uint8(IACTPKernel.State.SETTLED),
            "dispute settled despite reverting treasury (H-1 fallback)"
        );

        // AIP-14c double-fee fix: the FULL platform fee reaches feeRecipient — the archive cut redirected
        // from the kernel's balance PLUS the remaining treasury portion paid from the vault. Previously the
        // archive slice was double-counted (subtracted as if it stayed in escrow while it had already been
        // redirected out), so only the ~$0.01 cut arrived and ~$9.99 stranded in escrow (recoverable by the
        // provider via releaseEscrow).
        assertEq(usdc.balanceOf(feeCollector), fee, "AIP-14c: full fee reaches feeRecipient (archive redirect + treasury)");
        // The reverting treasury received nothing (its receiveFunds reverted; approval was cleared).
        assertEq(usdc.balanceOf(address(rt)), 0, "reverting treasury received nothing");

        // CONSERVATION: total USDC supply unchanged — the H-1 fallback loses NOTHING (no burn, no strand-to-zero).
        assertEq(usdc.totalSupply(), supplyBefore, "H-1: no USDC lost - full conservation");
        // The kernel's transient archive balance was flushed to feeRecipient (no dust left on the kernel).
        assertEq(usdc.balanceOf(address(kernel)), 0, "H-1: no archive dust stranded on the kernel");
        // AIP-14c double-fee fix: the escrow vault is fully drained — NO fee residue stranded (the exact bug
        // this closes: the archive slice was subtracted twice, leaving ~$9.99 recoverable via releaseEscrow).
        assertEq(escrow.remaining(txId), 0, "AIP-14c: escrow fully drained, no fee stranded");
    }

    // =========================================================================
    // CANCELLED-path paid-mediator approval guards (#891-893) — negative test.
    // =========================================================================

    /// An UNAPPROVED paid mediator named in a CANCELLED resolution proof must revert at #938.
    function test_CancelledGuard_UnapprovedMediator_Reverts() external {
        _deploy(address(0));
        bytes32 txId = _disputed();

        // 128-byte legacy CANCELLED proof with a NON-approved paid mediator (mediatorAmount > 0).
        bytes memory proof = abi.encode(
            uint256(500 * ONE_USDC), // requesterAmount
            uint256(400 * ONE_USDC), // providerAmount
            mediator,                // UNAPPROVED paid mediator
            uint256(100 * ONE_USDC)  // mediatorAmount
        );

        vm.expectRevert("Mediator not approved");
        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, proof);
    }

    /// An APPROVED-BUT-PENDING (timelock not elapsed) paid mediator must revert at #939.
    function test_CancelledGuard_ApprovalPendingMediator_Reverts() external {
        _deploy(address(0));
        // Approve the mediator NOW; its mediatorApprovedAt is block.timestamp + 2 days (pending).
        kernel.approveMediator(mediator, true);

        bytes32 txId = _disputed();

        bytes memory proof = abi.encode(
            uint256(500 * ONE_USDC),
            uint256(400 * ONE_USDC),
            mediator,                // approved but the 2-day timelock has NOT elapsed
            uint256(100 * ONE_USDC)
        );

        vm.expectRevert("Mediator approval pending");
        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, proof);
    }

    /// CONTROL: once the timelock elapses, the SAME CANCELLED paid-mediator proof settles cleanly.
    function test_CancelledGuard_ApprovedAndTimelocked_PaysMediator() external {
        _deploy(address(0));
        kernel.approveMediator(mediator, true);

        bytes32 txId = _disputed();
        vm.warp(block.timestamp + 2 days + 1); // clear the mediator approval timelock

        uint256 medBefore = usdc.balanceOf(mediator);
        bytes memory proof = abi.encode(
            uint256(500 * ONE_USDC),
            uint256(400 * ONE_USDC),
            mediator,
            uint256(100 * ONE_USDC)
        );
        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, proof);

        assertEq(
            uint8(kernel.getTransaction(txId).state),
            uint8(IACTPKernel.State.CANCELLED),
            "approved+timelocked mediator CANCELLED resolution settles"
        );
        assertEq(usdc.balanceOf(mediator) - medBefore, 100 * ONE_USDC, "paid mediator received its cut on the CANCELLED path");
    }
}
