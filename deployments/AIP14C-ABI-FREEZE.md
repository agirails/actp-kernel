# AIP-14c — Kernel ABI + shared AIRuling type freeze

> **2026-07-12 addendum (Apex pre-audit hardening; frozen surfaces UNCHANGED).** All values
> pinned below (createTransaction v2 selector, transitionState, `TransactionCreated` topic0,
> 9-field AIRuling type/typehash/golden digest, kernelVersion, D1 proof rule) are untouched.
> Landed (see `DISPUTE SYSTEM/APEX-RESPONSE-2026-07-12.md`):
> - **H4 (additive ABI)**: vault REVOCATION is now timelocked — `approveEscrowVault(vault,false)`
>   reverts; use `scheduleEscrowVaultRevocation`/`executeEscrowVaultRevocation` (2-day
>   ECONOMIC_PARAM_DELAY; re-approval cancels a pending revocation). Approval stays immediate.
> - **F-II (behavior on a frozen surface)**: `transitionState(txId, CANCELLED, "")` from DISPUTED
>   now REVERTS when `tx.resultHash != 0` ("Explicit resolution required") — M-2 proof symmetry
>   extended to the CANCELLED path; a dismissal needs an explicit `(requesterAmount, providerAmount)`
>   proof. On v2 every DISPUTED tx has a non-zero resultHash, so empty-proof dismissal is gone.
> - **F-C/F-IV/F-III**: unconditional archive-treasury allowance reset; corrected fee-recovery
>   comment; `DisputeBondBpsUpdated` event.
> - Runtime size: **24,432 B (144 B under EIP-170)** after a same-day revert-string trim
>   (7 strings >31 chars shortened; the D1 `"Delivery proof must be (window,resultHash)"` revert
>   quoted in this freeze is UNTOUCHED — it is SDK-referenced). Headroom is still thin: any
>   larger kernel addition should be preceded by a custom-errors migration (post-audit candidate).

> **Frozen 2026-07-11** after the kernel track (AIP-14c steps 1–6) went green: `forge test` = **703
> passed, 0 failed, 5 skipped (40 suites)**, `forge build` clean (src + all scripts). This is the pinned
> ABI surface the **BondEscalation (D7), evaluator, and TS/Python SDK** tracks build against — do NOT
> change these values without re-freezing here and re-running the golden vector.
>
> **SCOPE.** This freezes the **KERNEL ABI** (`ACTPKernel` create/transition/view/event/version + D1 proof)
> and the **shared 9-field `AIRuling` type / `RULING_TYPEHASH` / golden digest**. It does **NOT** freeze
> BondEscalation's `submitAIRuling` / `escalateToUMA` ABI — those change in the **D7 / Bond track**, which
> publishes its OWN final **BondEscalation ABI freeze** on completion.

## Kernel identity
| Item | Value |
|---|---|
| `kernelVersion()` | `keccak256("ACTP_KERNEL_V2_AIP14C_REV2")` = `0x6237ef5c6bfb5df789df4b1707183342f5ab5c813a9b570f3283a32ddc6f9be1` |
| Runtime codehash | **pinned at deploy** (network-specific, audited bytecode) — the deploy gate checks `kernelVersion` **AND** this codehash. Not frozen here (depends on final compiler settings + the deployed address). |

## AIRuling EIP-712 (v2, 9 fields)
Type string (field ORDER is load-bearing):
```
AIRuling(bytes32 disputeId,uint8 ruling,uint16 confidence,uint16 splitBps,uint64 timestamp,bytes32 reasoningHash,bytes32 bundleHash,bytes32 evidenceRefHash,bytes32 reasoningRefHash)
```
| Item | Value |
|---|---|
| `RULING_TYPEHASH` | `0x00e11bf3b34994a6bc6e216b116cbdaddee1227d0c97d46416f8d994ba8420ae` |
| Golden struct hash | `0x2b30b25ad0258f200a315a68b1a7ebffc4040679fca1a4bbdf1cae0b57c589b4` |
| Golden EIP-712 digest (SDK signers MUST match) | `0xc14778f377cd385dd4686b798cb2a010c8ff95e8a35a4f170af7e05bc8c2d8a0` |

D7 CID-binding formulas (evaluator + on-chain recompute in the BondEscalation track):
```
evidenceRefHash  = keccak256(abi.encode(bundleHash,   keccak256(bytes(evidenceCID))))
reasoningRefHash = keccak256(abi.encode(reasoningHash, keccak256(bytes(reasoningCID))))
```
Golden vector fixtures (from `test/EncodingCanonical.t.sol`): `GOLDEN_EVIDENCE_REF_HASH = keccak256("golden-evidence-ref")`, `GOLDEN_REASONING_REF_HASH = keccak256("golden-reasoning-ref")`. (In this digest-only freeze the anchor uses those literal fixtures; the D7 track wires the real CID-derived refs and NEGATIVE tests — zero / mismatch / CID-mutation.)

## Selectors
| Function | Selector |
|---|---|
| `createTransaction(address,address,uint256,uint256,uint256,bytes32,bytes32,uint256,uint256)` (v2 — with `agreementHash`) | `0xeb5003bc` |
| `createTransaction(...,bytes32,uint256,uint256)` (pre-v2, 8-arg — **MUST NOT resolve on v2**) | `0x432815a2` |
| `transitionState(bytes32,uint8,bytes)` (unchanged) | `0x48d6ecd6` |

> **`submitAIRuling` is NOT frozen here — Bond/D7 track.** The current 3-arg
> `submitAIRuling(bytes32,(…9-field AIRuling…),bytes[])` = `0x5e035e52` is **INTERIM (pre-D7)**. D7 requires
> `submitAIRuling` to receive BOTH CIDs so the contract recomputes the signed `evidenceRefHash`/`reasoningRefHash`
> before any bond transfer or state change. The final, non-bypassable entrypoint is:
> ```solidity
> submitAIRuling(bytes32 disputeId, AIRuling calldata ruling, string calldata evidenceCID,
>                string calldata reasoningCID, bytes[] calldata signatures)
> ```
> The old 3-arg `submitAIRuling` MUST NOT remain as a functional overload (it would bypass the CID recompute).
> The Bond track publishes the final BondEscalation selectors in its own ABI freeze.

## Events
`TransactionCreated(bytes32 indexed,address indexed,address indexed,uint256,bytes32,uint256,uint256,uint256,bytes32)` — trailing `agreementHash` added (AIP-14c).
| Item | Value |
|---|---|
| topic0 | `0x0027322326aad854de3be5d211e46c2c20b023e2f1b5bffbca427b7ed6b9936f` |

## Struct additions (appended — existing field offsets unchanged)
- `Transaction` / `TransactionView`: `+ bytes32 resultHash;` then `+ bytes32 agreementHash;` (after `disputeBond`).
- `createTransaction`: `bytes32 agreementHash` inserted immediately AFTER `serviceHash`.

## DELIVERED proof rule (D1)
`IN_PROGRESS → DELIVERED` proof MUST be exactly 64 bytes = `abi.encode(uint256 window, bytes32 resultHash)`:
- `MIN_DISPUTE_WINDOW (1 hours) ≤ window ≤ MAX_DISPUTE_WINDOW (30 days)` — `window == 0` **forbidden**.
- `resultHash != 0`.
- Empty / 32-byte proofs revert `"Delivery proof must be (window,resultHash)"`. No default-window sentinel.

## What downstream tracks MUST pin to this freeze
- **SDK (TS + Python + CLI + AA):** every delivery writer emits the 64-byte `(window, resultHash)` proof;
  createTransaction supplies `agreementHash`; the AIRuling signer uses the 9-field type + `RULING_TYPEHASH`
  above and reproduces `GOLDEN_DIGEST`; event decoders use the new `TransactionCreated` topic0.
- **Evaluator:** `RULING_TYPEHASH` / digest as above; TransactionReader reads `resultHash` + `agreementHash`
  from `TransactionView` (tuple positions per the struct additions).
- **BondEscalation (D7):** `submitAIRuling` recomputes `evidenceRefHash`/`reasoningRefHash` from the submitted
  CIDs via the formulas above and matches the signed values; `escalateToUMA` forwards only the persisted CID.

## Kernel test gate (regression anchor)
`test/AIP14cKernelGate.t.sol` (14 tests): 64-byte proof (empty/32-byte rejection, window {0,MIN-1,MIN,MAX,MAX+1},
zero-resultHash), resultHash + agreementHash storage/view/event parity, `kernelVersion`, old-selector rejection,
and SETTLED escrow-conservation (vault.remaining == 0). Treasury double-fee conservation: `test/audit/DisputeMoneyPathCoverage.t.sol`.
