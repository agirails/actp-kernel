# AIP-14c — BondEscalation ABI freeze (D7) — Rev 3

> **Rev 3 (2026-07-12, Apex pre-audit hardening).** All FROZEN selectors are UNCHANGED
> (`submitAIRuling` `0xca74ab82`, `escalateToUMA` `0xea487f8a`, removed legacy selectors still
> absent). Landed in response to Apex's 2026-07-12 security read (see
> `DISPUTE SYSTEM/APEX-RESPONSE-2026-07-12.md`):
> - **H2**: `forceResolveStale` now requires an EXTRA 30-day `TIER2_STALE_GRACE` for a Tier-2
>   dispute — the 50/50 backstop can no longer pre-empt a rightful UMA verdict.
> - **F-9**: `submitAIRuling` rejects a future-dated `ruling.timestamp` (5-min skew tolerance).
> - **F-10**: `DOMAIN_SEPARATOR` is now a `view` FUNCTION with the SAME selector as the previous
>   public immutable getter — recomputed if `block.chainid` deviates (post-fork replay safety).
> - **F-3/F-11**: rotating pool rejects intra-pool duplicates; hard cap `MAX_ROTATING_POOL = 32`.
> - **F-III (additive ABI)**: `pendingAdmin()`, `transferAdmin(address)`, `acceptAdmin()`
>   (two-step rotation) + `Paused`/`Unpaused`/`AdminTransferInitiated`/`AdminTransferred` events.
>   `pendingAdmin` storage is declared LAST (pre-existing slot layout preserved).
> - Runtime size: **22,904 B** (1,672 B under EIP-170). Suite: **732/0** (42 suites) incl. the new
>   `test/audit/ApexSecurityRead2026_07_12.t.sol`.

> **Re-frozen 2026-07-11** after the review's BLOCKER-2 (reasoning→UMA) + contract hardening landed on top
> of the D7 track. Full kernel suite: **718 passed / 0 failed** (41 suites); `AIP14cKernelGate` 14/14;
> `BondEscalationD7Adversarial` extended with parallel "Reasoning CID mismatch" cases. BondEscalation
> runtime bytecode **21,669 B** (2,907 B under EIP-170). Pairs with the kernel freeze
> [`AIP14C-ABI-FREEZE.md`](AIP14C-ABI-FREEZE.md). This is the pin the SDK + evaluator tracks build against.

## Selectors (final)
| Function | Selector |
|---|---|
| `submitAIRuling(bytes32,(…9-field AIRuling…),string evidenceCID,string reasoningCID,bytes[])` — **final, sole entrypoint** | `0xca74ab82` |
| `submitAIRuling(bytes32,(…9-field…),bytes[])` (pre-D7 3-arg — **REMOVED; must not resolve**) | `0x5e035e52` |
| `escalateToUMA(bytes32,string evidenceCID,string reasoningCID)` — **BLOCKER-2: 2-CID, final** | `0xea487f8a` |
| `escalateToUMA(bytes32,string)` (1-CID — **REMOVED; must not resolve**) | `0xa3c23734` |

## BLOCKER-2 (reasoning reaches the DVM) + hardening
- `escalateToUMA` now takes BOTH `evidenceCID` and `reasoningCID`; when a signed commitment exists it verifies
  BOTH persisted refs (`evidenceRefHashOf` via `evidenceBundleHashOf`, `reasoningRefHashOf` via the NEW
  `reasoningHashOf`) and embeds **both** ipfs CIDs in the UMA/DVM claim + the `EscalatedToUMA` event (now
  `(…, string evidenceCID, string reasoningCID)`).
- `submitAIRuling` explicitly rejects a zero `evidenceRefHash`/`reasoningRefHash` (`"Zero ref hash"`) — the
  zero ref is the load-bearing committed-vs-fresh sentinel.
- `escalateToUMA` applies the same 256-byte `MAX_CID_LENGTH` cap to both CIDs (`"CID required"` / `"CID too long"`).

## D7 CID binding (enforced on-chain)
`submitAIRuling` recomputes, and requires equality with the SIGNED refs **before** `_verifyEvaluatorSignatures`,
any persistence, or the bond `safeTransferFrom`:
```
evidenceRefHash  = keccak256(abi.encode(ruling.bundleHash,    keccak256(bytes(evidenceCID))))
reasoningRefHash = keccak256(abi.encode(ruling.reasoningHash, keccak256(bytes(reasoningCID))))
```
- CIDs: non-empty + `≤ MAX_CID_LENGTH` (256); revert `"CID required"` / `"CID too long"`. Mismatch reverts
  `"Evidence CID mismatch"` / `"Reasoning CID mismatch"`.
- Double-bind: a swapped CID fails the recompute; mutating the signed ref to match instead fails the 2/3
  evaluator EIP-712 quorum (`"Insufficient valid signatures"`) — the quorum signed the original 9-field ruling.
- **Storage holds only `bytes32` refs** (`evidenceRefHashOf`, `evidenceBundleHashOf`) — NO CID strings. The CID
  travels in the event + as the `escalateToUMA` arg (re-hashed and compared).

## escalateToUMA Tier-2 no-swap (reviewed sound)
```
if (evidenceRefHashOf[disputeId] != 0)
    require(keccak256(abi.encode(evidenceBundleHashOf[disputeId], keccak256(bytes(evidenceCID)))) == evidenceRefHashOf[disputeId], "Evidence CID mismatch");
```
**Conditional by design (confirmed against D7 intent):** when a signed AI-ruling commitment exists (ref ≠ 0),
the UMA claim MUST forward THAT exact evidence — no arbitrary-CID swap into the DVM claim. A dispute that
reached Tier-1 via `proposeDirectly` has NO signed commitment (ref == 0) and the escalator supplies fresh UMA
evidence unconstrained (nothing signed to protect; a $500 bond + UMA DVM are the backstop). A signed dispute
can NEVER have ref == 0 (keccak256 output is never zero), so no signed dispute is downgradable into that branch.

## What the SDK track MUST adopt against this freeze
- Call the 5-arg `submitAIRuling(disputeId, ruling, evidenceCID, reasoningCID, signatures)` — the old 3-arg form
  is gone; update `dispute/BondEscalation.ts` + `dispute/bond_escalation.py` + both `BondEscalation` ABI JSONs +
  `EvaluatorClient.ts` / `types/dispute.py`.
- Build `ruling.evidenceRefHash`/`reasoningRefHash` with the formulas above from the SAME CIDs passed to the call
  (the 9-field golden signer already covers the refs).
- `escalateToUMA` uses the committed evidence CID for a signed dispute.
