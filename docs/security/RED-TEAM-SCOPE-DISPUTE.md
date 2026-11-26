# Red team scope: dispute stack (ACTP #16)

| | |
|---|---|
| Decision | ACTP #16, Damir's ODLUKA of 26.11.2026, 14:32 CET (scope and severity criterion); sent to this session by the ODLUKA of 26.11.2026, 16:59 CET |
| Code base | `origin/main` at `ab7c608` (actp-kernel) |
| Status | Scope document for the red team. It records what to attack and what the code is meant to do. It is not an audit, and it makes no statement that any of this code is correct or safe. |

The red team works from this document, reports findings in the format of §6, and the mainnet gate in §2 is
applied to those findings. Existing tests and `docs/AIP14B-THREAT-MODEL.md` are starting points for repro tests,
not evidence that a scenario is closed.

---

## 1. Scope

### In scope

| Area | Files on `origin/main` |
|---|---|
| Bond-escalation engine (Tier 0/1) and UMA bridge (Tier 2) | `src/BondEscalation.sol` |
| Ruling → kernel state mapper | `src/CompositeMediator.sol` |
| Shared ruling type | `src/interfaces/DisputeTypes.sol` (`AIRuling`) |
| Interfaces | `src/interfaces/IBondEscalation.sol`, `src/interfaces/IBondEscalationAdmin.sol`, `src/interfaces/ICompositeMediator.sol` |
| Kernel dispute and resolver paths | `src/ACTPKernel.sol`: the DELIVERED → DISPUTED edge, the DISPUTED → SETTLED / CANCELLED exits, resolver authorization, proof decoding, escrow and bond distribution, pause behaviour of these paths |
| Escrow vault | `src/escrow/EscrowVault.sol`: escrow payouts and the dispute entry bond (`depositBond`, `releaseBond`) |
| UMA integration | `BondEscalation.escalateToUMA`, `settleUMAAssertion`, `assertionResolvedCallback`, `assertionDisputedCallback`, `retryMediatorResolution`, and the OOV3 interface `src/interfaces/IOptimisticOracleV3.sol` |

### Out of scope

Verbatim from the decision:

> Izvan opsega: SDK, posrednik i proxy (Q1).

(Out of scope: the SDK, the intermediary service (posrednik) and the proxy, both planned for Q1. Neither is a
contract in this repository.)

Nothing else is excluded. Off-chain components that are not in this repo (for example the evaluator service
that produces signatures) appear here only as the source of inputs; the on-chain checks of those inputs are in
scope.

---

## 2. Severity criterion and gate

Verbatim from the decision of 14:32:

> • CRITICAL: netko može ukrasti ili trajno zaključati tuđa sredstva, ili presuditi spor bez ovlasti.
> • HIGH: ishod spora se može izmanipulirati; sredstva zapnu nakon roka pa treba admin; pauza se može zaobići.
> • Sve ostalo je MEDIUM ili LOW i ne blokira mainnet.
>
> Gate: nula otvorenih HIGH/CRITICAL.

English gloss (the Croatian text above is binding):

- **CRITICAL:** someone can steal or permanently lock other people's funds, or rule on a dispute without authority.
- **HIGH:** the outcome of a dispute can be manipulated; funds get stuck after a deadline so an admin is needed;
  the pause can be bypassed.
- **MEDIUM / LOW:** everything else. Does not block mainnet.
- **Gate:** zero open HIGH/CRITICAL findings.

Every finding names the clause it meets (for example "HIGH: pauza se može zaobići"). Earlier accepted residuals
are not pre-accepted under this gate: `docs/AIP14B-THREAT-MODEL.md` §7 (settlement apathy, 2-of-3 evaluator
collusion, DVM correctness) is listed again as scenarios below and is classified anew.

---

## 3. System map

### 3.1 Roles

| Role | Where it is defined | What it can do in the dispute stack |
|---|---|---|
| Requester, provider | `ACTPKernel` transaction fields | Open a kernel dispute (DELIVERED → DISPUTED, `Party only`) inside `disputeWindow`; post the entry bond through `EscrowVault.depositBond` |
| Kernel admin | `ACTPKernel.onlyAdmin` | Is a resolver (`_isApprovedResolver` returns true for `admin`, INV-6); approves mediators and vaults; schedules vault revocation; `updateDisputeBondBps`; `emergencyRecoverUSDC` (only while paused); pause and unpause |
| Kernel pauser | `ACTPKernel.onlyPauser` (pauser or admin) | `pause`, `unpause`. Not a resolver (decision G1) |
| Approved mediator | `approvedMediators`, `mediatorApprovedAt`, `MEDIATOR_APPROVAL_DELAY` | Resolver after the timelock. In the deployed design this is `CompositeMediator` |
| BondEscalation | `CompositeMediator.bondEscalation`, `onlyBondEscalation` | The only caller of `CompositeMediator.resolve` |
| CompositeMediator deployer | `CompositeMediator.deployer` | One-shot `initialize` |
| BondEscalation admin | `BondEscalation.onlyAdmin` | `pause`, `unpause`, `transferAdmin`, evaluator and prompt-CID proposals, `removeFromRotatingPool` |
| Evaluators | `fixedEvaluators`, `rotatingPool` | Sign `AIRuling` (EIP-712, 2 of 3) for `submitAIRuling` |
| UMA OOV3 | `BondEscalation.UMA_OOV3` | The only caller of `assertionResolvedCallback` and `assertionDisputedCallback` |
| Anyone | no modifier | `openDispute`, `proposeDirectly`, `challenge`, `finalize`, `forceResolveStale`, `syncExternalResolution`, `escalateToUMA`, `settleUMAAssertion`, `retryMediatorResolution`, `claimEscalationRefund` (own deposit), timelocked `execute*` functions; on the kernel `releaseEscrow`, `retryPlatformFee`, `retryReputation`, `recoverStalledInProgress`, `executeEscrowVaultRevocation` |

### 3.2 Entry points

Generated from `forge inspect <Contract> methodIdentifiers` on `ab7c608`; getters are omitted. "Pausable"
means the function carries `whenNotPaused` of its own contract.

**`src/BondEscalation.sol`**

| Function | Access | Pausable | Notes |
|---|---|---|---|
| `openDispute` | anyone | yes | Kernel state must be DISPUTED; one dispute per `txId` (`disputeId = keccak256(abi.encode("ACTP_DISPUTE_V1", txId))`, `Already opened`) |
| `proposeDirectly` | anyone | yes | `tier == 0`; pulls the initial bond (`_calculateInitialBond`) |
| `submitAIRuling` | anyone, signature-gated | yes | `tier == 0`; CID binding; `_verifyEvaluatorSignatures` |
| `challenge` | anyone | yes | `tier == 1`, `block.timestamp <= d.livenessEnd`, different outcome, doubled bond capped at `MAX_ESCALATION_BOND` |
| `finalize` | anyone | no | `tier == 1`, `block.timestamp > d.livenessEnd`; pays the keeper bounty, then winner or split, then `compositeMediator.resolve` |
| `claimEscalationRefund` | depositor | no | split or `tier1Refundable` only |
| `syncExternalResolution` | anyone | no | Kernel no longer DISPUTED; local 50/50 bookkeeping |
| `forceResolveStale` | anyone | no | After `MAX_DISPUTE_DURATION`; Tier 2 also after `escalatedAt + UMA_LIVENESS + TIER2_STALE_GRACE`; resolves 50/50 |
| `escalateToUMA` | anyone | yes | `tier == 1`, `currentBond >= MAX_ESCALATION_BOND`, inside liveness, once |
| `settleUMAAssertion` | anyone | yes | Records `pendingSettler`, calls `settleAssertion` |
| `assertionResolvedCallback` | `UMA_OOV3` only | no | Pays Tier-1 pool, then `try compositeMediator.resolve`; on failure sets `mediatorRetryPending` |
| `assertionDisputedCallback` | `UMA_OOV3` only | no | Event only |
| `retryMediatorResolution` | anyone | no | `d.resolved` and `mediatorRetryPending` |
| `pause`, `unpause` | admin | — | |
| `transferAdmin` / `acceptAdmin` | admin / pending admin | — | Two-step |
| `proposeFixedEvaluatorUpdate`, `cancelFixedEvaluatorUpdate` | admin | — | `EVALUATOR_UPDATE_DELAY` |
| `executeFixedEvaluatorUpdate` | anyone after timelock | — | Disjointness checks |
| `proposeRotatingPoolAddition` | admin | — | Max `MAX_ROTATING_POOL` |
| `executeRotatingPoolAddition` | anyone after timelock | — | Re-checks disjointness at execute time |
| `removeFromRotatingPool` | admin | — | Immediate, keeps at least one member |
| `proposePromptCID`, `cancelPromptCID` | admin | — | |
| `executePromptCID` | anyone after timelock | — | |

**`src/CompositeMediator.sol`**

| Function | Access | Notes |
|---|---|---|
| `initialize` | `deployer`, once | Sets `bondEscalation` |
| `resolve` | `onlyBondEscalation` | Ruling 0/1 → 96-byte proof, SETTLED; ruling 2 → 64-byte proof, CANCELLED; both through `kernel.resolveDisputeWhilePaused`; `ZERO_REMAINING_SENTINEL` when `escrowPrincipal == 0` |

**`src/escrow/EscrowVault.sol`**

| Function | Access | Notes |
|---|---|---|
| `createEscrow`, `payoutToProvider`, `refundToRequester`, `payout`, `depositBond`, `releaseBond` | `onlyKernel` | `_disburse` caps at `amount - releasedAmount`; `releaseBond` checks `bondBalances` |
| `verifyEscrow`, `remaining`, `bondBalance` | view | |

**`src/ACTPKernel.sol` (dispute and resolver paths)**

| Function | Access | Pausable | Notes |
|---|---|---|---|
| `transitionState` | per edge in `_enforceAuthorization` | yes | DELIVERED → DISPUTED: `Party only`, `Dispute window closed`; DISPUTED → SETTLED/CANCELLED: `Resolver only` |
| `resolveDisputeWhilePaused` | `_isApprovedResolver` | no | `Resolve only`, `Not disputed`, `Resolver only` |
| `releaseMilestone` | requester | yes | IN_PROGRESS only; can empty the escrow before a dispute |
| `releaseEscrow` | anyone | no | SETTLED only |
| `retryPlatformFee` | anyone | no | Re-drives `pendingPlatformFeeFor` |
| `retryReputation` | anyone | no | SETTLED, or CANCELLED with `wasDisputed` and no `resultHash` |
| `recoverStalledInProgress` | anyone | no | IN_PROGRESS after `deadline + recoveryGrace` |
| `approveMediator` | admin | — | `MEDIATOR_APPROVAL_DELAY`, revoke-reapprove cooldown |
| `approveEscrowVault`, `scheduleEscrowVaultRevocation` | admin | — | Revocation behind `ECONOMIC_PARAM_DELAY` |
| `executeEscrowVaultRevocation` | anyone after timelock | — | Every payout path requires `approvedEscrowVaults` |
| `updateDisputeBondBps` | admin | — | In-flight rate locked (`disputeBondBpsLocked`) |
| `emergencyRecoverUSDC` | admin | requires paused | Kernel balance only |
| `pause`, `unpause` | pauser or admin | — | |
| `transferAdmin`, `acceptAdmin`, `updatePauser` | admin / pending admin | — | |

### 3.3 Fund pools

| Pool | Custodian | Moved by |
|---|---|---|
| Escrow principal | `EscrowVault.escrows` | Kernel only (`_payoutProviderAmount`, `_refundRequester`, `_payoutMediator`, `_distributeFee`) |
| Entry dispute bond | `EscrowVault.bondBalances` | Kernel only (`_distributeBond`, `_distributeBondOnCancellation`) |
| Tier-1 escalation bonds | `BondEscalation` (`accumulatedBonds`, `deposits`) | `finalize`, `claimEscalationRefund`, `assertionResolvedCallback` |
| UMA assertion bond | UMA OOV3 | UMA `settleAssertion` |

---

## 4. Attack categories

Scenario IDs are stable so findings can cite them. "Expected" is taken from `require` strings and NatSpec in the
code. Where the code does not define the intended outcome, the entry says so: **not defined by the code — the red
team reports, Damir classifies.**

### 4.1 Neovlaštene radnje (otvaranje, presuda ili isplata od strane nekoga tko nije strana u sporu ili nema ulogu)

*Gloss: unauthorized actions — opening, ruling or payout by someone who is not a party or has no role.*

**Surface:** `ACTPKernel._enforceAuthorization`, `_isApprovedResolver`, `resolveDisputeWhilePaused`,
`_handleCancellation` (second resolver check), `_payoutMediator`; `CompositeMediator.onlyBondEscalation`,
`initialize`; `EscrowVault.onlyKernel`; `BondEscalation.onlyAdmin`, the `UMA_OOV3` check in both callbacks,
`claimEscalationRefund`, `_verifyEvaluatorSignatures`.

**Assumptions:** the kernel admin is a multisig; `CompositeMediator` is the only approved mediator; evaluator
keys are honest unless a scenario says otherwise.

| ID | Scenario to attempt | Expected |
|---|---|---|
| RT-A-01 | A non-party calls `transitionState(txId, DISPUTED, …)` on a DELIVERED transaction | Revert `Party only` |
| RT-A-02 | A party disputes after `disputeWindow` | Revert `Dispute window closed` |
| RT-A-03 | Requester, provider, pauser, a random address and a mediator still inside `MEDIATOR_APPROVAL_DELAY` each try DISPUTED → SETTLED and DISPUTED → CANCELLED through `transitionState` and through `resolveDisputeWhilePaused` | Revert `Resolver only` |
| RT-A-04 | Revoke a mediator and re-approve it at once (`approveMediator`) to skip the timelock | Revert `Revoke-reapprove timelock`; starting point `test/M2_MediatorTimelockBypassTest.t.sol` |
| RT-A-05 | Call `CompositeMediator.resolve` from any address other than `bondEscalation`; call `initialize` as non-deployer, twice, or with zero | Reverts `Only tier system`, `Only deployer`, `Already initialized`, `bondEscalation=0` |
| RT-A-06 | Call every `EscrowVault` mutating function directly | Revert `Only kernel` |
| RT-A-07 | A third party front-runs `openDispute` for someone else's DISPUTED transaction, or calls it for a transaction that is not DISPUTED | Not DISPUTED: revert `Not in DISPUTED state`. Third-party opener: allowed by the code; the opener only appears in `DisputeOpened`. Whether this gives the opener any advantage is **not defined by the code — the red team reports, Damir classifies** |
| RT-A-08 | A non-party with bond capital drives the Tier-1 game alone: `proposeDirectly` with a chosen ruling, parties offline, `finalize` after `_livenessForEscrow` | The code allows any bonder (INV-16). Whether a non-party can decide a dispute this way when parties do not react inside the liveness window is **not defined by the code — the red team reports, Damir classifies** (candidate clause: "ishod spora se može izmanipulirati") |
| RT-A-09 | `submitAIRuling` with: signatures from non-evaluators; the same signer twice; a rotating pick that equals a fixed evaluator; malformed or high-s signatures; a ruling whose `disputeId` differs from the argument | `Insufficient valid signatures`, duplicate signer counted once, overlap zeroed (`thirdCandidate`), malformed signatures skipped, `Mismatched disputeId`; starting point `test/BondEscalationAdversarial.t.sol` |
| RT-A-10 | `claimEscalationRefund` by a non-depositor, or on a winner-takes-all dispute | `Nothing to claim`; `Not a split - winner takes all` |
| RT-A-11 | Call `assertionResolvedCallback` or `assertionDisputedCallback` from an address other than `UMA_OOV3` | Revert `Only UMA` |
| RT-A-12 | Non-admin calls every `onlyAdmin` function in `BondEscalation`; non-nominee calls `acceptAdmin` | `Only admin`; `Not pending admin` |
| RT-A-13 | Resolver submits a 128- or 160-byte resolution proof naming an unapproved or still-timelocked paid mediator, or a mediator amount above `MAX_MEDIATOR_FEE_BPS` | `Mediator not approved`, `Mediator approval pending`, `Med fee too high` |
| RT-A-14 | Evaluator governance: make one keypair control two of the three votes through `proposeFixedEvaluatorUpdate`, `executeFixedEvaluatorUpdate`, `proposeRotatingPoolAddition`, `executeRotatingPoolAddition`, including the queue route (propose rotating X, change a fixed slot to X, execute rotating X) | `Fixed slots must differ`, `Fixed overlaps rotating`, `Rotating overlaps fixed`, `Duplicate rotating` |

### 4.2 Replay

*Gloss: replaying signatures, callbacks, claims or identifiers.*

**Surface:** `BondEscalation._verifyEvaluatorSignatures` (`RULING_TYPEHASH`, `DOMAIN_SEPARATOR`,
`RULING_FRESHNESS`, `RULING_MAX_FUTURE_SKEW`), `submitAIRuling`, `escalateToUMA` (CID re-derivation),
`openDispute`, `assertionResolvedCallback`, `retryMediatorResolution`, `claimEscalationRefund`;
`ACTPKernel.linkEscrow` (`usedEscrowIds`), `_clearUsedEscrowId`.

| ID | Scenario to attempt | Expected |
|---|---|---|
| RT-R-01 | Replay a signed `AIRuling` on another dispute | `disputeId` is in the struct and the digest: `Mismatched disputeId` or `Insufficient valid signatures` |
| RT-R-02 | Replay the same ruling on the same dispute after a proposal exists | `Already escalated` (`tier == 0` required) |
| RT-R-03 | Replay across chains or deployments, including after a chain fork | Domain binds `block.chainid` and `address(this)`; `DOMAIN_SEPARATOR()` recomputes on chain-id change |
| RT-R-04 | Submit a ruling older than `RULING_FRESHNESS` or dated further ahead than `RULING_MAX_FUTURE_SKEW` | `Ruling stale`; `Ruling timestamp in future` |
| RT-R-05 | Swap the evidence or reasoning CID at `submitAIRuling` or at `escalateToUMA` | `Evidence CID mismatch`; `Reasoning CID mismatch`; starting point `test/BondEscalationD7Adversarial.t.sol` |
| RT-R-06 | Open a second dispute for the same `txId`; try to bring a transaction back into DISPUTED | `Already opened`; `_isValidTransition` only allows DELIVERED → DISPUTED |
| RT-R-07 | Deliver `assertionResolvedCallback` twice for one assertion, or for an unknown `assertionId` | Second call: `UMACallbackIgnored`, no payout; unknown: `Unknown dispute` |
| RT-R-08 | Call `retryMediatorResolution` again after success, or with a different ruling | `No pending retry`; the ruling is read from storage (`d.currentRuling`, `d.splitBps`), not from the caller |
| RT-R-09 | Claim the same escalation refund twice | `deposits` is zeroed before transfer: `Nothing to claim` |
| RT-R-10 | Reuse an `escrowId` in the same vault so entry-bond accounting (`bondBalances[escrowId]`) mixes two transactions | `Escrow ID already used`; `_clearUsedEscrowId` is a no-op on `ab7c608`; starting point `test/EscrowReuseTest.t.sol` |

### 4.3 Preslagivanje transakcija

*Gloss: transaction reordering — front-running, back-running, ordering at boundaries.*

**Surface:** `BondEscalation.proposeDirectly` vs `submitAIRuling` (both need `tier == 0`), `challenge` vs
`finalize` at `livenessEnd`, `escalateToUMA` (`lastProposerForRuling` left unchanged), `settleUMAAssertion`
(`pendingSettler`), `syncExternalResolution` / `forceResolveStale` vs kernel admin resolution;
`ACTPKernel._enforceTiming` at `disputeWindow`; `releaseMilestone` before delivery.

| ID | Scenario to attempt | Expected |
|---|---|---|
| RT-O-01 | Front-run a pending `submitAIRuling` with `proposeDirectly`, so the signed ruling can no longer land | Signed ruling reverts `Already escalated`; the dispute continues in Tier 1 from the direct proposal. Whether this lets a party steer the outcome is **not defined by the code — the red team reports, Damir classifies** |
| RT-O-02 | `challenge` and `finalize` in the same block at `livenessEnd` and at `livenessEnd + 1` | Mutually exclusive: `challenge` needs `<= livenessEnd` (`Liveness expired`), `finalize` needs `> livenessEnd` (`Liveness active`) |
| RT-O-03 | A non-bonder front-runs `escalateToUMA` to capture the Tier-1 pool | `lastProposerForRuling` is not overwritten by the escalator; with no proposer for the winning direction the pool becomes refundable (`tier1Refundable`) |
| RT-O-04 | Front-run another keeper's `settleUMAAssertion` to take the settle bounty | The bounty goes to `pendingSettler`, the caller of `settleUMAAssertion`; a direct `settleAssertion` on the oracle pays no bounty |
| RT-O-05 | Order kernel admin resolution, `finalize`, `syncExternalResolution` and `forceResolveStale` against each other | Once the kernel is no longer DISPUTED, BondEscalation only syncs (`ExternalResolutionSynced`), sets ruling 2 / `splitBps` 5000 and makes Tier-1 bonds refundable; `compositeMediator.resolve` is not called |
| RT-O-06 | Requester disputes and a third party auto-settles in the block where `block.timestamp == disputeWindow`, and one block later | Dispute needs `<= disputeWindow`; non-requester settle needs `> disputeWindow` (`Requester decision pending`) |
| RT-O-07 | Requester drains the escrow with `releaseMilestone` in IN_PROGRESS, then the transaction is delivered and disputed with nothing left | `CompositeMediator.resolve` emits `ZERO_REMAINING_SENTINEL`; kernel distributes nothing (`if (remaining > 0)`) and still distributes the entry bond; dispute must remain finalizable |
| RT-O-08 | Change the escrow principal between the kernel's DISPUTED transition and `openDispute` (for example through `retryPlatformFee`) so `escrowAmount` cached at `openDispute` differs from the principal at resolution | Bond size and liveness use the cached `escrowAmount`; the mediator reads the live `escrowPrincipal`. Any divergence and its effect is **not defined by the code — the red team reports, Damir classifies** |

### 4.4 Djelomični padovi

*Gloss: partial failures — one leg of a multi-step operation fails.*

**Surface:** `BondEscalation.assertionResolvedCallback` (`try compositeMediator.resolve … catch`,
`mediatorRetryPending`, `MediatorResolutionDeferred`), `finalize` and `forceResolveStale` (no try/catch around
`compositeMediator.resolve`), `escalateToUMA` (`_resolveWhitelistedIdentifier`, `getMinimumBond`);
`ACTPKernel._distributeFee` (try/catch, `pendingPlatformFeeFor`), `_recordReputation` (try/catch, gas-capped),
`_payoutProviderAmount` / `_refundRequester` / `_payoutMediator` (all require `approvedEscrowVaults`);
`EscrowVault._disburse`, `releaseBond`.

| ID | Scenario to attempt | Expected |
|---|---|---|
| RT-P-01 | Make the kernel leg revert inside `assertionResolvedCallback` (vault revoked, fee recipient reverting, gas starvation) | Callback does not revert; Tier-1 bonds are paid; `mediatorRetryPending` set; escrow movement re-drivable via `retryMediatorResolution`; starting point `MockOOV3.setCallbackGasLimit` |
| RT-P-02 | Make `compositeMediator.resolve` revert permanently during `finalize`, for example by executing a scheduled vault revocation (`scheduleEscrowVaultRevocation`, then `executeEscrowVaultRevocation`) while a dispute is open | `finalize` reverts as a whole (bounty and winner payout roll back). `forceResolveStale` calls the same `resolve` and would also revert. Whether funds then need an admin action (re-approving the vault) is **not defined by the code — the red team reports, Damir classifies** (candidate clause: "sredstva zapnu nakon roka pa treba admin") |
| RT-P-03 | Make a USDC transfer to a specific recipient fail (token-level blocklist on the winner, the keeper, the requester or the provider) in `finalize`, `claimEscalationRefund`, the UMA callback or a kernel payout | Each of these uses `safeTransfer` without try/catch except the callback's kernel leg. Which disputes become unresolvable, and whether the 50/50 `forceResolveStale` path then changes the outcome, is **not defined by the code — the red team reports, Damir classifies** |
| RT-P-04 | Fee recipient or archive treasury reverts during a dispute settlement | `_distributeFee` catches; fee stays reserved (`pendingPlatformFeeFor`) and `retryPlatformFee` re-drives it; participant principal unaffected |
| RT-P-05 | Agent registry reverts or burns gas during `_recordReputation` | Caught (gas cap 150000 in `_recordReputation`); settlement proceeds; `retryReputation` re-drives |
| RT-P-06 | `settleAssertion` on the oracle reverts inside `settleUMAAssertion` | Whole call reverts, `pendingSettler` not left set; dispute stays Tier 2 |
| RT-P-07 | No whitelisted UMA identifier, or `getMinimumBond` above `UMA_BOND` | `No whitelisted UMA identifier` before any bond is pulled; bond posted is `max(UMA_BOND, getMinimumBond)` |
| RT-P-08 | `releaseBond` with a bond balance lower than `disputeBond` | Revert `Insufficient bond`; the whole kernel resolution reverts. Whether any path leads there is **not defined by the code — the red team reports, Damir classifies** |

### 4.5 Retry i oporavak

*Gloss: retry and recovery paths.*

**Surface:** `BondEscalation.retryMediatorResolution`, `forceResolveStale` (`MAX_DISPUTE_DURATION`,
`TIER2_STALE_GRACE`, `escalatedAt`), `syncExternalResolution`, `claimEscalationRefund` (split snapshot:
`accumulatedBonds` / `originalPool`); `ACTPKernel.retryPlatformFee`, `retryReputation`, `releaseEscrow`,
`recoverStalledInProgress`, `emergencyRecoverUSDC`; the admin resolver path (INV-6).

| ID | Scenario to attempt | Expected |
|---|---|---|
| RT-X-01 | Use `retryMediatorResolution` to enact a ruling other than the stored one, or to resolve a dispute the kernel already closed | Ruling comes from storage; a closed kernel transaction makes `resolve` revert and the flag stays set |
| RT-X-02 | Losing party waits until `MAX_DISPUTE_DURATION` passes without anyone calling `finalize`, then calls `forceResolveStale` to turn a full loss into 50/50 (Tier 1, and Tier 0 with no proposal at all) | The code allows this whenever `finalize` has not run first. `AIP14B-THREAT-MODEL.md` §7 lists settlement apathy as accepted; under this gate the outcome is **not defined by the code — the red team reports, Damir classifies** (candidate clause: "ishod spora se može izmanipulirati") |
| RT-X-03 | Call `forceResolveStale` on a Tier-2 dispute before the DVM has answered, including a dispute escalated late in its life | Revert `UMA pending: settle assertion first` until `escalatedAt + UMA_LIVENESS + TIER2_STALE_GRACE` |
| RT-X-04 | Kernel admin resolves the transaction directly while a Tier-1 game or a UMA assertion is live | BondEscalation syncs on its next touch; Tier-1 bonds become split-refundable; UMA callback no-ops (`ExternalResolutionSynced`); UMA bond follows UMA |
| RT-X-05 | Split refunds: rounding, last claimer, claims after a winner-takes-all leg, `originalPool == 0` | Σ shares ≤ snapshot; `Not resolved` before resolution. Any stranded remainder is **not defined by the code — the red team reports, Damir classifies** |
| RT-X-06 | Recovery calls during kernel pause: `releaseEscrow`, `retryPlatformFee`, `retryReputation`, `recoverStalledInProgress` | Allowed (no `whenNotPaused`) |
| RT-X-07 | `emergencyRecoverUSDC` used to reach escrow or bond funds | Requires pause (`Must be paused`) and transfers only the kernel's own balance; vault funds unreachable from this function |

### 4.6 Zaobilaženje pauze

*Gloss: bypassing the pause.*

**Surface:** `ACTPKernel.whenNotPaused` (`transitionState`, `linkEscrow`, `releaseMilestone`, …) vs
`resolveDisputeWhilePaused`; `BondEscalation.whenNotPaused` (`openDispute`, `proposeDirectly`,
`submitAIRuling`, `challenge`, `escalateToUMA`, `settleUMAAssertion`) vs the unpaused `finalize`,
`claimEscalationRefund`, `syncExternalResolution`, `forceResolveStale`, `retryMediatorResolution` and both UMA
callbacks. The two contracts have separate pause flags and separate admins.

| ID | Scenario to attempt | Expected |
|---|---|---|
| RT-Z-01 | While the kernel is paused, use `resolveDisputeWhilePaused` for any edge other than DISPUTED → SETTLED/CANCELLED, or as a non-resolver | `Resolve only`, `Not disputed`, `Resolver only` |
| RT-Z-02 | While BondEscalation is paused, the Tier-1 liveness keeps running: a party cannot `challenge` (`Paused`), then anyone calls `finalize` after `livenessEnd` | Code: `finalize` is not pausable and `livenessEnd` is not extended by a pause. Whether a pause can decide a dispute this way is **not defined by the code — the red team reports, Damir classifies** (candidate clauses: "pauza se može zaobići", "ishod spora se može izmanipulirati") |
| RT-Z-03 | While BondEscalation is paused, settle a UMA assertion by calling `settleAssertion` on the oracle directly | Callback is not pausable and resolves the dispute; only the bounty path (`settleUMAAssertion`) is paused. Whether this counts as bypass is **not defined by the code — the red team reports, Damir classifies** |
| RT-Z-04 | Kernel paused, BondEscalation not: open a new kernel dispute | Blocked: DELIVERED → DISPUTED goes through `transitionState` (`Kernel paused`), so `openDispute` finds no DISPUTED transaction |
| RT-Z-05 | Kernel paused: `finalize` → `CompositeMediator.resolve` → `resolveDisputeWhilePaused` | Allowed by design (INV-9); `CompositeMediator` must be an approved, timelocked resolver |
| RT-Z-06 | Pauser role tries to resolve | Not a resolver (G1): `Resolver only` |
| RT-Z-07 | Any other state-changing path into escrow or bonds while paused (`releaseMilestone`, `linkEscrow`, `acceptQuote`, `transitionState`) | `Kernel paused` |

### 4.7 Eskalacija na UMA tier (rokovi, bond, ishodi)

*Gloss: escalation to the UMA tier — deadlines, bond, outcomes.*

**Surface:** `BondEscalation.escalateToUMA` (`MAX_ESCALATION_BOND`, `UMA_BOND`, `UMA_LIVENESS`,
`_resolveWhitelistedIdentifier`, `MAX_CID_LENGTH`, claim text), `settleUMAAssertion`,
`assertionResolvedCallback` (`assertedTruthfully` → ruling 0, otherwise ruling 1; `lastProposerForRuling`;
`FINALIZATION_BOUNTY_BPS`; `tier1Refundable`), `assertionDisputedCallback`, `forceResolveStale` (Tier-2
branch); `src/interfaces/IOptimisticOracleV3.sol`; test double `test/mocks/MockOOV3.sol`; fork test
`test/E2E_UMA_Fork.t.sol`.

| ID | Scenario to attempt | Expected |
|---|---|---|
| RT-U-01 | Escalate before the bond reaches `MAX_ESCALATION_BOND`, after liveness, twice, from Tier 0, with empty or oversized CIDs | `Bond ceiling not reached`, `Liveness expired - use finalize()`, `Not in Tier 1` (Tier 0, and a second escalation because the tier is already 2; the later `Already escalated` check on `disputeToAssertion` is the second guard), `CID required`, `CID too long` |
| RT-U-02 | UMA bond accounting: the bond is pulled from the escalator and never enters `accumulatedBonds` | Tier-1 payouts never include the UMA bond |
| RT-U-03 | Winner selection: several proposers alternate rulings; check who receives the Tier-1 pool for each UMA outcome, including a superseded early proposer and a split proposer (`lastProposerForRuling[d][2]` can never win through UMA) | Winner is `lastProposerForRuling[disputeId][ruling]`; none → `tier1Refundable`, no bounty. Fairness of this rule under the criterion is **not defined by the code — the red team reports, Damir classifies** |
| RT-U-04 | Claim text injection: for a dispute without signed evidence (reached Tier 1 through `proposeDirectly`), pass CID strings that change the meaning of the `abi.encodePacked` claim sent to the DVM | CIDs are bounded by `MAX_CID_LENGTH` but not validated as CIDs when no signed reference exists. Effect on the DVM outcome is **not defined by the code — the red team reports, Damir classifies** |
| RT-U-05 | Incentive asymmetry: the assertion always states that the provider delivered, and the escalator is the asserter. A requester-side escalator therefore bonds against its own position | Not defined by the code — the red team reports, Damir classifies |
| RT-U-06 | Deadlines: assertion liveness (`UMA_LIVENESS`), the DVM dispute path (`assertionDisputedCallback`), late callbacks after `forceResolveStale`, and the `escalatedAt` anchor | Late callback after local resolution: `UMACallbackIgnored`; stale backstop as in RT-X-03 |
| RT-U-07 | Callback reentrancy and gas: re-enter BondEscalation from the callback, run the callback with low gas | `nonReentrant` on the callback; kernel leg deferred as in RT-P-01 |
| RT-U-08 | Oracle misbehaviour within the interface: no callback, two callbacks, callback for another contract's assertion, wrong currency | No callback → RT-X-03; two → RT-R-07; unknown assertion → `Unknown dispute`. `AIP14B-THREAT-MODEL.md` §7 accepts DVM correctness as a residual; under this gate it is listed, not pre-accepted |
| RT-U-09 | 2-of-3 evaluator collusion produces a ruling that nobody challenges inside liveness | Enters as a challengeable Tier-1 proposal (INV-16); the threat model §7 residual is re-classified under this gate |

---

## 5. Test harness

- Shared fixture: `test/helpers/DisputeTestBase.sol`.
- Oracle double: `test/mocks/MockOOV3.sol` (`mockResolve`, `mockDispute`, `mockArmResult`, `setCallbackGasLimit`).
- Existing starting points: `test/BondEscalationThreatModel.t.sol`, `test/BondEscalationAdversarial.t.sol`,
  `test/BondEscalationD7Adversarial.t.sol`, `test/BondEscalationInvariant.t.sol`, `test/CompositeMediator.t.sol`,
  `test/UMAIntegration.t.sol`, `test/E2E_UMA_Fork.t.sol`, `test/AdminPauseStrandProbe.t.sol`,
  `test/M2_MediatorTimelockBypassTest.t.sol`, `test/H2_EmptyDisputeResolutionTest.t.sol`,
  `test/EscrowReuseTest.t.sol`.
- New repro tests go under `test/redteam/`, one file per finding, named after the finding ID.
- Baseline on `ab7c608` (forge 1.9.0): `forge build` exit 0; `forge test` 55 suites, 808 passed, 0 failed,
  5 skipped.

---

## 6. Finding format

```markdown
### RT-<category letter>-<scenario>-<n>: <one-line title>

- Category: <one of the seven categories in §4, verbatim>
- Scenario: <ID from §4, or "new">
- Severity: CRITICAL | HIGH | MEDIUM | LOW
- Criterion clause: <the exact clause from §2 the finding meets>
- Affected code: <path> `<Contract.function>` (+ modifier / role involved)
- Preconditions: <roles, state, timing>
- Steps: <numbered>
- Impact: <who loses what, or what is blocked>
- Repro: `test/redteam/<ID>.t.sol`, test `<testName>`, run `forge test --match-test <testName> -vvv`
- Expected (from the code): <require string / NatSpec>
- Actual: <observed>
- Status: OPEN | FIXED <commit> | INVALID <reason, with the repro showing it>
- Reporter / date:
```

Rules:

- A finding is valid only with a Foundry repro test that fails on the affected commit.
- HIGH and CRITICAL leave OPEN only as FIXED (the repro test passes on the fix commit) or INVALID (the repro shows
  the behaviour is not reachable). Severity changes and any acceptance are Damir's decision, recorded in the
  finding.
- Gate check before mainnet: count of findings with Severity HIGH or CRITICAL and Status OPEN is zero.

---

## 7. Verification list

Every function, modifier, constant, revert string and file named in this document was checked against
`origin/main` at `ab7c608` with the commands below. Each must print at least one line.

```bash
# BondEscalation functions, modifiers, constants and revert strings
for s in "function openDispute" "function proposeDirectly" "function submitAIRuling" "function challenge" \
  "function finalize" "function claimEscalationRefund" "function syncExternalResolution" \
  "function forceResolveStale" "function escalateToUMA" "function settleUMAAssertion" \
  "function assertionResolvedCallback" "function assertionDisputedCallback" "function retryMediatorResolution" \
  "function _verifyEvaluatorSignatures" "function _calculateInitialBond" "function _livenessForEscrow" \
  "function _resolveWhitelistedIdentifier" "function DOMAIN_SEPARATOR" "function pause" "function unpause" \
  "function transferAdmin" "function acceptAdmin" "function proposeFixedEvaluatorUpdate" \
  "function executeFixedEvaluatorUpdate" "function cancelFixedEvaluatorUpdate" "function proposeRotatingPoolAddition" \
  "function executeRotatingPoolAddition" "function removeFromRotatingPool" "function proposePromptCID" \
  "function executePromptCID" "function cancelPromptCID" "modifier onlyAdmin" "modifier whenNotPaused" \
  "MAX_ESCALATION_BOND" "UMA_BOND" "UMA_LIVENESS" "MAX_DISPUTE_DURATION" "TIER2_STALE_GRACE" "RULING_FRESHNESS" \
  "RULING_MAX_FUTURE_SKEW" "EVALUATOR_UPDATE_DELAY" "MAX_ROTATING_POOL" "MAX_CID_LENGTH" "FINALIZATION_BOUNTY_BPS" \
  "RULING_TYPEHASH" "lastProposerForRuling" "tier1Refundable" "mediatorRetryPending" "pendingSettler" "escalatedAt" \
  "thirdCandidate" "ACTP_DISPUTE_V1" \
  "\"Already opened\"" "\"Not in DISPUTED state\"" "\"Mismatched disputeId\"" "\"Already escalated\"" \
  "\"Insufficient valid signatures\"" "\"Ruling stale\"" "\"Ruling timestamp in future\"" "\"Evidence CID mismatch\"" \
  "\"Reasoning CID mismatch\"" "\"Liveness expired\"" "\"Liveness active\"" "\"Nothing to claim\"" \
  "\"Not a split - winner takes all\"" "\"Not resolved\"" "\"Only UMA\"" "\"Unknown dispute\"" "\"No pending retry\"" \
  "\"UMA pending: settle assertion first\"" "\"Bond ceiling not reached\"" "\"Liveness expired - use finalize()\"" \
  "\"Not in Tier 1\"" "\"CID required\"" "\"CID too long\"" "\"No whitelisted UMA identifier\"" "\"Only admin\"" \
  "\"Not pending admin\"" "\"Fixed slots must differ\"" "\"Fixed overlaps rotating\"" "\"Rotating overlaps fixed\"" \
  "\"Duplicate rotating\"" "\"Paused\""; do
  git show origin/main:src/BondEscalation.sol | grep -cF -- "$s" | sed "s|^|BondEscalation  $s  |"
done

# CompositeMediator
for s in "function initialize" "function resolve" "modifier onlyBondEscalation" "ZERO_REMAINING_SENTINEL" \
  "resolveDisputeWhilePaused" "\"Only tier system\"" "\"Only deployer\"" "\"Already initialized\"" "\"bondEscalation=0\""; do
  git show origin/main:src/CompositeMediator.sol | grep -cF -- "$s" | sed "s|^|CompositeMediator  $s  |"
done

# EscrowVault
for s in "function createEscrow" "function payoutToProvider" "function refundToRequester" "function payout(" \
  "function depositBond" "function releaseBond" "function verifyEscrow" "function remaining" "function bondBalance" \
  "function _disburse" "modifier onlyKernel" "bondBalances" "\"Only kernel\"" "\"Insufficient bond\""; do
  git show origin/main:src/escrow/EscrowVault.sol | grep -cF -- "$s" | sed "s|^|EscrowVault  $s  |"
done

# ACTPKernel
for s in "function transitionState" "function resolveDisputeWhilePaused" "function _transitionState" \
  "function _enforceAuthorization" "function _enforceTiming" "function _isApprovedResolver" "function _isValidTransition" \
  "function _decodeResolutionProof" "function _handleDisputeSettlement" "function _handleCancellation" \
  "function _payoutProviderAmount" "function _refundRequester" "function _payoutMediator" "function _distributeFee" \
  "function _distributeBond" "function _distributeBondOnCancellation" "function _recordReputation" \
  "function _clearUsedEscrowId" "function linkEscrow" "function acceptQuote" "function releaseMilestone" "function releaseEscrow" \
  "function escrowPrincipal" "function retryPlatformFee" "function retryReputation" "function recoverStalledInProgress" \
  "function approveMediator" "function approveEscrowVault" "function scheduleEscrowVaultRevocation" \
  "function executeEscrowVaultRevocation" "function updateDisputeBondBps" "function emergencyRecoverUSDC" \
  "function pause" "function unpause" "function transferAdmin" "function acceptAdmin" "function updatePauser" \
  "modifier onlyAdmin" "modifier onlyPauser" "modifier whenNotPaused" "MEDIATOR_APPROVAL_DELAY" "ECONOMIC_PARAM_DELAY" \
  "MAX_MEDIATOR_FEE_BPS" "disputeBondBpsLocked" "pendingPlatformFeeFor" "usedEscrowIds" "approvedEscrowVaults" \
  "\"Party only\"" "\"Dispute window closed\"" "\"Resolver only\"" "\"Resolve only\"" "\"Not disputed\"" \
  "\"Revoke-reapprove timelock\"" "\"Mediator not approved\"" "\"Mediator approval pending\"" "\"Med fee too high\"" \
  "\"Requester decision pending\"" "\"Escrow ID already used\"" "\"Must be paused\"" "\"Kernel paused\""; do
  git show origin/main:src/ACTPKernel.sol | grep -cF -- "$s" | sed "s|^|ACTPKernel  $s  |"
done

# Types, interfaces, tests and mocks
git show origin/main:src/interfaces/DisputeTypes.sol | grep -c "struct AIRuling"
for f in src/interfaces/IBondEscalation.sol src/interfaces/IBondEscalationAdmin.sol src/interfaces/ICompositeMediator.sol \
  src/interfaces/IOptimisticOracleV3.sol docs/AIP14B-THREAT-MODEL.md test/helpers/DisputeTestBase.sol \
  test/mocks/MockOOV3.sol test/BondEscalationThreatModel.t.sol test/BondEscalationAdversarial.t.sol \
  test/BondEscalationD7Adversarial.t.sol test/BondEscalationInvariant.t.sol test/CompositeMediator.t.sol \
  test/UMAIntegration.t.sol test/E2E_UMA_Fork.t.sol test/AdminPauseStrandProbe.t.sol \
  test/M2_MediatorTimelockBypassTest.t.sol test/H2_EmptyDisputeResolutionTest.t.sol test/EscrowReuseTest.t.sol; do
  git cat-file -e origin/main:$f && echo "exists $f"
done
for s in "function mockResolve" "function mockDispute" "function mockArmResult" "function setCallbackGasLimit"; do
  git show origin/main:test/mocks/MockOOV3.sol | grep -cF -- "$s" | sed "s|^|MockOOV3  $s  |"
done
```

Second pass: every identifier written in backticks anywhere in this document must occur in `src/` or `test/` on
`origin/main`. The only tokens it may report are the non-code ones: `ab7c608`, the test file stems
`BondEscalationInvariant` and `BondEscalationThreatModel`, `methodIdentifiers`, `origin`, `redteam`, `testName`,
`tr`, and the words `RED`, `TEAM`, `THREAT`, `MODEL` from the two document file names.

```bash
git grep -h "" origin/main -- src test > /tmp/redteam-scope-src.txt
grep -oE '`[^`]+`' docs/security/RED-TEAM-SCOPE-DISPUTE.md | tr -d '`' | grep -oE '[A-Za-z_][A-Za-z0-9_]*' | sort -u |
  while read -r t; do grep -qw -- "$t" /tmp/redteam-scope-src.txt || echo "not in src/test: $t"; done
```

Result on `ab7c608`: every line of the first block printed a count of 1 or more, every file printed `exists`, and
the second pass reported only the non-code tokens listed above.
