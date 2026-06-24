# AIP-14b — Gas-Sponsorship Paymaster Allowlist Decision (§7.5.5, OPS, P4-7)

> Scope: which dispute-system functions AGIRAILS will **sponsor gas for** (CDP + Pimlico paymasters),
> under what receipt/condition gating, and with what spend caps + circuit breakers. The dispute system
> is the one place where sponsoring the *wrong* function turns gas sponsorship into a free griefing
> subsidy — bonds and the UMA $500 are real money an attacker would happily spend *our* gas to move.
>
> **Decision: OQ-6 = sponsor DECIDED**, with a **per-function allowlist** (not a blanket sponsor) and a
> **receipt gate** on the spend-bearing functions.
>
> References: AIP-14b §7.5.5, §4.3 (off-chain AI fee, INV-3), §7.5.6 (`settle-keeper-decision.md`),
> §8.5, Threat Model §5 (griefing surfaces), INV-3, INV-9. Companion:
> `x402-endpoint-deploy.md`, `settle-keeper-decision.md`. Prior-art pattern: the existing CDP+Pimlico
> per-target allowlist for AgentRegistry + X402Relay (MEMORY: paymaster allowlists DONE 2026-03-09).

---

## 1. Why a per-function allowlist (not blanket sponsor)

A blanket "sponsor everything on BondEscalation" is unsafe: the dispute engine has functions that
**accept a bond / move money on the caller's behalf** (`proposeDirectly`, `challenge`, `escalateToUMA`)
and functions that are **permissionless recovery / housekeeping** (`finalize`, `forceResolveStale`,
`settleUMAAssertion`, `claimEscalationRefund`). Sponsoring the former lets an attacker run the
bond-escalation game — including posting the $500 UMA bond — **on our gas**, turning the liveness
ping-pong / split-griefing surfaces of Threat Model §5 into a gas-subsidized attack.

The allowlist therefore splits the surface into three classes:

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ ALLOW — caps+allowlist only (no receipt needed)                                │
│   openDispute            ← entry to the dispute system; no funds move here       │
├──────────────────────────────────────────────────────────────────────────────┤
│ ALLOW — ONLY after a verified + consumed receipt                                │
│   submitAIRuling         ← requires a paid x402 evaluator receipt (§4.3)         │
│   keeper-recovery group  ← settleUMAAssertion / retryMediatorResolution /        │
│                            forceResolveStale / syncExternalResolution            │
├──────────────────────────────────────────────────────────────────────────────┤
│ DENY — never sponsored (caller pays their own gas)                              │
│   proposeDirectly  challenge  escalateToUMA  finalize  claimEscalationRefund     │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. The decision, function by function

### 2.1 ALLOW — `openDispute` (caps + allowlist only, NO receipt yet)

- **Why sponsor:** `openDispute` is the on-ramp. It moves **no funds** (it only snapshots escrow +
  records `disputedAt`); the entry bond was already taken by the kernel on `DELIVERED → DISPUTED`. A
  requester who has already been wronged should not also have to hold gas to *open* the dispute.
- **Why no receipt:** there is nothing to have paid for yet — this is the first step. It is gated by
  the per-sender + per-day caps + the global circuit breaker (§3) only.
- **Abuse bound:** opening a dispute requires the txn to already be in kernel `DISPUTED`
  (`require(txn.state == DISPUTED)`), which itself required posting the kernel entry bond. So
  `openDispute` cannot be spammed for free — the costly step (the entry bond) is upstream in the
  kernel, paid by the disputer, not sponsored.

### 2.2 ALLOW — `submitAIRuling` (ONLY after a verified + consumed receipt)

- **Why sponsor:** submitting a signed AI ruling is the "good citizen" path that resolves disputes
  cheaply (Tier 0). We want it to be frictionless for keepers/agents.
- **Why receipt-gated:** the ruling bundle is produced by the **paid** x402 dispute-evaluator
  (`x402-endpoint-deploy.md`, §4.3). Sponsorship is conditioned on presenting the **x402 settlement
  receipt** for that evaluation (the `X-PAYMENT-RESPONSE` / facilitator receipt), **verified** (its
  signature/settlement checked) and **consumed** (single-use; the receipt nonce is burned in the
  paymaster policy store so it cannot sponsor two submissions). This ties our gas to a *real, paid*
  ruling and blocks free spam of `submitAIRuling` with junk bundles.
- **Defense-in-depth:** even without the gate, a junk ruling reverts on-chain at
  `_verifyEvaluatorSignatures` (`"Insufficient valid signatures"`), and reverted txs are only sponsored
  inside the small carve-out (§3). The receipt gate makes even *valid-but-spammed* submissions
  un-sponsorable without a paid evaluation behind them.

### 2.3 ALLOW — keeper-recovery group (ONLY after a verified + consumed receipt)

Sponsored functions in this group: **`settleUMAAssertion`**, **`retryMediatorResolution`**,
**`forceResolveStale`**, **`syncExternalResolution`**.

- **Why sponsor:** these are the **permissionless liveness backstops** (INV-9). We want a keeper bot
  (and any honest party) to be able to drive a stuck dispute to resolution without holding gas — this
  is what keeps the "walk-away" guarantee real and what closes R17 (`settle-keeper-decision.md`).
- **Why receipt-gated:** to stop an attacker from burning our gas calling these in a loop, sponsorship
  requires a **verified + consumed receipt** proving there is real work to do — e.g. for
  `settleUMAAssertion`, a receipt/attestation that a UMA assertion exists and its liveness has expired
  (the keeper bot's settle job emits/holds this); for `retryMediatorResolution`, evidence the dispute
  is `mediatorRetryPending`. The receipt is single-use (consumed) so a function can't be re-sponsored
  in a tight loop on the same dispute. `settleUMAAssertion` sponsorship is what makes the F-6
  settle-bounty bot self-funding (`settle-keeper-decision.md` §4.1) without a treasury subsidy.
- **No double-spend of gas:** because the receipt is consumed, the keeper is sponsored **once** per
  legitimate recovery action; subsequent no-op retries (`d.resolved` already latched) are not
  sponsorable.

### 2.4 DENY — `proposeDirectly`, `challenge`, `escalateToUMA`, `finalize`, `claimEscalationRefund`

Never sponsored. The caller pays their own gas. Rationale per function:

| Function | Why DENY |
|----------|----------|
| `proposeDirectly` | Posts a Tier-1 bond on the caller's behalf — a participant staking their own money should pay their own gas; sponsoring lets an attacker open-and-stake the bond game on our gas. |
| `challenge` | Posts a **doubling** bond; the liveness-ping-pong griefing surface (Threat Model §5) becomes *gas-subsidized* if sponsored. The challenger has economic skin in the game and can afford gas. |
| `escalateToUMA` | Posts the **$500 UMA bond**; sponsoring the gas around a $500 voluntary escalation is pointless and invites griefers to spam escalation attempts on our gas. |
| `finalize` | Already self-incentivized by the on-chain **finalization bounty** (`max(pool*10%, $0.10)`, §7.9) — the keeper is *paid* to finalize, so it needs no gas subsidy. Sponsoring would double-pay. |
| `claimEscalationRefund` | A depositor pulling **their own** refund; trivially in their interest, no reason to subsidize, and sponsoring enables dust-claim gas-drain spam. |

> Note the deliberate asymmetry with `settle-keeper-decision.md`: `finalize` is DENY (it has its own
> bounty), but `settleUMAAssertion` is ALLOW-with-receipt (its bounty only pays *if* a settler shows up,
> and we want the keeper bot's gas covered so the bounty path actually fires before the 30-day R17
> backstop).

---

## 3. Spend caps + circuit breakers (apply to every ALLOWED function)

These are enforced in **both** the CDP paymaster policy and the Pimlico policy (failover parity), the
same dual-paymaster posture already in production for AgentRegistry + X402Relay.

| Cap | Value | Rationale |
|-----|-------|-----------|
| **Max gas / dispute action** | **~600k gas (~$0.08 at target gas price)** | The heaviest sponsored call is the first-resolution UMA callback fan-out (`settleUMAAssertion → callback → mediator → kernel → escrow payout + reputation`), gas-bounded in Threat Model §4 (R13). 600k covers it with headroom; anything larger is rejected (it would be an anomalous/forged op). |
| **Max daily spend** | **$5–25 / day** (start at $5 testnet / mainnet ramp; raise toward $25 with volume) | Bounds total dispute-gas exposure per day. |
| **Circuit breaker** | trip at **80% of the daily cap** | At 80% consumed, auto-pause new sponsorship for the day and alert OPS — leaves a 20% buffer to absorb in-flight ops without overrun, and surfaces an attack/anomaly before the cap is fully drained. |
| **Per-sender cap** | **~$0.10 / sender / day** | One address can get at most ~1–2 sponsored dispute actions/day. Defeats single-key spam: a griefer would need to spin up many funded senders, each still bounded, and each `openDispute` still requires an upstream kernel entry bond. |
| **Reverted-tx carve-out** | sponsor reverts up to **~15%** of sponsored ops | Honest ops sometimes revert on races (e.g. `settleUMAAssertion` losing to a concurrent settler → `"Already resolved"`; `finalize`'s sync-only branch). A small reverted-tx budget keeps those from bricking honest keepers, but is capped so an attacker cannot grind free reverts. Above 15% reverts/day → treat as anomaly, trip the breaker. |

### 3.1 Receipt-gate store (for §2.2 / §2.3)

- The verified-receipt nonces are tracked in the paymaster policy store (CDP webhook policy + Pimlico
  sponsorship policy). A receipt is **consumed** (nonce burned) the first time it sponsors an op, so it
  cannot sponsor a second op. This is what makes "verified + consumed" enforceable off-chain at the
  paymaster, with no kernel change.
- `openDispute` (§2.1) needs **no** receipt — it is allowlisted on caps alone.

---

## 4. Allowlist target wiring (per chain, per paymaster)

The allowlist is keyed on **(target contract address, function selector)** and applied identically to
CDP and Pimlico. The target addresses come from `deployments/aip14b.json` — read from env / written-back
values, **never hardcoded** (the `BondEscalation` address is `null` / `AWAIT_BROADCAST` until P4-1
Sepolia / P6-1 mainnet). No private keys appear anywhere; the policy is updated via the paymaster
dashboards / API by an operator, or as Safe-submittable config where applicable.

| Target | Selector(s) | Policy |
|--------|-------------|--------|
| `BondEscalation` (`disputeContracts.BondEscalation.address`) | `openDispute(bytes32)` | ALLOW — caps only |
| `BondEscalation` | `submitAIRuling(bytes32,AIRuling,bytes[])` | ALLOW — receipt-gated |
| `BondEscalation` | `settleUMAAssertion(bytes32)`, `retryMediatorResolution(bytes32)`, `forceResolveStale(bytes32)`, `syncExternalResolution(bytes32)` | ALLOW — receipt-gated (keeper-recovery) |
| `BondEscalation` | `proposeDirectly`, `challenge`, `escalateToUMA`, `finalize`, `claimEscalationRefund` | **DENY** |
| `CompositeMediator` (`disputeContracts.CompositeMediator.address`) | `resolve(bytes32,uint8,uint16)` | **DENY** — only callable by BondEscalation (`onlyBondEscalation`); never an EOA-sponsored op |
| `ACTPKernel` (dispute leg) | `resolveDisputeWhilePaused`, `transitionState(...DISPUTED→...)` | **DENY** at the dispute layer — these are driven by the mediator internally, not by sponsored EOAs |

> Selectors are computed from the deployed ABI at policy-set time, not transcribed by hand, to avoid a
> selector typo silently denying a meant-to-allow function.

---

## 5. Why this is safe (mapping to the threat model)

- **Liveness ping-pong / split-griefing (§5):** the bond-posting functions (`challenge`,
  `proposeDirectly`, `escalateToUMA`) are **DENY**, so the griefer funds their own gas for every round —
  the doubling-bond economic cap (Threat Model §5) is preserved and is **not** subsidized.
- **submitAIRuling spam:** receipt-gated to a **paid** x402 evaluation; junk bundles also revert on
  `_verifyEvaluatorSignatures` and are outside the 15% revert carve-out if spammed.
- **Keeper-recovery gas-drain:** receipt-gated + per-sender $0.10/day + consumed-once nonces, so a
  bot can be reimbursed for *real* recovery work but cannot loop our gas. This is the mechanism that
  makes the F-6 settle-bounty self-funding (`settle-keeper-decision.md`) without a treasury subsidy.
- **INV-3 boundary:** the AI fee itself is **off-chain x402** and makes **zero kernel calls** — the
  paymaster never sponsors the evaluation, only the (optional) on-chain `submitAIRuling` that *follows*
  a paid evaluation. The evaluator service holds no kernel-write keys (`x402-endpoint-deploy.md` §3).
- **INV-9 walk-away:** every sponsored recovery function is a **non-pausable** backstop, so sponsoring
  them strengthens the walk-away guarantee (a keeper with no gas can still drive resolution) without
  granting any new authority — these functions are permissionless by design.

---

## 6. Decision record

- **OQ-6 = sponsor DECIDED**, implemented as a **per-function CDP + Pimlico allowlist**.
- **ALLOW (caps only):** `openDispute`.
- **ALLOW (verified + consumed receipt):** `submitAIRuling`; keeper-recovery group
  (`settleUMAAssertion`, `retryMediatorResolution`, `forceResolveStale`, `syncExternalResolution`).
- **DENY:** `proposeDirectly`, `challenge`, `escalateToUMA`, `finalize`, `claimEscalationRefund`
  (+ `CompositeMediator.resolve`, kernel dispute-leg).
- **Caps:** ~600k gas / ~$0.08 per dispute action; $5–25/day with an **80% circuit breaker**; ~$0.10
  per-sender/day; ~15% reverted-tx carve-out.
- **No hardcoded addresses / no keys:** targets read from `deployments/aip14b.json` (env / write-back);
  policy applied to both paymasters for failover parity, mirroring the existing AgentRegistry +
  X402Relay allowlist.
