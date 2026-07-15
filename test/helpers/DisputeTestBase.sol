// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/ACTPKernel.sol";
import "../../src/CompositeMediator.sol";
import "../../src/BondEscalation.sol";
import "../../src/tokens/MockUSDC.sol";
import "../../src/escrow/EscrowVault.sol";
import {IACTPKernel} from "../../src/interfaces/IACTPKernel.sol";
import {ICompositeMediator} from "../../src/interfaces/ICompositeMediator.sol";
import {AIRuling} from "../../src/interfaces/DisputeTypes.sol";
import {MockOOV3} from "../mocks/MockOOV3.sol";

/// @title DisputeTestBase — wires the full AIP-14b dispute stack for BondEscalation tests.
/// @notice Deploys MockUSDC + ACTPKernel + EscrowVault + CompositeMediator + BondEscalation and
///         performs the same resolver-auth wiring CompositeMediatorTest uses (approveMediator +
///         2-day timelock warp). A MockOOV3 is injected as the BondEscalation `UMA_OOV3` immutable
///         (testability override, §8.4) so Tier-2 escalation/callbacks are exercised without
///         vm.etch — the mock keeps its assertion storage for lookups and does real bond custody.
///
///         Helpers:
///           _createDisputed()      — drives a fresh tx to DISPUTED (mirrors ResolverAuth.t.sol).
///           _makeEvaluators()      — seeds the 2 fixed + 1 rotating evaluators (addr + privkey).
///           _signRuling(r, pk)     — EIP-712 signature over an AIRuling matching BondEscalation's
///                                    DOMAIN_SEPARATOR / RULING_TYPEHASH.
abstract contract DisputeTestBase is Test {
    // ----- core stack -----
    ACTPKernel internal kernel;
    MockUSDC internal usdc;
    EscrowVault internal escrow;
    CompositeMediator internal compositeMediator;
    BondEscalation internal bondEscalation;
    MockOOV3 internal oov3;

    // ----- actors -----
    address internal admin = address(this);
    address internal pauser = address(0xFA053);
    address internal feeCollector = address(0xFEE);
    address internal requester = address(0x1);
    address internal provider = address(0x2);
    address internal keeper = address(0x3); // finalizer / proposer / challenger
    address internal rando = address(0xBAD);

    // ----- evaluators (set by _makeEvaluators) -----
    address internal fixed0;
    uint256 internal fixed0Pk;
    address internal fixed1;
    uint256 internal fixed1Pk;
    address internal rotating0;
    uint256 internal rotating0Pk;

    // ----- constants -----
    uint256 internal constant ONE_USDC = 1_000_000;
    uint256 internal constant TRANSACTION_AMOUNT = 1_000 * ONE_USDC; // 1,000 USDC escrow

    // EIP-712 typehash mirror (MUST match BondEscalation.RULING_TYPEHASH).
    bytes32 internal constant RULING_TYPEHASH = keccak256(
        "AIRuling(bytes32 disputeId,uint8 ruling,uint16 confidence,uint16 splitBps,uint64 timestamp,bytes32 reasoningHash,bytes32 bundleHash,bytes32 evidenceRefHash,bytes32 reasoningRefHash)"
    );

    // AIP-14c D7: canonical evidence/reasoning CIDs used by `_ruling()`. The ruling's ref-hashes are
    // derived from these via the on-chain formula, so `submitAIRuling(..., EVIDENCE_CID, REASONING_CID,
    // ...)` recomputes matching refs. Helpers below expose the derivation for manual-ruling call sites.
    string internal constant EVIDENCE_CID = "QmEvidenceCID";
    string internal constant REASONING_CID = "QmReasoningCID";

    /// @notice D7 ref derivation, mirroring BondEscalation.submitAIRuling (abi.encode, NOT encodePacked).
    function _evidenceRef(bytes32 bundleHash, string memory cid) internal pure returns (bytes32) {
        return keccak256(abi.encode(bundleHash, keccak256(bytes(cid))));
    }

    /// @notice Convenience wrapper: submit an AI ruling built by `_ruling()` with the canonical CIDs.
    function _submitAIRuling(bytes32 disputeId, AIRuling memory r, bytes[] memory sigs) internal {
        bondEscalation.submitAIRuling(disputeId, r, EVIDENCE_CID, REASONING_CID, sigs);
    }

    function _setUpStack() internal {
        // 1) Token + kernel + escrow (mirrors ResolverAuth.t.sol setUp).
        usdc = new MockUSDC();
        kernel = new ACTPKernel(admin, pauser, feeCollector, address(0), address(usdc), 1 hours);
        escrow = new EscrowVault(address(usdc), address(kernel));
        kernel.approveEscrowVault(address(escrow), true);

        // 2) Fund actors generously (escrow + bonds + UMA bond headroom).
        usdc.mint(requester, 1_000_000 * ONE_USDC);
        usdc.mint(provider, 1_000_000 * ONE_USDC);
        usdc.mint(keeper, 1_000_000 * ONE_USDC);
        usdc.mint(rando, 1_000_000 * ONE_USDC);

        // 3) Evaluators.
        _makeEvaluators();

        // 4) Mock UMA OOV3 (injected as the BondEscalation UMA_OOV3 immutable).
        oov3 = new MockOOV3();

        // 5) CompositeMediator (deployer == admin == address(this)).
        compositeMediator = new CompositeMediator(IACTPKernel(address(kernel)));

        // 6) BondEscalation, wired to the mediator + the mock OOV3.
        address[2] memory fixedEvaluators = [fixed0, fixed1];
        address[] memory rotatingPool = new address[](1);
        rotatingPool[0] = rotating0;
        bondEscalation = new BondEscalation(
            IACTPKernel(address(kernel)),
            IERC20(address(usdc)),
            ICompositeMediator(address(compositeMediator)),
            admin,
            fixedEvaluators,
            rotatingPool,
            address(oov3) // testability override → mock OOV3 (§8.4)
        );

        // 7) Back-reference wiring (G4 write-once init) + kernel resolver-auth (P0-3).
        compositeMediator.initialize(address(bondEscalation));
        kernel.approveMediator(address(compositeMediator), true);

        // 8) Pass the 2-day mediator timelock so resolutions can transition kernel state.
        vm.warp(block.timestamp + 2 days + 1);
    }

    // =====================================================================
    // Evaluators
    // =====================================================================
    function _makeEvaluators() internal {
        (fixed0, fixed0Pk) = makeAddrAndKey("fixed0");
        (fixed1, fixed1Pk) = makeAddrAndKey("fixed1");
        (rotating0, rotating0Pk) = makeAddrAndKey("rotating0");
    }

    // =====================================================================
    // Drive a fresh transaction to DISPUTED (mirrors ResolverAuth.t.sol).
    // =====================================================================
    function _createDisputed() internal returns (bytes32 txId) {
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

    // =====================================================================
    // EIP-712 ruling signing (matches _verifyEvaluatorSignatures digest).
    // =====================================================================
    function _signRuling(AIRuling memory ruling, uint256 privKey) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                RULING_TYPEHASH,
                ruling.disputeId,
                ruling.ruling,
                ruling.confidence,
                ruling.splitBps,
                ruling.timestamp,
                ruling.reasoningHash,
                ruling.bundleHash,
                ruling.evidenceRefHash,
                ruling.reasoningRefHash
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", bondEscalation.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @notice Convenience: a default valid AIRuling bound to `disputeId` with `ruling` direction.
    function _ruling(bytes32 disputeId, uint8 ruling, uint16 splitBps) internal view returns (AIRuling memory) {
        return AIRuling({
            disputeId: disputeId,
            ruling: ruling,
            confidence: 9000,
            splitBps: splitBps,
            timestamp: uint64(block.timestamp),
            reasoningHash: keccak256("reasoning"),
            bundleHash: keccak256("bundle"),
            // AIP-14c D7: refs derived from the canonical CIDs so submitAIRuling's recompute matches.
            evidenceRefHash: _evidenceRef(keccak256("bundle"), EVIDENCE_CID),
            reasoningRefHash: _evidenceRef(keccak256("reasoning"), REASONING_CID)
        });
    }

    /// @notice Read the escrow remaining for a txId via the vault.
    function _remaining(bytes32 txId) internal view returns (uint256) {
        IACTPKernel.TransactionView memory txn = kernel.getTransaction(txId);
        return escrow.remaining(txn.escrowId);
    }
}
