# AIP-14b — Dispute-Evaluator x402 Endpoint Deploy (OPS, P4-7)

> Scope: standing up `services/dispute-evaluator` as a public **x402-paywalled HTTP service** on
> Railway. The evaluator quotes + charges for the AI ruling work **off-chain** and returns an
> EIP-712-signed `AIRuling` bundle. It is a pure information service: **INV-3 — the evaluator makes
> ZERO kernel calls** and never holds escrow. The on-chain leg (`submitAIRuling`) is performed later
> by a separate keeper/SDK caller using the bundle this service returns.
>
> References: AIP-14b §4.3 (AI fee = dynamic x402 quote, off-chain), §8.5 (no on-chain confidence
> gate), Threat Model §5 "Evidence-inflation", INV-3. Companion docs:
> `paymaster-allowlist-decision.md` (§7.5.5), `settle-keeper-decision.md` (§7.5.6).

---

## 0. The one invariant this service must never break

**INV-3 — zero kernel calls.** The dispute-evaluator:

- MUST NOT import an RPC signer, a `PRIVATE_KEY`, an ACTP SDK *write* client, or any
  `kernel.*` / `bondEscalation.*` / `compositeMediator.*` write path.
- MAY read chain state **read-only** (e.g. `kernel.getTransaction(txId)` over a public RPC) solely to
  validate that the dispute exists and is in `DISPUTED`, and to size the quote against `escrowAmount`.
  Read-only `eth_call` is not a "kernel call" in the INV-3 sense (it moves no funds, signs nothing).
- Returns a **signed ruling bundle**; it NEVER submits it. `submitAIRuling` is a *different* actor's
  job (keeper/SDK), gated separately by the paymaster allowlist (`paymaster-allowlist-decision.md`).

A boot-time assertion (below) greps the process env for a private key and **refuses to start** if one
is present, so a copy-paste of a deploy `.env` into the evaluator service can never silently arm it
with signing power. This is the operational enforcement of INV-3.

---

## 1. Two-phase x402 flow (what the endpoint speaks)

The evaluator implements the standard **x402 two-phase** challenge/settle handshake — identical in
shape to the SDK's x402 adapter, so any ACTP requester (or the AGIRAILS SDK) can pay it with no custom
code.

```
Phase 1  (quote)                         Phase 2  (deliver)
─────────────────                        ──────────────────
POST /v1/evaluate                        POST /v1/evaluate
  (no X-PAYMENT header)                    X-PAYMENT: <signed USDC authorization>
        │                                        │
        ▼                                        ▼
  402 Payment Required                     200 OK
  body: x402 quote                         body: { ruling: AIRuling, signatures: bytes[] }
    - maxAmountRequired (USDC, 6dp)          - EIP-712 AIRuling struct (disputeId, ruling,
    - payTo  = evaluator x402 receiver         confidence, splitBps, timestamp,
    - asset  = USDC (chain-correct)            reasoningHash, bundleHash)
    - resource = /v1/evaluate#<disputeId>    - 2-of-3 evaluator signatures over RULING_TYPEHASH
    - nonce, validUntil                      - X-PAYMENT-RESPONSE: settlement receipt
```

- **Phase 1 — 402 quote.** The first request (no `X-PAYMENT`) returns HTTP `402` with the x402 quote
  JSON. The price is the **dynamic AI fee** of §4.3: `$1 per 50k tokens` of the evidence bundle, with a
  **~100k-token bundle cap** (Threat Model §5, evidence-inflation bound). Oversized bundles are
  rejected at quote time (`413`), never priced — this is the only DoS bound that matters here because
  the fee is off-chain and never touches the kernel.
- **Phase 2 — 200 deliver.** The retry carries `X-PAYMENT` (an EIP-3009 / USDC transfer authorization).
  The service verifies + settles the payment (via the x402 facilitator or direct `transferWithAuthorization`),
  runs the evaluator ensemble, and returns the **signed `AIRuling` bundle** + an `X-PAYMENT-RESPONSE`
  settlement receipt header. **No kernel write occurs in either phase** (INV-3).

The returned `confidence` (>= 9000 bps per §4.1) is advisory metadata the *caller* uses to decide
`submitAIRuling` vs `proposeDirectly`; the chain does NOT enforce it (BondEscalation §4.1 comment),
so the evaluator simply reports it — it is not a gate here either.

### `AIRuling` wire shape (must match the on-chain `RULING_TYPEHASH`)

The bundle the evaluator signs MUST match, field-for-field and in order,
`BondEscalation.RULING_TYPEHASH`:

```
AIRuling(bytes32 disputeId,uint8 ruling,uint16 confidence,uint16 splitBps,
         uint64 timestamp,bytes32 reasoningHash,bytes32 bundleHash)
```

and the EIP-712 domain MUST be the on-chain `DOMAIN_SEPARATOR`:

```
EIP712Domain(name="ACTPDisputeEvaluator", version="1",
             chainId=<deploy chain>, verifyingContract=<BondEscalation address>)
```

`verifyingContract` is the deployed **BondEscalation** address from `deployments/aip14b.json`
(`disputeContracts.BondEscalation.address`) for the target chain — read from env, NEVER hardcoded
(it is `null`/AWAIT_BROADCAST until P4-1 Sepolia / P6-1 mainnet). `chainId` likewise comes from the
deploy network (84532 Sepolia / 8453 mainnet). A wrong domain → on-chain `submitAIRuling` recovers the
wrong signers → `"Insufficient valid signatures"`. **Freshness:** `timestamp` must be within
`RULING_FRESHNESS = 1 hour` of on-chain submission (§4.5), so the evaluator stamps server time and the
caller must submit promptly.

---

## 2. Railway service definition

`services/dispute-evaluator` deploys as a standard Railway web service. It is **stateless** (no DB; the
only persistence is the evaluator signing keys, which live in KMS/Railway secrets, never in the repo).

### Required environment (Railway secrets — NO keys in repo)

| Var | Purpose | Notes |
|-----|---------|-------|
| `EVALUATOR_CHAIN` | `base-sepolia` or `base-mainnet` | selects chainId + addresses |
| `BOND_ESCALATION_ADDRESS` | EIP-712 `verifyingContract` | from `deployments/aip14b.json`; chain-matched. Service refuses to start if it does not match `EVALUATOR_CHAIN`'s deployed BondEscalation. |
| `USDC_ADDRESS` | x402 settlement asset | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` (mainnet) / `0x444b4e1A65949AB2ac75979D5d0166Eb7A248Ccb` (Sepolia MockUSDC) |
| `X402_PAY_TO` | evaluator's x402 receiving address | the address that collects the AI fee; NOT a kernel address |
| `READ_RPC_URL` | read-only RPC for `getTransaction` validation | public RPC is fine (`sepolia.base.org` / `mainnet.base.org`); read-only |
| `X402_FACILITATOR_URL` | x402 settlement facilitator (optional) | if absent, settle `transferWithAuthorization` directly |
| `EVALUATOR_KMS_KEY_REF` | KMS handle(s) for the 2-of-3 signers | **handles only** — raw keys never enter the process env |
| `MAX_BUNDLE_TOKENS` | evidence cap | default `100000` (§5 evidence-inflation bound) |
| `FEE_PER_50K_TOKENS_USDC` | §4.3 unit price | default `1000000` ($1, 6dp) |

> **Forbidden env (boot-time refuse).** `PRIVATE_KEY`, `ACTP_PRIVATE_KEY`, `DEPLOYER_*`,
> `MNEMONIC`, or any var that decodes to a 32-byte secp256k1 key. The signer for the *ruling* is a
> KMS reference, not a raw env key, and even that signs **only** the EIP-712 ruling — it has no kernel
> write authority. See the boot guard in §3.

### `railway.json` / start

```
build:  services/dispute-evaluator  (Dockerfile or Nixpacks Node service)
start:  node dist/server.js   (or the service's documented start cmd)
health: GET /health → 200 { status: "ok", chain, bondEscalation, inv3: "no-kernel-calls" }
```

The `/health` payload echoes the wired `bondEscalation` address + chain so an operator can confirm,
at a glance, the service is pointed at the right (and a *non-null*) deployment before announcing it.

---

## 3. INV-3 enforcement at the service boundary (boot guard)

The service MUST fail closed if it is mis-provisioned with signing power. Pseudo-guard run at boot,
before the HTTP listener binds:

```
// INV-3 boot guard — refuse to start with any kernel-write capability.
for (const k of Object.keys(process.env)) {
  const v = process.env[k] ?? "";
  if (/^(PRIVATE_KEY|ACTP_PRIVATE_KEY|MNEMONIC|DEPLOYER_.*)$/.test(k)) {
    throw new Error(`INV-3 violation: forbidden secret '${k}' present — dispute-evaluator must not hold kernel-write keys.`);
  }
  if (/^0x[0-9a-fA-F]{64}$/.test(v) && k !== "BOND_ESCALATION_ADDRESS" /* 20-byte, not 32 */) {
    throw new Error(`INV-3 violation: env '${k}' looks like a 32-byte private key.`);
  }
}
// Read client is read-only: assert no signer is attached.
assert(readClient.signer === undefined, "INV-3: read RPC client must have no signer");
```

This is belt-and-suspenders to the architectural fact that the evaluator code imports **no** ACTP
write SDK and **no** `kernel.transitionState` path. The grep-able guarantee: a security reviewer can
`grep -rE 'transitionState|openDispute|submitAIRuling|\.resolve\(|safeTransfer|sendTransaction' services/dispute-evaluator/src`
and find **only** the read-only `getTransaction` call and the local EIP-712 signing — never a write.

---

## 4. Deploy runbook

> No on-chain broadcast happens here — this service does not deploy a contract. "Deploy" = ship the
> Railway service. The **contract** addresses it references come from P4-1 (Sepolia) / P6-1 (mainnet).

1. **Prereq:** BondEscalation is deployed and its address written back into `deployments/aip14b.json`
   for `EVALUATOR_CHAIN`. While that slot is `null` / `AWAIT_BROADCAST`, the service start-up assertion
   (`BOND_ESCALATION_ADDRESS` must be a non-zero, code-bearing address on `READ_RPC_URL`) keeps it from
   booting against a phantom domain. **Do not deploy the evaluator before P4-1.**
2. **Provision evaluator signers in KMS.** The 2 fixed + ≥1 rotating evaluator addresses must equal
   `fixedEvaluators` / `rotatingPool` in the BondEscalation constructor args (`aip14b.json`). The
   service only needs the **fixed** signers + the rotating signer(s) it is responsible for; per
   Threat Model §3 residual, run rotating evaluators from **diverse vendors** so no single-vendor
   compromise reaches 2/3.
3. **Set Railway secrets** per §2. Confirm **no** forbidden key var is present (the boot guard will
   refuse otherwise — verify in deploy logs).
4. **Deploy + smoke:**
   - `GET /health` → 200, `bondEscalation` matches `aip14b.json`, `chain` matches.
   - **Phase-1 smoke:** `POST /v1/evaluate` with a real `DISPUTED` `txId`, no `X-PAYMENT` → expect
     `402` with a well-formed x402 quote (price = `ceil(tokens/50k) * FEE_PER_50K_TOKENS_USDC`,
     `payTo == X402_PAY_TO`, `asset == USDC_ADDRESS`).
   - **Oversized-bundle smoke:** evidence > `MAX_BUNDLE_TOKENS` → `413`, never priced.
   - **Phase-2 smoke (testnet only):** pay the quote with a Sepolia USDC authorization → `200` with a
     bundle whose 2-of-3 signatures recover to the configured evaluator addresses under the on-chain
     domain. Verify by `ECDSA.recover` against `DOMAIN_SEPARATOR` off-chain (do NOT submit on-chain in
     the smoke — that is the keeper's separately-gated call).
5. **Announce** the URL only after `/health` shows a non-null, chain-correct `bondEscalation`.

---

## 5. What this service does NOT do (explicit non-goals → INV-3)

- It does **not** call `openDispute`, `submitAIRuling`, `proposeDirectly`, `challenge`,
  `escalateToUMA`, `finalize`, `settleUMAAssertion`, or any other BondEscalation/kernel/mediator
  function. Those are on-chain actions performed by keepers/SDK callers and are gas-governed by
  `paymaster-allowlist-decision.md`, not by this service.
- It does **not** custody escrow, entry bonds, Tier-1 bonds, or the UMA bond. The only value it
  touches is its **own AI fee** (x402, off-chain), credited to `X402_PAY_TO`.
- It does **not** decide finality. A signed ruling is **non-authoritative** (INV-16/21): it enters
  on-chain as a *challengeable* Tier-1 proposal. The evaluator's `confidence` field is advisory only.
- It is **not** in the escrow-solvency or dispute-bond trust path. A compromised evaluator service can
  at worst sign a bad ruling — which the bond game / UMA Tier-2 corrects — and can never move funds.
