# Argus security closure

- Worktree: `/tmp/argus-actp-remediation-20261105`
- Branch: `fix/argus-security-closure`
- Base: `3d8d1311340bb1c4ad3e55e97041aa25f2d4f8cf`
- Scope: five findings from the October kernel source review; see
  `SECURITY-REMEDIATION-2026-11-06.md` for contracts, ABI compatibility and verification limits.
- Baseline: default Forge 1.9 execution 742 pass / 1 pre-existing gas-ceiling failure / 5 RPC skips;
  previous non-isolated execution 743 pass / 0 fail / 5 skips.
- Dependencies: local shared Git clones of the exact pinned submodule commits. No env secrets copied.
- Evidence staging: `/tmp/codex-security-artifacts-66423b5ed8bf7961facb9d461310e0e9fec5d2b7facc0078afda846245cf7be0`;
  the final retained remediation report links authoritative check output and patch digest.
- Original checkout and other worktrees retain their source unchanged. No commit, push or deployment.

- Gas-test closure: default and legacy suites each 782 pass / 0 fail / 5 RPC skips; exact discovery
  794 -> 798 tuples, only four new gas tests. Warm 300k and minimal cold 600k limits unchanged.
  Configured callbacks use the pre-existing conditional 984375 bound; 1M gas must remain at the
  oracle CALLSITE, not merely be the keeper's total gas limit. Production/scripts/config hashes
  (44 files) unchanged from the reviewed security candidate. Coverage exits zero, 98.57% / 100%.
- Merge preparation: the verified fork-test correction is applied; it asserts the premature
  disputedAt+30d revert and recovery after the assertion's liveness+30d grace. Production unchanged.
  The unsupported 600k whole-action claim is replaced by the SDK's existing bundler-estimated
  UserOperation flow, with measured real-OOV3/self-funded-AA figures and explicit evidence limits.
- CDP and Pimlico endpoint/stub probes ran. The Pimlico key in the former root SANITY-CHECK.md
  was found and verified; credentials were not copied into this worktree. Stub availability is
  distinct from final sponsorship. OPEN activation check: sponsored settlement of the approved
  new deployment, actual paymaster overhead, policy limits/receipts and configured failover.
- Gas sweep observed seven atomic reverts, zero deferred callbacks, five complete settlements.
  Do not describe the stale split fallback as economically equivalent to an oracle-ruling retry.
- Final merge-preparation checks: default and legacy each 782 pass / 0 fail / 5 skips; the full
  RPC-enabled UMA run is 786 pass / 0 fail / 1 unrelated Sepolia setup skip, with all four UMA
  tests executed. Audit 75/75; discovery 798 unchanged. Evidence under `merge-prep-20261106/`.
  This final increment changes only the fork test, operator document and these two status notes;
  all 44 protected production/script/config files are unchanged. No commit, merge or deployment.
