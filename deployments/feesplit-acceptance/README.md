# FeeSplitVault acceptance: run files and reports

Written by `script/AcceptFeeSplitArm.s.sol`, `script/SmokeFeeSplit.s.sol` and the soak runner; read by
`script/AcceptFeeSplitExec.s.sol` and `deployments/scripts/reconcile_feesplit.py`. `foundry.toml` grants
the scripts read and write access to this directory only.

| File | What it is |
|---|---|
| `sepolia-<set>-<block>.json` (`"kind":"run"`) | a run file: the manifest of the escrows one Arm run created (label, acceptance row, profile, transaction id, vault, parties, amount, requested terms, expected terminal state, the time-gated action and its earliest time). Written once, when the escrows are created, and never rewritten; its hash goes into the evidence file |
| `sepolia-negatives-<block>.json` (`"kind":"negatives"`) | A23 and the consent negatives: calls against live state at the recorded block that reverted with the expected reason. Never broadcast |
| `sepolia-soak-d<day>-<block>.json` (`"kind":"run"`) | one day of the soak, written by sdk-js `scripts/feesplit-soak.ts` in the same format; `AcceptFeeSplitExec` executes its time-gated entries. An escrow funded from a smart wallet carries two more fields: `paymaster` (`cdp` or `pimlico`, the provider that wallet is bound to) and `sponsor` (the paymaster address the EntryPoint charged for the funding UserOp, read from the chain). The file lists every requester of the day, EOA and smart wallets, as `requesters` |
| reconciler reports | `reconcile_feesplit.py --out <file>` |

The reconciler takes the addresses that are dedicated to these scripts with `--requester <address>`
(repeatable): an escrow of such an address that no run file names fails with C6. Without the flag the
dedicated addresses are only those the run files name, so a requester whose every entry is missing
would go unnoticed. Pass the acceptance requester and every soak requester (the EOA and the smart
wallet of each paymaster; a soak run file lists them as `requesters`) on every Base Sepolia run.

If the broadcast of an Arm run does not complete, its run file names escrows that do not exist. Delete
that file before anything else is recorded: it was never evidence. A file whose hash is in
`deployments/FEESPLIT-SEPOLIA-ACCEPTANCE.md` is never deleted or edited.

`local-*.json` files come from the anvil self-test (`deployments/scripts/feesplit_selftest.py`), which
moves them out when it ends; they are ignored by git.
