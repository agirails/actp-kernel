# AIP-14b — settleAssertion Keeper Financing Decision (§7.5.6, OPS, P4-7)

> Scope: who pays to call UMA's `settleAssertion` (via our
> `BondEscalation.settleUMAAssertion` helper) once a Tier-2 (UMA) assertion's liveness expires, and how
> that keeper is compensated so a clean UMA win does **not** silently rot into a forced 50/50 split at
> the 30-day `forceResolveStale` backstop (risk **R17**).
>
> **Decision: Option 1 — settle-bounty `max(pool*bps, floor)`, net $0, mirroring `finalize()`.**
> This is OQ-6 (keeper) = **Option 1 DECIDED**. Critically, **F-6 already implements this on-chain** —
> this doc is the named mechanism + OPS/SDK degradation handling, not a request to build it.
>
> References: AIP-14b §7.5.6, §8.5 (UMA callbacks), §7.9 `finalize()` bounty, Threat Model §4 (R17,
> "Forced-50/50 degradation"), §5 ("settlement apathy" residual), INV-3, INV-9.

---

## 1. The problem (R17): settlement apathy → forced 50/50

UMA's OOV3 does **not** auto-distribute. After an assertion's liveness expires (and, if disputed, after
the DVM rules), **someone must call `settleAssertion`** to trigger UMA's payout AND our
`assertionResolvedCallback`, which distributes the **Tier-1 escalation pool** (`accumulatedBonds`) to
the rightful winner and drives the kernel-side escrow leg via `compositeMediator.resolve`.

If nobody calls it:

- The Tier-1 pool sits in BondEscalation; the rightful Tier-1 winner is unpaid.
- The dispute stays `DISPUTED` in the kernel; escrow stays frozen.
- At **`disputedAt + MAX_DISPUTE_DURATION` (30 days)** anyone can call `forceResolveStale`, which
  resolves to a **forced 50/50 split** (`currentRuling = 2, splitBps = 5000`). This **penalizes the
  rightful winner** — they had a clean UMA win but get half because no one settled. That is R17.

So a settle **incentive** is needed: pay whoever calls `settleAssertion` a small bounty so settlement
happens promptly on its own, the way `finalize()` already incentivizes Tier-1 finalization.

---

## 2. Options considered

| # | Mechanism | Funding | Net cost to AGIRAILS | Fixes R17? |
|---|-----------|---------|----------------------|-----------|
| **1 (CHOSEN)** | **settle-bounty** = `max(pool * FINALIZATION_BOUNTY_BPS, MIN_FINALIZATION_BOUNTY)`, clamped to pool, deducted from the Tier-1 pool BEFORE the winner payout — paid to the settler recorded by `settleUMAAssertion`. **Mirrors `finalize()` exactly.** | The Tier-1 escalation pool (the disputers' own bonds) | **$0** — no treasury/subsidy; the bounty comes out of the same pool `finalize()` would have taxed | **Yes** |
| 2 | keeper-fee charged at `escalateToUMA` time | the escalator pre-pays a keeper fee alongside the $500 UMA bond | $0 to treasury, but raises the cost of escalating and needs custody + refund logic for the unspent fee | partial; adds escalation friction |
| 3 | capped daily subsidy `$2–10/day` | AGIRAILS treasury reimburses a bot that settles | **$2–10/day subsidy** (ongoing OPEX) | yes, but at a recurring cost and with a centralized settler |

**Committed = Option 1.** It is net $0, requires no new treasury flow, and is *structurally identical*
to the already-shipped `finalize()` bounty — so it carries the same audited solvency proof. Option 3 is
the documented **fallback OPS posture** (run a settler bot) but it does not *replace* Option 1; with
Option 1 live, the bot is just one more party eligible to earn the on-chain bounty, not a subsidy line.

> **"Recovered" holds under Option 1 and Option 2** (the settle cost is recovered from the pool /
> escalator, not subsidized). Only Option 3 is a true subsidy.

---

## 3. Option 1 mechanism — and the fact that it is ALREADY on-chain (F-6)

**This is the load-bearing note:** the F-6 audit fix **already implemented Option 1** in
`src/BondEscalation.sol`. This decision *names and ratifies* it; it does not ask for new contract code.

### 3.1 The settle helper records the keeper (`settleUMAAssertion`, §8.5b)

```solidity
function settleUMAAssertion(bytes32 disputeId) external whenNotPaused {
    DisputeState storage d = disputes[disputeId];
    require(d.disputedAt != 0, "Dispute not opened");
    require(!d.resolved, "Already resolved");
    require(d.tier == 2, "Not escalated to UMA");
    bytes32 assertionId = disputeToAssertion[disputeId];
    require(assertionId != bytes32(0), "No assertion");
    pendingSettler[disputeId] = msg.sender;            // ← record the keeper BEFORE settle
    IOptimisticOracleV3(UMA_OOV3).settleAssertion(assertionId);
    delete pendingSettler[disputeId];                  // ← cleared after the synchronous callback
}
```

It records `msg.sender` as `pendingSettler` **before** calling `OOV3.settleAssertion`, because UMA's
OOV3 fires `assertionResolvedCallback` **synchronously from inside** `settleAssertion` with
`msg.sender == UMA_OOV3` (not the keeper). The mapping is how the callback learns who to pay. It is
intentionally **not** `nonReentrant` (the genuine OOV3 re-enters the nonReentrant callback from inside
`settleAssertion`; guarding the wrapper too would self-deadlock) and moves no funds itself.

### 3.2 The callback pays the bounty, mirroring `finalize()` (§8.5)

Inside `assertionResolvedCallback`, on the **winner-takes-all** leg:

```solidity
address settler = pendingSettler[disputeId];
address winner  = lastProposerForRuling[disputeId][ruling];
if (winner != address(0)) {
    uint256 bounty = 0;
    if (settler != address(0)) {
        bounty = (d.accumulatedBonds * FINALIZATION_BOUNTY_BPS) / 10000; // 10%
        if (bounty < MIN_FINALIZATION_BOUNTY) bounty = MIN_FINALIZATION_BOUNTY; // $0.10 floor
        if (bounty > d.accumulatedBonds)      bounty = d.accumulatedBonds;      // clamp to pool
    }
    d.accumulatedBonds -= bounty;
    uint256 payout = d.accumulatedBonds; d.accumulatedBonds = 0;
    if (bounty > 0) USDC.safeTransfer(settler, bounty);   // ← keeper paid
    if (payout > 0) USDC.safeTransfer(winner,  payout);   // ← winner paid
}
```

This is **exactly the shape** of `finalize()`'s bounty (`FINALIZATION_BOUNTY_BPS = 1000` = 10%,
`MIN_FINALIZATION_BOUNTY = 100_000` = $0.10), so:

- **Net $0 to AGIRAILS:** the bounty is carved from `accumulatedBonds` (the disputers' Tier-1 bonds),
  not the treasury and not escrow. Σ(bounty + winner payout) == originalPool — never exceeds the pool,
  so **solvency is preserved** (the corrected R8 live-solvency invariant, Threat Model §6).
- **Only on the clean win:** the bounty is taken **only** on the winner-takes-all leg. On the
  no-winner **SPLIT** leg the pool is left intact for proportional `claimEscalationRefund` — deducting
  a bounty there would make Σ(shares) < accumulatedBonds and strand the bounty-sized remainder
  (the split divisor `originalPool` is the FULL pool). This asymmetry is deliberate and matches
  `finalize()`.
- **Safe degradation if not routed through the helper:** a *bare* `OOV3.settleAssertion(assertionId)`
  (not via `settleUMAAssertion`) leaves `pendingSettler == 0` → **no bounty is paid** and the **full**
  Tier-1 pool goes to the winner. No funds are lost; only the settle incentive is forgone.

### 3.3 INV-9 / pause posture

`settleUMAAssertion` carries `whenNotPaused` (it is an *entry* helper, not a recovery path), but the
**recovery** routes it depends on — `assertionResolvedCallback`'s downstream `compositeMediator.resolve`
(which uses the kernel's pause-exempt `resolveDisputeWhilePaused`), plus `forceResolveStale`,
`retryMediatorResolution`, `syncExternalResolution`, `claimEscalationRefund` — are **NOT** pausable
(INV-9). So even under a pause the dispute is never trapped: if `settleUMAAssertion` is blocked by a
pause, the 30-day `forceResolveStale` still frees the bonds (at the R17 50/50 cost). The bounty exists
precisely to make the *happy*, non-degraded path the default so that backstop is rarely needed.

---

## 4. Status-quo-no-keeper degradation (OPS + SDK warnings)

Even with the bounty, the bounty only *pays* a settler — it does not *summon* one. OPS must ensure a
settler actually fires. The degradation ladder if no one settles a Tier-2 win:

| Time after liveness expiry | State | Consequence |
|----------------------------|-------|-------------|
| 0 | UMA liveness expired, assertion settleable | Nobody is forced to settle yet. Tier-1 winner unpaid, escrow frozen. |
| any | `settleUMAAssertion` called (keeper OR the winner themselves) | Winner paid; settler earns the bounty; escrow leg driven. **Happy path.** |
| up to 30d | still unsettled | escrow + Tier-1 pool remain frozen; rightful winner accrues opportunity cost. |
| **`disputedAt + 30d`** | `forceResolveStale` callable by anyone | **Forced 50/50 split (R17).** Rightful winner gets HALF. Tier-1 bonds freed via split refund. The clean UMA verdict is economically discarded. |

### 4.1 OPS posture (the Option-3 fallback bot, complementary not substitute)

- Run a lightweight **settler keeper** (Option-3-style bot) that watches for UMA assertions whose
  liveness has expired and calls `BondEscalation.settleUMAAssertion(disputeId)`. With Option 1 live,
  this bot **earns the on-chain bounty** for each settle — so it is self-funding in steady state and
  is **not a subsidy** unless the per-settle gas exceeds the bounty (sub-dust disputes; see §4.2).
- This keeper's gas IS in scope for the paymaster allowlist: `settleUMAAssertion` is part of the
  **keeper-recovery** function group ALLOWED by `paymaster-allowlist-decision.md` (§7.5.5) — but only
  *after a verified+consumed receipt*, with the per-dispute / per-day / circuit-breaker caps there.
- Alert if any Tier-2 assertion is **> 24h past liveness and unsettled** (well inside the 30-day
  window) so an operator can manually settle long before the R17 backstop. This alert — with the full
  event→alert→owner mapping — is operationalized in `ops/aip14b/monitoring-alerts.md`, a **P5-4
  deliverable not yet in the repo**; until it lands, the settler keeper above is the primary guard.

### 4.2 SDK warnings (surface R17 to the affected party)

The SDK MUST warn the party who stands to lose from R17 — the **Tier-1 winner** of a UMA-escalated
dispute — so they self-settle (and pocket the bounty) rather than waiting:

- When a dispute the caller is the prevailing Tier-1 proposer on reaches **tier 2 + UMA liveness
  expired**, surface: *"Your UMA assertion is settleable. Call `settleUMAAssertion` to claim your
  Tier-1 pool now — you also earn the settle bounty. If left unsettled for 30 days, the dispute force-
  resolves to a 50/50 split and you forfeit half (R17)."*
- The SDK helper exposes a one-call `settleDispute(disputeId)` wrapping `settleUMAAssertion`, so the
  winner needs no UMA-specific knowledge.
- Sub-dust note: if `accumulatedBonds * 10% < MIN_FINALIZATION_BOUNTY ($0.10)`, the floor still pays
  $0.10 (clamped to pool), so even tiny pools incentivize settlement; if the pool is below $0.10 the
  bounty clamps to the whole pool — the winner still nets ~0 either way, so the SDK should note that on
  dust-sized Tier-1 pools self-settling is the only way to avoid the 30-day 50/50.

---

## 5. Decision record

- **Chosen:** Option 1 — settle-bounty `max(pool * 10%, $0.10)`, clamped to pool, net $0, mirroring
  `finalize()`. (OQ-6 keeper = Option 1 DECIDED.)
- **Already implemented on-chain:** YES — F-6 audit fix, `BondEscalation.settleUMAAssertion` +
  `assertionResolvedCallback` (`pendingSettler` mechanism). No new contract code required.
- **"Recovered" holds:** under Option 1 (pool-funded) and Option 2 (escalator-funded). Option 3 alone
  would be a subsidy; here Option-3-style bots are merely bounty earners.
- **Residual:** settlement apathy (the 30-day forced-50/50) is an *accepted economic* trade-off
  (Threat Model §7), mitigated — not eliminated — by the bounty + the OPS settler bot + the SDK
  winner-warning. It is a liveness/economics concern, never a safety one (no funds are ever stuck:
  `forceResolveStale` + `claimEscalationRefund` are permissionless and non-pausable, INV-9).
