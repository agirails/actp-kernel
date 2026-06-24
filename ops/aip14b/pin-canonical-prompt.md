# OPS — Pin the canonical evaluator prompt + set its on-chain CID (P4-6)

> **What this runbook does:** pins the canonical evaluator prompt bytes to IPFS (Pinata), obtains the
> deterministic **CIDv1**, then sets that CID as the active on-chain reference **via the executed
> 2-day timelock** (propose → ≥2-day delay → execute), and finally arms the re-pin watchdog. This is
> the operational companion to the SLA in `docs/AIP14B-PINNING-SLA.md`. The governance change-process
> rationale is in `DISPUTE SYSTEM/evaluator-prompt/PROMPT-GOVERNANCE.md`.
>
> **Hard rules for this runbook (match the rest of the AIP-14b deploy ops):**
> - **NO private keys in any command or file.** Use env placeholders only. On Sepolia, signing is via
>   `--account`/hardware/keystore (operator's local wallet manager), never a literal key. On mainnet,
>   the on-chain calls are **Safe-submitted** — this runbook only emits the calldata; the Gnosis Safe
>   2-of-3 operators build and sign the actual transactions.
> - **NO `--broadcast` in this document.** Every `cast send` below is shown for the operator to run
>   against a live RPC with their own signer; the doc itself performs no transaction. Read-only
>   `cast call` / IPFS fetches are safe to copy-paste.
> - **Addresses come from `deployments/aip14b.json` / env, never hardcoded literals** (the only fixed
>   literals are the known immutables: USDC, UMA OOV3 — neither is touched here).

---

## 0. Prerequisites

| Need | Where it comes from |
|---|---|
| Canonical prompt bytes | `DISPUTE SYSTEM/evaluator-prompt/canonical-prompt.md` (the exact bytes; do NOT reformat) |
| Pinata credentials | `PINATA_JWT` env (see `.env.example` — `IPFS_PINNING_PROVIDER=pinata`) |
| Deployed dispute addresses | `deployments/aip14b.json` (BondEscalation address, kernel, admin/Safe) |
| RPC | `BASE_SEPOLIA_RPC` / `BASE_MAINNET_RPC` env |
| Signer | Sepolia: operator keystore/hardware via `--account`. Mainnet: Gnosis Safe (calldata only) |

Load the network + addresses from the config artifact (no hardcoded literals):

```bash
# Pick the network up front. Everything else is derived.
export NETWORK="base-sepolia"          # or base-mainnet
export RPC_URL="$BASE_SEPOLIA_RPC"     # or $BASE_MAINNET_RPC for mainnet

# Read deployed addresses from the config artifact (NOT broadcast literals).
export BOND_ESCALATION=$(jq -r ".networks[\"$NETWORK\"].disputeContracts.BondEscalation.address" deployments/aip14b.json)
export DISPUTE_ADMIN=$(jq -r ".networks[\"$NETWORK\"].disputeContracts.BondEscalation.constructorArgs.admin" deployments/aip14b.json)

# Guard: these resolve to null until the P4-1 (Sepolia) / P6-1 (mainnet) broadcast writes them back.
test "$BOND_ESCALATION" != "null" || { echo "BondEscalation not yet deployed for $NETWORK — run P4-1/P6-1 first"; exit 1; }
```

> The **prompt-CID governance entrypoint** is the same timelocked admin surface the evaluator
> registry uses (`EVALUATOR_UPDATE_DELAY = 2 days`, mirroring `proposeFixedEvaluatorUpdate` /
> `executeFixedEvaluatorUpdate` in `src/BondEscalation.sol`). Per AIP-14b FINAL §4.2 the prompt
> governance is described **abstractly** (explicit function names intentionally removed in v5.7), so
> the exact selector is supplied by env at run time and MUST match the deployed contract's ABI — do
> not assume a name. Set it once:
>
> ```bash
> # Selectors are read from the deployed ABI, NOT guessed. Example shape (adjust to the frozen ABI):
> export PROMPT_PROPOSE_SIG="proposePromptCID(string)"     # propose: records pending CID, starts 2-day clock
> export PROMPT_EXECUTE_SIG="executePromptCID()"           # execute: activates pending CID after the delay
> export PROMPT_ACTIVE_SIG="activePromptCID()(string)"     # read: the currently-active prompt CID
> export PROMPT_PENDING_SIG="pendingPromptCID()(string,uint256)"  # read: pending CID + unlock timestamp
> ```
>
> If the frozen dispute ABI exposes the prompt CID through a different surface (e.g. carried in the
> evaluator-registry update or an off-chain attestation rather than a dedicated setter), use that
> surface's propose/execute pair instead — the **propose → ≥2-day → execute** shape and the read-back
> verification below are the invariant, not the function names.

---

## 1. Pin the prompt to Pinata (deterministic CIDv1)

Pinning MUST be deterministic so the CID is a pure function of the bytes (PROMPT-GOVERNANCE §3):
**CIDv1**, multibase **base32**, multihash **sha2-256**, fixed UnixFS chunker. Re-pinning the
identical bytes MUST always yield the **same** CIDv1.

```bash
# Pin the EXACT bytes — do not transform, re-wrap, or normalize line endings.
PROMPT_FILE="../../DISPUTE SYSTEM/evaluator-prompt/canonical-prompt.md"   # path relative to ops/aip14b/

export PROMPT_CID=$(curl -s -X POST "https://api.pinata.cloud/pinning/pinFileToIPFS" \
  -H "Authorization: Bearer $PINATA_JWT" \
  -F "pinataOptions={\"cidVersion\":1}" \
  -F "file=@${PROMPT_FILE}" | jq -r '.IpfsHash')

echo "Pinned prompt CIDv1: $PROMPT_CID"        # expect a bafy… CIDv1
```

**Determinism check (do this every time — it is the trustless anchor):**

```bash
# Re-pin the identical bytes; the CID MUST be byte-identical to $PROMPT_CID.
RECHECK_CID=$(curl -s -X POST "https://api.pinata.cloud/pinning/pinFileToIPFS" \
  -H "Authorization: Bearer $PINATA_JWT" \
  -F "pinataOptions={\"cidVersion\":1}" \
  -F "file=@${PROMPT_FILE}" | jq -r '.IpfsHash')
test "$RECHECK_CID" = "$PROMPT_CID" || { echo "NON-DETERMINISTIC PIN — STOP. Check cidVersion/chunker settings."; exit 1; }
echo "Deterministic CIDv1 confirmed: $PROMPT_CID"
```

Confirm the content is retrievable and content-addressed (any gateway, not just Pinata):

```bash
curl -sL "https://gateway.pinata.cloud/ipfs/$PROMPT_CID" | head -5
curl -sL "https://ipfs.io/ipfs/$PROMPT_CID"            | head -5   # independent gateway = content-address proof
```

---

## 2. Propose the CID on-chain (starts the 2-day timelock)

A prompt change is **never** instant. Proposing records the pending CID and starts the
`EVALUATOR_UPDATE_DELAY = 2 days` clock; the CID is NOT yet active.

### 2a. Sepolia (operator signer, NO literal key, NO `--broadcast` in this doc)

```bash
# Operator signs with their local keystore/hardware wallet via --account; never a literal PRIVATE_KEY.
cast send "$BOND_ESCALATION" "$PROMPT_PROPOSE_SIG" "$PROMPT_CID" \
  --rpc-url "$RPC_URL" --account "$KEYSTORE_ACCOUNT"
```

### 2b. Mainnet (Safe-submittable calldata ONLY — operators build the tx)

Do **not** send from a raw key on mainnet. Generate the calldata and hand it to the Gnosis Safe
(`$DISPUTE_ADMIN` = the 2-of-3 Safe). The Safe operators submit + sign:

```bash
# Calldata generation is read-only; this performs NO transaction.
PROPOSE_CALLDATA=$(cast calldata "$PROMPT_PROPOSE_SIG" "$PROMPT_CID")
echo "Safe tx →"
echo "  to:    $BOND_ESCALATION"
echo "  value: 0"
echo "  data:  $PROPOSE_CALLDATA"
echo "  note:  propose canonical prompt CID; starts 2-day timelock (admin = Safe $DISPUTE_ADMIN)"
```

Record the unlock time the propose set (read-back):

```bash
cast call "$BOND_ESCALATION" "$PROMPT_PENDING_SIG" --rpc-url "$RPC_URL"
# → (pendingCID, unlockTimestamp). Verify pendingCID == $PROMPT_CID and unlock ≈ now + 2 days.
```

**During the ≥2-day window:** anyone fetches the proposed CID, diffs it against the active prompt, and
may object. This is the governance-attack guard (§4.2 / PROMPT-GOVERNANCE §2). If a problem is found,
**cancel** (admin/Safe) before execution rather than executing.

---

## 3. Execute after the timelock elapses (activates the CID)

After `block.timestamp >= unlockTimestamp`:

```bash
# Confirm the timelock has elapsed first.
cast call "$BOND_ESCALATION" "$PROMPT_PENDING_SIG" --rpc-url "$RPC_URL"   # unlock must be in the past
```

### 3a. Sepolia

```bash
cast send "$BOND_ESCALATION" "$PROMPT_EXECUTE_SIG" \
  --rpc-url "$RPC_URL" --account "$KEYSTORE_ACCOUNT"
```

### 3b. Mainnet (Safe calldata)

```bash
EXECUTE_CALLDATA=$(cast calldata "$PROMPT_EXECUTE_SIG")
echo "Safe tx →"
echo "  to:    $BOND_ESCALATION"
echo "  value: 0"
echo "  data:  $EXECUTE_CALLDATA"
echo "  note:  execute pending prompt CID after 2-day timelock"
```

**Verify activation (cast call returns the CID — the P4-6 acceptance check):**

```bash
ACTIVE=$(cast call "$BOND_ESCALATION" "$PROMPT_ACTIVE_SIG" --rpc-url "$RPC_URL")
echo "Active on-chain prompt CID: $ACTIVE"
test "$ACTIVE" = "$PROMPT_CID" || { echo "MISMATCH — on-chain CID != pinned CID; STOP."; exit 1; }
echo "On-chain prompt CID matches the pinned CIDv1."
```

---

## 4. Arm the re-pin watchdog (FIXED cost — AGIRAILS-owned)

The watchdog enforces the §1 SLA on the AGIRAILS-owned prompt pin. It is a standing FIXED cost
amortized into `infra_margin` (NOT per-dispute) — see `docs/AIP14B-PINNING-SLA.md` §2.1/§3.

Schedule a cron (Railway/host) running these three probes; alert on any failure
(route per `ops/aip14b/monitoring-alerts.md`, P5-4):

```bash
# 1) Liveness + content-address probe (Pinata AND an independent gateway).
for GW in https://gateway.pinata.cloud/ipfs https://ipfs.io/ipfs; do
  curl -sfL "$GW/$ACTIVE" >/dev/null || echo "ALERT: prompt CID unretrievable via $GW"
done

# 2) Retention probe — assert remaining pin retention ≥ 35-day floor; re-pin identical bytes if near expiry.
#    (Pinata pin-list API; re-pin is deterministic ⇒ same CIDv1, so the on-chain ref never dangles.)
curl -s -H "Authorization: Bearer $PINATA_JWT" \
  "https://api.pinata.cloud/data/pinList?hashContains=$ACTIVE&status=pinned" | jq '.count'   # must be ≥ 1

# 3) On-chain consistency probe — re-pin canonical-prompt.md, assert it equals the on-chain CID.
#    Any mismatch = attempted silent swap → page (it would also fail the on-chain timelock).
```

---

## 5. Evidence-bundle pinning (reference — NOT this runbook's job)

Per §8.6 / SLA §2.2, **the ESCALATOR self-pins evidence bundles** through the liveness + DVM window
(`IPFS_per_bundle = 0` to AGIRAILS). This runbook pins the **prompt only**. AGIRAILS pins a user
bundle **only** if `AGIRAILS_PINS_USER_BUNDLES = true` (default **false**), in which case it is a
VARIABLE quote line (≤ $0.01/dispute) + the two caps + the §7.5.4 envelope — see SLA §4. Sanity-fetch
a sample escalated bundle's CID (read-only, proves DVM retrievability):

```bash
# evidenceCID is the string embedded as ipfs://<cid> in the UMA assertTruth claim (escalateToUMA §8.4).
curl -sfL "https://gateway.pinata.cloud/ipfs/$SAMPLE_EVIDENCE_CID" | jq '.schemaVersion'   # expect "1.0.0"
```

---

## 6. Done-criteria (P4-6)

- [ ] `canonical-prompt.md` pinned to Pinata; **deterministic CIDv1** confirmed (re-pin matches).
- [ ] Prompt CID **proposed** on-chain (pending + ≥2-day unlock recorded); diffable during the window.
- [ ] Prompt CID **executed** after the timelock; `cast call $PROMPT_ACTIVE_SIG` returns the CID and it
      equals the pinned CIDv1.
- [ ] Mainnet calls were **Safe-submitted** (calldata emitted here; no raw-key broadcast).
- [ ] Re-pin watchdog armed (liveness + retention ≥35-day + on-chain-consistency probes; alerts wired).
- [ ] A sample evidence-bundle CID fetches (schemaVersion `1.0.0`).
- [ ] No private keys in any file; addresses came from `deployments/aip14b.json` / env.
