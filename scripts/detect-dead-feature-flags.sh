#!/usr/bin/env bash
# Detect potentially stale/dead feature flags in the OpenBurnBar codebase.
#
# Strategy:
#   1. Extract all feature flag identifiers from canonical sources
#      (RemoteConfig keys in Swift, HermesSquareFeatureFlags.kt, AGENTS.md table)
#   2. For each flag, count usages across the entire codebase (excluding tests)
#   3. Report flags that appear only 1-2 times (likely only defined, never consumed)
#      or flags in the canonical list that no longer appear at all
#
# Usage: ./scripts/detect-dead-feature-flags.sh [--json] [--fail-on-stale]

set -euo pipefail
cd "$(dirname "$0")/.."

FLAG_THRESHOLD=${FLAG_THRESHOLD:-2}  # flags with <= N usages are flagged
JSON_OUTPUT=false
FAIL_ON_STALE=false
for arg in "$@"; do
  case "$arg" in
    --json) JSON_OUTPUT=true ;;
    --fail-on-stale) FAIL_ON_STALE=true ;;
  esac
done

# ── 1. Extract known flag names from codebase ─────────────────────────────

echo "==> Scanning for feature flag definitions..." >&2

# RemoteConfig keys in Swift (look for "computer_use_*" and similar patterns)
SWIFT_FLAGS=$(
  grep -rEh '"[a-z][a-z0-9_]{4,}"' \
    AgentLens/ OpenBurnBarCore/ OpenBurnBarDaemon/ OpenBurnBarMobile/ \
    --include="*.swift" 2>/dev/null \
    | grep -oE '"[a-z][a-z0-9_]{4,}"' \
    | grep -E '_enabled|_flag|_mode|_active|_allowed|_kill|_switch' \
    | sort -u \
    | tr -d '"' \
    || true
)

# Android feature flags from HermesSquareFeatureFlags.kt and similar
KOTLIN_FLAGS=$(
  grep -rEh '"[a-z][a-z0-9_]{4,}"' \
    android/app/src/ \
    --include="*.kt" 2>/dev/null \
    | grep -oE '"[a-z][a-z0-9_]{4,}"' \
    | grep -E '_enabled|_flag|_mode|_active|_allowed|_kill|_switch' \
    | sort -u | tr -d '"' \
    || true
)

# Flags referenced in AGENTS.md (backtick-quoted identifiers)
AGENTS_FLAGS=$(
  grep -oE '`[a-z][a-z0-9_]{4,}`' AGENTS.md \
    | grep -E '_enabled|_flag|_mode|_active|_allowed|_kill|_switch' \
    | tr -d '`' | sort -u \
    || true
)

# Combine all unique flag names
ALL_FLAGS=$(printf '%s\n%s\n%s\n' "$SWIFT_FLAGS" "$KOTLIN_FLAGS" "$AGENTS_FLAGS" \
  | sort -u | grep -v '^$' || true)

if [[ -z "$ALL_FLAGS" ]]; then
  echo "No feature flags found." >&2
  exit 0
fi

FLAG_COUNT=$(echo "$ALL_FLAGS" | wc -l | tr -d ' ')
echo "==> Found ${FLAG_COUNT} unique flag identifiers." >&2

# ── 2. Count usages for each flag — using rg for speed ───────────────────

STALE_FLAGS=()
ACTIVE_FLAGS=()

# Directories to search (exclude build artifacts and vendored code)
SEARCH_DIRS=(
  AgentLens OpenBurnBarCore OpenBurnBarDaemon OpenBurnBarMobile
  android/app/src functions/src extensions/openburnbar/src
  AGENTS.md CONTRIBUTING.md README.md
)
SEARCH_GLOB="--glob=*.{swift,kt,ts,md}"

if command -v rg &>/dev/null; then
  # Fast path: use ripgrep
  while IFS= read -r flag; do
    [[ -z "$flag" ]] && continue
    USAGE_COUNT=$(
      rg --count-matches --no-heading -F "$flag" \
        $SEARCH_GLOB \
        "${SEARCH_DIRS[@]}" 2>/dev/null \
        | grep -c ":" || echo 0
    )
    if [[ $USAGE_COUNT -le $FLAG_THRESHOLD ]]; then
      STALE_FLAGS+=("$flag:$USAGE_COUNT")
    else
      ACTIVE_FLAGS+=("$flag:$USAGE_COUNT")
    fi
  done <<< "$ALL_FLAGS"
else
  # Slow path: use grep (may take 30-60s on large repos)
  echo "==> rg (ripgrep) not found; falling back to grep — this may be slow." >&2
  while IFS= read -r flag; do
    [[ -z "$flag" ]] && continue
    USAGE_COUNT=$(
      grep -rlF "$flag" \
        --include="*.swift" --include="*.kt" --include="*.ts" --include="*.md" \
        "${SEARCH_DIRS[@]}" 2>/dev/null | grep -c "." || echo 0
    )
    if [[ $USAGE_COUNT -le $FLAG_THRESHOLD ]]; then
      STALE_FLAGS+=("$flag:$USAGE_COUNT")
    else
      ACTIVE_FLAGS+=("$flag:$USAGE_COUNT")
    fi
  done <<< "$ALL_FLAGS"
fi

# ── 3. Report results ────────────────────────────────────────────────────

if [[ "$JSON_OUTPUT" == "true" ]]; then
  echo "{"
  echo "  \"active\": ["
  for f in "${ACTIVE_FLAGS[@]:-}"; do
    name="${f%%:*}" count="${f##*:}"
    echo "    {\"flag\": \"$name\", \"usages\": $count},"
  done
  echo "  ],"
  echo "  \"stale\": ["
  for f in "${STALE_FLAGS[@]:-}"; do
    name="${f%%:*}" count="${f##*:}"
    echo "    {\"flag\": \"$name\", \"usages\": $count},"
  done
  echo "  ]"
  echo "}"
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
