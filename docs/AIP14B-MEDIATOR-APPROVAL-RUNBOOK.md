# AIP-14b — CompositeMediator Approval Runbook (PRD P4-3 / P6-2)

> Scope: registering the **CompositeMediator contract** as an approved kernel resolver via
> `ACTPKernel.approveMediator(composite, true)`, and the **2-day `MEDIATOR_APPROVAL_DELAY`
> calendar gate** that must elapse before the mediator can resolve a real dispute.
>
> Refs: PRD §5.1 (kernel resolver-auth edit sites), §11 (rollout checklist), **INV-13**
> (dual-gate resolver auth), AIP14B-DECISIONS.md G1 (admin-only + mediator, **no pauser**).
> Script: `script/ApproveCompositeMediator.s.sol`. Config: `deployments/aip14b.json`.

---

## 0. The one thing to get right

**The approved mediator is the `CompositeMediator` CONTRACT — never an evaluator EOA.**

The kernel's resolver set is `{admin} ∪ {approved mediators past their 2-day timelock}`
(`ACTPKernel._isApprovedResolver`, §5.1 / INV-13). The 3-LLM evaluators sign AI rulings *inside
BondEscalation*; they have **no** kernel privilege. The kernel only ever recognizes the single
`CompositeMediator` bridge (AIP-14b §6) as a resolver. Approving an evaluator address here would be
a security bug, not a wiring shortcut.

This is enforced by the deploy order in `deployments/aip14b.json#wiring.deployOrder` step 4:
`kernel.approveMediator(compositeMediator, true)` — the argument is always the step-1 CompositeMediator
write-back address.

---

## 1. Why a 2-day timelock exists (INV-13 dual-gate)

`approveMediator(mediator, true)` does **not** make the mediator a live resolver immediately. It sets:

```
approvedMediators[mediator]  = true
mediatorApprovedAt[mediator] = block.timestamp + MEDIATOR_APPROVAL_DELAY   // +2 days
```

A DISPUTED→{SETTLED,CANCELLED} resolution is authorized only when **both** gates pass
(`_isApprovedResolver`, used at *both* "Resolver only" require sites — the settle path and the
cancel path — which is exactly what **INV-13** locks as a dual-gate edit):

```
approvedMediators[sender] == true
&& mediatorApprovedAt[sender] != 0
&& block.timestamp >= mediatorApprovedAt[sender]
```

So for the first **2 days** after approval, a CompositeMediator-routed resolution **reverts**:

- `"Mediator approval pending"` — when the kernel reaches the mediator-payout / resolution guards
  (`require(block.timestamp >= mediatorApprovedAt[mediator], "Mediator approval pending")`), or
- `"Resolver only"` — at the `_enforceAuthorization` / `_handleCancellation` resolver-auth gate
  (`require(_isApprovedResolver(msg.sender), "Resolver only")`).

The window is a **detect-and-cancel** safety margin: a mistaken or rushed approval can be revoked
before the mediator can ever move funds. It is deliberately **not** a protection against a compromised
admin/Safe — INV-6 keeps admin able to resolve immediately; admin-key risk is mitigated by Safe 2-of-3
key custody, not by this timelock (see the `_isApprovedResolver` NatSpec in `src/ACTPKernel.sol`).

---

## 2. The calendar gate (operational rule)

```
T+0h     Broadcast approveMediator(composite, true)   →  timelock STARTS
         (mediatorApprovedAt = T + 48h)
...
T+48h    Timelock ELAPSES                              →  mediator becomes a live resolver
         (block.timestamp >= mediatorApprovedAt)
T+48h+   First CompositeMediator-routed DISPUTED→SETTLED test may run
```

**Rule:** broadcast `approveMediator` **as early as possible** in the deploy sequence (right after
P4-1/P4-2 wiring), so the 2-day clock is already running while the rest of the rollout proceeds. Do
**not** schedule any mediator-routed resolution test (P4-1 happy-path E2E, P4-5 UMA fork smoke
on-chain leg, P6-2 first mainnet dispute) until **+48h** has passed. Put the unlock timestamp on the
team calendar at broadcast time.

This is identical in spirit to the kernel's other 2-day governance gates (`ECONOMIC_PARAM_DELAY`,
the AgentRegistry-update timelock) — same delay constant value (`2 days`), separate state.

---

## 3. Sepolia (testnet) — direct broadcast

Admin on Sepolia is the deployer EOA, so the call is a normal key broadcast.

```bash
# Prereqs: P4-1 wrote CompositeMediator into deployments/aip14b.json; export the address.
export COMPOSITE_MEDIATOR_ADDRESS=0x...            # from aip14b.json write-back (P4-1)
export KERNEL_ADDRESS=0x469CBADbACFFE096270594F0a31f0EEC53753411   # or the P4-2 v2 kernel
export PRIVATE_KEY=0x...                            # deployer == kernel.admin()

forge script script/ApproveCompositeMediator.s.sol \
  --rpc-url $BASE_SEPOLIA_RPC \
  --broadcast
```

The script self-checks `sender == kernel.admin()` (onlyAdmin) before broadcasting, then asserts
`approvedMediators[composite] == true` and `mediatorApprovedAt != 0` after. It prints the exact
resolver-eligible unix timestamp.

> Note (G3 / P4-2): if the kernel was redeployed as v2, pass the **v2** `KERNEL_ADDRESS` explicitly.
> The Sepolia default literal in the script is the *current pre-v2* ground-truth kernel; it is a
> convenience default, not a hardcoded broadcast target — env always wins.

> Note (Tier-2 on Sepolia): there is **no UMA OOV3 on Base Sepolia** (G2 probe 2026-06-21), so the
> full Tier-2 escalation path is exercised on a **Base-mainnet fork** (P4-5), not live Sepolia. The
> mediator-approval timelock itself is chain-agnostic and is validated on live Sepolia via the
> Tier-0/1 DISPUTED→SETTLED path.

---

## 4. Mainnet — Gnosis Safe (2-of-3), NO keys in any file

Admin on mainnet is the Gnosis Safe `0x61fE58E9EdB380EA65EC74bD364D9D2cba30B7f2` (2-of-3).
`approveMediator` is `onlyAdmin`, so it **must** be a Safe transaction. **Do not** put any private
key in any file and **do not** broadcast.

Run the script **without** `PRIVATE_KEY` to emit Safe-submittable calldata:

```bash
export COMPOSITE_MEDIATOR_ADDRESS=0x...     # mainnet CompositeMediator (P6-1 write-back)
export KERNEL_ADDRESS=$MAINNET_KERNEL_V2     # P4-2/P6-1 v2 kernel, NOT pre-v2 0x132B...2d29
unset PRIVATE_KEY

forge script script/ApproveCompositeMediator.s.sol --rpc-url $BASE_MAINNET_RPC
```

It prints:

```
to:    <kernel v2 address>
value: 0
data:  <approveMediator(composite, true) ABI-encoded calldata>
```

The Safe operator builds a transaction with exactly that `to` / `value` / `data`, collects 2-of-3
signatures, and executes. This matches `deployments/aip14b.json#safeCalldata.transactions[step 4]`.

After the Safe executes, the **+48h** calendar gate (§2) applies before the first mainnet dispute can
be mediator-resolved (PRD P6-2: "2-day timelock observed before first mainnet dispute").

---

## 5. Post-timelock success check (the P4-3 / P6-2 acceptance gate)

The approval is correct **iff**, at `T+48h` or later, on-chain reads show:

```
approvedMediators[composite]  == true
mediatorApprovedAt[composite] != 0   &&   mediatorApprovedAt[composite] <= now
```

Read them directly (no key needed):

```bash
cast call $KERNEL_ADDRESS "approvedMediators(address)(bool)"     $COMPOSITE_MEDIATOR_ADDRESS --rpc-url $RPC
cast call $KERNEL_ADDRESS "mediatorApprovedAt(address)(uint256)" $COMPOSITE_MEDIATOR_ADDRESS --rpc-url $RPC
# success condition: bool == true AND uint256 <= current block.timestamp (and != 0)
```

**Functional proof:** after the gate, a CompositeMediator-routed `DISPUTED → SETTLED` (or `→ CANCELLED`
on a split) **succeeds** — it does **not** revert with `"Mediator approval pending"` or
`"Resolver only"`. Concretely: drive a transaction to DISPUTED, then have BondEscalation finalize a
ruling so `CompositeMediator.resolve()` calls `kernel.resolveDisputeWhilePaused(txId, SETTLED, proof)`.
Before `T+48h` this reverts; at/after `T+48h` it lands and funds distribute. That before/after pair is
the executable P4-3 acceptance evidence (Sepolia) and the P6-2 mainnet equivalent.

---

## 6. C-1 penalty — revoke → re-approve costs another 2 days

`approveMediator(mediator, false)` revokes and records `mediatorRevokedAt = now`. The **C-1 fix**
blocks re-approval until the cooldown elapses:

```
re-approve allowed only when  block.timestamp >= mediatorRevokedAt[mediator] + MEDIATOR_APPROVAL_DELAY
```

Calling `approveMediator(mediator, true)` inside that window **reverts**
`"Cannot bypass timelock via revoke-reapprove"`. So a **revoke → re-approve costs a fresh 2 days**,
and after the eventual re-approval the *new* `mediatorApprovedAt` is **another +2 days** out — i.e. a
revoke during an incident effectively re-arms a full timelock before the mediator can resolve again.

Operational implications:
- **Rollback (P6-4):** the documented emergency order is **pause BondEscalation → INV-6 admin
  fallback → revoke mediator**. Revoking the mediator is the *last, heaviest* lever precisely because
  of this 2-day re-approval penalty; prefer pause + admin resolution for transient incidents and keep
  revoke for confirmed mediator compromise.
- **Idempotent re-approval:** `approveMediator(composite, true)` when the mediator is *already*
  approved does **not** reset `mediatorApprovedAt` (the `if (!approvedMediators[mediator])` guard) —
  so re-running this script is safe and will not silently restart or shorten the clock.

The script (`ApproveCompositeMediator.s.sol`) surfaces a prior revocation: if
`mediatorRevokedAt != 0` it prints the earliest re-approval timestamp and **reverts the script**
(`"C-1: revoke->re-approve 2-day penalty not elapsed"`) rather than broadcasting a call that would
revert on-chain.

---

## 7. Pre-flight checklist

- [ ] `COMPOSITE_MEDIATOR_ADDRESS` is the **CompositeMediator contract** (P4-1/P6-1 write-back in
      `aip14b.json`), **not** an evaluator EOA, **not** the BondEscalation address.
- [ ] `KERNEL_ADDRESS` is the resolver kernel the dispute system wires against (G3 v2 on the redeploy
      path; the pre-v2 ground-truth kernel only on the legacy wiring).
- [ ] CompositeMediator is fully wired first: `CompositeMediator.bondEscalation != 0`
      (`initialize` ran, G4 write-once) **before** approving it.
- [ ] Mainnet: `PRIVATE_KEY` is **unset**; calldata is Safe-submitted (admin == Safe 2-of-3).
- [ ] Calendar entry created for **broadcast time + 48h** = mediator-resolver unlock.
- [ ] No mediator-routed resolution test scheduled before that unlock.
- [ ] Post-gate: `approvedMediators[composite]==true && mediatorApprovedAt<=now` confirmed by
      `cast call`, and a DISPUTED→SETTLED resolution succeeds (no `"Mediator approval pending"` /
      `"Resolver only"`).

---

## 8. References

- `src/ACTPKernel.sol` — `approveMediator` (L593), `_isApprovedResolver` (L755), the two
  `"Resolver only"` sites and the three `"Mediator approval pending"` guards, `MEDIATOR_APPROVAL_DELAY`
  (`2 days`).
- `src/CompositeMediator.sol` — the thin ruling→kernel bridge; the only contract approved here.
- `script/ApproveCompositeMediator.s.sol` — this runbook's executable counterpart.
- `deployments/aip14b.json` — `wiring.deployOrder` (step 4), `postDeployTimelock`,
  `safeCalldata.transactions` (step 4).
- PRD §5.1 (resolver-auth edit sites), §11 (rollout), **INV-13** (dual-gate), AIP14B-DECISIONS.md
  G1 (admin-only + mediator, no pauser) / G3 (redeploy) / G4 (write-once init), C-1 fix (revoke
  cooldown).
- PRD rows: **P4-3** (this task, Sepolia), **P6-2** (mainnet Safe + 2-day gate), **P6-4** (rollback /
  revoke penalty).
