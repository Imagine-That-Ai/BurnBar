#!/usr/bin/env bash
# Detect potentially stale/dead feature flags in the OpenBurnBar codebase.
#
# Strategy:
#   1. Extract rollout identifiers from canonical sources only: Remote Config
#      defaults/constants and the local Hermes Square feature-flag registry.
#   2. Count literal usages across source/docs. Counts are matches, not files.
#   3. Report flags that appear only once, which usually means "defined but
#      never read." Do not scrape generic strings like `router_mode` or
#      telemetry event names; they are not feature flags.
#
# Usage: ./scripts/detect-dead-feature-flags.sh [--json] [--fail-on-stale]

set -euo pipefail
cd "$(dirname "$0")/.."

FLAG_THRESHOLD=${FLAG_THRESHOLD:-1}  # flags with <= N literal usages are flagged
JSON_OUTPUT=false
FAIL_ON_STALE=false
for arg in "$@"; do
  case "$arg" in
    --json) JSON_OUTPUT=true ;;
    --fail-on-stale) FAIL_ON_STALE=true ;;
  esac
done

# ── 1. Extract known flag names from canonical sources ────────────────────

echo "==> Scanning for feature flag definitions..." >&2

CANONICAL_SOURCES=(
  AgentLens/Services/SettingsManager.swift
  OpenBurnBarMobile/Services/Media/MobileMediaBudgetStatusStore.swift
  OpenBurnBarMobile/Services/IrohRelay/HermesIrohRelayTransport.swift
  AgentLens/Services/IrohRelay/HermesIrohRelayHostClient.swift
  OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/PhoneControlAttestationPolicy.swift
  OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/PhoneControlAuthoritySigningKey.swift
  OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/ControlFrameSeal.swift
  OpenBurnBarCore/Sources/OpenBurnBarMedia/MediaFrameAEAD.swift
  android/app/src/main/java/com/openburnbar/data/square/HermesSquareFeatureFlags.kt
  android/app/src/main/java/com/openburnbar/data/computeruse/AndroidAppCheckAttestationReader.kt
  android/app/src/main/java/com/openburnbar/data/computeruse/PhoneControlSecureEnclaveKeystore.kt
  android/app/src/main/java/com/openburnbar/data/computeruse/ControlFrameSeal.kt
  android/app/src/main/java/com/openburnbar/data/media/MediaFrameAead.kt
  functions/src/computerUseRemoteConfig.ts
  functions/src/mediaRemoteConfig.ts
  functions/src/cloudProAllowanceRemoteConfig.ts
)

extract_flags() {
  local source
  for source in "${CANONICAL_SOURCES[@]}"; do
    [[ -f "$source" ]] || continue
    grep -E '"[A-Za-z0-9_.-]+"' "$source" \
      | grep -vE '^[[:space:]]*(//|/\*|\*|#)' \
      | grep -oE '"[A-Za-z0-9_.-]+"' \
      | tr -d '"' \
      | grep -E '^computer_use_[a-z0-9_]+$|^media_(kill_switch|budget_[a-z0-9_]+|normal_[a-z0-9_]+|soft_[a-z0-9_]+)$|^cloud_pro_[a-z0-9_]+$|^hosted_quota_[a-z0-9_]+$|^hermes_iroh_hosted_relay_url$|^square\.feature\.[A-Za-z0-9_.-]+$' \
      || true
  done
}

ALL_FLAGS=$(extract_flags | sort -u | grep -v '^$' || true)

if [[ -z "$ALL_FLAGS" ]]; then
  echo "No feature flags found." >&2
  exit 0
fi

FLAG_COUNT=$(echo "$ALL_FLAGS" | wc -l | tr -d ' ')
echo "==> Found ${FLAG_COUNT} unique flag identifiers." >&2

# ── 2. Count usages for each flag — using rg for speed ───────────────────

STALE_FLAGS=()
ACTIVE_FLAGS=()

# Directories to search (exclude build artifacts and vendored code).
SEARCH_DIRS=(
  AgentLens OpenBurnBarCore OpenBurnBarDaemon OpenBurnBarMobile
  android/app/src functions/src extensions/openburnbar/src
  docs droid-wiki AGENTS.md CONTRIBUTING.md README.md
)
SEARCH_GLOBS=(--glob=*.swift --glob=*.kt --glob=*.ts --glob=*.md)

count_literal_uses() {
  local flag="$1"
  if command -v rg >/dev/null 2>&1; then
    rg --count-matches --no-heading -F "$flag" \
      "${SEARCH_GLOBS[@]}" \
      --glob='!**/build/**' \
      --glob='!**/.build/**' \
      --glob='!**/node_modules/**' \
      "${SEARCH_DIRS[@]}" 2>/dev/null \
      | awk -F: '{sum += $NF} END {print sum + 0}'
  else
    grep -RhoF "$flag" \
      --include="*.swift" --include="*.kt" --include="*.ts" --include="*.md" \
      "${SEARCH_DIRS[@]}" 2>/dev/null | wc -l | tr -d ' '
  fi
}

while IFS= read -r flag; do
  [[ -z "$flag" ]] && continue
  USAGE_COUNT="$(count_literal_uses "$flag")"
  if [[ "$USAGE_COUNT" -le "$FLAG_THRESHOLD" ]]; then
    STALE_FLAGS+=("$flag:$USAGE_COUNT")
  else
    ACTIVE_FLAGS+=("$flag:$USAGE_COUNT")
  fi
done <<< "$ALL_FLAGS"

# ── 3. Report results ────────────────────────────────────────────────────

if [[ "$JSON_OUTPUT" == "true" ]]; then
  JSON_ARGS=()
  if [[ "${#ACTIVE_FLAGS[@]}" -gt 0 ]]; then
    JSON_ARGS+=("${ACTIVE_FLAGS[@]}")
  fi
  JSON_ARGS+=(--)
  if [[ "${#STALE_FLAGS[@]}" -gt 0 ]]; then
    JSON_ARGS+=("${STALE_FLAGS[@]}")
  fi
  python3 - "${JSON_ARGS[@]}" <<'PY'
import json
import sys

active_raw, stale_raw = [], []
target = active_raw
for item in sys.argv[1:]:
    if item == "--":
        target = stale_raw
        continue
    target.append(item)

def parse(values):
    parsed = []
    for value in values:
        name, count = value.rsplit(":", 1)
        parsed.append({"flag": name, "usages": int(count)})
    return parsed

print(json.dumps({"active": parse(active_raw), "stale": parse(stale_raw)}, indent=2, sort_keys=True))
PY
else
  echo ""
  echo "=== Feature Flag Audit ==="
  echo ""
  echo "Active flags (>${FLAG_THRESHOLD} usages):"
  for f in "${ACTIVE_FLAGS[@]:-}"; do
    name="${f%%:*}" count="${f##*:}"
    printf "  %-55s %s usages\n" "$name" "$count"
  done

  echo ""
  echo "Potentially stale flags (<=${FLAG_THRESHOLD} usages) — review for cleanup:"
  if [[ ${#STALE_FLAGS[@]} -eq 0 ]]; then
    echo "  (none — all flags appear active)"
  else
    for f in "${STALE_FLAGS[@]:-}"; do
      name="${f%%:*}" count="${f##*:}"
      printf "  %-55s %s usages\n" "$name" "$count"
    done
  fi
  echo ""
fi

if [[ "$FAIL_ON_STALE" == "true" && ${#STALE_FLAGS[@]} -gt 0 ]]; then
  echo "::error::${#STALE_FLAGS[@]} potentially stale feature flag(s) detected. Review and clean up." >&2
  exit 1
fi
