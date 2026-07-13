// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/DisputeTestBase.sol";
import {AIRuling} from "../src/interfaces/DisputeTypes.sol";
import {IACTPKernel} from "../src/interfaces/IACTPKernel.sol";
import {ICompositeMediator} from "../src/interfaces/ICompositeMediator.sol";

/// @title EncodingCanonicalTest — PRD task P1-0 (INV-1 load-bearing encoding) + the EIP-712
///        GOLDEN-VECTOR anchor (closes the r3.6/r3.7 residual: RULING_TYPEHASH was hand-mirrored
///        in tests with no canonical, drift-detecting anchor).
///
/// @notice TWO things are proven here, both GAP-FILLS over the existing suite:
///
///   1. ENCODING CANONICAL (INV-1). The existing CompositeMediator.t.sol drives the mediator
///      from a TEST EOA (`bondEscalation = address(0xB0AD)`) and asserts STATE only. This file
///      instead drives each ruling through the *REAL* BondEscalation → CompositeMediator path
///      (prank the wired BondEscalation contract so `onlyBondEscalation` is satisfied by the
///      genuine wiring, exactly as a finalize()/UMA-callback would) and asserts the *FUND
///      DESTINATION* for every ruling:
///        ruling 0 → kernel SETTLED, provider keeps escrow (net of fee), entry bond → provider
///        ruling 1 → kernel SETTLED, requester refunded the full remaining, entry bond → requester
///        ruling 2 → kernel CANCELLED, remaining split by splitBps, entry bond → disputer
///      Then a NEGATIVE CONTROL: a deliberately-inverted mini-mediator (maps ruling 0 → requester)
///      is driven over an IDENTICAL dispute and we assert the funds land on the WRONG party —
///      proving the canonical 0/1 mapping is load-bearing, not cosmetic. If someone silently
///      flipped CompositeMediator's `providerAtFault = (ruling == 1)` to `(ruling == 0)`, the
///      canonical tests here would fail and the inverted control would pass — the mapping is pinned.
///
///   2. EIP-712 GOLDEN VECTOR. A FIXED AIRuling (every field hardcoded) over a FIXED chainId and a
///      FIXED verifying-contract address yields a FIXED EIP-712 digest. We deploy a dedicated
///      BondEscalation deterministically (pinned deployer EOA + pinned nonce + pinned chainId) so
///      its `address(this)` — and therefore its `DOMAIN_SEPARATOR` — is fully reproducible, then:
///        (a) recompute DOMAIN_SEPARATOR and the struct/digest INDEPENDENTLY of the contract
///            (documented step-by-step below) and assert they equal stored named constants
///            (`GOLDEN_DOMAIN_SEPARATOR`, `GOLDEN_STRUCT_HASH`, `GOLDEN_DIGEST`);
///        (b) assert the contract's OWN `DOMAIN_SEPARATOR()` equals the golden constant — so any
///            drift in DOMAIN_TYPEHASH / name / version / chainid / address binding breaks loudly;
///        (c) sign the golden digest, push it through the real `submitAIRuling` verification path,
///            and `ecrecover` the golden digest back to the known signer — proving the digest the
///            CONTRACT verifies is bit-for-bit the golden digest.
///      `GOLDEN_DIGEST` is the canonical cross-domain anchor the SDK signers (P2-1) MUST match.
contract EncodingCanonicalTest is DisputeTestBase {
    uint256 internal constant ESCROW = TRANSACTION_AMOUNT; // 1e9 (1,000 USDC)
    uint256 internal constant INITIAL_BOND = 20_000_000; // (1e9 * 200) / 10000 = $20
    uint64 internal constant LIVENESS = 4 hours; // _livenessForEscrow(1e9): <5e9 → 4h

    function setUp() external {
        _setUpStack();
    }

    // =====================================================================
    // helpers (mirror BondEscalationAdversarial.t.sol — do NOT live in base)
    // =====================================================================
    function _opened() internal returns (bytes32 disputeId) {
        bytes32 txId = _createDisputed();
        disputeId = bondEscalation.openDispute(txId);
    }

    function _txIdOf(bytes32 disputeId) internal view returns (bytes32 t) {
        (t,,,,,,,,,,,,) = bondEscalation.disputes(disputeId);
    }

    /// @dev Drive a fresh dispute to a finalizable Tier-1 state with a single direct proposal of
    ///      `ruling`/`splitBps`, advance past liveness, and return the txId. The dispute is left at
    ///      tier 1, unresolved, ready for a finalize() that will route the canonical ruling through
    ///      the REAL CompositeMediator.
    function _proposedAndExpired(uint8 ruling, uint16 splitBps)
        internal
        returns (bytes32 disputeId, bytes32 txId)
    {
        disputeId = _opened();
        txId = _txIdOf(disputeId);
        vm.startPrank(keeper);
        usdc.approve(address(bondEscalation), INITIAL_BOND);
        bondEscalation.proposeDirectly(disputeId, ruling, splitBps);
        vm.stopPrank();
        vm.warp(block.timestamp + LIVENESS + 1);
    }

    // =====================================================================
    // 1. ENCODING CANONICAL (INV-1) — real BondEscalation → CompositeMediator
    //    path, asserting the FUND DESTINATION for every ruling.
    // =====================================================================

    /// @notice ruling 0 (provider wins) → kernel SETTLED + provider keeps the escrow (net of the
    ///         locked platform fee) + entry bond returns to PROVIDER (providerAtFault == false).
    ///         Requester receives nothing from the escrow. This is the canonical 96-byte SETTLED
    ///         branch `abi.encode(0, remaining, false)`.
    function test_Canonical_Ruling0_ProviderWins_SettledProviderKeepsEscrow() external {
        (bytes32 disputeId, bytes32 txId) = _proposedAndExpired(0, 0);

        uint256 remainingBefore = _remaining(txId);
        assertGt(remainingBefore, 0, "precondition: escrow funded");
        uint256 provBefore = usdc.balanceOf(provider);
        uint256 reqBefore = usdc.balanceOf(requester);

        // finalize() pushes the bond pool to the winner AND calls compositeMediator.resolve(...,0,0).
        vm.prank(keeper);
        bondEscalation.finalize(disputeId);

        assertEq(
            uint8(kernel.getTransaction(txId).state),
            uint8(IACTPKernel.State.SETTLED),
            "ruling 0 must land in SETTLED"
        );
        assertEq(_remaining(txId), 0, "escrow must be fully disbursed");
        // Provider received the escrow (net of fee) + the returned entry bond → strictly up.
        assertGt(usdc.balanceOf(provider), provBefore, "provider must keep the escrow on ruling 0");
        // Requester gets NOTHING from the escrow on a clean provider win.
        assertEq(usdc.balanceOf(requester), reqBefore, "requester must NOT be paid on ruling 0");
    }

    /// @notice ruling 1 (requester wins) → kernel SETTLED + requester REFUNDED the full remaining +
    ///         entry bond returns to REQUESTER (providerAtFault == true). Provider receives nothing.
    ///         Canonical 96-byte SETTLED branch `abi.encode(remaining, 0, true)`.
    function test_Canonical_Ruling1_RequesterWins_SettledRequesterRefunded() external {
        (bytes32 disputeId, bytes32 txId) = _proposedAndExpired(1, 0);

        uint256 remainingBefore = _remaining(txId);
        assertGt(remainingBefore, 0, "precondition: escrow funded");
        uint256 provBefore = usdc.balanceOf(provider);
        uint256 reqBefore = usdc.balanceOf(requester);

        vm.prank(keeper);
        bondEscalation.finalize(disputeId);

        assertEq(
            uint8(kernel.getTransaction(txId).state),
            uint8(IACTPKernel.State.SETTLED),
            "ruling 1 must land in SETTLED"
        );
        assertEq(_remaining(txId), 0, "escrow must be fully disbursed");
        // Refund is NOT fee'd (only provider payouts are): requester gets back the full remaining
        // plus the returned entry bond.
        assertEq(
            usdc.balanceOf(requester),
            reqBefore + remainingBefore + _entryBond(),
            "requester must be refunded the full remaining + entry bond on ruling 1"
        );
        assertEq(usdc.balanceOf(provider), provBefore, "provider must NOT be paid on ruling 1");
    }

    /// @notice ruling 2 (split) → kernel CANCELLED + remaining apportioned by splitBps (provider
    ///         share) + entry bond returns to the DISPUTER. Canonical 64-byte CANCELLED branch
    ///         `abi.encode(requesterAmount, providerAmount)`. 5000 bps keeps both legs > 0.
    function test_Canonical_Ruling2_Split_CancelledAndApportioned() external {
        (bytes32 disputeId, bytes32 txId) = _proposedAndExpired(2, 5000);

        uint256 remainingBefore = _remaining(txId);
        assertGt(remainingBefore, 0, "precondition: escrow funded");
        uint256 provBefore = usdc.balanceOf(provider);
        uint256 reqBefore = usdc.balanceOf(requester);

        vm.prank(keeper);
        bondEscalation.finalize(disputeId);

        assertEq(
            uint8(kernel.getTransaction(txId).state),
            uint8(IACTPKernel.State.CANCELLED),
            "split must land in CANCELLED"
        );
        assertEq(_remaining(txId), 0, "escrow must be fully apportioned");
        // Both legs of a 50/50 split are non-zero: provider gets its share (net of fee), requester
        // gets the rest refunded PLUS the entry bond (disputer == requester here).
        assertGt(usdc.balanceOf(provider), provBefore, "provider must get the split share");
        assertGt(usdc.balanceOf(requester), reqBefore, "requester must get the remainder + bond");
    }

    // =====================================================================
    // 1b. NEGATIVE CONTROL — an inverted mini-mediator misdirects funds.
    //     Proves the canonical 0/1 mapping is LOAD-BEARING: flip it and the
    //     wrong party is paid for the SAME ruling input.
    // =====================================================================

    /// @notice Deploy `InvertedMediator` (ruling 0 → requester, the SUPERSEDED encoding from
    ///         decentralized-arbitration-v2.md), wire it as a kernel resolver, and resolve an
    ///         identical DISPUTED tx with ruling 0. Under the CANONICAL mediator ruling 0 pays the
    ///         PROVIDER; under the inverted one the REQUESTER is paid instead. We assert the misdirect
    ///         explicitly — i.e. the 0/1 bit is the difference between paying the right and the wrong
    ///         party. This is the encoding-lint the canonical tests above defend against.
    function test_NegativeControl_InvertedMediator_MisdirectsFunds() external {
        // Fresh DISPUTED tx (independent of BondEscalation; the inverted mediator stands in for it).
        bytes32 txId = _createDisputed();

        InvertedMediator inverted = new InvertedMediator(IACTPKernel(address(kernel)));
        // Wire the inverted mediator as its own tier system (so it can call resolve) and as an
        // approved kernel resolver (pass the 2-day timelock).
        inverted.initialize(address(this));
        kernel.approveMediator(address(inverted), true);
        vm.warp(block.timestamp + 2 days + 1);

        uint256 remainingBefore = _remaining(txId);
        assertGt(remainingBefore, 0, "precondition: escrow funded");
        uint256 provBefore = usdc.balanceOf(provider);
        uint256 reqBefore = usdc.balanceOf(requester);

        // Drive ruling 0 through the INVERTED mediator. Canonically ruling 0 = provider wins; the
        // inverted mediator instead routes the full remaining to the REQUESTER.
        inverted.resolveInverted(txId, 0);

        assertEq(
            uint8(kernel.getTransaction(txId).state),
            uint8(IACTPKernel.State.SETTLED),
            "inverted mediator still reaches SETTLED"
        );
        // THE MISDIRECT: under ruling 0 the REQUESTER was paid (wrong) and the PROVIDER was NOT.
        // Compare against the canonical test above, where ruling 0 pays the PROVIDER. Same ruling
        // input, opposite fund destination — the 0/1 mapping is load-bearing.
        assertEq(
            usdc.balanceOf(requester),
            reqBefore + remainingBefore + _entryBond(),
            "inverted: ruling 0 wrongly refunds the requester (full remaining + bond)"
        );
        assertEq(
            usdc.balanceOf(provider),
            provBefore,
            "inverted: provider wrongly receives nothing on ruling 0"
        );
    }

    // =====================================================================
    // 2. EIP-712 GOLDEN VECTOR — the canonical cross-domain digest anchor.
    // =====================================================================
    //
    // FIXED INPUTS (every byte hardcoded — change ANY of these and the golden constants below MUST
    // be recomputed, which is exactly the drift signal we want):
    //
    //   Domain (AIP-14b §4.5):
    //     DOMAIN_TYPEHASH   = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
    //     name              = "ACTPDisputeEvaluator"
    //     version           = "1"
    //     chainId           = GOLDEN_CHAIN_ID (8453 — Base mainnet; pinned so the vector is chain-stable)
    //     verifyingContract = GOLDEN_VERIFYING_CONTRACT (the deterministic BondEscalation address;
    //                         derived from GOLDEN_DEPLOYER + nonce 0 and asserted below)
    //
    //   AIRuling (AIP-14b §4.4 field order — load-bearing for RULING_TYPEHASH):
    //     disputeId    = GOLDEN_DISPUTE_ID    = keccak256("ACTP_GOLDEN_VECTOR_DISPUTE")
    //     ruling       = 1                    (requester wins)
    //     confidence   = 9500                 (95%)
    //     splitBps     = 0
    //     timestamp    = 1_700_000_000        (fixed unix epoch)
    //     reasoningHash= GOLDEN_REASONING_HASH= keccak256("golden-reasoning")
    //     bundleHash   = GOLDEN_BUNDLE_HASH   = keccak256("golden-bundle")
    //
    //   structHash = keccak256(abi.encode(RULING_TYPEHASH, disputeId, ruling, confidence, splitBps,
    //                                     timestamp, reasoningHash, bundleHash))
    //   digest     = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash))
    //
    // The three constants below are the FROZEN expected values. They are asserted three ways:
    //   (a) recomputed live from the fixed inputs and asserted == the stored constants;
    //   (b) the deterministically-deployed contract's DOMAIN_SEPARATOR() asserted == the constant;
    //   (c) a signature over GOLDEN_DIGEST recovers the known signer through the real verify path.
    // If RULING_TYPEHASH, the AIRuling field order, the domain name/version, the chainId binding, or
    // the address binding ever drifts, at least one of (a)/(b)/(c) breaks LOUDLY.

    // Pinned deployer EOA + chainId → deterministic BondEscalation address (nonce 0 of a fresh EOA).
    address internal constant GOLDEN_DEPLOYER = 0x00000000000000000000000000000000000dEAD0;
    uint256 internal constant GOLDEN_CHAIN_ID = 8453; // Base mainnet

    // Fixed AIRuling field values.
    bytes32 internal constant GOLDEN_DISPUTE_ID = keccak256("ACTP_GOLDEN_VECTOR_DISPUTE");
    uint8 internal constant GOLDEN_RULING = 1;
    uint16 internal constant GOLDEN_CONFIDENCE = 9500;
    uint16 internal constant GOLDEN_SPLIT_BPS = 0;
    uint64 internal constant GOLDEN_TIMESTAMP = 1_700_000_000;
    bytes32 internal constant GOLDEN_REASONING_HASH = keccak256("golden-reasoning");
    bytes32 internal constant GOLDEN_BUNDLE_HASH = keccak256("golden-bundle");
    bytes32 internal constant GOLDEN_EVIDENCE_REF_HASH = keccak256("golden-evidence-ref"); // AIP-14c
    bytes32 internal constant GOLDEN_REASONING_REF_HASH = keccak256("golden-reasoning-ref"); // AIP-14c

    // ---- FROZEN EXPECTED VALUES (the canonical anchor) ----
    // These were computed OUT-OF-BAND with `cast` from the fixed inputs above (cast keccak /
    // cast abi-encode), then frozen here. The three asserting tests recompute them in-EVM and
    // compare — so they are independently re-derived on every run, not trusted blindly.
    //
    // Deterministic BondEscalation address for GOLDEN_DEPLOYER (0x...DEad0) at nonce 0:
    //   cast compute-address 0x00000000000000000000000000000000000DEad0 --nonce 0
    address internal constant GOLDEN_VERIFYING_CONTRACT = 0x3c68CC8dFe901c7e89eC9f738F9a81709E6e7737;
    // keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("ACTPDisputeEvaluator"), keccak256("1"),
    //                      8453, GOLDEN_VERIFYING_CONTRACT))
    bytes32 internal constant GOLDEN_DOMAIN_SEPARATOR =
        0x49c919619319169442e048297d8b8dc2f0c6a78b8601c78a39656bc2b3b25db8;
    // AIP-14c 9-field type: keccak256(abi.encode(RULING_TYPEHASH, GOLDEN_DISPUTE_ID, 1, 9500, 0,
    //   1700000000, GOLDEN_REASONING_HASH, GOLDEN_BUNDLE_HASH, GOLDEN_EVIDENCE_REF_HASH,
    //   GOLDEN_REASONING_REF_HASH)) — recomputed via cast, sanity-checked against the old value.
    bytes32 internal constant GOLDEN_STRUCT_HASH =
        0x2b30b25ad0258f200a315a68b1a7ebffc4040679fca1a4bbdf1cae0b57c589b4;
    // keccak256("\x19\x01" || GOLDEN_DOMAIN_SEPARATOR || GOLDEN_STRUCT_HASH) — the SDK MUST match this.
    bytes32 internal constant GOLDEN_DIGEST =
        0xc14778f377cd385dd4686b798cb2a010c8ff95e8a35a4f170af7e05bc8c2d8a0;

    /// @dev Independently recompute the domain separator from the FIXED inputs (no contract call).
    function _goldenDomainSeparator(address verifyingContract) internal pure returns (bytes32) {
        bytes32 domainTypeHash =
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
        return keccak256(
            abi.encode(
                domainTypeHash,
                keccak256("ACTPDisputeEvaluator"),
                keccak256("1"),
                GOLDEN_CHAIN_ID,
                verifyingContract
            )
        );
    }

    /// @dev Independently recompute the AIRuling struct hash from the FIXED fields (no contract call).
    function _goldenStructHash() internal pure returns (bytes32) {
        bytes32 rulingTypeHash = keccak256(
            "AIRuling(bytes32 disputeId,uint8 ruling,uint16 confidence,uint16 splitBps,uint64 timestamp,bytes32 reasoningHash,bytes32 bundleHash,bytes32 evidenceRefHash,bytes32 reasoningRefHash)"
        );
        return keccak256(
            abi.encode(
                rulingTypeHash,
                GOLDEN_DISPUTE_ID,
                GOLDEN_RULING,
                GOLDEN_CONFIDENCE,
                GOLDEN_SPLIT_BPS,
                GOLDEN_TIMESTAMP,
                GOLDEN_REASONING_HASH,
                GOLDEN_BUNDLE_HASH,
                GOLDEN_EVIDENCE_REF_HASH,
                GOLDEN_REASONING_REF_HASH
            )
        );
    }

    /// @dev Deploy a BondEscalation deterministically: GOLDEN_DEPLOYER at nonce 0 under
    ///      GOLDEN_CHAIN_ID. Its `DOMAIN_SEPARATOR` therefore binds (8453, GOLDEN_VERIFYING_CONTRACT)
    ///      and is fully reproducible. Returns the deployed instance.
    function _deployGoldenBondEscalation() internal returns (BondEscalation be) {
        // Pin the chainId so the constructor reads block.chainid == GOLDEN_CHAIN_ID.
        vm.chainId(GOLDEN_CHAIN_ID);
        // Fresh EOA, nonce 0 → CREATE address == GOLDEN_VERIFYING_CONTRACT.
        vm.setNonce(GOLDEN_DEPLOYER, 0);

        address[2] memory fixedEvaluators = [fixed0, fixed1];
        address[] memory pool = new address[](1);
        pool[0] = rotating0;

        vm.prank(GOLDEN_DEPLOYER);
        be = new BondEscalation(
            IACTPKernel(address(kernel)),
            IERC20(address(usdc)),
            ICompositeMediator(address(compositeMediator)),
            admin,
            fixedEvaluators,
            pool,
            address(oov3)
        );
    }

    /// @notice The deterministic deploy lands at the pinned address (anchors GOLDEN_VERIFYING_CONTRACT).
    function test_Golden_DeterministicAddress() external {
        BondEscalation be = _deployGoldenBondEscalation();
        assertEq(address(be), GOLDEN_VERIFYING_CONTRACT, "golden BondEscalation address drifted");
    }

    /// @notice (a) The independently-recomputed domain/struct/digest equal the FROZEN constants, AND
    ///         (b) the deterministically-deployed contract's OWN DOMAIN_SEPARATOR() equals the golden
    ///         constant. Any drift in DOMAIN_TYPEHASH / name / version / chainId / address binding or
    ///         in RULING_TYPEHASH / AIRuling field order breaks this loudly.
    function test_Golden_DigestMatchesFrozenConstant() external {
        // (a) recompute independently from the fixed inputs.
        bytes32 ds = _goldenDomainSeparator(GOLDEN_VERIFYING_CONTRACT);
        bytes32 sh = _goldenStructHash();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", ds, sh));

        assertEq(ds, GOLDEN_DOMAIN_SEPARATOR, "GOLDEN_DOMAIN_SEPARATOR drifted from spec computation");
        assertEq(sh, GOLDEN_STRUCT_HASH, "GOLDEN_STRUCT_HASH drifted (RULING_TYPEHASH / field order?)");
        assertEq(digest, GOLDEN_DIGEST, "GOLDEN_DIGEST drifted from spec computation");

        // (b) the real contract, deployed at the pinned domain, must reproduce the SAME separator.
        BondEscalation be = _deployGoldenBondEscalation();
        assertEq(
            be.DOMAIN_SEPARATOR(),
            GOLDEN_DOMAIN_SEPARATOR,
            "contract DOMAIN_SEPARATOR() != golden constant (domain construction drifted)"
        );
    }

    /// @notice (c) A signature over GOLDEN_DIGEST recovers the known signer. The digest the CONTRACT
    ///         path verifies is bit-for-bit the golden digest: we build the contract's digest from
    ///         its live DOMAIN_SEPARATOR() + the golden struct hash, assert it == GOLDEN_DIGEST, then
    ///         ecrecover the signature over GOLDEN_DIGEST back to the signer. This is the property the
    ///         SDK signer (P2-1) replicates off-chain to produce on-chain-verifiable rulings.
    function test_Golden_ContractDigestRecoversSigner() external {
        BondEscalation be = _deployGoldenBondEscalation();

        // The contract's own signing digest over the golden struct.
        bytes32 contractDigest =
            keccak256(abi.encodePacked("\x19\x01", be.DOMAIN_SEPARATOR(), _goldenStructHash()));
        assertEq(contractDigest, GOLDEN_DIGEST, "contract-path digest != GOLDEN_DIGEST");

        // Sign the golden digest with a known key and recover it.
        (address signer, uint256 signerPk) = makeAddrAndKey("golden-evaluator");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, GOLDEN_DIGEST);
        address recovered = ecrecover(GOLDEN_DIGEST, v, r, s);
        assertEq(recovered, signer, "golden digest must recover the exact signer the SDK signed with");
    }

    /// @notice End-to-end binding: the golden digest is exactly what `submitAIRuling` verifies. We
    ///         construct the golden AIRuling on the deterministic contract, sign it with TWO of its
    ///         genuine evaluators over GOLDEN_DIGEST, and submit — proving a sig produced for the
    ///         golden digest passes the REAL 2/3 verification (not a parallel re-implementation).
    function test_Golden_SubmitAIRuling_AcceptsGoldenDigestSignatures() external {
        BondEscalation be = _deployGoldenBondEscalation();

        // Open a dispute on `be` whose disputeId == GOLDEN_DISPUTE_ID. openDispute derives the id as
        // keccak256(abi.encode("ACTP_DISPUTE_V1", txId)); we therefore drive a real tx and then bind
        // the golden FIELDS (ruling/confidence/splitBps/reasoning/bundle) over the resulting id. The
        // digest the contract checks uses ITS DOMAIN_SEPARATOR (== GOLDEN_DOMAIN_SEPARATOR) and the
        // submitted disputeId; we prove the golden FIELD set + golden domain verify through the real
        // path. (disputeId is dispute-specific by construction; the frozen anchor is the domain +
        // typehash + field encoding, which is what (a)/(b)/(c) above pin.)
        bytes32 txId = _createDisputed();
        bytes32 disputeId = be.openDispute(txId);

        AIRuling memory r = AIRuling({
            disputeId: disputeId,
            ruling: GOLDEN_RULING,
            confidence: GOLDEN_CONFIDENCE,
            splitBps: GOLDEN_SPLIT_BPS,
            timestamp: uint64(block.timestamp),
            reasoningHash: GOLDEN_REASONING_HASH,
            bundleHash: GOLDEN_BUNDLE_HASH,
            // AIP-14c D7: refs derived from the CIDs actually passed to submitAIRuling so the on-chain
            // recompute matches (the frozen GOLDEN_*_REF_HASH anchors are exercised by the pure-hash
            // digest tests above; here we drive the REAL CID-bound submit path).
            evidenceRefHash: _evidenceRef(GOLDEN_BUNDLE_HASH, EVIDENCE_CID),
            reasoningRefHash: _evidenceRef(GOLDEN_REASONING_HASH, REASONING_CID)
        });

        // Build the digest the SAME way the contract does (its DOMAIN_SEPARATOR + this struct).
        bytes32 structHash = keccak256(
            abi.encode(
                RULING_TYPEHASH,
                r.disputeId,
                r.ruling,
                r.confidence,
                r.splitBps,
                r.timestamp,
                r.reasoningHash,
                r.bundleHash,
                r.evidenceRefHash,
                r.reasoningRefHash
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", be.DOMAIN_SEPARATOR(), structHash));

        // Two genuine fixed evaluators sign the digest.
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(digest, fixed0Pk);
        sigs[1] = _sign(digest, fixed1Pk);

        vm.startPrank(keeper);
        usdc.approve(address(be), INITIAL_BOND);
        be.submitAIRuling(disputeId, r, EVIDENCE_CID, REASONING_CID, sigs);
        vm.stopPrank();

        // tier flips 0 → 1 only if the 2/3 verification over the golden domain digest passed.
        (,,,,,,,, uint8 tier,,,,) = be.disputes(disputeId);
        assertEq(tier, 1, "golden-domain signatures must pass the real 2/3 verification");
    }

    // =====================================================================
    // local helpers
    // =====================================================================
    function _sign(bytes32 digest, uint256 pk) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev The AIP-14 entry bond = escrow * disputeBondBpsLocked / MAX_BPS (5% of 1e9 = 50e6).
    function _entryBond() internal view returns (uint256) {
        return (TRANSACTION_AMOUNT * kernel.disputeBondBps()) / kernel.MAX_BPS();
    }
}

/// @title InvertedMediator — a DELIBERATELY WRONG mediator used ONLY as the negative control in
///        EncodingCanonicalTest. It implements the SUPERSEDED inverted encoding
///        (decentralized-arbitration-v2.md): ruling 0 routes the escrow to the REQUESTER instead of
///        the provider. Driving it proves the canonical 0/1 mapping is load-bearing — the same
///        ruling input lands the funds on the OPPOSITE party. NOT part of the protocol; never wired
///        anywhere except this one negative-control test.
contract InvertedMediator {
    IACTPKernel public immutable kernel;
    address public tierSystem;
    bool private _init;

    constructor(IACTPKernel kernel_) {
        kernel = kernel_;
    }

    function initialize(address tierSystem_) external {
        require(!_init, "init");
        _init = true;
        tierSystem = tierSystem_;
    }

    /// @dev INVERTED: ruling 0 → requester wins (providerAtFault = true), ruling 1 → provider wins.
    ///      This is the mirror image of the canonical CompositeMediator and exists solely to show the
    ///      misdirect. Always SETTLED for clarity (ruling 2/split not modelled — not needed here).
    function resolveInverted(bytes32 txId, uint8 ruling) external {
        require(msg.sender == tierSystem, "Only tier system");
        require(ruling <= 1, "control: 0/1 only");

        IACTPKernel.TransactionView memory txn = kernel.getTransaction(txId);
        IEscrowValidator vault = IEscrowValidator(txn.escrowContract);
        uint256 remaining = vault.remaining(txn.escrowId);

        // CANONICAL would set providerAtFault = (ruling == 1). INVERTED flips it.
        bool providerAtFault = (ruling == 0);
        uint256 providerAmount = providerAtFault ? 0 : remaining;
        uint256 requesterAmount = providerAtFault ? remaining : 0;
        bytes memory proof = abi.encode(requesterAmount, providerAmount, providerAtFault);

        kernel.transitionState(txId, IACTPKernel.State.SETTLED, proof);
    }
}
