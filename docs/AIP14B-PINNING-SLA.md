# AIP-14b — IPFS Pinning & Evidence-Bundle Persistence SLA (PRD P4-6)

> Scope: the durability-of-record policy for the two IPFS artifacts the Tier-0/1/2 dispute engine
> depends on — (1) the **canonical evaluator prompt** (the bytes the 3-LLM ensemble runs against,
> referenced on-chain) and (2) **per-dispute evidence bundles** (what an AI evaluator and a UMA DVM
> voter rule on). It pins the retention floor, the single provider choice, the re-pin watchdog, the
> one-canonical-serializer mandate, and the cost classification (who pays, fixed vs. variable).
>
> Normative sources: AIP-14b FINAL **§4.2** (evaluator prompt on-chain CID + timelocked governance),
> **§8.4** (UMA claim embeds the evidence-bundle CID; CID MUST match the committed `bundleHash`),
> **§8.6** (escalator is responsible for evidence pinning through the liveness + DVM window),
> PRD **§7.5.8** (IPFS / pinning policy — the half-split resolution), **G-IPFS** (Pinata, ≥35-day),
> **INV-20** (UMA assertions embed an IPFS evidence-bundle CID), **R9 / L11** (persistence + cost
> mis-classification leak).
>
> Operational procedure (the `cast`/Pinata runbook for pinning the prompt and setting its on-chain
> CID via the executed 2-day timelock) lives in `ops/aip14b/pin-canonical-prompt.md`.
> Prompt-governance change process (propose → 2-day → execute) lives in
> `DISPUTE SYSTEM/evaluator-prompt/PROMPT-GOVERNANCE.md`. This document is the **SLA** the runbook
> and governance both serve.

---

## 0. One-paragraph summary

There are two IPFS artifacts and they have **different owners**. The **canonical evaluator prompt**
is AGIRAILS-owned: AGIRAILS pins it to a single provider (Pinata), runs a re-pin watchdog, references
its CIDv1 on-chain, and updates it only through a 2-day timelock — this is a **FIXED operational
cost amortized into the quote's `infra_margin`, never billed per-dispute**. **Per-dispute evidence
bundles** are by default **escalator-owned**: under §8.6 the escalator self-pins and owns persistence
through the UMA liveness + DVM window, so `IPFS_per_bundle = 0` to AGIRAILS. A single optional flag,
**`AGIRAILS_PINS_USER_BUNDLES` (DEFAULT false)**, lets AGIRAILS additionally pin a *convenience copy*
of a user bundle for UX; flipping it on reclassifies bundle pinning as a **VARIABLE per-dispute cost**
(hard-capped $0.01/dispute) that MUST enter the quote as the `IPFS_per_bundle` line — and even then,
AGIRAILS's copy is **not** the durability-of-record: the escalator still self-pins for the ≥35-day SLA.

---

## 1. Retention SLA — single provider, ≥35-day floor

| Parameter | Value | Why |
|---|---|---|
| **Provider** | **Pinata** (single, named — G-IPFS) | One provider per disputes so there is a single system-of-record pin and a single watchdog target. Mirrors MAY exist for redundancy (§3), but Pinata is authoritative. |
| **Retention floor** | **≥ 35 days** beyond any window in which a CID can be referenced or challenged | Must cover UMA liveness (`UMA_LIVENESS = 7200s = 2h`) **plus** the DVM resolution window (48–96h) **plus** the 30-day `forceResolveStale` / `MAX_DISPUTE_DURATION_DAYS` backstop, with margin. 30d backstop + ~4d DVM + slack ⇒ 35d floor. |
| **Addressing** | CIDv1, `base32`, multihash `sha2-256`, fixed UnixFS chunker | Content-addressed: retrieval correctness does NOT depend on trusting Pinata's index — any IPFS node verifies fetched bytes hash to the CID (§3). |

The 35-day floor is a **single, system-wide number** so there is exactly one retention parameter to
monitor and alert on. It applies identically to the canonical prompt pin (AGIRAILS-owned) and to any
evidence bundle AGIRAILS is on the hook for (escalator-owned by default; AGIRAILS only if it
*separately* and explicitly takes the durability decision — the `AGIRAILS_PINS_USER_BUNDLES` UX copy
does **not** put AGIRAILS on this SLA hook).

---

## 2. The two artifacts

### 2.1 Canonical evaluator prompt — AGIRAILS-owned, FIXED cost

- **What:** the exact prompt bytes (`DISPUTE SYSTEM/evaluator-prompt/canonical-prompt.md`) the 3-LLM
  ensemble runs against. Pinned to Pinata as a deterministic CIDv1; that CID is referenced on-chain.
- **On-chain reference + change control (§4.2):** the active prompt CID is governed by the **same
  2-day timelock** the evaluator registry uses (`EVALUATOR_UPDATE_DELAY = 2 days` in
  `src/BondEscalation.sol`, mirroring `proposeFixedEvaluatorUpdate` / `executeFixedEvaluatorUpdate`).
  A prompt change is **never** instant: admin **proposes** the new CID (starts the 2-day clock),
  anyone can fetch + diff the proposed CID during the window, then it is **executed**. Each ruling
  carries `reasoning.evaluatorPromptCID` so it is attributable to the exact prompt version it ran
  under. Step-by-step: `ops/aip14b/pin-canonical-prompt.md`.
- **Who pays:** **AGIRAILS.** The prompt pin + re-pin watchdog + on-chain CID upkeep are a **standing
  FIXED operational cost**, amortized into the quote's `infra_margin` (`fixed_floor` term, §7.5.2 /
  §7.5.8) — **NOT a per-dispute line item.** At ~500 disputes/mo the attributable fixed amortization
  is ≈ $0.11–0.19/dispute, recovered **statistically** via `infra_margin`, not exactly.

### 2.2 Per-dispute evidence bundle — escalator-owned by default, VARIABLE only if flag on

- **What:** the versioned canonical-JSON bundle (`EVIDENCE-BUNDLE-SCHEMA.md`, schemaVersion `1.0.0`)
  carrying the spec, deliverable-or-hash, dispute timeline, and any Tier-0 AI reasoning. Pinned as a
  CIDv1; the pinned CID's content MUST hash to the committed `bundleHash` (INV-20 / OQ-10), and
  `escalateToUMA(disputeId, evidenceCID)` embeds `ipfs://` + that CID in the UMA `assertTruth` claim.
- **Who pays (DEFAULT):** the **ESCALATOR.** Per §8.6 the escalator self-pins and **owns persistence
  through the liveness + DVM window** — an unavailable bundle is itself grounds for a FALSE DVM
  resolution. To AGIRAILS this is **`IPFS_per_bundle = 0`**; the quote does NOT include it.
- See §4 for the `AGIRAILS_PINS_USER_BUNDLES` UX exception.

---

## 3. Re-pin watchdog + alert (AGIRAILS-owned)

A lightweight cron (the **re-pin watchdog**) continuously enforces the §1 SLA on the
AGIRAILS-owned pins:

1. **Liveness probe** — for the active on-chain prompt CID (and any bundle AGIRAILS has separately
   committed to durability for): fetch via the Pinata gateway **and** an independent public IPFS
   gateway, and assert the fetched bytes hash to the referenced CID (content-address check, not an
   index check).
2. **Retention probe** — assert the pin's remaining retention ≥ the 35-day floor; if a pin is within
   the alert margin of expiry, **re-pin the identical bytes** (deterministic ⇒ same CIDv1, §3 of
   PROMPT-GOVERNANCE) so the on-chain reference never dangles.
3. **On-chain consistency probe** — assert the bytes pinned at the active CID still
   deterministically re-pin to the **exact CID referenced on-chain**; a mismatch means a silent
   prompt swap was attempted and MUST page (it would also have failed the on-chain timelock, so a
   mismatch is a hard alarm).
4. **Alert** — any probe failure (unretrievable, sub-floor retention, CID mismatch) raises an alert
   to the dispute-ops owner. Monitoring wiring is in `ops/aip14b/monitoring-alerts.md` (P5-4);
   this SLA defines *what* the watchdog asserts, that runbook defines *where the alert lands*.

The watchdog is part of the FIXED `infra_margin` cost (§2.1), not a per-dispute charge.

---

## 4. The `AGIRAILS_PINS_USER_BUNDLES` flag — the §7.5.8 half-split gap

**Default: `false`.** This is the one place where the fixed/variable classification can flip, so it is
specified exactly.

- **`AGIRAILS_PINS_USER_BUNDLES = false` (DEFAULT, recommended):** escalator self-pins (§2.2),
  `IPFS_per_bundle = 0`, nothing enters the quote, nothing is reported per-dispute. AGIRAILS carries
  only the FIXED prompt-pin cost.
- **`AGIRAILS_PINS_USER_BUNDLES = true` (deliberate UX upgrade only):** AGIRAILS additionally pins a
  **convenience copy** of the user's evidence bundle. The moment this is on, four things become
  mandatory and turn on **automatically** so the cost stays recovered + reported:
  1. **It is a VARIABLE per-dispute cost** — bundle pinning stops being fixed and MUST enter the
     unit-economics quote as the **`IPFS_per_bundle`** line
     (`= min(storage_marginal + bandwidth_marginal, $0.01)`).
  2. **Hard cap `$0.01/dispute`** on `IPFS_per_bundle`, regardless of measured marginal bytes.
  3. **Size discipline** — with AGIRAILS paying, the escalator's incentive to keep the bundle small
     is gone, so the **hard 100 000-token cap** (already enforced by `BundleTooLargeError` via
     tiktoken `cl100k_base`, OQ-9) **plus** a per-dispute **stored-bytes cap** are enforced before
     the pin.
  4. **Monthly envelope line** — the UX-pin total (`≤ $0.01 × monthly dispute volume`) is reported
     in the §7.5.4 monthly bounded-subsidy envelope so the picture stays complete.
- **Durability-of-record is unchanged.** Even with the flag ON, AGIRAILS's pin is a **convenience
  copy, NOT the durability-of-record.** The escalator is **still required to self-pin** for §8.6 /
  UMA durability and the ≥35-day SLA. AGIRAILS is **not** on the ≥35-day hook for user bundles unless
  it explicitly takes that as a *separately-priced* decision (distinct from this UX copy).

> Leak L11 (R9): "AGIRAILS pinning user bundles for UX silently turns a fixed cost variable." Closed
> by: default false; if on, reclassify to the variable `IPFS_per_bundle` quote line + the two caps +
> the monthly envelope line — all automatic.

---

## 5. One-canonical-serializer mandate

There is **exactly one** canonical serializer for evidence bundles, and every consumer **imports**
it — none re-implements it. This is what makes the pinned CID, the committed `bundleHash`, and the
`ipfs://`-CID embedded in the UMA claim refer to **byte-identical** content across every component.

- **The artifact:** `EVIDENCE-BUNDLE-SCHEMA.md` (FROZEN, schemaVersion `1.0.0`) defines the field
  set, the canonical byte form (canonical JSON, UTF-8, recursively key-sorted, whitespace-free,
  integers-only), the `bundleHash = keccak256(canonical_bytes)` rule, and the 100k-token cap. The
  single serializer implementations are `sdk-js/src/dispute/EvidenceBundle.ts` and
  `python-sdk-v2/.../dispute/evidence_bundle.py` (P2-3 / M1.5), proven byte-identical across TS & Py
  via the shared `test-vectors/bundle-vectors.json` (all fixtures + an escape-stress vector).
- **Mandate (normative):** the AI evaluator service, the SDK pinning helper (`pinEvidenceBundle`),
  and the `escalateToUMA` bundle assembly **MUST import the single canonical serializer and MUST NOT
  re-implement** the field set, the canonical byte form, the `bundleHash` rule, or the token cap.
  Re-implementation is the R7 hash-parity drift footgun (a prior prod outage) — forbidden.
- **Binding chain (must all agree on the same bytes):**
  `committed bundleHash` (in `AIRuling`, §4.4) `==` `keccak256` of the pinned bundle bytes (OQ-10)
  `==` the content addressed by the `evidenceCID` embedded as `ipfs://`+CID in the UMA claim (§8.4,
  INV-20). The canonical prompt has its own parallel mandate: `canonical-prompt.md` is the single
  source, pinned deterministically (PROMPT-GOVERNANCE §3) so identical bytes ⇒ identical CIDv1.

---

## 6. Cost classification summary

| Item | Owner / payer | Fixed or variable | Enters the quote as | Default |
|---|---|---|---|---|
| Canonical-prompt pin | **AGIRAILS** | **FIXED** (amortized) | `infra_margin` `fixed_floor` (NOT per-dispute) | always on |
| Re-pin watchdog + on-chain CID upkeep | **AGIRAILS** | **FIXED** (amortized) | `infra_margin` `fixed_floor` | always on |
| Evidence-bundle pin (durability-of-record) | **ESCALATOR** (self-pin, §8.6) | n/a to AGIRAILS | — (`IPFS_per_bundle = 0`) | always |
| Evidence-bundle UX convenience copy | AGIRAILS (only if flag) | **VARIABLE** | `IPFS_per_bundle` (≤ $0.01/dispute) + §7.5.4 envelope | **OFF** (`AGIRAILS_PINS_USER_BUNDLES=false`) |

Pinata plan floor (~$20/mo Picnic, 1TB) is **shared** with existing AGIRAILS pinning, so the
attributable dispute share of the FIXED cost is a fraction of $20 (§7.5.8).

---

## 7. Audit checklist

- [ ] Active on-chain prompt CID resolves on Pinata; fetched bytes hash to that exact CIDv1.
- [ ] `DISPUTE SYSTEM/evaluator-prompt/canonical-prompt.md` deterministically re-pins to the active
      on-chain CID (CIDv1 / base32 / sha2-256 / fixed chunker).
- [ ] Pinata retention satisfies the **≥ 35-day** G-IPFS floor for every AGIRAILS-owned pin.
- [ ] Re-pin watchdog runs on a cron; liveness + retention + on-chain-consistency probes all GREEN;
      alert path wired (`ops/aip14b/monitoring-alerts.md`).
- [ ] Any pending prompt-CID change shows a ≥ 2-day unlock and is diffable before execution.
- [ ] A sample evidence-bundle CID fetches and its bytes hash to the committed `bundleHash`
      (INV-20 / OQ-10).
- [ ] `AGIRAILS_PINS_USER_BUNDLES` is **false** in production config; if ever flipped on, confirm the
      `IPFS_per_bundle` quote line, the $0.01 cap, the per-dispute stored-bytes cap, and the §7.5.4
      monthly envelope line are all active (and the escalator still self-pins).
- [ ] No vendor/model names baked into `canonical-prompt.md` (those are LIVE-CONFIG via the evaluator
      registry, §4.6/§4.9).
- [ ] Every evidence-bundle consumer imports the single canonical serializer (P2-3); grep finds no
      re-implementation of the field set / canonical bytes / `bundleHash` rule / token cap.
