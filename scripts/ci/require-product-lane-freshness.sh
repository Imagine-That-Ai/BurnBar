#!/usr/bin/env bash
# Check whether the Mac/iOS product lanes on main have a success inside the
# configured freshness window. The shared circuit-breaker mode in
# governance/burnbar-ci-gate.json controls the verdict:
#   observe: report red evidence without blocking any event.
#   enforce: fail merge_group/push while pull_request remains advisory, so a
#            repair can still reach review.
set -euo pipefail

REPO="${GITHUB_REPOSITORY:-Imagine-That-Ai/BurnBar}"
EVENT="${GITHUB_EVENT_NAME:-}"
MAX_AGE_SECONDS="${PRODUCT_LANE_MAX_AGE_SECONDS:-86400}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CIRCUIT_BREAKER_MODE="${PRODUCT_LANE_CIRCUIT_BREAKER_MODE:-}"
if [[ -z "${CIRCUIT_BREAKER_MODE}" ]]; then
  CONFIG="${PRODUCT_LANE_GATE_CONFIG:-${ROOT}/governance/burnbar-ci-gate.json}"
  [[ -f "${CONFIG}" ]] || {
    echo "::error::Product-lane circuit-breaker config is missing: ${CONFIG}"
    exit 1
  }
  CIRCUIT_BREAKER_MODE="$(
    python3 - "${CONFIG}" <<'PY'
import json, sys

config = json.load(open(sys.argv[1], encoding="utf-8"))
print(config.get("circuitBreaker", {}).get("mode", ""))
PY
  )"
fi
if [[ "${CIRCUIT_BREAKER_MODE}" != "observe" && "${CIRCUIT_BREAKER_MODE}" != "enforce" ]]; then
  echo "::error::Invalid product-lane circuit-breaker mode: ${CIRCUIT_BREAKER_MODE:-<empty>}"
  exit 1
fi
now="$(date -u +%s)"

if ! command -v gh >/dev/null 2>&1; then
  echo "::error::gh is required to inspect App PR Gate / full harness."
  exit 1
fi

inspect_workflow() {
  local workflow="$1"
  local json
  json="$(gh run list --repo "$REPO" --workflow "$workflow" --branch main --limit 8 --json conclusion,createdAt,event,status,databaseId,url)"
  python3 - "$workflow" "$json" "$now" "$MAX_AGE_SECONDS" <<'PY'
import json, sys
from datetime import datetime, timezone

workflow, raw, now_s, max_age = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
runs = json.loads(raw)
completed = [r for r in runs if r.get("conclusion") in ("success", "failure", "cancelled", "timed_out")]
print(f"{workflow}: sampled {len(runs)} runs, completed {len(completed)}")
if not completed:
    print(f"{workflow}: no completed runs on main")
    sys.exit(2)
latest = completed[0]
created = datetime.fromisoformat(latest["createdAt"].replace("Z", "+00:00")).timestamp()
age = now_s - int(created)
print(f"{workflow}: latest conclusion={latest['conclusion']} event={latest.get('event')} age_s={age} url={latest.get('url')}")
success_in_window = False
for run in completed:
    if run.get("conclusion") != "success":
        continue
    ts = datetime.fromisoformat(run["createdAt"].replace("Z", "+00:00")).timestamp()
    if now_s - int(ts) <= max_age:
        success_in_window = True
        break
if latest["conclusion"] != "success" and age > max_age and not success_in_window:
    sys.exit(3)
if latest["conclusion"] != "success" and not success_in_window:
    sys.exit(3)
PY
}

status=0
inspect_workflow "app-pr-gate.yml" || status=$?
inspect_workflow "openburnbar-pr-harness.yml" || status=$?

if [[ "$status" -ne 0 ]]; then
  echo "Product lane on main is red with no success inside ${MAX_AGE_SECONDS}s."
  if [[ "${CIRCUIT_BREAKER_MODE}" == "observe" ]]; then
    echo "::warning::Product-lane freshness is red; circuit-breaker mode=observe, so this event remains non-blocking."
    exit 0
  fi
  if [[ "$EVENT" == "pull_request" ]]; then
    echo "::warning::Product-lane freshness is red; circuit-breaker mode=enforce will block merge_group until App PR Gate / full harness succeed on main."
    exit 0
  fi
  echo "::error::Red App PR Gate / full harness older than ${MAX_AGE_SECONDS}s blocks merge (circuit-breaker mode=enforce)."
  exit 1
fi

echo "Product-lane freshness: App PR Gate and full harness have a success inside the window (circuit-breaker mode=${CIRCUIT_BREAKER_MODE})."
