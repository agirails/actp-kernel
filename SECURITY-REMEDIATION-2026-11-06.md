> 2026-11-09 follow-up: see SECURITY-REMEDIATION-2026-11-09.md for final-fault retry and permanent verification. This historical evidence predates that candidate.

# Security remediation: October source review

Base: `3d8d1311340bb1c4ad3e55e97041aa25f2d4f8cf`. Local, uncommitted remediation;
no deployment or live-contract equivalence is asserted.

## Corrected contracts

- UMA's authenticated clean ruling controls principal and entry bonds even if no Tier-1 proposer
  backed its winning direction. `tier1Refundable(disputeId)` and `Tier1RefundsEnabled` independently
  expose proportional Tier-1 refund eligibility. The `disputes` getter tuple is unchanged.
- Direct DID owner changes consume the outgoing owner's nonce. All signed message formats and the
  exactly-once nonce consumption of signed operations remain unchanged.
- The real agent registry accepts reputation accounting for a historically registered profile after
  deregistration. Never-registered addresses and duplicate transaction accounting remain rejected.
- `DeployKernelV2` and `DeployBaseMainnet` transfer archive ownership from the broadcaster to the
  configured admin during deployment. Safe-only kernel wiring remains a separate operator action.
- Outstanding platform fees have separate escrow accounting. Every milestone, refund, recovery and
  dispute amount/presence check excludes that debt, including zero-principal terminal operations.

## Additive ABI and deployment compatibility

`IACTPKernel` adds `escrowPrincipal(bytes32)` and `retryPlatformFee(bytes32)`. The former reports
unpaid principal excluding fees still reserved in escrow. The latter is permissionless,
non-reentrant and pause-exempt, requires an approved vault, and only retries fee recipients.
It can run during an active transaction or after either terminal state; it never changes state,
pays participants or calls the reputation registry. Failed transfers leave their debt reserved.

Existing proof encodings and the REV2 lifecycle identity remain unchanged. Amounts in dispute proofs
now refer to distributable principal, excluding reserved fees. Both deployment gates require the new
selectors in addition to their prior checks. Selector presence is a heuristic; audited runtime
codehash pins remain necessary for implementation identity.

Deploy the matching kernel, vault and dispute stack together. These contracts are non-upgradeable;
this patch does not update existing deployments. Existing SDK/operator proof builders must use
`escrowPrincipal`, particularly after a fee-transfer failure. No external consumer was changed here.

## Verification and limits

`test/audit/SecurityClosure20261105.t.sol` reproduces each original defect against the base and
checks the corrected behavior, exact balances, refunds, retries, zero-principal exits, archive
outflow and fuzzed conservation. `test/KernelFeeABIGate.t.sol` rejects incompatible old kernels.
The original invariant handler now exercises independent refundable Tier-1 pools.

Before changes, the reproduction suite had 20 failures and 3 passing controls. The expanded
candidate suite has 35 passing tests, including a 256-case fee-conservation fuzz test. The three
deployment scenarios execute sequentially inside one test, so process-wide environment variables
cannot race under default parallel test execution. Run it with:

```sh
forge test --offline --match-contract 'SecurityClosure|KernelFeeABIGateTest' -vv
forge test --offline --summary
```

Forge 1.9 defaults to isolated execution, unlike the historical test environment. On the original
base the full suite had 742 passes, five RPC-gated skips and one failing 300k callback-gas assertion
(381,107 gas); the previous non-isolated run had 743 passes and five skips. After security fixes but
before gas-test closure, default execution had 777 passes, one gas failure (383,923) and five skips;
non-isolated execution had 778 passes and five skips. These are distinct snapshots.

The gas-test closure changes only `test/BondEscalationThreatModel.t.sol`, `test/mocks/MockOOV3.sol`
and these status notes. All 44 production/source-script/configuration fingerprints remain unchanged
from the independently reviewed security candidate. The historical warm benchmark alone opts out
of isolation and retains the 300,000 ceiling in normal `forge test`. A new minimal cold benchmark
retains the original 600,000 bounded call. Runner-mode witnesses enforce the intended semantics
in both configured profiles even when the global isolate setting differs. Coverage uses instrumented
`--ir-minimum` bytecode: it retains bounded calls and full functional assertions, but does not apply
the release-only warm 300k ceiling. No test is skipped to make this distinction.

Two additional cold tests wire the real registry and archive, fresh keeper payout and both oracle
outcomes through `settleUMAAssertion` and the synchronous mock callback. They cap that nested CALL
at the pre-existing 984,375 envelope. This assumes 1,000,000 gas remains AT THE ORACLE CALLSITE;
it makes no claim about a 1M total keeper transaction. Exact escrow, bond, fee, archive, keeper,
reputation and duplicate-accounting effects must all complete. The cold gas sweep from 50k through
600k observes seven complete rollbacks and five complete settlements; no deferred-mediator case
was observed. A failed oracle callback can be retried with sufficient gas. The 30-day stale split
fallback can change the economic outcome; it is not equivalent to executing the oracle ruling.

Gas-closure validation before final merge preparation: default and legacy each 782 passed,
zero failed, five RPC-gated skips.
Discovery compares exact (file, contract, function) tuples: 794 before, 798 after, four additions,
no removals. Listed functions differ from runtime summary units because invariant bundles and a
fork setup skip collapse multiple functions. Coverage completes with 744 passes, zero failures,
five skips in CI's isolated copy excluding only `test/treasury/` (the unchanged compiler workaround);
BondEscalation line coverage is 414/420 (98.57%), CompositeMediator 39/39 (100%), both above 90%.
The treasury suite remains in both full production-profile runs. Disposable negative controls force
mediator failure: all four positive gas tests fail on incomplete escrow settlement even though gas
consumption is below the ceilings.

**Merge-preparation update:** the former 600k whole-action headroom claim has been removed from
`ops/aip14b/paymaster-allowlist-decision.md`. The SDK already estimates UserOperation gas dynamically;
this update does not alter SDK behavior or production gas limits. On Base fork block 53858872,
real OOV3/USDC paths measured 600,108–799,792 direct settlement gas and 757,291–1,127,917 through
EntryPoint/CoinbaseSmartWallet, including first wallet deployment. Disputed outcomes inject only
the upstream DVM price. The AA measurements are self-funded; actual paymaster validation/postOp
and public Base L1-data fees are not included. CDP and Pimlico read-only endpoint/stub checks ran;
Pimlico credentials were found in the former root `SANITY-CHECK.md` and work. Stub data does not
prove final policy enforcement or execution. No external paymaster policy was changed.

The real-oracle fork exposed a stale test expectation: Tier-2 stale recovery is anchored to
UMA escalation + its liveness + 30 days, rather than simply disputedAt + 30 days. The existing
test now requires the premature call to revert and the correctly timed call to recover.
The original fork suite was 3 pass / 1 fail; the corrected isolated copy passed all four.
The production contract's guard is unchanged. A stale split remains different from oracle settlement.

After applying that test correction and the operator-document update, complete default and legacy
runs each pass 782 tests with five opt-in/RPC skips. A complete run with `FORK_UMA=1` and the real
Base RPC passes 786 tests with one unrelated Sepolia-fork setup skip: all four UMA tests execute
and pass. The audit suites pass 75/75, discovery remains the same 798 function tuples, and all
44 production/script/build-config fingerprints remain unchanged by this merge-preparation increment.
The existing UMA test selects latest internally; its live RPC block window is recorded separately
from the earlier pinned gas probe. No sponsor approval or transaction submission is implied by it.

**OPEN activation acceptance:** after approval of a new deployment, verify final sponsorship and
complete settlement with exact balances/reputation through the configured provider paths. Confirm
actual paymaster overhead and deployment-specific spend/receipt controls. Owner: deployment/paymaster
operator. Missing fallback validation does not itself prevent a working CDP-sponsored operation;
dual-provider acceptance still requires testing Pimlico. Public deployment, sponsorship execution
and provider policy changes remain separate authorized steps.

Full validation logs, final check results, independent review and exact patch digest are retained
in the associated remediation evidence report. Local tests use a faithful MockOOV3 custody/callback
interface; live UMA/DVM outcomes, production deployment, complete vendored audit and out-of-repository
SDK/provider integrations are not claimed verified. Existing generic settled reputation retry
semantics were preserved; no new general terminal reputation retry was introduced.

Independent candidate review also reproduced repeated archive allocation on retry: archive received
119 units instead of 60 from a 60,000-unit fee. Fresh fee charges now allocate archive once;
reserved treasury debt retries its owed sink directly, including through `releaseEscrow`.
Tests assert each sink's exact balance across repeated failures and recovery.
