---
name: verify-actp-escrow
description: Verify oracle-award/refund independence and reserved-fee principal conservation after changes to ACTP escrow, disputes, or settlement.
disable-model-invocation: true
---

# ACTP escrow verification

P1: when an authenticated oracle callback is the first dispute resolution while the kernel is DISPUTED, its principal award survives missing Tier1 winners and deferred mediator retries. Tier1 refunds never rewrite that award. This prevents a clean oracle win becoming a split.

P2: reserved platform-fee debt is unavailable as participant principal. Initial deposits equal participant and paid-mediator distributions plus actual fee outflow from the vault plus remaining vault funds. Entry and Tier1 bonds are separate. This prevents paying the same reserved money twice.

## Run from a fresh checkout

Read WRITERS.md and coverage.json first. The sync base is a6c6f4e63b54a0bbbe4ab4752e1ab57889e94180; the hashes bind the uncommitted candidate, not that base's contents. Use Python 3.10+, Linux bubblewrap, Forge 1.9.0, solc 0.8.34 and the installed shared Harness. No package installation, wallet, environment file or RPC is needed. Read each model result using the shared /statechart skill; it is the authority for the installed wrapper and reports shortest counterexamples. verify.py invokes that installed wrapper, without vendoring its implementation.

From repository root:

```sh
python3 .agents/skills/verify-actp-escrow/doctor.py
python3 .agents/skills/verify-actp-escrow/verify.py --out /tmp/actp-escrow-check --harness "$HARNESS_ROOT" --forge "$HOME/.local/share/actp-security-tools/bin/forge" --solc "$HOME/.local/share/actp-security-tools/bin/solc"
```

Set HARNESS_ROOT to your installed shared Harness root. Choose a new output directory on each run. Add --negative-controls to exercise disposable broken models, broken Solidity snapshots and a stale coverage hash. The full command is slower because each Solidity mutation recompiles. Ordinary verification runs both models and six real-contract tests, including two stateful invariants (256 runs, depth 100, seed 0x9a117). Deterministic companions assert observed callback success/deferral, exact late stale/sync rejection counts in both deferred/completed windows, and exact per-mode archive/collector/kernel flow counts for both escrows. Sticky handler failures are asserted outside actions so fail_on_revert=false cannot hide the tested mismatches. Known-valid callback, retry, duplicate and stale-first calls also record execution failures; duplicate refund rejection remains intentionally permitted. Marker order is first-writer, unexpected execution failure, per-row economic outcome, retry completion, callback completion. P1/P2 counters are printed. Forge runs offline with no network, empty environment, read-only source and bounded writable build space. Outputs include exact logs and result.json with source hashes. Results are valid only if the entire command exits zero.

## Interpret results

Doctor exit 0 means synchronized; 2 means missing or malformed assets; 3 means source drift. A changed hash is NOT a broken property. A model counterexample is a bounded design failure; confirm its action mapping against real code before calling it a product defect. A real harness assertion is a concrete Solidity failure on the named seed/path. A compiler or tool error supplies no property result.

Negative controls are distinct: each model's mapped action is changed to violate its invariant; independent Solidity mutations reintroduce oracle-to-refund coupling or spending fee debt, and must fail both deterministic companions and their stateful invariant selections. Additional real-code controls force unexpected callback deferral, remove the stale guard, conditionally bypass the sync guard after completion, and make archive forwarding always revert. The first three must fail the named P1 stateful invariant and companion at the intended marker. Sync's canary preserves the deferred rejection so its recorded failure proves acceptance of a completed oracle result. Archive must fail the deterministic forwarding assertion; safe fallback need not violate conservation. Removing mediator retry must fail its completion check. Changing a covered source hash must report drift. There are ten controls in total. The stale mutation guarantees acceptance is challenged in the deferred window. Both APIs and both windows share the same late-result checker; conditional sync proves its completed-window acceptance handling. A separate completed-stale mutation is not included. The candidate is never mutated. Failure to see the intended invariant/assertion fails verification. After mutation checks, rerun the ordinary command cold against the unchanged candidate.

## Bounds and assumptions

Both models contain two transactions. OracleRefund models an atomic callback plus attempted mediator call, independent pull refunds, optional Tier1 winner, retry, duplicate callback and timeout-first split. FeeDebt uses four abstract deposit units and a one-unit minimum fee, not all Solidity arithmetic. See model configs for finite constants. TLC safety exploration is exhaustive only within these abstractions; no fairness or eventual recovery is proved.

P1 excludes trusted admin/approved-resolver overrides. An override after a deferred callback can leave mediator retry pending and reverting: the real deterministic control records this accepted authority boundary. Timeout-first split followed by a late oracle no-op is a separate valid result, not an oracle-first guarantee. The two real P1 rows both cover the missing-winner/refund branch. Winner-present is abstracted in the model and exercised by separate BondEscalation suites; it is not covered by this stateful handler. Permissionless post-oracle stale and sync calls must reject and preserve the outcome. sync has no TLA action: its negative real-API calls check first-writer guard conformance. Pre-oracle trusted kernel resolution followed by permissionless sync is outside the oracle-first claim. Tier1 refund flooring may leave dust. The model does not claim all other refund or bounty arithmetic.

P2 assumes approved deployed vaults, canonical token transfer behavior (apart from injected fee-recipient blocking), and configured deployed archive treasury. Count vault-to-kernel fee transfer once, even if downstream archive forwarding fails. Kernel-held fee recovery is outside the two-vault model. External donations, malicious admin/vault/token/treasury, gas economics, all parameter values, upgrades, production RPC and chain integration are excluded. Real handlers exercise fresh fees on milestones and disputed exits, six terminal exits including paid mediator, four fee-recipient/archive availability combinations, successful archive forwarding, fallback/kernel retention, recovery, repeats and out-of-order actions. They are bounded randomized/deterministic evidence, not a proof for arbitrary Solidity executions.

CI runs doctor and these real harnesses through the regular suite. TLC is a developer gate requiring installed Harness; this change does not claim hosted TLC execution.

## Maintain

Use /maintain-formal-verification-skill whenever a covered hash changes. Inventory every writer again, confirm intended protocol semantics, update action mapping/models and real harness together, prove both negative controls still detect their target, then regenerate coverage hashes and synced_at. Do not merely refresh hashes to silence drift. Never weaken the property to make code pass. Changes invalidate prior evidence. Preserve the relative .claude/skills/verify-actp-escrow link and run doctor from a clean checkout. Never commit or push as part of this skill.
