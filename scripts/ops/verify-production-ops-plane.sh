#!/usr/bin/env bash
# Production ops plane: code gates + ops alerts + prod health (not full commercial launch).
set -euo pipefail
cd "$(dirname "$0")/../.."

export GCLOUD_PROJECT="${GCLOUD_PROJECT:-${GOOGLE_CLOUD_PROJECT:-burnbar}}"
export GOOGLE_CLOUD_PROJECT="$GCLOUD_PROJECT"
export OPENBURNBAR_FIREBASE_PROJECT="${OPENBURNBAR_FIREBASE_PROJECT:-$GCLOUD_PROJECT}"

GATE_JSON="$(mktemp)"
SUMMARY_JSON="${VERIFY_OPS_PLANE_SUMMARY:-verify-ops-plane-summary.json}"
FAILED=0
declare -a STEPS=()

record() {
  STEPS+=("$1")
}

trap 'rm -f "$GATE_JSON"' EXIT

echo "==> verify-ops-readiness"
if bash scripts/ci/verify-ops-readiness.sh; then
  record "verify-ops-readiness:pass"
else
  record "verify-ops-readiness:fail"
  FAILED=1
fi

echo "==> check-ops-alerts"
if node scripts/ops/check-ops-alerts.mjs; then
  record "check-ops-alerts:pass"
else
  record "check-ops-alerts:fail"
  FAILED=1
fi

if [[ "${FULL_LAUNCH_GATE:-0}" == "1" ]]; then
  echo "==> commercial-launch-gate (FULL_LAUNCH_GATE=1)"
  if node scripts/commercial-launch-gate.mjs >"$GATE_JSON"; then
    record "commercial-launch-gate:pass"
  else
    record "commercial-launch-gate:fail"
    FAILED=1
  fi
else
  echo "==> commercial-launch-gate (audit only, non-blocking)"
  node scripts/commercial-launch-gate.mjs >"$GATE_JSON" 2>/dev/null || true
  record "commercial-launch-gate:audit"
fi

echo "==> post-deploy-health-gate"
# shellcheck source=scripts/ops/resolve-functions-base-url.sh
source scripts/ops/resolve-functions-base-url.sh >/dev/null
export FUNCTIONS_HEALTH_LIVE_URL FUNCTIONS_HEALTH_READY_URL FUNCTIONS_BASE_URL
if bash scripts/ci/post-deploy-health-gate.sh; then
  record "post-deploy-health-gate:pass"
else
  record "post-deploy-health-gate:fail"
  FAILED=1
fi

STEPS_CSV="$(IFS=,; echo "${STEPS[*]}")"
export FAILED STEPS_CSV SUMMARY_JSON GCLOUD_PROJECT GATE_JSON
export FUNCTIONS_BASE_URL FUNCTIONS_HEALTH_LIVE_URL FUNCTIONS_HEALTH_READY_URL
python3 <<'PY'
import json, os
from datetime import datetime, timezone

steps = [s for s in os.environ.get("STEPS_CSV", "").split(",") if s]
launch = {}
gate_path = os.environ.get("GATE_JSON", "")
if gate_path and os.path.isfile(gate_path):
    with open(gate_path) as f:
        launch = json.load(f)

checks = launch.get("checks", {})
ops = checks.get("opsAlerts", {})
ops_alerts_ok = "check-ops-alerts:pass" in steps
summary = {
    "generatedAt": datetime.now(timezone.utc).isoformat(),
    "project": os.environ.get("GCLOUD_PROJECT", "burnbar"),
    "ok": os.environ.get("FAILED", "1") == "0",
    "steps": steps,
    "launchGateVerdict": launch.get("verdict", {}).get("status"),
    "opsAlertsOk": ops_alerts_ok,
    "launchGateOpsAlertsOk": ops.get("ok"),
    "healthLiveUrl": os.environ.get("FUNCTIONS_HEALTH_LIVE_URL", ""),
    "healthReadyUrl": os.environ.get("FUNCTIONS_HEALTH_READY_URL", ""),
}
path = os.environ.get("SUMMARY_JSON", "verify-ops-plane-summary.json")
with open(path, "w") as f:
    json.dump(summary, f, indent=2)
print(json.dumps(summary, indent=2))
PY

if [[ "$FAILED" -ne 0 ]]; then
  echo "FAIL: production ops plane verification" >&2
  exit 1
fi
echo "PASS: production ops plane verification"
