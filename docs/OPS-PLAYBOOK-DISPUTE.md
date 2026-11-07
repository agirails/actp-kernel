# AIP-14b — Dispute System OPS Playbook (P5-4)

> Scope: operating the three-tier dispute engine (`src/BondEscalation.sol` +
> `src/CompositeMediator.sol`) in production: what a pause does and does NOT freeze, how to recover a
> stuck dispute, the 30-day `forceResolveStale` decision tree (including the unsettled-UMA forced-50/50
> degradation), the `settleAssertion` keeper procedure, and the exact `cast` commands that still work
> WHILE PAUSED — the executable proof of INV-9.
>
> Companions:
> - `ops/aip14b/monitoring-alerts.md` — every dispute event mapped to an alert + owner + threshold
>   (this playbook forward-references it for the "what fires an operator" half).
> - `ops/aip14b/settle-keeper-decision.md` — the keeper financing decision (Option 1, net $0); §4 here
>   is the operational procedure that decision describes.
> - `ops/aip14b/paymaster-allowlist-decision.md` — which recovery calls are gas-sponsored.
> - `docs/AIP14B-THREAT-MODEL.md` — §4 (OOV3 misbehavior, R17), §5 (pause-griefing bound by INV-9).
>
> PRD refs: §7.12 (recovery surface), §7.14 (pause posture), §8.5 (UMA callbacks + settle), §8.6 (UMA
> self-dispute), INV-9 (recovery never pausable), INV-22 (split is reputation-visible).

---

## 0. Mental model (read first)

The dispute engine has exactly two posture classes for its external functions:

- **ENTRY paths** — let new money / new state INTO the dispute game. These are pausable: an admin can
  freeze the front door during an incident so no new disputes / proposals / escalations begin.
- **RECOVERY paths** — let already-committed money OUT of the dispute game. These are NEVER pausable
  (INV-9). A pause must never trap a user's bond. Recovery runs even under a contract pause AND under a
  kernel pause.

If you remember one thing: **a pause stops the bleeding, it never locks the exits.**

---

## 1. The pausable set vs the non-pausable set (§7.14, INV-9)

This is the load-bearing table. It is enforced at the source: every ENTRY function carries the
`whenNotPaused` modifier; every RECOVERY function carries `nonReentrant` ONLY (no `whenNotPaused`).
Verify any time with the grep in §6.3.

### 1.1 PAUSABLE — ENTRY paths (frozen by `pause()`)

| Function | Why it is an entry path | Effect of pause |
|----------|-------------------------|-----------------|
| `openDispute` | Opens a brand-new dispute (snapshots escrow, records `disputedAt`). | No new disputes can be opened. |
| `submitAIRuling` | Enters a Tier-0 AI ruling as a challengeable Tier-1 proposal. | No new AI rulings enter. |
| `proposeDirectly` | Enters a Tier-1 direct proposal with a bond. | No new direct proposals enter. |
| `challenge` | Doubles the bond and counters the standing proposal (Tier-1 game). | No new challenges; the bond game freezes in place. |
| `escalateToUMA` | Posts the $500 UMA bond and opens a Tier-2 assertion. | No new UMA escalations. |

> `settleUMAAssertion` ALSO carries `whenNotPaused` — it is an *entry* helper, not a recovery path
> (it pulls a UMA verdict IN). It is listed separately in §4 because its DOWNSTREAM recovery
> (the callback's `compositeMediator.resolve` via the kernel's pause-exempt `resolveDisputeWhilePaused`)
> is NOT pausable. If `settleUMAAssertion` is blocked by a pause, the 30-day `forceResolveStale`
> backstop still frees the bonds (at the R17 cost — see §3).

### 1.2 NON-PAUSABLE — RECOVERY paths (run even while paused, INV-9)

| Function | What it recovers | Pause-exempt because |
|----------|------------------|----------------------|
| `finalize` | Pays the Tier-1 winner (winner push + settler bounty) and frees the pool. | A finished bond game must always pay out. |
| `forceResolveStale` | 30-day backstop: resolves a stuck dispute to a forced 50/50 split, frees Tier-1 bonds. | The permissionless walk-away guarantee. Never resets. |
| `claimEscalationRefund` | Pulls a disputer's proportional share after a split resolution. | A depositor must always be able to reclaim their share. |
| `syncExternalResolution` | Reconciles kernel-side state when the dispute was resolved out of band. | Housekeeping that frees a dispute the callback could not. |

> `retryMediatorResolution` is also `nonReentrant`-only (non-pausable). It re-drives a deferred
> `compositeMediator.resolve` (e.g. after `MediatorResolutionDeferred`) and is part of the recovery
> surface even though it is not in the §7.14 canonical four.

**INV-9 statement:** the set {`finalize`, `forceResolveStale`, `claimEscalationRefund`,
`syncExternalResolution`} carries NO `whenNotPaused`. Proven in
`test/BondEscalationAdversarial.t.sol::test_Inv9_ClaimRefund_WorksUnderKernelPause` and re-provable live
in §6. The kernel's own resolution leg used by the UMA callback is the pause-exempt
`resolveDisputeWhilePaused` (NOT the pausable `transitionState`), so the callback's downstream resolve
also survives a kernel pause.

### 1.3 Pause-griefing bound (Threat Model §5)

A malicious or compromised admin who pauses to "trap" user bonds CANNOT: every exit in §1.2 ignores the
pause. The worst a pause achieves is freezing the front door (§1.1) — a liveness inconvenience, never a
safety loss. This is the whole point of splitting entry from recovery.

---

## 2. How to pause / unpause

- `pause()` / `unpause()` are `onlyAdmin` (Gnosis Safe 2-of-3 in production; admin EOA on testnet).
- Pause is for an active incident (suspected evaluator-key compromise, a bad mediator, an upstream
  kernel emergency). It is a blunt instrument — it freezes ALL entry paths in §1.1 at once.
- Pausing does NOT pause the kernel, and pausing the kernel does NOT pause BondEscalation; the two pause
  switches are independent. Recovery survives BOTH (INV-9).

```
# testnet (admin EOA). On mainnet, submit the same calldata through the Safe.
cast send $BOND_ESCALATION "pause()"   --rpc-url $BASE_SEPOLIA_RPC --private-key $DISPUTE_ADMIN_KEY
cast send $BOND_ESCALATION "unpause()" --rpc-url $BASE_SEPOLIA_RPC --private-key $DISPUTE_ADMIN_KEY

# confirm state
cast call $BOND_ESCALATION "paused()(bool)" --rpc-url $BASE_SEPOLIA_RPC
```

Before unpausing, confirm the incident is closed (e.g. compromised evaluator rotated via the 2-day
timelock, or the rotating evaluator removed immediately via `removeFromRotatingPool`).

---

## 3. The `forceResolveStale` 30-day decision tree

`forceResolveStale(disputeId)` is the permissionless backstop: 30 days after `disputedAt`
(`MAX_DISPUTE_DURATION = 30 days`, immutable, NEVER resets — INV-5) anyone can call it to drive the
dispute to a **forced 50/50 split** (`currentRuling = 2`, `splitBps = 5000`) and free the Tier-1 bonds.
It exists so NO dispute can be frozen forever. It is a backstop, not a happy path — a 50/50 split is a
degraded outcome whenever there was actually a rightful winner.

### 3.1 Decision tree

```
A dispute is past disputedAt + 30 days and still unresolved.
|
+- Is it Tier-2 (escalated to UMA) AND the UMA assertion is settleable
|  (liveness expired / DVM ruled) but NOBODY called settleAssertion?
|  |
|  +- YES  -> STOP. Do NOT call forceResolveStale yet.
|  |         Call settleUMAAssertion FIRST (sec 4). The clean UMA verdict
|  |         pays the rightful winner the FULL Tier-1 pool (minus the
|  |         settle bounty). forceResolveStale here would DISCARD that
|  |         verdict and force 50/50 -- the R17 degradation. See sec 3.2.
|  |
|  +- NO (UMA never delivered, or it is a non-UMA Tier-0/1 stale dispute):
|            -> forceResolveStale is the correct backstop. Call it.
|               Outcome: forced 50/50, bonds freed via the split path,
|               each depositor reclaims their proportional share with
|               claimEscalationRefund. No funds are ever stuck.
|
+- Is it < 30 days since disputedAt?
   -> forceResolveStale is NOT callable yet (reverts). Drive the normal
      path instead: finalize (if a Tier-1 game ended), or settleUMAAssertion
      (if a UMA assertion is settleable). The 30-day clock is a floor, not a target.
```

### 3.2 R17 — the unsettled-UMA forced-50/50 degradation (READ THIS)

> **WARNING.** UMA's OOV3 does NOT auto-distribute. After a Tier-2 assertion's liveness expires (and,
> if disputed, after the DVM rules), SOMEONE must call `settleAssertion` to trigger the payout and our
> `assertionResolvedCallback`. If nobody settles, the dispute sits unresolved until
> `disputedAt + 30 days`, at which point `forceResolveStale` forces a **50/50 split** —
> **penalizing the rightful Tier-1 winner**, who had a CLEAN UMA win but now gets HALF because nobody
> settled. That is risk R17 (Threat Model §4).

Operational consequence: for a Tier-2 dispute, **always prefer `settleUMAAssertion` over
`forceResolveStale`** while the assertion is settleable. `forceResolveStale` on a settleable-but-
unsettled UMA dispute is a degradation, not a recovery. Only use `forceResolveStale` on a Tier-2
dispute when UMA genuinely never delivered a usable verdict (the (a) "never fires" path of Threat
Model §4) — in that case 50/50 is the correct, fund-freeing backstop and there is no clean verdict to
discard.

This is why the monitoring alert "Tier-2 assertion > 24h past liveness and unsettled" exists
(`ops/aip14b/monitoring-alerts.md`): it fires well inside the 30-day window so an operator (or the
winner, or the keeper bot) settles BEFORE the R17 backstop ever triggers.

### 3.3 `forceResolveStale` commands

```
# precondition: block.timestamp >= disputedAt + 30 days
cast call $BOND_ESCALATION "disputes(bytes32)" $DISPUTE_ID --rpc-url $BASE_SEPOLIA_RPC   # read disputedAt
cast send $BOND_ESCALATION "forceResolveStale(bytes32)" $DISPUTE_ID \
    --rpc-url $BASE_SEPOLIA_RPC --private-key $KEEPER_KEY
# then each depositor reclaims their split share (permissionless, non-pausable):
cast send $BOND_ESCALATION "claimEscalationRefund(bytes32)" $DISPUTE_ID \
    --rpc-url $BASE_SEPOLIA_RPC --private-key $DEPOSITOR_KEY
```

---

## 4. `settleAssertion` keeper procedure (Option 1, per `settle-keeper-decision.md`)

The keeper financing decision is **Option 1 — settle-bounty `max(pool * 10%, $0.10)`, clamped to pool,
net $0, mirroring `finalize()`** (OQ-6 keeper = DECIDED; already implemented on-chain by the F-6 fix).
Whoever calls `settleUMAAssertion` is recorded as `pendingSettler` and earns the bounty from the
Tier-1 pool on the winner-takes-all leg. This is the procedure that decision operationalizes.

### 4.1 When to settle

Settle as soon as a Tier-2 assertion is settleable (liveness expired; or DVM ruled if it was disputed).
The earlier it settles, the further from the R17 30-day backstop the dispute stays. The monitoring alert
in §3.2 fires at > 24h past liveness; treat that as the SLA to settle by.

### 4.2 Who settles (in priority order)

1. **The Tier-1 winner themselves** — they get the FULL pool minus the bounty; settling early is in
   their direct interest (and the SDK `settleDispute(disputeId)` helper makes it one call). The SDK
   surfaces the R17 warning to them.
2. **The settler keeper bot** (the Option-3-style watcher) — earns the on-chain bounty per settle, so it
   is self-funding in steady state, NOT a subsidy. This is the primary operational guard until the
   monitoring alert lands and an operator can do it manually.
3. **Any operator, manually** — when the alert fires and neither of the above has acted.

### 4.3 The command

```
# precondition: the UMA assertion's liveness has expired (settleable)
cast send $BOND_ESCALATION "settleUMAAssertion(bytes32)" $DISPUTE_ID \
    --rpc-url $BASE_MAINNET_RPC --private-key $KEEPER_KEY
# This records msg.sender as pendingSettler, calls OOV3.settleAssertion, which synchronously fires
# assertionResolvedCallback -> pays the settler the bounty + the winner the rest -> drives the escrow leg.
```

Notes:
- `settleUMAAssertion` carries `whenNotPaused`. If BondEscalation is paused, settle is blocked — but the
  dispute is NOT trapped: the 30-day `forceResolveStale` still frees the bonds (at the R17 50/50 cost).
  Unpause to restore the happy path before the 30-day window closes.
- A bare `OOV3.settleAssertion(assertionId)` (NOT routed through our helper) leaves `pendingSettler == 0`
  → no bounty is paid and the FULL pool goes to the winner. No funds lost; only the settle incentive is
  forgone. Always route through `settleUMAAssertion`.
- Sub-dust pools: if `pool * 10% < $0.10`, the $0.10 floor still pays (clamped to pool). On pools below
  $0.10 the bounty clamps to the whole pool, so on dust-sized pools self-settling by the winner is the
  only way to dodge the 30-day 50/50.

### 4.4 Tier-2 settle decision tree

```
UMA assertion exists for disputeId.
|
+- Liveness NOT yet expired -> wait. Nothing to settle.
|
+- Liveness expired, assertion settleable, dispute NOT resolved:
|   +- BondEscalation paused? -> unpause (admin) THEN settleUMAAssertion,
|   |                            or accept the 30-day forceResolveStale fallback.
|   +- not paused -> settleUMAAssertion(disputeId)   <- HAPPY PATH. Do this.
|
+- d.resolved already true (someone settled / synced / forced):
    -> nothing to do. A late callback early-returns with UMACallbackIgnored (INV-19, idempotent).
```

---

## 5. Recovery runbook by symptom

| Symptom | Likely cause | Action |
|---------|-------------|--------|
| Dispute stuck DISPUTED, UMA liveness expired, unsettled | settlement apathy (R17 risk) | `settleUMAAssertion` (§4). Settle BEFORE 30 days. |
| Dispute stuck DISPUTED, UMA never delivered, > 30 days | OOV3 never fired the callback (Threat Model §4a) | `forceResolveStale` (§3) — correct backstop, frees bonds. |
| `UMACallbackIgnored` emitted | late callback after local resolution (INV-19) | none — idempotent, expected. Confirm dispute already resolved. |
| `MediatorResolutionDeferred` emitted | mediator resolve leg deferred | `retryMediatorResolution(disputeId)` (non-pausable). |
| Tier-1 game ended, winner unpaid | nobody called `finalize` | `finalize(disputeId)` (non-pausable, pays the finalizer the bounty). |
| Split resolved, depositor unpaid | depositor has not claimed | depositor calls `claimEscalationRefund` (non-pausable). |
| Kernel/contract paused, user bond appears trapped | NOT actually trapped | run the §6 recovery commands — they ignore the pause (INV-9). |
| Rotating evaluator pool dropped below 3 | governance removed/expired evaluators | add evaluators (2-day timelock) to restore the ops floor >= 3. Alert is in monitoring file. |

---

## 6. INV-9 demonstration — recovery commands that WORK WHILE PAUSED

This section is the executable proof for the P5-4 acceptance criterion: recovery runs on testnet while
the system is paused.

### 6.1 Setup: pause, then recover anyway

```
# 1) Pause BOTH the dispute contract and (optionally) the kernel to prove either pause is irrelevant.
cast send $BOND_ESCALATION "pause()" --rpc-url $BASE_SEPOLIA_RPC --private-key $DISPUTE_ADMIN_KEY
cast send $ACTP_KERNEL     "pause()" --rpc-url $BASE_SEPOLIA_RPC --private-key $KERNEL_ADMIN_KEY

# 2) Confirm paused.
cast call $BOND_ESCALATION "paused()(bool)" --rpc-url $BASE_SEPOLIA_RPC   # -> true
cast call $ACTP_KERNEL     "paused()(bool)" --rpc-url $BASE_SEPOLIA_RPC   # -> true

# 3) ENTRY paths must REVERT while paused (proves the pause is real):
cast send $BOND_ESCALATION "openDispute(bytes32)" $TX_ID \
    --rpc-url $BASE_SEPOLIA_RPC --private-key $USER_KEY        # EXPECT: revert "Paused"

# 4) RECOVERY paths must SUCCEED while paused (proves INV-9):
cast send $BOND_ESCALATION "finalize(bytes32)" $DISPUTE_ID \
    --rpc-url $BASE_SEPOLIA_RPC --private-key $KEEPER_KEY      # EXPECT: success, winner + bounty paid
cast send $BOND_ESCALATION "claimEscalationRefund(bytes32)" $DISPUTE_ID \
    --rpc-url $BASE_SEPOLIA_RPC --private-key $DEPOSITOR_KEY   # EXPECT: success, share pulled
cast send $BOND_ESCALATION "forceResolveStale(bytes32)" $DISPUTE_ID \
    --rpc-url $BASE_SEPOLIA_RPC --private-key $KEEPER_KEY      # EXPECT: success (if >= 30d), bonds freed
cast send $BOND_ESCALATION "syncExternalResolution(bytes32)" $DISPUTE_ID \
    --rpc-url $BASE_SEPOLIA_RPC --private-key $KEEPER_KEY      # EXPECT: success, kernel state reconciled
```

The asymmetry between step 3 (revert) and step 4 (success) IS the proof of INV-9: the same pause that
blocks the entry path leaves every recovery path open.

### 6.2 Unpause when the incident is closed

```
cast send $BOND_ESCALATION "unpause()" --rpc-url $BASE_SEPOLIA_RPC --private-key $DISPUTE_ADMIN_KEY
cast send $ACTP_KERNEL     "unpause()" --rpc-url $BASE_SEPOLIA_RPC --private-key $KERNEL_ADMIN_KEY
```

### 6.3 Verify the pause posture from source (no chain needed)

```
# ENTRY paths carry whenNotPaused:
grep -nE "function (openDispute|submitAIRuling|proposeDirectly|challenge|escalateToUMA)" \
    src/BondEscalation.sol     # each line / its body carries whenNotPaused

# RECOVERY paths carry nonReentrant ONLY (NO whenNotPaused) -- this is INV-9 at the source:
grep -nE "function (finalize|forceResolveStale|claimEscalationRefund|syncExternalResolution)" \
    src/BondEscalation.sol     # each is `external ... nonReentrant`, no whenNotPaused
```

### 6.4 Addresses

The dispute contracts (`$BOND_ESCALATION`, `$COMPOSITE_MEDIATOR`) are written back to
`deployments/aip14b.json` -> `networks.<net>.disputeContracts` by the P4-1 deploy script. Until that
broadcast lands they are `AWAIT_BROADCAST`; pull them from the deploy artifact / env, never hardcode.
Kernel/vault/USDC for Base Sepolia are in `deployments/aip14b.json` -> `networks.base-sepolia.existing`.
The live Base-mainnet UMA OOV3 is `0x2aBf1Bd76655de80eDB3086114315Eec75AF500c` (DEFAULT_UMA_OOV3).

---

## 7. Quick reference card

```
PAUSE FREEZES (entry):     openDispute, submitAIRuling, proposeDirectly, challenge, escalateToUMA
                           (+ settleUMAAssertion -- an entry helper; its downstream resolve is NOT frozen)
PAUSE NEVER FREEZES (INV-9, recovery):
                           finalize, forceResolveStale, claimEscalationRefund, syncExternalResolution
                           (+ retryMediatorResolution)

R17 RULE:  Tier-2 settleable-but-unsettled -> settleUMAAssertion FIRST. Never forceResolveStale a clean
           UMA verdict into a 50/50. forceResolveStale Tier-2 only when UMA truly never delivered.

KEEPER:    settleUMAAssertion records you as pendingSettler -> bounty max(pool*10%, $0.10) on the win.
           Net $0 to AGIRAILS (carved from the disputers' own Tier-1 pool). Settle within 24h of liveness.

ALERTS:    see ops/aip14b/monitoring-alerts.md for the full event -> alert -> owner -> threshold map.
```
