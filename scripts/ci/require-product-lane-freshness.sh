#!/usr/bin/env bash
# Fail closed when the Mac/iOS product lanes on main have been red for >24h.
# Merge-queue (merge_group) and push:main are the enforcement events.
# pull_request prints the same evidence but does not fail, so the gate can land
# while App PR Gate is being repaired.
set -euo pipefail

REPO="${GITHUB_REPOSITORY:-Imagine-That-Ai/BurnBar}"
EVENT="${GITHUB_EVENT_NAME:-}"
MAX_AGE_SECONDS="${PRODUCT_LANE_MAX_AGE_SECONDS:-86400}"
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
  if [[ "$EVENT" == "pull_request" ]]; then
    echo "::warning::Product-lane freshness is red; merge_group will fail until App PR Gate / full harness succeed on main."
    exit 0
  fi
  echo "::error::Red App PR Gate / full harness older than 24h blocks merge."
  exit 1
fi

echo "Product-lane freshness: App PR Gate and full harness have a success inside the window."
