# Mainnet Redeploy Plan — Pre-Deploy Threat Model

> **Status**: Plan (not executed). Approved sequencing below.  Execution is gated on multisig signoff and a final pre-flight check the day-of.
>
> **Drafted**: 2026-05-18 (Apex Faza 1 threat-model pass).
> **Source audit**: Apex 2026-05-17 `actp-kernel-refresh.md`, forward note "mainnet redeploy readiness".

## Why redeploy

Current mainnet kernel `0x132B9eB321dBB57c828B083844287171BDC92d29` (deployed 2026-02-09) is **storage-incompatible** with every behavioural improvement that landed since `d3be22e` (pre-AIP-14). Specifically missing:

| Feature | Commit | Impact today |
|---------|--------|--------------|
| AIP-14 dispute bonds + outcome-based reputation | `cbc643e` | No economic skin-in-game on disputes |
| ERC-8004 `agentId` param on createTransaction | `5e47c40` | Reputation hooks half-wired |
| AgentRegistry v2 (configHash / configCID / listed) | `3df0214` | Profiles can't sync from chain |
| 11 April audit fixes (H-1 prep, M-1..M-4, L-1..L-4, CEI fix) | `6d500ab` | Documented vulnerabilities open |
| Re-registration reputation-wipe + feeRecipient DOS fix | `141abc4` | Two exploitable paths |
| PRD-0 audit (X402Relay two-step admin, AgentRegistry zero-address guard) | `d1d1288` | Admin-takeover risk |
| `acceptQuote()` for negotiation price updates | `ed1bfb3` | AIP-2.1 multi-round negotiation broken |
| Permissionless auto-settle after dispute window | `91f4f90` | **6 of 9 live mainnet txs stuck right now** |
| Per-tx `requesterPenaltyBpsLocked` + pauser removed from resolver + dust guard + milestone-drained settle fix | `d9c6e8e` | Governance bumps retroactively re-price open txs; pauser can resolve disputes; some legitimate flows revert |

The kernel also has `agentRegistry()` set to `0x0` on-chain — the schedule/execute timelock dance was never run on mainnet, so AIP-7 reputation tracking has never functioned in production. Same gap we closed on Sepolia 2026-05-12 with `executeAgentRegistryUpdate()`.

**Conclusion**: this is a clean replacement, not an upgrade. Storage layout changes alone forbid an in-place upgrade; the diff scope and pause/resolver auth tightening make it the right time to retire the old kernel.

---

## What's on mainnet today (state-of-the-world)

**Kernel** `0x132B9eB321dBB57c828B083844287171BDC92d29`
- `admin` = `0x61fE58E9EdB380EA65EC74bD364D9D2cba30B7f2` (2-of-3 Gnosis Safe)
- `pauser` = same Safe (currently identical role; new kernel separates them)
- `paused` = false
- `platformFeeBps` = 100 (1%)
- `agentRegistry` = `0x0000000000000000000000000000000000000000` ← never set

**Live txs since deploy (2026-02-09 → 2026-04-18)**: **9 created, 3 SETTLED, 5 DELIVERED (stuck), 1 COMMITTED (stuck). 0 disputed.** 27 days of silence after 2026-04-18.

| # | Date | Amount | Provider | State |
|---|------|--------|----------|-------|
| 1 | 2026-02-21 | $1.00 | `0xf40dfd…c838` | ? |
| 2 | 2026-02-21 | $3.69 | `0x9ee3a0…2d20` | ? |
| 3 | 2026-02-24 | $0.10 | `0x809e3d…d7f4` | ? |
| 4 | 2026-02-24 | $0.05 | `0x7cb192…c9c9` | ? |
| 5 | 2026-02-25 | $0.05 | `0x7cb192…c9c9` | ? |
| 6 | 2026-02-25 | $0.05 | `0x7cb192…c9c9` | ? |
| 7 | 2026-02-27 | $10.00 | `0x760ad5…ad0d` | ? |
| 8 | 2026-04-18 | $2.00 | `0xf172d9…355f` | ? |
| 9 | 2026-04-18 | $2.00 | `0xf172d9…355f` | ? |

> Per-tx state needs to be re-pulled the day-of from `StateTransitioned` event log. Without permissionless auto-settle on the old kernel, the 6 stuck txs require explicit `transitionState` calls from the original provider (or admin via dispute path) — they will not heal on their own.

**Total at-risk USDC in old escrow**: ~$13–17 (depending on which 6 are stuck and at what state). Symbolic exposure, but operationally important not to abandon escrows that still hold funds.

---

## Address surface map (what needs updating where)

Hardcoded mainnet addresses are well-scoped: every SDK has a single config file, and there are no scattered references inside library code.

| Surface | File(s) | Notes |
|---------|---------|-------|
| **sdk-js** | `src/config/networks.ts`, `src/config/networks.test.ts`, `src/protocol/ACTPKernel.test.ts` | 1 source + 2 test fixtures |
| **python-sdk-v2** | `src/agirails/config/networks.py` | 1 file |
| **n8n-nodes-actp** | (none — uses `@agirails/sdk`) | Re-publish picks up new SDK |
| **agirails-mcp-server** | (none — uses `@agirails/sdk`) | Re-publish picks up new SDK |
| **agirails.app web** | `app/api/cron/index-stats/route.ts` (lines 22-30, mainnet `CHAINS` entry) | Update `kernel` + `deployBlock` |
| **agirails.app web** | `vercel env` BASE_MAINNET_RPC already set to Tenderly — no change |
| **CDP + Pimlico paymaster allowlists** | external — managed via dashboards | Add new addresses BEFORE Vercel deploy to avoid gas-sponsorship gap |
| **Documentation** | `docs-site/docs/**/*.md` (12 files); `actp-kernel/SECURITY.md`, `actp-kernel/deployments/TESTING.md`; `actp-kernel/deployments/base-mainnet.json` (NEW — does not exist yet) | Docs can lag deploy by a few hours, not lockstep-critical |
| **Random project notes** | `WhatsApp.md`, `PLAN-agent-friendly-docs.md`, `SANITY-CHECK.md`, `agirails.app/resources/PRDs/20-LAUNCHPAD-MVP.md` | Personal notes — update if convenient, not on critical path |

**No address ends up in published bundle code** — all SDK call sites resolve via `getNetwork(networkName).contracts.X`. Good.

**Action item**: create `deployments/base-mainnet.json` mirroring the Sepolia file so future tooling (and Apex's next audit pass — they specifically flagged its absence) can consume mainnet metadata.

---

## Solidity compiler decision

`foundry.toml` currently pins `solc_version = "0.8.20"` + `via_ir = true`. Solidity bug catalogue (as of 2026-05-17) lists **9 bugs introduced ≤ 0.8.20 and unfixed at 0.8.20**, of which **4 touch via_ir / Yul-optimizer paths** we exercise:

1. **FullInlinerNonExpressionSplitArgumentEvaluationOrder** — argument-evaluation-order bug with FullInliner
2. **VerbatimInvalidDeduplication** — Yul optimizer mis-unifies `verbatim` blocks
3. **InlineAssemblyMemorySideEffects** — Yul optimizer may drop inline-asm memory writes
4. **StorageWriteRemovalBeforeConditionalTermination** — optimizer may drop storage writes preceding conditional termination

Plus 5 non-via_ir bugs (ABI re-encoding, dirty bytes copy, storage array slot overflow, missing `.selector` evaluation, transient-storage clearing collision).

**Recommendation**: bump to **0.8.34** for the redeploy. Storage layout is changing anyway, so the cost of a compiler bump is zero. 0.8.34 closes all 9 listed bugs **including** the `TransientStorageClearingHelperCollision` bug specifically flagged by Apex's 2026-05-17 weekly digest (introduced in 0.8.28, unfixed through 0.8.33). Sticking with 0.8.20 means we ship known optimizer pathologies as cheaply replaced as bumping a string.

**Validation step**: run the full forge suite + invariant fuzz under 0.8.34 before deploy. Diff the size report against 0.8.20 (expected: small bytecode shifts, no semantic changes). Pin compiler version explicitly in `foundry.toml`.

---

## Stuck-tx migration strategy

Three options considered:

| Option | Description | Pros | Cons |
|--------|-------------|------|------|
| A. Forced migration | Settle / cancel all 9 txs on old kernel before deprecating | Clean break, no orphan escrows | Provider-side action required for 6 stuck txs; some providers may be gone; manual outreach |
| B. Coexist (default) | Deploy new kernel, leave old one running. Old txs eventually heal or expire. New traffic goes to new kernel. | Zero migration drama; symmetric to how every L2 contract upgrade works | Old escrow funds stay locked until provider returns or admin disputes them out |
| C. Hybrid (recommended) | Coexist for 60 days while reaching out to stuck providers via off-chain channels. After 60d, admin force-resolves remaining stuck txs via `transitionState(DISPUTED → SETTLED)` (allowed under d9c6e8e admin-only resolver, but **only on the new kernel** — the OLD kernel has the old resolver allowlist) | Best of both: not abandoning escrows, not blocking deploy on outreach | Two kernels alive during transition; documentation burden |

**Recommendation**: **Option C**. The 6 stuck txs total ~$13–17 in mU SDC — small economic exposure that doesn't justify blocking the deploy. 60-day outreach window is generous; if it lapses, admin resolves the remainder.

> **Important nuance**: dispute resolution on the OLD kernel happens under the OLD allowlist (`admin || pauser` — both currently the Safe). Force-resolve flow is available now; we don't need new-kernel features to clean up old-kernel state.

**60-day deadline**: ~2026-07-17. Add this to the rollout checklist + a Vercel cron reminder.

---

## Lockstep deployment sequence

The on-chain pieces and off-chain pieces have different change-control surfaces, so they upgrade in **two coordinated phases**:

### Phase 1 — On-chain deploy (multisig actions, ~30–60 min wall time)

1. **Pre-flight on-chain checks** (read-only)
   - `cast call <OLD_KERNEL> "paused()(bool)"` → confirm `false`
   - Confirm Safe is still 2-of-3 with expected signers
   - Confirm Tenderly mainnet RPC is healthy (we depend on it; cron + indexer + this checklist)
   - Re-pull stuck-tx state and freeze the migration list

2. **Deploy MockUSDC stand-in** — N/A (mainnet uses Circle's USDC `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`).

3. **Deploy new ACTPKernel** via `forge script script/DeployBaseMainnet.s.sol --broadcast --rpc-url $BASE_MAINNET_RPC --private-key $DEPLOYER_KEY`
   - Sets `admin = Safe`, `pauser = <new dedicated pauser EOA>` (NOT the Safe — role separation per d9c6e8e), `feeRecipient = ArchiveTreasury`, `agentRegistry = 0x0` (constructor default), `usdc = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`
   - Verify Sourcify exact-match in the same step (Apex FIND-015 carry-forward)

4. **Deploy new EscrowVault** with `token = USDC`, `kernel = <new kernel>`. Verify Sourcify.

5. **Deploy new AgentRegistry** with `actpKernel = <new kernel>`. Verify Sourcify.

6. **Deploy new ArchiveTreasury** with `usdc, kernel, uploader = deployer`. Verify Sourcify.

7. **Multisig post-deploy wiring (Safe transactions, 2-of-3)**
   1. `kernel.approveEscrowVault(<new vault>)` — **must precede any user-facing flow**, per Apex
   2. `kernel.setArchiveTreasury(<new treasury>)`
   3. `kernel.scheduleAgentRegistryUpdate(<new registry>)` — 2-day timelock starts
   4. `vault.setKernel(<new kernel>)` — if Vault requires explicit kernel acknowledgment (check current Vault interface; on Sepolia this is implicit via immutable constructor arg)

8. **Wait 2 days for AgentRegistry timelock** OR proceed without registry and execute later (acceptable — reputation tracking is non-functional today already; not a regression).

9. **`kernel.executeAgentRegistryUpdate()`** — permissionless, anyone can call. Set a 2-day calendar reminder.

10. **Paymaster allowlists** (CDP + Pimlico dashboards): add new kernel, vault, registry. Do this BEFORE Phase 2 step 1 so gasless flows don't break.

11. **X402Relay decision**: **do NOT redeploy**. Sepolia metadata marks it deprecated (`status: deprecated`, SDK 3.3.0+ direct-routes via `@x402/fetch`). Old X402Relay can stay on the old kernel; no need on the new one. Document the absence in `base-mainnet.json`.

### Phase 2 — Off-chain switch (~15 min wall time, coordinated PR)

After Phase 1 lands and `executeAgentRegistryUpdate` has been called:

1. **`agirails.app/web`** — Edit `app/api/cron/index-stats/route.ts` mainnet `CHAINS` entry:
   - `kernel` → new address
   - `deployBlock` → new deploy block
   - Push to master → Vercel auto-deploy
   - Next cron tick (≤5 min) starts indexing from new kernel
   - Old kernel events stop being indexed; receipts for old-kernel settlements after this point won't mint. Document this — owners of stuck txs that ever settle on old kernel won't get a public receipt. Symbolic loss; old txs were never meant to be the receipts-system showcase.

2. **`sdk-js`** — Edit `src/config/networks.ts` + 2 test fixtures. Bump version (likely 4.0.0 since this is breaking for mainnet integrators). Publish.

3. **`python-sdk-v2`** — Edit `src/agirails/config/networks.py`. Bump version (mirror SDK-js). Publish.

4. **`n8n-nodes-actp`** — Bump `@agirails/sdk` dependency to the new TS version. Publish.

5. **`agirails-mcp-server`** — Bump `@agirails/sdk` dependency. Publish.

6. **Docs site** — Update 12 markdown files + regenerate. Lower-priority; can lag by hours.

7. **Cosmetic project notes** (`WhatsApp.md`, `PLAN-agent-friendly-docs.md`, `SANITY-CHECK.md`, `LAUNCHPAD-MVP.md`) — update opportunistically.

8. **Create `deployments/base-mainnet.json`** mirroring the Sepolia file. Push to actp-kernel repo.

---

## EIP-712 + cross-deployment replay analysis

Apex's forward-watch SWC-121 framing: any signed payload during the transition window that doesn't bind to (chainId, verifyingContract, version) tightly is replayable across the old and new kernel.

**Audit list** (the SDK surfaces that ever sign):

| Surface | Domain binding | Risk after deploy |
|---------|----------------|-------------------|
| AIP-13 keystore wallet-sig auth | `chainId` only | Replay risk MEDIUM — old and new kernel share chainId 8453 |
| AIP-2.1 negotiation signed messages | `chainId + nonce` | Replay risk LOW — nonce binding |
| Web Receipts EIP-712 ReceiptWrite | `chainId + nonce + issuedAt` | Replay risk LOW — server-issued nonce |
| `agirails.app` API upsertAgent message | timestamp + slug only | Replay risk LOW — slug uniqueness on server |
| ACTP transaction ids (`keccak256(requester, provider, amount, serviceHash, nonce)`) | requesterNonce only | Replay risk MEDIUM — same requester+provider+amount on both kernels would produce the same txId |

**Mitigation** — add `verifyingContract` (the kernel address) to every signed domain that doesn't already have it. Action items for the SDK version that ships with the new mainnet kernel:

- AIP-13 keystore auth: include kernel address in domain separator
- ACTP transactionId derivation: include kernel address in the hash preimage (this requires kernel-side cooperation — out of scope for this redeploy, document as known transition-window risk)

**Acceptable risk during transition window**: the txId collision risk needs the same requester to send the same (provider, amount, serviceHash, nonce) tuple to BOTH kernels. In practice the SDK only ever points to one kernel at a time, and AIP-13 keystore-signed bundles are short-lived. We accept this risk for the transition window with documentation, fix it in a follow-up SDK release.

---

## Rollback plan

The new kernel is **additive** — old kernel keeps working independently. So rollback isn't "rolling back the deploy" — it's "reverting the off-chain switch":

1. **Revert agirails.app web commit** that switched indexer to new kernel → `git revert <sha> && git push origin master`
2. **Revert SDK config commits + re-publish previous version** as a patch bump (e.g. 4.0.0 → 4.0.1 with old addresses restored)
3. **n8n + MCP + python SDK** repeat the SDK-config revert pattern
4. **Paymaster allowlists** — leave new kernel allowlisted; no harm in over-approval. Don't remove until the post-rollback investigation is done.

Maximum rollback wall time: ~30 min, gated on `npm publish` and `vercel deploy` durations.

**Kill-switch on new kernel** — if a critical bug is found post-deploy, multisig calls `kernel.pause()` on the new kernel. All write paths revert. Read paths stay live. This is the hard-stop while we decide between rollback (revert off-chain switch) and fix-forward (deploy a third kernel).

---

## Monitoring + integration with existing ACTP-BETA-PROD plan

`ACTP-BETA-PROD-MONITORING-KILLSWITCH-ROLLOUT-PLAN.md` (root AGIRAILS) already covers:
- `actp_ops_total{op,network,result}` Prometheus counters
- 24/7 on-call rotation
- Kill-switch via `ACTP_WRITES_ENABLED=false` env flag
- 10% → 50% → 100% canary gates

**Integration points for this redeploy**:

1. Add new kernel address to the existing dashboards' `network` label dimension (no schema change — same Prometheus label, new value seen).
2. The 10% → 50% → 100% canary applies to **client-side traffic** (SDK fraction-rolling). Since we're flipping the SDK config atomically in npm, the canary is implicit in npm-update cadence — agents that update SDK first hit the new kernel; laggers stay on old until they `npm install` again. This is naturally gradual rollout over days/weeks, which is what we want.
3. Set a hard kill-switch on the SDK side too: `ACTP_KERNEL_OVERRIDE` env var can point any agent back to the old kernel if needed during transition. Document for integrators in release notes.

---

## Pre-flight checklist (day-of)

Run through this list immediately before kicking off Phase 1.

- [ ] Tenderly mainnet RPC healthy (`cast block-number --rpc-url ...` returns recent)
- [ ] Safe still 2-of-3 with expected signers (`gh api ...` Safe app or Safe Transaction Service API)
- [ ] Re-pull stuck-tx state from old kernel logs — finalize the 60-day outreach list
- [ ] `forge build --sizes` under solc 0.8.34 — confirm bytecode fits and no semantic regressions
- [ ] `forge test -vvv` under solc 0.8.34 — full suite green
- [ ] `forge coverage --report summary` under solc 0.8.34 — coverage hasn't regressed
- [ ] Slither pass — review any NEW findings vs the Sepolia baseline
- [ ] Pimlico + CDP paymaster dashboards open in browser tab — ready to allowlist
- [ ] SDK release branches pre-staged with new addresses pasted in (don't push to npm yet)
- [ ] Vercel deploy-on-push enabled and master branch protected (FIND-001 follow-up — confirm via `gh api`)
- [ ] Kill-switch dry-run executed on Sepolia in the last 30 days (per BETA-PROD plan §2.2)
- [ ] Communication: heads-up to known integrators (today: ~2 active wallets) in advance; release notes drafted

---

## What I'm explicitly NOT planning for

- **Migrating receipts from old kernel** — receipts table on agirails.app for the 3 old SETTLED txs stays as-is. No backfill of post-cutover SETTLEDs on old kernel into receipts (per the indexer switch, those events stop being watched).
- **Sourcify-verifying the old kernel** — not worth the time. Old kernel becomes archival.
- **Renaming the old kernel in docs to "legacy"** — done implicitly when the new address replaces references.
- **Coordinating with Coinbase/Base** — none of the changes touch infra they care about.
- **Public announcement** — release notes in docs-site/updates, npm release notes, MCP description bump. No press push. (Tweet thread from 18-04.md can finally land alongside this if you want.)

---

## Open decisions for Damir + Justin

1. **Compiler bump 0.8.20 → 0.8.34**: yes/no. Default: yes (this plan assumes yes).
2. **Pauser key separation** (new dedicated EOA vs reusing Safe). Default: NEW dedicated EOA. Per d9c6e8e role separation intent — Safe stays admin, pauser becomes a hot-wallet operational key with a single privilege (`pause()`).
3. **Stuck-tx outreach window** — 60 days suggested. Adjust if outreach effort is higher/lower priority.
4. **SDK breaking version**: bump to 4.0.0 (TS) + 3.0.0 (Python)? Default: yes — mainnet address change is a breaking API for production integrators. Major-version signals "act now".
5. **Tweet thread coordination** — fire `18-04.md` thread the day this lands? Default: yes, but only after 48h of clean monitoring.
6. **Cron reminder for 2026-07-17 60-day stuck-tx force-resolve** — set in Damir's calendar or in a Vercel cron job?

---

## What's left to do BEFORE execution (estimated effort)

1. Bump `foundry.toml` to 0.8.34, run full test suite under new compiler, fix any deltas — **1–2h**
2. Author the EIP-712 domain-separator SDK patches (kernel address binding) — **2–4h**
3. Stage the SDK release branches with new addresses — **30 min**
4. Pre-deploy dry-run on a fork of mainnet via `anvil --fork-url $BASE_MAINNET_RPC` — **1–2h**
5. Schedule a 90-min execution window with Justin available for multisig signing — **scheduling**
6. Final pre-flight checklist run-through — **15 min**

**Total preparation time before deploy day**: ~6–8 hours, mostly in one focused session.

---

## Pre-execution prep results (2026-05-18 Faza 1.5)

Items 1, 2, 3, and most of 4 from the "What's left to do BEFORE execution" list have been run through. Findings below; deploy-day actual effort is now closer to **~1.5h** because the SDK EIP-712 work turned out to be a no-op.

### ✅ Compiler bump 0.8.20 → 0.8.34 — DONE WITH CAVEAT

Bumped `foundry.toml` and 9 strict-pragma files to `0.8.34`. Build clean under 0.8.34. Sizes effectively unchanged:

```
ACTPKernel       22,174 bytes
AgentRegistry    14,063 bytes
ArchiveTreasury   5,513 bytes
EscrowVault       3,383 bytes
```

`forge test` under 0.8.34: **479 pass, 3 fail, 1 skipped** (vs 482/0/1 under 0.8.20).

The 3 failures are all in `test/M2_MediatorTimelockBypassTest.t.sol`:

| Test | Failure |
|------|---------|
| `testM2ExploitPrevented_TimelockBypass` | `1036801 != 172801` |
| `testM2Fix_MultipleRevokeCyclesRespectTimelock` | `1123201 != 691201` |
| `testM2Fix_TimelockAlwaysResetOnApproval` | `1123201 != 172801` |

Verified by isolating the file: same 3 fail under 0.8.34 alone, all 5 pass under 0.8.20. The deltas are exact multiples of 1 day (86,400s) — consistent with `block.timestamp` accumulating across what should be isolated test functions under forge 1.4.4 + solc 0.8.34. The `approveMediator` contract logic itself sets `mediatorApprovedAt = block.timestamp + MEDIATOR_APPROVAL_DELAY` — the math is correct on-chain; the assertions just use stale captures.

**Verdict**: test-side issue, not a contract bug. Mediator timelock logic is unaffected.

**Fix before deploy day** (~30 min): refactor the 3 tests to assert deltas (`mediatorApprovedAt - block.timestamp == MEDIATOR_APPROVAL_DELAY`) instead of absolute timestamp equality. This is compiler-version-independent and isolates correctly.

Repository state was reverted to `solc = "0.8.20"` after the experiment so main stays green pending the test fix.

### ✅ Anvil fork dry-run — DONE, all checks pass

Forked Base mainnet via `anvil --fork-url $BASE_MAINNET_RPC --port 8546` and ran the full Phase 1 sequence:

1. `forge script script/DeployBaseMainnet.s.sol --rpc-url http://localhost:8546 --broadcast` against the fork — all 4 contracts deployed; every in-script `require()` config verification passed (admin/pauser/feeRecipient/USDC/kernel/escrow links all wired correctly).
2. Impersonated the Safe (`anvil_impersonateAccount 0x61fE58E9...`) + funded it with 1 ETH (`anvil_setBalance`).
3. Multisig actions executed in sequence:
   - `kernel.approveEscrowVault(newVault, true)` — status=1, gas=47,974
   - `kernel.setArchiveTreasury(newArchive)` — status=1, gas=48,069
   - `kernel.scheduleAgentRegistryUpdate(newRegistry)` — status=1, gas=92,331
   - Verified post-state: `approvedEscrowVaults[newVault] = true`, `archiveTreasury = newArchive`, `agentRegistry = 0x0` (still — timelock active).
4. Warped time forward 2 days + 1 second via `anvil_increaseTime`, then called `executeAgentRegistryUpdate()` from a random EOA (permissionless per kernel design). Status=1, gas=34,724. Post-state: `agentRegistry = newRegistry`. ✓
5. Confirmed USDC contract on the fork has real balances (whale account had $952 USDC) — full E2E smoke tx is not blocked by USDC liquidity.

**Verdict**: deploy script + multisig + timelock sequence behaves exactly as specified in this plan. No script changes needed.

### ✅ EIP-712 SDK audit — NO PATCHES NEEDED

Audited every signing call site in `@agirails/sdk` (10 grep hits across `DeliveryProofBuilder`, `CounterAcceptBuilder`, `CounterOfferBuilder`, `QuoteBuilder`, `MessageSigner`, `ACTPClient`). All EIP-712 typed-data signatures already construct their domain with `verifyingContract: kernelAddress`. Apex's forward-watch on EIP-712 domain binding is **already addressed in the codebase** — credit to whoever wrote the builders.

Three plain-text `signMessage` call sites exist (`publish.ts`, `claim-code.ts`, `claim.ts`), all targeting `agirails.app` server endpoints rather than the kernel. Server-side nonce/challenge mechanism (Redis-backed `claim/challenge`, timestamp-bound publish messages) bounds replay independently of kernel address. No patches needed.

The one outstanding kernel-side concern — txId derivation `keccak256(requester, provider, amount, serviceHash, nonce)` without kernel address — remains accepted-risk for the transition window per the original plan. It would need kernel-side cooperation to fix and is out of scope for this redeploy.

**Verdict**: -3 hours from the original estimate; SDK release branches just need address swaps + version bumps.

### ✅ Release-day update script — STAGED

`deployments/scripts/update-mainnet-addresses.sh`. One command does the lockstep address swap across sdk-js (3 files), python-sdk-v2 (1 file), and agirails.app web indexer (1 file). Validates address shape, refuses to no-op, prints a manual hand-off checklist for the npm publishes / Vercel push / paymaster allowlist updates / docs lag.

Usage on deploy day:

```bash
cd Protocol/actp-kernel
./deployments/scripts/update-mainnet-addresses.sh \
  <new-kernel> <new-vault> <new-registry> <new-archive> <deploy-block>
```

Smoke-tested: invalid args reject cleanly. Real dry-run requires fresh addresses so it's not been end-to-end executed; idempotent and verifies before/after counts so a mistyped run is safe to re-run with corrected args.

### ⏸ Open prep work still pending

| Item | Effort |
|------|--------|
| Fix the 3 M2 mediator timelock tests to use deltas | ~30 min |
| Schedule 90-min execution window with Justin (multisig signing) | scheduling |
| Final pre-flight checklist run-through | ~15 min |

**Total remaining preparation**: ~45 min + scheduling. Down from the original ~6–8h estimate.

---

## 2026-05-19 SDK-side readiness update

> Update appended after the SDK 4.0.0 beta cycle concluded with `4.0.0-beta.11`
> on the `next` channel. Plan content above remains the authoritative
> on-chain procedure; this section just maps what the SDK side has finished
> doing while waiting for the on-chain redeploy window.

### What the SDK has done since this plan was drafted (2026-05-18)

| Track | Status as of 2026-05-19 | Reference |
|---|---|---|
| **AA bypass cascade (beta.1..9)** | 10+ provider/requester routing fixes, full state-machine walk validated end-to-end | sdk-js `CHANGELOG.md` 4.0.0-beta.1 … 4.0.0-beta.9 |
| **Apex structural audit follow-up (beta.10)** | publish workflow with provenance + tag-driven attested releases, CodeQL JS/TS baseline, RelayChannel SSRF guard, `publishConfig.provenance: true` | beta.10 entry + `.github/workflows/{publish,codeql}.yml` |
| **Apex source-level audit follow-up (beta.11)** | `parseAgirailsMd` 256 KB cap + tightened `maxAliasCount`, `actp init` writes `.env.example` + extends `.gitignore`, README runtime-secret disclosure, `PUBLISH_CLIENT_KEY` docstring | beta.11 entry + `src/config/agirailsmd.ts` + `src/cli/utils/config.ts` |
| **Production canary (Sepolia, against the new-kernel d9c6e8e build)** | 10/10 SETTLED across ~20h soak, mean elapsed 27s, range 22–34s; alternating wallets; zero RPC race retries; zero bundler/paymaster failovers | `/tmp/canary-soak.jsonl`, `/tmp/canary-soak-summary.txt` |
| **Dispute path (AIP-14 bond + admin resolve)** | End-to-end SETTLED on Sepolia: requester deposits $1 bond, admin resolves with full-refund + provider-at-fault proof, bond returns to disputer per fault attribution | tx `0x24b677ff71280948e001e51484ff36a5a3e1d6732bd519d6c225a9e44bd836f6` |
| **Matrix coverage** | $0.05 / $1 / $5 happy paths, cancel pre-commit + cancel post-commit, $11 over-budget filter rejection | session log; per-tx hashes recorded |
| **2293 unit tests** | green; lint 0 errors; tsc clean; tarball 698 files | every beta release validated this gate |

**What's confirmed working on the new-kernel build that this plan deploys to mainnet**:

- Requester-driven `linkEscrow` flow (kernel `Only requester` guard)
- Provider-side `transitionState` for `IN_PROGRESS` / `DELIVERED` routed via SmartWalletRouter / Paymaster (gasless)
- `Agent.pollForJobs` mode-gated (mock polls `INITIATED`, blockchain polls `COMMITTED` + `IN_PROGRESS`)
- Orphan IN_PROGRESS recovery (re-entry-safe `processJob` state gating)
- Permanent-revert classifier (`Transaction expired`, `Only requester`, `Only provider`, etc.) — matches both plaintext AND hex-encoded forms in bundler simulation reverts
- Retry-with-backoff on RPC propagation lag in `StandardAdapter.linkEscrow`
- `SettleOnInteract` routed via StandardAdapter so the expired-DELIVERED sweep is AA-aware
- AIP-14 dispute bond deposit + distribution + fault-attributed reputation hook

These are all kernel-version-aware — they were written and validated against the d9c6e8e build, which is what this plan deploys to mainnet.

### What the SDK side still needs from the on-chain redeploy

Exactly the operations the plan already names in **Phase 2 step 2**:

1. **`src/config/networks.ts`** — replace `base-mainnet.contracts.{actpKernel, escrowVault, agentRegistry, archiveTreasury}` with the new addresses
2. **`src/config/networks.test.ts`** — fixture refresh
3. **`src/protocol/ACTPKernel.test.ts`** — fixture refresh (per plan's surface map)
4. **`package.json` version**: `4.0.0-beta.11` → `4.0.0` (drop the pre-release suffix)
5. **`CHANGELOG.md`** entry: `## [4.0.0] — <deploy date>` confirming stable release of the same code as beta.11 + the address swap
6. **`actpKernelDeploymentBlock`** under `base-mainnet` — set to the new-kernel deploy block (catch-up sweep window pivots on this)
7. **Publish via the new tag-driven workflow** (`v4.0.0` annotated tag → `.github/workflows/publish.yml` fires → npm publish with provenance attestation, dist-tag `latest`)
8. **`npm dist-tag rm @agirails/sdk next`** (optional) once `latest` is on 4.0.0 — keeps tag discipline clean

No SDK code changes other than the address swap + version bump. Everything else needed for 4.0.0 stable has already landed in beta.11 and is on `feat/4.0.0-event-driven-provider-listening` (and tagged `v4.0.0-beta.11`).

### Pre-staged for execution day

- `feat/4.0.0-event-driven-provider-listening` branch is current with beta.1..11 + all audit fixes — base for the 4.0.0 stable commit
- `v4.0.0-beta.11` tag anchors the npm release on the `next` channel
- `publish.yml` workflow ready to fire on `v4.0.0` tag push (assumes `NPM_TOKEN` secret OR npm trusted publisher configured)
- CodeQL + secret-scanning enabled at repo level
- 698 files / 837 KB tarball baseline (`npm pack --dry-run` from beta.11)

### What the SDK side is NOT prepared for (and the plan above correctly defers)

- **CDP paymaster allowlist** — Coinbase dashboard task (Phase 1 step 10). The audit observed Sepolia is currently relying on Pimlico fallback because CDP hasn't allowlisted the new Sepolia kernel; mainnet must NOT ship with that single-provider risk. Adding new mainnet kernel + vault + registry to BOTH CDP and Pimlico dashboards before Phase 2 starts is load-bearing for gasless flows.
- **Old-kernel stuck-tx outreach (Option C, 60-day window)** — operational task, not SDK.
- **Tweet thread + release notes** — Damir's call per plan §"What I'm explicitly NOT planning for".

### Pending plan-level open decisions (from "Open decisions for Damir + Justin")

The 6 questions in that section are unchanged by the SDK work. Recommended SDK-side defaults:

| # | Question | Recommended default | Rationale |
|---|---|---|---|
| 4 | SDK breaking version | **4.0.0 stable (drop -beta.N suffix)** | Major bump correctly signals breaking changes from 3.x; `^3.x.x` consumers won't auto-upgrade |
| — | New mainnet `actpKernelDeploymentBlock` | Use the deploy block from `forge script` output | Catch-up sweep window starts here |
| — | Tag-driven publish workflow first attested release | **Yes, this is 4.0.0** | Closes Apex FIND-007 for `4.0.0+`; betas remain unattested but anchored by git tags |

Other open decisions (compiler bump, pauser separation, outreach window, tweet timing, cron reminder) are kernel/operational scope — no SDK input needed.

---

## Hand-off summary

This plan is now execution-ready. The day-of operator (Damir, with Justin available for Safe co-signing) should:

1. Read this whole doc (~15 min).
2. Resolve the 6 §"Open decisions for Damir + Justin" — write the answers as a bullet list and paste them into the deploy-day chat session.
3. Fix the 3 M2 tests (~30 min — refactor to use deltas vs absolute timestamps).
4. Re-bump `foundry.toml` to `0.8.34` + the 9 strict-pragma files; confirm `forge test` is 482/0/1 (the same number as the 0.8.20 baseline).
5. Run pre-flight checklist (§Pre-flight checklist, ~15 min).
6. Execute Phase 1 with Justin online to co-sign Safe transactions (~30 min).
7. Wait 2 days for the AgentRegistry timelock.
8. Run `./deployments/scripts/update-mainnet-addresses.sh <args>` + follow its printed hand-off checklist (~45 min of npm + vercel work).
9. Set the calendar reminders: T+2 days `executeAgentRegistryUpdate` confirmation, T+60 days stuck-tx force-resolve.
10. Tweet thread + release notes go up after 48h of clean monitoring.

_Plan complete. Next session: confirm open decisions and execute._
