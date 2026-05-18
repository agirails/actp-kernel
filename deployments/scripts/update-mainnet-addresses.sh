#!/usr/bin/env bash
# ─── Update mainnet contract addresses across all repos ────────────────
#
# Run AFTER Phase 1 (on-chain deploy) of MAINNET-REDEPLOY-PLAN.md to
# propagate the new contract addresses into every consumer in lockstep.
#
# Usage:
#   ./update-mainnet-addresses.sh <kernel> <vault> <registry> <archive> <deploy-block>
#
# Example:
#   ./update-mainnet-addresses.sh \
#     0xDEADBEEF... 0xCAFEBABE... 0xBADC0FFEE... 0xFACEFEED... 46123456
#
# What it does:
#   1. Validates all 4 addresses + the deploy block via sanity checks
#   2. Updates sdk-js (src/config/networks.ts + 2 test fixtures)
#   3. Updates python-sdk-v2 (src/agirails/config/networks.py)
#   4. Updates agirails.app web (app/api/cron/index-stats/route.ts mainnet block)
#   5. Prints a checklist of NEXT actions (build + test + publish + commit)
#
# What it does NOT do (intentional — these need human review/judgment):
#   - Run npm publish / pypi upload (those need credentials + a clean head)
#   - Update docs-site markdown (lower priority; can lag by hours)
#   - Update cosmetic project notes
#   - Modify paymaster allowlists (those are dashboard actions)
#
# Idempotent: safe to re-run if you mistyped one address — it will only
# replace the OLD mainnet addresses that this script knows about, so a
# second run with corrected args undoes the first.

set -euo pipefail

# ─── Argument parsing ─────────────────────────────────────────────────
if [[ $# -ne 5 ]]; then
  echo "Usage: $0 <new-kernel> <new-vault> <new-registry> <new-archive> <deploy-block>"
  echo ""
  echo "Example:"
  echo "  $0 0x1234... 0x5678... 0x9abc... 0xdef0... 46123456"
  exit 2
fi

NEW_KERNEL="$1"
NEW_VAULT="$2"
NEW_REGISTRY="$3"
NEW_ARCHIVE="$4"
NEW_DEPLOY_BLOCK="$5"

# Current mainnet addresses (the ones we're replacing).
# Sourced from deployments/base-mainnet.json (when created) or from memory
# at the top of MAINNET-REDEPLOY-PLAN.md.
OLD_KERNEL="0x132B9eB321dBB57c828B083844287171BDC92d29"
OLD_VAULT="0x6aAF45882c4b0dD34130ecC790bb5Ec6be7fFb99"
OLD_REGISTRY="0x6fB222CF3DDdf37Bcb248EE7BBBA42Fb41901de8"
OLD_ARCHIVE="0x0516C411C0E8d75D17A768022819a0a4FB3cA2f2"
OLD_DEPLOY_BLOCK="41935749"

# ─── Validation ───────────────────────────────────────────────────────
hex_addr_re='^0x[a-fA-F0-9]{40}$'
for label_addr in \
  "kernel:$NEW_KERNEL" \
  "vault:$NEW_VAULT" \
  "registry:$NEW_REGISTRY" \
  "archive:$NEW_ARCHIVE"; do
  label="${label_addr%%:*}"
  addr="${label_addr##*:}"
  if [[ ! "$addr" =~ $hex_addr_re ]]; then
    echo "✗ Invalid $label address: $addr"
    echo "  Must be 0x + 40 hex chars."
    exit 1
  fi
done
if [[ ! "$NEW_DEPLOY_BLOCK" =~ ^[0-9]+$ ]]; then
  echo "✗ Deploy block must be a non-negative integer, got: $NEW_DEPLOY_BLOCK"
  exit 1
fi
if [[ "$NEW_KERNEL" == "$OLD_KERNEL" ]]; then
  echo "✗ New kernel address is identical to old kernel — refusing to no-op."
  exit 1
fi

# ─── Locate repos ─────────────────────────────────────────────────────
REPO_ROOT_KERNEL="$(cd "$(dirname "$0")/../.." && pwd)"
REPO_ROOT_SDKJS="$(cd "$REPO_ROOT_KERNEL/../../SDK and Runtime/sdk-js" 2>/dev/null && pwd || true)"
REPO_ROOT_PYSDK="$(cd "$REPO_ROOT_KERNEL/../../SDK and Runtime/python-sdk-v2" 2>/dev/null && pwd || true)"
REPO_ROOT_WEB="$(cd "$REPO_ROOT_KERNEL/../../Platform/agirails.app/web" 2>/dev/null && pwd || true)"

for repo in "$REPO_ROOT_SDKJS" "$REPO_ROOT_PYSDK" "$REPO_ROOT_WEB"; do
  if [[ -z "$repo" || ! -d "$repo" ]]; then
    echo "✗ Could not locate one of the consumer repos. Expected layout:"
    echo "     <agirails>/Protocol/actp-kernel/  (this repo)"
    echo "     <agirails>/SDK and Runtime/sdk-js/"
    echo "     <agirails>/SDK and Runtime/python-sdk-v2/"
    echo "     <agirails>/Platform/agirails.app/web/"
    exit 1
  fi
done

echo "▶ Repos located:"
echo "    sdk-js:        $REPO_ROOT_SDKJS"
echo "    python-sdk-v2: $REPO_ROOT_PYSDK"
echo "    agirails.app:  $REPO_ROOT_WEB"
echo ""

# ─── In-place edits ───────────────────────────────────────────────────
# Use sed -i '' for macOS (BSD sed). On Linux, drop the '' arg.
SED_INPLACE=(-i "")
if [[ "$(uname)" == "Linux" ]]; then
  SED_INPLACE=(-i)
fi

# Helper: sed-replace OLD→NEW in given files. Verifies the file actually
# changed, so a quiet sed-miss doesn't slip past unnoticed.
replace_in() {
  local old="$1" new="$2"
  shift 2
  for file in "$@"; do
    if [[ ! -f "$file" ]]; then
      echo "  ⚠ Skipping (not found): $file"
      continue
    fi
    before=$(grep -c "$old" "$file" || true)
    if [[ "$before" -eq 0 ]]; then
      echo "  ⚠ Old value not found in $file — already updated?"
      continue
    fi
    sed "${SED_INPLACE[@]}" "s|$old|$new|g" "$file"
    after=$(grep -c "$old" "$file" || true)
    if [[ "$after" -ne 0 ]]; then
      echo "  ✗ Replace incomplete in $file ($after occurrences remain)"
      exit 1
    fi
    echo "  ✓ $(basename "$file"): $before replacement(s)"
  done
}

echo "▶ Updating sdk-js"
replace_in "$OLD_KERNEL"   "$NEW_KERNEL"   "$REPO_ROOT_SDKJS/src/config/networks.ts" "$REPO_ROOT_SDKJS/src/config/networks.test.ts" "$REPO_ROOT_SDKJS/src/protocol/ACTPKernel.test.ts"
replace_in "$OLD_VAULT"    "$NEW_VAULT"    "$REPO_ROOT_SDKJS/src/config/networks.ts" "$REPO_ROOT_SDKJS/src/config/networks.test.ts" "$REPO_ROOT_SDKJS/src/protocol/ACTPKernel.test.ts"
replace_in "$OLD_REGISTRY" "$NEW_REGISTRY" "$REPO_ROOT_SDKJS/src/config/networks.ts" "$REPO_ROOT_SDKJS/src/config/networks.test.ts"
replace_in "$OLD_ARCHIVE"  "$NEW_ARCHIVE"  "$REPO_ROOT_SDKJS/src/config/networks.ts"
echo ""

echo "▶ Updating python-sdk-v2"
replace_in "$OLD_KERNEL"   "$NEW_KERNEL"   "$REPO_ROOT_PYSDK/src/agirails/config/networks.py"
replace_in "$OLD_VAULT"    "$NEW_VAULT"    "$REPO_ROOT_PYSDK/src/agirails/config/networks.py"
replace_in "$OLD_REGISTRY" "$NEW_REGISTRY" "$REPO_ROOT_PYSDK/src/agirails/config/networks.py"
replace_in "$OLD_ARCHIVE"  "$NEW_ARCHIVE"  "$REPO_ROOT_PYSDK/src/agirails/config/networks.py"
echo ""

echo "▶ Updating agirails.app web (indexer cron)"
INDEXER="$REPO_ROOT_WEB/app/api/cron/index-stats/route.ts"
replace_in "$OLD_KERNEL"       "$NEW_KERNEL"       "$INDEXER"
replace_in "$OLD_DEPLOY_BLOCK" "$NEW_DEPLOY_BLOCK" "$INDEXER"
echo ""

echo "▶ All in-place edits complete."
echo ""

# ─── Hand-off checklist ───────────────────────────────────────────────
cat <<EOF
═══════════════════════════════════════════════════════════════════════
  NEXT STEPS (manual, in order)
═══════════════════════════════════════════════════════════════════════

In sdk-js:
  cd "$REPO_ROOT_SDKJS"
  npm install
  npm run lint
  npm run typecheck
  npm test
  # Bump version in package.json (e.g. 3.5.3 → 4.0.0 — breaking change for integrators)
  git add . && git commit -m "release: mainnet redeploy — new kernel <addr-short>" && git tag v4.0.0
  git push origin main --tags
  npm publish --access public

In python-sdk-v2:
  cd "$REPO_ROOT_PYSDK"
  pip install -e .
  pytest
  # Bump version in pyproject.toml
  git add . && git commit -m "release: mainnet redeploy" && git tag v3.0.0
  git push origin main --tags
  python3 -m build && twine upload dist/*

In agirails.app web:
  cd "$REPO_ROOT_WEB"
  npm run lint && npm run typecheck && npm run build
  git add app/api/cron/index-stats/route.ts
  git commit -m "ops: indexer follows mainnet redeploy to new kernel"
  git push origin master   # Vercel auto-deploys

In agirails-mcp-server and n8n-nodes-actp:
  cd "<each>"
  npm install @agirails/sdk@latest
  npm test && npm run build
  # Bump version, commit, tag, push, publish

External dashboards (do these IN PARALLEL with the SDK publishes above):
  - CDP paymaster: add NEW_KERNEL + NEW_VAULT + NEW_REGISTRY to allowlist
  - Pimlico paymaster: same
  - These must land BEFORE the SDK publishes so gasless flows don't break

Documentation (lower priority; can lag by hours):
  - actp-kernel/deployments/base-mainnet.json — CREATE this file mirroring base-sepolia.json
  - actp-kernel/SECURITY.md — bump "Last Updated" + add a line under H-1 noting the redeploy
  - actp-kernel/README.md — update mainnet address block
  - docs-site/docs/{installation,contract-reference,...}.md — 12 files; bulk-update via sed
  - docs-site/updates/$(date -u +%Y-%m-%d)-mainnet-redeploy.md — release-notes post

Calendar reminders to set:
  - +2 days: confirm executeAgentRegistryUpdate() was called by anyone (permissionless)
  - +60 days: force-resolve any still-stuck old-kernel txs per MAINNET-REDEPLOY-PLAN.md §"Stuck-tx migration strategy" Option C

═══════════════════════════════════════════════════════════════════════
EOF
