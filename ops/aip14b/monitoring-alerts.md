# AIP-14b — Dispute Monitoring & Alerts (P5-4)

> Scope: the canonical map from EVERY dispute-system on-chain signal to an alert, an owner, and a firing
> threshold. This is the file forward-referenced by `settle-keeper-decision.md` (the "Tier-2 unsettled
> > 24h past liveness" alert that guards against the R17 forced-50/50) and by `OPS-PLAYBOOK-DISPUTE.md`
> (the "what summons an operator" half of recovery).
>
> Indexer: events are read from `src/BondEscalation.sol`, `src/CompositeMediator.sol`,
> `src/ACTPKernel.sol`, and `src/interfaces/IBondEscalationAdmin.sol`. One off-chain watcher subscribes
> to these logs on Base (mainnet + Sepolia), evaluates the thresholds below, and routes to the owner.
>
> PRD refs: P5-4 (§7.12/7.14, §8.5/8.6, INV-9/22, §3.5). Companions: `settle-keeper-decision.md`,
> `paymaster-allowlist-decision.md`, `docs/OPS-PLAYBOOK-DISPUTE.md`, `docs/AIP14B-THREAT-MODEL.md`.

---

## 0. Owners (routing targets)

| Owner tag | Who | Channel |
|-----------|-----|---------|
| **KEEPER** | settler keeper bot (Option-3-style watcher; self-funding via the on-chain bounty) | bot action + log |
| **OPS** | on-call operator | PagerDuty / ops Slack |
| **SEC** | security on-call (Gnosis Safe signers) | security pager + Safe |
| **ANALYTICS** | reputation / metrics indexer | dashboard, no page |
| **PRODUCT** | product owner (dispute UX) | Slack digest, no page |

Severity: **P1** page-now (funds-at-risk or R17 imminent), **P2** same-business-day, **INFO**
dashboard/digest only.

---

## 1. The event -> alert -> owner -> threshold map

Every row below is a real on-chain signal. The first ten rows are the named events in the P5-4
deliverable; row 11 is the named non-event condition (rotating pool below 3). Event sources are exact
(`Contract.EventName`).

| # | Signal (event / condition) | Source | What it means | Alert + threshold | Owner | Sev |
|---|---------------------------|--------|---------------|-------------------|-------|-----|
| 1 | `DisputeOpened(disputeId, txId, escrowAmount, opener)` | `BondEscalation` (also kernel-side `ACTPKernel.DisputeOpened(txId, initiator, bondAmount, ts)`) | A new dispute entered the system. | **INFO** on each. **P2** if open-dispute rate > N/hour (spam / griefing wave) OR if the matching kernel `DisputeOpened` is missing within 2 blocks (indexer/desync). Start the per-dispute lifecycle timer (drives rows 4-6, 8). | OPS | INFO / P2 |
| 2 | `DisputeSplitRecorded(txId, requester, provider, splitBps)` | `CompositeMediator` | A ruling-2 (50/50 / split) resolution was recorded — the neutral, reputation-visible split trace (INV-22). | **INFO** always (feeds per-agent split-rate). **P2** if a single agent's rolling split rate crosses the abuse threshold (split-griefing, Threat Model §5) OR if the cluster of splits correlates with `forceResolveStale` (i.e. forced 50/50s from settlement apathy, not genuine ties — see row 4). | ANALYTICS (+ OPS on the forced-split correlation) | INFO / P2 |
| 3 | DISPUTED -> CANCELLED transition | derived: `CompositeMediator.resolve(txId, ruling=2, splitBps)` -> kernel `transitionState` to CANCELLED (no dedicated event; observed as the ruling-2 leg of resolution, co-emitted with `DisputeSplitRecorded`) | The escrow was apportioned and the txn cancelled (the split outcome of a dispute). | **INFO** when it matches a clean tie. **P2** when it is the product of `forceResolveStale` on a Tier-2 dispute that HAD a clean UMA verdict (the R17 degradation actually landed — a rightful winner just got 50/50). Cross-reference row 7/4. | OPS | INFO / P2 |
| 4 | `EscalatedToUMA(disputeId, assertionId, escalator, bond, evidenceCID)` | `BondEscalation` | A dispute reached Tier-2: $500 UMA bond posted, assertion opened. **Starts the R17 clock.** | **INFO** on emit. **THEN ARM the settle watch:** when this assertion's UMA liveness expires and it is still unsettled, fire **P2 at > 24h past liveness** ("Tier-2 settleable but unsettled — settle before the 30-day forced-50/50") and **P1 at > 25 days since `disputedAt`** (R17 backstop imminent). This is the alert `settle-keeper-decision.md` forward-references. | KEEPER (auto-settle) -> OPS (escalate at P1) | INFO -> P2 -> P1 |
| 5 | `UMAResolutionReceived(disputeId, assertionId, ruling, winner, payout)` | `BondEscalation` | UMA's callback fired and the dispute resolved (happy Tier-2 path). DISARMS the row-4 settle watch. | **INFO** (close the lifecycle timer). **P2** if `winner == address(0)` / ruling-2 (UMA itself returned no-winner -> split path) so analytics can distinguish a genuine UMA split from an apathy-forced one. | OPS | INFO / P2 |
| 6 | `UMACallbackIgnored(disputeId, assertionId, reason)` | `BondEscalation` | A UMA callback arrived AFTER the dispute was already resolved locally and was gracefully no-op'd (INV-19, idempotent). | **INFO** normally (expected idempotency). **P2** if it repeats for the same `disputeId` or spikes in volume (signals a desync between local resolution and UMA, or a misbehaving OOV3 — Threat Model §4b). | OPS | INFO / P2 |
| 7 | `UMADisputeEscalated(disputeId, assertionId)` | `BondEscalation` | The UMA assertion was itself DISPUTED -> goes to UMA's DVM (the slow path). Liveness no longer governs; DVM timing does. | **P2 on emit** (this dispute will be slow; resolution now depends on the DVM, and the 30-day `forceResolveStale` clock is still ticking against it). Re-arm the row-4 settle watch against the DVM resolution, not liveness. | OPS | P2 |
| 8 | `StalledInProgressRecovered(transactionId, requester, amount)` | `ACTPKernel` | A stalled IN_PROGRESS txn was recovered by the kernel's permissionless stall path (§3.5 recovery, refund to requester). | **P2** on emit (a transaction needed recovery — investigate why it stalled). **P1** if rate spikes (systemic stall — provider outage or a kernel issue). | OPS | P2 / P1 |
| 9 | `PromptCIDUpdated(cid)` | `BondEscalation` (admin, via `IBondEscalationAdmin`) | The canonical evaluator-prompt CID was changed (executed after the 2-day timelock). Changes what the 3-LLM evaluator runs. | **P1 on emit** (a prompt change alters every future AI ruling — confirm it was an authorized, timelocked governance action, not a compromised admin). Cross-check the preceding `PromptCIDProposed` + the 2-day delay. ALSO verify the new CID is pinned per the pinning SLA. | SEC (+ OPS to verify the pin) | P1 |
| 10 | (paired) `PromptCIDProposed(newCID, unlockTime)` / `PromptCIDProposalCancelled()` | `BondEscalation` (admin) | A prompt-CID change was proposed / cancelled (the timelock window for row 9). | **P2** on `Proposed` (a prompt change is pending — start the pin-and-review SLA before `unlockTime`). **INFO** on `Cancelled`. | SEC | P2 / INFO |
| 11 | **Rotating evaluator pool < 3** (CONDITION, not an event) | derived from `BondEscalation` rotating-pool state (`rotatingPoolLength()` / governance add/remove logs) vs the ops floor `MIN_ROTATING_POOL = 3` (`DeployDisputeSystem`) | The live rotating evaluator pool dropped below the OPERATIONAL floor of 3 (the CONTRACT floor is only `>= 1`, deliberately permissive — Threat Model §3). Below 3, a single-vendor compromise can more easily reach the 2/3 rotating threshold. | **P1** the moment live `rotatingPool.length < 3` (this is an operational-invariant breach, not a contract one — Threat Model §3 "monitoring must alert if the live rotating pool ever drops below 3"). Restore via timelocked add. | SEC | P1 |

---

## 2. Why these specific signals (mapping back to the threats)

- **Rows 4/5/6/7 (the UMA quartet)** are the Tier-2 lifecycle. Row 4 ARMS the R17 guard; rows 5/6
  DISARM it (resolved / idempotent late callback); row 7 reroutes it through the DVM. The
  **> 24h-past-liveness-and-unsettled** alert on row 4 is the single most important alert in this file —
  it is what stops settlement apathy from becoming the forced-50/50 of `settle-keeper-decision.md` §1
  (R17). It fires ~29 days before the `forceResolveStale` backstop, giving the keeper bot, the winner,
  and OPS three independent chances to settle.
- **Rows 2/3 (split signals)** make ambiguity reputationally visible (INV-22) AND let analytics tell a
  GENUINE tie apart from a forced-50/50 (row 3 + `forceResolveStale` correlation = R17 actually landed,
  a P2 that should never recur if row 4 is acted on).
- **Row 8 (`StalledInProgressRecovered`)** is the kernel-side §3.5 recovery surfacing — a recovery firing
  is itself a signal that something upstream stalled.
- **Rows 9/10 (PromptCID)** are governance integrity: changing the evaluator prompt changes every future
  ruling, so a CID change is a SEC-page event that must be tied to a legitimate timelocked proposal AND a
  successful re-pin (pinning SLA).
- **Row 11 (pool < 3)** is the only ops-invariant (not contract-invariant) in the set — the contract
  permits `>= 1`, so ONLY monitoring enforces the `>= 3` posture that keeps the 2/3 rotating threshold
  hard to compromise.

---

## 3. INV-9 note (why no alert "traps" funds)

None of these alerts gate fund recovery. Even if the whole alerting stack is down AND the system is
paused, the recovery paths (`finalize`, `forceResolveStale`, `claimEscalationRefund`,
`syncExternalResolution`) remain permissionless and non-pausable (INV-9 — see
`OPS-PLAYBOOK-DISPUTE.md` §1.2/§6). Monitoring exists to make the HAPPY path the default (settle before
R17, restore the pool above 3, catch a bad prompt change) — never as a precondition for getting money
out. Alerts improve liveness and integrity; they are never load-bearing for safety.

---

## 4. Threshold summary (operator cheat sheet)

```
DisputeOpened spam            -> P2 if rate > N/hour  (set N from baseline volume)
DisputeSplitRecorded          -> ANALYTICS always; P2 on per-agent split-rate abuse / forced-split cluster
DISPUTED->CANCELLED           -> P2 only if it is a forced-50/50 over a clean UMA verdict (R17 landed)
EscalatedToUMA                -> ARM R17 watch: P2 at >24h past liveness unsettled; P1 at >25d since disputedAt
UMAResolutionReceived         -> close timer; P2 if no-winner/ruling-2
UMACallbackIgnored            -> INFO once; P2 if repeats / spikes (desync)
UMADisputeEscalated           -> P2 always (now DVM-paced; 30d clock still runs)
StalledInProgressRecovered    -> P2 each; P1 on rate spike
PromptCIDUpdated              -> P1 always (verify timelocked + re-pinned)
PromptCIDProposed/Cancelled   -> P2 on Proposed (start pin/review); INFO on Cancelled
rotating pool < 3             -> P1 immediately (ops-invariant breach, Threat Model sec 3)
```
