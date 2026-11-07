# AIP-14b — Bond-Escalation Threat Model (PRD P1-8)

> Scope: the Tier-0/1/2 dispute engine (`src/BondEscalation.sol`) and its thin bridge
> (`src/CompositeMediator.sol`). The ACTP kernel and EscrowVault are the sole fund authority over
> *escrow*; BondEscalation custodies ONLY its own Tier-1 escalation bonds (`accumulatedBonds`) and never
> the UMA bond. This document enumerates the adversarial surfaces, states how the architecture bounds
> each, and points at the executable proof.
>
> Proofs live in:
> - `test/BondEscalationInvariant.t.sol` — stateful invariants (≥256 randomized sequences, `[invariant]` profile).
> - `test/BondEscalationThreatModel.t.sol` — targeted adversarial tests.
> - `test/BondEscalationAdversarial.t.sol` — the MAJOR-1/MAJOR-2/sig-DoS regression locks (pre-existing).

---

## 1. Trust model and asset inventory

Three structurally separate custodians hold three separate pools (INV-7). No code path moves value
between them, which is the root reason a compromise of one pool cannot drain another.

| Pool | Custodian | Accounting | Moved by |
|------|-----------|------------|----------|
| Entry bond (disputer's stake) | **EscrowVault** | `bondBalances` | kernel `transitionState` only |
| Tier-1 escalation bonds | **BondEscalation** | `accumulatedBonds` + `deposits[disputeId][addr]` | `finalize` / `claimEscalationRefund` / `assertionResolvedCallback` |
| UMA assertion + disputer bond | **UMA OOV3** | OOV3-internal | UMA `settleAssertion` only |

Authority assumptions:
- The **admin** (Gnosis Safe in production) can pause the *entry* paths and run the kernel's INV-6
  override, but holds **no** function that extracts Tier-1 bonds from BondEscalation (proven by
  `invariant_NoAdminWithdraw`).
- The **evaluators** (2 fixed + a rotating pool, 2/3 EIP-712 threshold) attest AI rulings but hold **no**
  finality: a signed ruling enters as a *challengeable* Tier-1 proposal (INV-16/21).
- **UMA OOV3** is trusted to deliver one resolution callback; the design tolerates it
  misbehaving (no callback, late callback, or a re-entering callback) without losing funds.

---

## 2. Cross-tier reentrancy

**Surface.** Every BondEscalation payout ends in `USDC.safeTransfer(...)`:
`finalize` (winner push + bounty), `claimEscalationRefund` (split pull), and
`assertionResolvedCallback` (winner push). A malicious USDC, a malicious winner contract, or a
malicious OOV3 could attempt to re-enter during that transfer and collect a second payout, or re-enter
a *different* mutating entrypoint to corrupt accounting.

**Bound.**
1. **`nonReentrant` on every mutating entrypoint** — `proposeDirectly`, `submitAIRuling`, `challenge`,
   `finalize`, `claimEscalationRefund`, `forceResolveStale`, `escalateToUMA`,
   `assertionResolvedCallback`, `assertionDisputedCallback` all carry the OZ `ReentrancyGuard` modifier.
   The guard runs as the **first** modifier, so a re-entering call reverts *before* any state read —
   including before `assertionResolvedCallback`'s own `require(msg.sender == UMA_OOV3)`.
2. **CEI ordering** — state is written before the external transfer in every case:
   `claimEscalationRefund` zeroes `deposits[disputeId][msg.sender]` *before* `safeTransfer`; `finalize`
   sets `resolved = true` / `winnerPaid = true` and zeroes `accumulatedBonds` *before* the winner push;
   the callback does the same. Even a hypothetical guard bypass would find the deposit/pool already
   consumed, so double-pay is doubly impossible.

**Proof.** `BondEscalationThreatModel.t.sol`:
- `test_Reentrancy_ClaimRefund_CannotDoublePay` — a `ReentrantUSDC` re-enters `claimEscalationRefund`
  during the split refund; nested call reverts; depositor gets exactly one share.
- `test_Reentrancy_FinalizeWinnerPush_CannotDoublePay` — re-enters `finalize` from the bounty transfer;
  nested call reverts; pool drained exactly once.
- `test_Reentrancy_UMACallback_CannotReenter` — re-enters `assertionResolvedCallback` from the winner
  push *inside the locked frame*; nested call reverts; pool pushed once.

The exhaustiveness claim: these three are the *only* sites where BondEscalation makes an external call
that an attacker can control the recipient/token of. `escalateToUMA` calls out to the OOV3 but transfers
the UMA bond (not a BondEscalation pool) and is itself `nonReentrant`.

---

## 3. EIP-712 ruling forgery and replay

**Surface.** AI rulings (Tier 0) enter via `submitAIRuling` gated by `_verifyEvaluatorSignatures`
(2/3 over `RULING_TYPEHASH`). An attacker could try to: (a) replay a ruling signed for dispute A onto
dispute B; (b) replay a ruling signed against one BondEscalation deployment onto another; (c) replay an
old-but-validly-signed ruling later; (d) collapse the 2/3 threshold to 1/1 via evaluator-set overlap.

**Bound.**
- **Cross-dispute** — `disputeId` is a signed field of the struct, and `submitAIRuling` additionally
  requires `ruling.disputeId == disputeId`. Rebranding the struct's id breaks signature recovery; not
  rebranding it trips the `"Mismatched disputeId"` require.
- **Cross-contract** — the `DOMAIN_SEPARATOR` binds `chainId` + `address(this)`, so the same struct
  hashes to a different digest on a different deployment; recovered signers mismatch.
- **Freshness / late replay** — `require(block.timestamp <= ruling.timestamp + RULING_FRESHNESS)`
  (1 hour) rejects stale rulings.
- **Evaluator-set overlap (MAJOR-1)** — the rotating pick is zeroed on overlap with a fixed slot, and
  per-slot `seen[3]` flags prevent one key counting twice; constructor + governance enforce write-time
  disjointness, with an execute-time re-check on rotating additions.

**Proof.**
- `BondEscalationThreatModel.t.sol`: `test_Replay_CrossDispute_Rejected`,
  `test_Replay_CrossContract_Rejected` (with a positive control under be2's own domain),
  `test_Replay_StaleRuling_Rejected`.
- `BondEscalationAdversarial.t.sol`: the full MAJOR-1 overlap suite (`test_Major1_*`) and the
  malformed/malleable-signature DoS-tolerance tests.

**Residual: evaluator-key compromise.** If an attacker obtains **2 of 3** evaluator keys, they can
sign an arbitrary ruling that passes verification. This is *bounded by design, not eliminated*:
- A signed ruling has **no finality** — it enters as a Tier-1 proposal that any honest party can
  `challenge` with a doubling bond, and ultimately escalate to UMA's DVM (Tier 2). Tier-0 compromise
  therefore degrades **cost and latency**, never the **outcome** (INV-21).
- Governance can rotate a compromised fixed evaluator (2-day timelock) or, for the rotating slot, remove
  it immediately (`removeFromRotatingPool`). The timelock is the deliberate trade: it prevents a
  compromised *admin* from instantly swapping in a colluding evaluator set.
- Operational recommendation (App-B item 5, INV-18): run **3+** rotating evaluators from diverse
  vendors so a single-vendor compromise cannot reach the 2/3 threshold for the rotating slot.
- **Floor relationship (contract vs ops):** the *contract* floor is `rotatingPool.length >= 1`
  (BondEscalation constructor) — deliberately permissive, and admin can shrink the live pool toward it.
  The *ops/deploy* floor is **>= 3**, enforced at deploy time by `DeployDisputeSystem`
  (`MIN_ROTATING_POOL = 3`, with no-zero / no-fixed-overlap / no-duplicate checks). The >=3 posture is
  therefore an **operational invariant, not a contract guarantee** — monitoring must alert if the live
  rotating pool ever drops below 3.

A single compromised key changes nothing (2/3 still requires a second signer; the overlap guard prevents
one key filling two slots).

---

## 4. OOV3 / UMA misbehavior

**Surface.** Tier-2 hands resolution to an external oracle. Failure modes: (a) the oracle never fires
the callback; (b) it fires late, after the dispute was already resolved locally; (c) it fires with a
re-entrant sub-call; (d) it fires for an unknown assertion; (e) the kernel was admin-moved out of
DISPUTED while a UMA assertion is live (MAJOR-2).

**Bound.**
- **(a) Never fires** → `forceResolveStale` (30-day, never pausable) resolves to a forced 50/50 split
  and frees Tier-1 bonds; UMA settles its own bond independently. No stuck funds (App-B item 1).
- **(b) Late callback** → `assertionResolvedCallback` early-returns with `UMACallbackIgnored` when
  `d.resolved` is already true (INV-19). Idempotent.
- **(c) Re-entrant callback** → `nonReentrant` (§2 above).
- **(d) Unknown assertion** → both callbacks `require(disputes[disputeId].disputedAt != 0)`.
- **(e) Kernel admin-moved (MAJOR-2)** → the callback re-reads kernel state; if it is no longer
  DISPUTED, it syncs locally and **returns without calling the mediator**, avoiding an illegal
  transition that would otherwise revert UMA's whole `settleAssertion` and strand the UMA bond.
- **Forced-50/50 degradation warning (R17)** — the (a) path penalizes the rightful Tier-1 winner by
  splitting rather than awarding. Mitigation is operational: an SDK helper + OPS runbook tell the
  winner to call `settleAssertion` themselves (collecting the bounty), which is the incentive that
  fixes settlement apathy. This is an economic, not a safety, concern.

**Gas of the callback (R13, App-B item 2).** UMA forwards a *bounded* amount of gas to the callback.
The early-return (already-resolved) path is cheap. The **first-resolution** path is heavy: it fans out
through `safeTransfer(winner) → compositeMediator.resolve → kernel.transitionState → escrow payout +
reputation try/catch`. If the forwarded budget were ever smaller than this chain needs, the callback
would OOG. That is **a liveness inconvenience, not stuck funds**: `forceResolveStale` /
`syncExternalResolution` resolve the dispute without the callback, and UMA's bond settlement is
independent of the callback's success.

**Proof.** `BondEscalationThreatModel.t.sol`:
- `test_Gas_FirstResolutionUMACallback_FitsBudget` — snapshots the full first-resolution chain and
  asserts it stays under a bounded forwarded-callback envelope.
- `test_Gas_EarlyReturnUMACallback_IsCheap` — pins the cheap-path asymmetry.
- `test_Recovery_ForceStale_WhenCallbackNeverRuns` — proves the OOG recovery path frees the bonds.
- `BondEscalationAdversarial.t.sol`: `test_Major2_Callback_NoOp_AfterAdminCancel` / `_AfterAdminSettle`,
  `test_Minor_DisputedCallback_UnknownAssertion_Reverts`.

---

## 5. Griefing surfaces

| Vector | How it is bounded |
|--------|-------------------|
| **Signature-DoS** — submit one garbage signature to break an otherwise-valid 2/3 | `ECDSA.tryRecover` skips malformed / high-s sigs (no revert); 2 valid + 1 garbage still passes (§4.7 step 6). Proven in `BondEscalationAdversarial.t.sol`. |
| **Liveness ping-pong** — keep challenging at the ceiling to reset liveness forever | Each challenge **doubles** the bond up to the $500 ceiling; at the ceiling the only continuation is `escalateToUMA` (a $500 bond) — so indefinite ping-pong is economically capped, and the 30-day `forceResolveStale` clock (INV-5, `disputedAt` immutable) is a hard backstop that never resets. |
| **Ambiguity / split-griefing** — push outcomes to a cost-free 50/50 | Every ruling-2 resolution emits `DisputeSplitRecorded` (INV-22); splits are reputation-visible (indexers surface split rates), so cost-free ambiguity is not cost-free reputationally. |
| **Evidence-inflation** — huge evidence bundles to inflate AI cost | AI fee is a dynamic x402 quote ($1 / 50k tokens) with a ~100k-token bundle cap (INV-3, §4.3); the fee is off-chain and never touches the kernel. |
| **Empty-escrow deadlock** — drain escrow via `releaseMilestone`, then dispute | `CompositeMediator` emits a provably-inert 1-wei `ZERO_REMAINING_SENTINEL` so the kernel decoder's existence check passes; the sentinel is never transferred (`remaining == 0` gates every payout). |
| **Pause-griefing of recovery** — admin pauses to trap user bonds | Recovery paths (`finalize`, `forceResolveStale`, `claimEscalationRefund`, `syncExternalResolution`) carry **no** `whenNotPaused` (INV-9); they run even under a contract or kernel pause. Proven in `BondEscalationAdversarial.t.sol::test_Inv9_ClaimRefund_WorksUnderKernelPause`. |
| **Admin fund-theft** — a hidden admin withdraw path | No such function exists (grep + `invariant_NoAdminWithdraw`); admin USDC balance never rises across a full randomized game. |

---

## 6. Invariants asserted (stateful, ≥256 runs)

From `test/BondEscalationInvariant.t.sol`, holding after every randomized sequence over a pool of
concurrent disputes driven through propose / AI-ruling / challenge / finalize / claim / escalate /
UMA-resolve / force-stale:

- **`invariant_DepositsEqualAccumulatedDuringGame`** (INV-15) — mid-game (Tier-1, unresolved),
  `Σ deposits[disputeId][*] == accumulatedBonds`.
- **`invariant_LiveSolvency`** (R8, **corrected form**) —
  `USDC.balanceOf(bondEscalation) ≥ Σ over disputes of the Tier-1 obligation`, where the obligation is
  `accumulatedBonds` for an unresolved dispute, `0` for a resolved winner-takes-all dispute, and
  `Σ_{a: deposits[a]>0} deposits[a]·accumulatedBonds/originalPool` (sum of **unclaimed** proportional
  shares) for a resolved split. The UMA bond is excluded (held by OOV3). This is **not**
  `balance ≥ accumulatedBonds` — after a split, `accumulatedBonds` is a frozen distribution snapshot
  (the claim numerator), not a live balance.
- **`invariant_TierAndResolvedMonotonic`** (INV-5) — `tier` never decreases, `resolved` never flips
  `true → false`, `disputedAt` never changes once set.
- **`invariant_NoAdminWithdraw`** (R8) — the admin's USDC balance never rises across the game.

---

## 7. Out of scope / accepted residuals

- **DVM correctness** — we trust UMA's DVM to resolve assertions; a wrong DVM verdict is a UMA-layer
  concern. Our bound is that a wrong verdict still cannot drain Tier-1 bonds beyond the single payout.
- **2-of-3 evaluator collusion** — bounded to cost/latency degradation (challengeable, escalatable);
  not eliminated. See §3.
- **Settlement apathy** — the forced-50/50 degradation if no one calls `settleAssertion` within 30 days
  is an accepted economic trade-off with an operational mitigation (§4, R17).
- **Escrow / kernel internals** — covered by the kernel's own test suite; this document scopes the
  BondEscalation + CompositeMediator surface only.
