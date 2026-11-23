# Slither triage: ACTP kernel on main

Tool: `slither-analyzer==0.11.6` with `crytic-compile==0.4.2`, run as
`slither . --fail-high --filter-paths 'lib/|test/|script/'`. Source: `src/` on
`main` at 3e8acc7. That tree's `src/` is byte-identical to the deployed b08c0c6
(`git diff b08c0c6 origin/main -- src foundry.toml` is empty).

Totals: 2 High, 13 Medium, 53 Low, 15 Informational, 5 Optimization.
**No real High or Critical.** Both High results are false positives, and nothing was
opened against #18.

Short ids are the first 12 hex characters of Slither's result `id`.

## High: suppressed through `slither.db.json`

| id | Detector | Location | Verdict |
|---|---|---|---|
| 311894c4e6b5 | arbitrary-send-erc20 | `EscrowVault.createEscrow` → `token.safeTransferFrom(requester, …)` | false positive |
| 3bbbf5624973 | arbitrary-send-erc20 | `EscrowVault.depositBond` → `token.safeTransferFrom(from, …)` | false positive |

Why these are false positives, re-checked against the current `ACTPKernel.sol`:

- `EscrowVault` has `onlyKernel` (`msg.sender == kernel`) on both functions. `kernel`
  and `token` are `immutable`. No other caller can reach `transferFrom`.
- `createEscrow` is called only from `ACTPKernel.linkEscrow` (lines 418–440).
  `linkEscrow` requires `approvedEscrowVaults[escrowContract]` and
  `msg.sender == txn.requester` ("Only requester"). It then passes `txn.requester` as
  `from`. The payer is always the caller who signed the transaction.
- `depositBond` is called only at line 351,
  `vault.depositBond(txn.escrowId, msg.sender, bond)`, during the DISPUTED transition.
  `_enforceAuthorization` (lines 854–869) restricts that transition to requester or
  provider ("Party only"). The bond payer is always `msg.sender`.
- `grep` finds no other `createEscrow` or `depositBond` call site in `src/`.

### Why a triage database, not source comments

The PR first suppressed these findings with `// slither-disable-next-line` comments in
`EscrowVault.sol`. We measured what those comments do to the bytecode by building main
with and without them under the repo's `foundry.toml`:

- Only `EscrowVault` changes. Every other contract's runtime bytecode is identical:
  ACTPKernel, BondEscalation, CompositeMediator, AgentRegistry, ArchiveTreasury and
  MockOOV3.
- In `EscrowVault`, the executable code is identical. Only the trailing CBOR metadata
  differs, because the source hash changes (ipfs `4da3fd…` vs `913ce5…`).
- The on-chain runtime codehash therefore changes. A source-verified explorer match
  against b08c0c6 would also break.

To keep `src/` byte-identical to what was deployed, `EscrowVault.sol` stays as on main.
The suppression lives in `slither.db.json`, which Slither reads from the repo root by
default. Slither drops a result when its `id` **or** its exact description matches an
entry. Both include file line numbers, so moving the flagged lines re-surfaces the finding.
Neither covers modifiers or function bodies: deleting `onlyKernel` from line 104 leaves the
line count unchanged, and the database alone would still suppress the finding. The
suppression is therefore valid only together with three CI checks in the Slither job:

1. **Content pin.** `slither.db.pins` holds the SHA-256 of `src/escrow/EscrowVault.sol`.
   Any edit to the vault fails the job until someone re-triages and re-pins it.
2. **Call-site check.** `createEscrow` and `depositBond` must be referenced exactly twice
   in `src/`, ignoring declarations and comments. Both references must be in
   `ACTPKernel.sol`, with the reviewed payer arguments: `txn.requester` for
   `createEscrow` and `msg.sender` for `depositBond`.
3. **Positive control.** A second Slither run with an empty triage database must produce
   exactly the triaged High findings. A stale entry, a new High, or an analysis that
   covers nothing fails the job.

Two forge tests, `testDepositBondRejectsNonKernel` and `testReleaseBondRejectsNonKernel`
in `test/EscrowVaultBranchCoverage.t.sol`, also pin the `onlyKernel` guard that the
false-positive verdict depends on. Before this PR, no test called the bond functions from
a non-kernel address.

Controls:

| Run | Result |
|---|---|
| no `slither.db.json` | exactly 2 High (the ids above), exit 255 |
| with `slither.db.json` | exit 0 |
| same tree copied to a different absolute path | exit 0 (the database is path-independent) |
| one comment line inserted at line 51 of `EscrowVault.sol`, shifting both flagged calls | exit 255 (fail-closed) |
| fresh venv with the CI pins | exit 0 |
| `onlyKernel` removed from line 104 (line count unchanged) | Slither alone: exit 0. Preconditions: `EscrowVault.sol: FAILED`. `testDepositBondRejectsNonKernel` fails |
| kernel `depositBond` payer changed to `txn.requester` | preconditions fail ("depositBond call site changed") |
| kernel `createEscrow` payer changed to `txn.provider` | preconditions fail ("createEscrow payer argument changed") |
| extra `abi.encodeCall(IEscrowValidator.createEscrow, …)` reference in the kernel | preconditions fail ("expected exactly two … references") |
| a ghost entry added to `slither.db.json` | positive control fails ("no longer matches a live finding") |
| one entry removed from `slither.db.json` | gate exit 255; positive control fails ("untriaged High") |

## Medium

Medium findings are keyed by detector and function, not by Slither `id`. An independent
reviewer got different ids for three of the reentrancy findings in another checkout, so
those ids are not a portable key. None of them is in the triage database.

| Detector | Location | Count | Verdict | Reason |
|---|---|---|---|---|
| incorrect-equality | AgentRegistry.sol:84 `registeredAt == 0` | 1 | false positive | sentinel for "not registered", not a balance or timestamp race |
| incorrect-equality | ACTPKernel.sol:299 `state == DISPUTED` | 1 | false positive | enum comparison |
| reentrancy-no-eth | ACTPKernel `_releaseEscrow` (987–997) | 2 | accepted risk, trusted callees | see note R |
| reentrancy-no-eth | ACTPKernel `_payoutProviderAmount` (1128–1166) | 1 | accepted risk, trusted callees | see note R |
| reentrancy-no-eth | ACTPKernel `_handleCancellation` (1051–1126) | 1 | accepted risk, trusted callees | see note R |
| reentrancy-no-eth | ACTPKernel `_handleDisputeSettlement` (1013–1049) | 1 | accepted risk, trusted callees | see note R |
| reentrancy-no-eth | ACTPKernel `_recordReputation` (999–1007) | 1 | accepted risk | see note R. The registry call is capped at 150000 gas and wrapped in `try`, and `reputationProcessedBy` is only read here |
| reentrancy-no-eth | BondEscalation `escalateToUMA` (657–757) | 1 | accepted risk, trusted callees | see note U |
| uninitialized-local | ACTPKernel.sol:1188–1189 `escrowedArchive`, `escrowedTreasury` | 2 | false positive | zero is the intended start value. Each is set only on its success branch and summed at line 1256 |
| uninitialized-local | BondEscalation.sol:991 `bool[3] seen` | 1 | false positive | zero-initialised "seen" bitmap for duplicate-signer rejection |
| unused-return | BondEscalation.sol:998 `ECDSA.tryRecover` | 1 | false positive | `signer` and `err` are used and `err` is checked. Only the third value (`errArg`, the diagnostic payload) is ignored |

**Note R (kernel reentrancy).** Every path that reaches these internal functions starts at
a `nonReentrant` entrypoint: `transitionState` (266), `resolveDisputeWhilePaused` (296),
`releaseMilestone` (477), `releaseEscrow` (498), `retryPlatformFee` (510),
`retryReputation` (517) and `recoverStalledInProgress` (537). `linkEscrow` (418) carries
the same guard. They share one OpenZeppelin guard, so no guarded kernel function can be
re-entered mid-payout. `pendingPlatformFeeFor` is read or written only at lines 513, 528,
994, 1155 and 1256, all behind `nonReentrant` or inside a `view`.

The external non-view kernel functions without the guard are:

- open to users: `createTransaction` (205), `acceptQuote` (460) and `anchorAttestation` (563);
- role-gated: `pause`/`unpause` (577, 583), `emergencyRecoverUSDC` (599) and the other
  `onlyAdmin` setters and schedulers;
- callable by anyone after a timelock: `acceptAdmin` (629, pending admin only) and the
  `execute*` functions at 668, 736 and 791.

None of them writes `pendingPlatformFeeFor` or escrow balances. `executeEscrowVaultRevocation`
(668) clears `approvedEscrowVaults`, but only after its timelock. A payout re-entering it
could only make a later approval check fail. `emergencyRecoverUSDC` is admin-only, works
only while paused, and can move USDC that the kernel holds transiently inside
`_distributeFee`. That is an admin trust assumption, not a reentrancy path.
The external callees are an admin-approved escrow vault, the timelocked `agentRegistry`,
the admin-set `archiveTreasury` and USDC. The cross-function target Slither names,
`_escrowPrincipal` (527–529), is `view`. The residual exposure is a read-only reentrancy:
the external `escrowPrincipal()` view could return an intermediate value if a callee called
back into it during a payout. Two contracts in `src/` read that view:

- `BondEscalation.openDispute` (321) stores it as `DisputeState.escrowAmount`. It requires
  the transaction to be DISPUTED, and the kernel commits the new state at line 355 before
  any payout.
- `CompositeMediator.resolve` (124) derives split amounts from it. It ends in the guarded
  `resolveDisputeWhilePaused` (`CompositeMediator.sol:153`), so a re-entrant call would
  revert.

One window exists: `retryPlatformFee` on a DISPUTED transaction, between `vault.payout`
(1246) and the decrement at 1256. Reaching it would need the approved vault or USDC to call
back into BondEscalation. We found no exploitable path with the trusted callees. This is
reasoning from code, with no PoC.

**Note U (UMA escalation).** `escalateToUMA` is `nonReentrant`. The call Slither flags goes
to `UMA_OOV3`, which is `immutable` (BondEscalation.sol:119). The function also calls USDC
and the UMA finder and whitelist (773–777), which are trusted infrastructure as well. The cross-function
targets `openDispute`, `settleUMAAssertion` and `syncExternalResolution` lack the guard.
`settleUMAAssertion` is intentionally unguarded (comment at 889–900), because the real
OOV3 calls the guarded `assertionResolvedCallback` from inside `settleAssertion`.
Exploiting this would require the UMA oracle itself to be malicious, which is outside the
threat model.

## Low

| Detector | Count | Verdict |
|---|---|---|
| timestamp | 48 (ACTPKernel 24, BondEscalation 17, ArchiveTreasury 3, AgentRegistry 3, AGIRAILSIdentityRegistry 1) | accepted risk: deadline, timelock and liveness comparisons measured in hours or days. Seconds of sequencer skew on Base do not change outcomes |
| reentrancy-benign | 4 (`_distributeFee`, `assertionResolvedCallback`, `settleUMAAssertion`, `escalateToUMA`) | false positive: the writes after the call are bookkeeping on `nonReentrant` paths, or the intentional `pendingSettler` clear described in note U |
| events-access | 1 (`CompositeMediator.initialize`, line 87) | accepted: one-shot wiring by the immutable `deployer`, guarded by `_initialized`. An event would add nothing an indexer cannot read from the deploy transaction |

## Informational

| Detector | Count | Verdict |
|---|---|---|
| naming-convention | 11 (functions, parameters, variables) | accepted: style only. Renaming public names would change the ABI |
| unindexed-event-address | 2 (`IBondEscalationAdmin.RotatingPoolUpdated`, `RotatingPoolAdditionProposed`) | accepted: low-volume admin events. Changing indexing changes event signatures and topics |
| too-many-digits | 1 (`AgentRegistry._calculateReputationScore`) | accepted: fixed-point scale literals |
| unused-state | 1 (`ACTPKernel.escrowProviderPaid`, line 110) | intentional: documented as a reserved legacy slot superseded by explicit fee-debt accounting |

## Optimization

| Detector | Count | Verdict |
|---|---|---|
| cache-array-length | 4 (BondEscalation 1100, 1156, 1177; AgentRegistry 340) | accepted: small admin-bounded arrays |
| immutable-states | 1 (`ACTPKernel.USDC`, line 91) | accepted for now: making it `immutable` changes kernel bytecode, and the kernel is 191 B under the size limit. Candidate for the next kernel version |

## CI supply chain

Echidna is pinned by version and release SHA-256. `slither-analyzer` and `crytic-compile`
are pinned by version, but their transitive pip dependencies are not hash-locked.
Accepted for now: both jobs run with `contents: read` and hold no secrets, so a compromised
dependency could at worst produce a false green. Follow-up: a hash-locked requirements file
for the security-tools venv.

The `main` ruleset currently enforces only no-deletion and no-force-push, and requires no
status checks. Until `Slither (gate on HIGH)` and `Echidna (EscrowVault solvency)` are
required checks, a red gate shows on the PR but does not block the merge.

## What changes in this PR

- No `src/` change. `EscrowVault.sol` matches main and b08c0c6.
- `slither.db.json`: the two reviewed High entries. `slither.db.pins`: the SHA-256 of
  `EscrowVault.sol` those entries were reviewed against.
- Tests: `onlyKernel` tests for `depositBond` and `releaseBond`.
- CI, Slither job: pinned versions, the preconditions step, the High gate and the positive
  control.
- CI, new Echidna job: the EscrowVault solvency campaign (`balance == outstanding`) and
  three mutation controls. The relaxed `amount <= available + 1` bound must be caught. A
  bond that is never pulled and an escrow that over-pulls by one must both make the
  property return false. A vacuous campaign or an always-true property cannot pass.
