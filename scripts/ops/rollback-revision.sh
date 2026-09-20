#!/usr/bin/env bash
# Fast revision-pin rollback (sub-minute — no rebuild, no redeploy).
#
# Gen2 Cloud Functions ARE Cloud Run services, so a bad deploy can be reverted
# by flipping 100% of traffic back to a previous-good revision in seconds. Use
# this as the PRIMARY rollback path. The slow source rollback (git checkout +
# rebuild + firebase deploy) lives at scripts/rollback.sh and is the fallback.
#
# Usage:
#   ./scripts/ops/rollback-revision.sh <cloud-run-service> [target-revision]
#
# Flags:
#   --yes               Non-interactive: skip the confirmation prompt.
#   --dry-run           Print the plan and the gcloud command; change nothing.
#   --revisions-json <file>
#                       Use a checked-in/offline revisions fixture; never calls gcloud.
#   --drill             Execute the live pin and write a receipt (requires --receipt).
#   --receipt <file>    Receipt path for --drill (or ROLLBACK_DRILL_RECEIPT).
#   --region <r>        Cloud Run region (default us-central1).
#   --project <p>       GCP project (default from .firebaserc / gcloud config).
#
# Examples:
#   # Pin <service> back to the most-recent non-serving revision (interactive):
#   ./scripts/ops/rollback-revision.sh searchknowledge
#
#   # Pin to an explicit revision, non-interactive:
#   ./scripts/ops/rollback-revision.sh searchknowledge searchknowledge-00041-abc --yes
#
#   # Preview only:
#   ./scripts/ops/rollback-revision.sh searchknowledge --dry-run
#
# Prerequisites:
#   - gcloud CLI installed and authenticated (gcloud auth login / ADC)
#   - Caller has roles/run.admin (or run.services.update + run.revisions.list)
set -euo pipefail
cd "$(dirname "$0")/../.."

SERVICE=""
TARGET_REVISION=""
REGION="${FUNCTIONS_REGION:-us-central1}"
PROJECT=""
ASSUME_YES=false
DRY_RUN=false
REVISIONS_JSON_FILE=""
REVISIONS_JSON_INPUT="${ROLLBACK_REVISIONS_JSON:-}"
TRAFFIC_JSON="${ROLLBACK_TRAFFIC_JSON:-}"
DRILL=false
DRILL_RECEIPT="${ROLLBACK_DRILL_RECEIPT:-}"

usage() {
  sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'
}

# ── Parse arguments ───────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y) ASSUME_YES=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --revisions-json) REVISIONS_JSON_FILE="${2:?--revisions-json needs a file}"; shift 2 ;;
    --revisions-json=*) REVISIONS_JSON_FILE="${1#*=}"; shift ;;
    --drill) DRILL=true; shift ;;
    --receipt) DRILL_RECEIPT="${2:?--receipt needs a file}"; shift 2 ;;
    --receipt=*) DRILL_RECEIPT="${1#*=}"; shift ;;
    --region) REGION="${2:?--region needs a value}"; shift 2 ;;
    --region=*) REGION="${1#*=}"; shift ;;
    --project) PROJECT="${2:?--project needs a value}"; shift 2 ;;
    --project=*) PROJECT="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "ERROR: unknown flag: $1" >&2; usage; exit 1 ;;
    *)
      if [[ -z "$SERVICE" ]]; then
        SERVICE="$1"
      elif [[ -z "$TARGET_REVISION" ]]; then
        TARGET_REVISION="$1"
      else
        echo "ERROR: unexpected positional argument: $1" >&2
        usage
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$SERVICE" ]]; then
  echo "ERROR: <cloud-run-service> is required." >&2
  usage
  exit 1
fi
if [[ ! "$SERVICE" =~ ^[a-z][a-z0-9-]{0,62}$ ]]; then
  echo "ERROR: service must be a Cloud Run service name, not a resource path or URL." >&2
  exit 1
fi
if [[ ! "$REGION" =~ ^[a-z]+-[a-z0-9]+$ ]]; then
  echo "ERROR: region must be a Cloud Run region name." >&2
  exit 1
fi

if [[ -n "$REVISIONS_JSON_FILE" && -n "$REVISIONS_JSON_INPUT" ]]; then
  echo "ERROR: use only one of --revisions-json and ROLLBACK_REVISIONS_JSON." >&2
  exit 1
fi

# A fixture is an offline plan input. It must never be allowed to flow into a
# traffic mutation or a live drill receipt, even if an operator forgets
# --dry-run.
FIXTURE_MODE=false
if [[ -n "$REVISIONS_JSON_FILE" || -n "$REVISIONS_JSON_INPUT" ]]; then
  FIXTURE_MODE=true
fi
if [[ "$DRILL" == "true" && "$FIXTURE_MODE" == "true" ]]; then
  echo "ERROR: --drill requires a real gcloud session; fixture revisions are offline only." >&2
  exit 1
fi
if [[ "$DRILL" == "true" && -z "$DRILL_RECEIPT" ]]; then
  echo "ERROR: --drill requires --receipt <file> or ROLLBACK_DRILL_RECEIPT." >&2
  exit 1
fi
if [[ "$DRILL" != "true" && -n "$DRILL_RECEIPT" ]]; then
  echo "ERROR: --receipt is only valid with --drill; no receipt is recorded for an ordinary rollback." >&2
  exit 1
fi
if [[ "$DRILL" == "true" && "$DRY_RUN" == "true" ]]; then
  echo "ERROR: --drill cannot be combined with --dry-run." >&2
  exit 1
fi

if [[ "$FIXTURE_MODE" != "true" ]] && ! command -v gcloud >/dev/null 2>&1; then
  echo "ERROR: gcloud CLI not found. Install Cloud SDK and authenticate, or pass --revisions-json <file>." >&2
  exit 1
fi

# ── Resolve project (flag → environment → .firebaserc → gcloud config) ─────
if [[ -z "$PROJECT" ]]; then
  PROJECT="${FIREBASE_PROJECT:-${GCLOUD_PROJECT:-}}"
fi
if [[ -z "$PROJECT" && -f .firebaserc ]]; then
  PROJECT="$(python3 -c "
import json, sys
try:
    with open('.firebaserc') as f:
        d = json.load(f)
    print(d.get('projects', {}).get('default', ''))
except Exception:
    print('')
" 2>/dev/null || echo "")"
fi
if [[ -z "$PROJECT" && "$FIXTURE_MODE" != "true" ]]; then
  PROJECT="$(gcloud config get-value project 2>/dev/null || echo "")"
fi
if [[ -z "$PROJECT" && "$FIXTURE_MODE" == "true" ]]; then
  PROJECT="burnbar"
fi
if [[ -z "$PROJECT" ]]; then
  echo "ERROR: could not resolve GCP project. Pass --project <p> or set the .firebaserc default." >&2
  exit 1
fi

if [[ "$FIXTURE_MODE" == "true" ]]; then
  if [[ -n "$REVISIONS_JSON_FILE" ]]; then
    if [[ ! -f "$REVISIONS_JSON_FILE" ]]; then
      echo "ERROR: revisions fixture not found: ${REVISIONS_JSON_FILE}" >&2
      exit 1
    fi
    REVISIONS_JSON="$(cat "$REVISIONS_JSON_FILE")"
  elif [[ -f "$REVISIONS_JSON_INPUT" ]]; then
    REVISIONS_JSON="$(cat "$REVISIONS_JSON_INPUT")"
  else
    REVISIONS_JSON="$REVISIONS_JSON_INPUT"
  fi

  fixture_payload="$REVISIONS_JSON"
  # Accept either the raw gcloud revisions-list array or an object carrying a
  # `revisions`/`result` array. The latter makes fixtures self-describing
  # without changing the production gcloud response contract. An optional
  # `traffic` object lets an offline fixture exercise automatic target
  # selection with the same service readback shape as gcloud.
  if ! REVISIONS_JSON="$(python3 -c '
import json
import sys

try:
    payload = json.load(sys.stdin)
except (TypeError, ValueError) as exc:
    print(f"invalid JSON: {exc}", file=sys.stderr)
    raise SystemExit(1)

if isinstance(payload, list):
    revisions = payload
elif isinstance(payload, dict):
    revisions = payload.get("revisions", payload.get("result", payload.get("items", [])))
else:
    revisions = []

if not isinstance(revisions, list):
    print("fixture must contain a revisions array", file=sys.stderr)
    raise SystemExit(1)
print(json.dumps(revisions))
 ' <<<"$REVISIONS_JSON"
)"; then
    echo "ERROR: invalid revisions fixture." >&2
    exit 1
  fi
  if [[ -z "$TRAFFIC_JSON" ]]; then
    if ! TRAFFIC_JSON="$(python3 -c '
import json
import sys

try:
    payload = json.load(sys.stdin)
except (TypeError, ValueError):
    raise SystemExit(1)

traffic = payload.get("traffic", {}) if isinstance(payload, dict) else {}
print(json.dumps(traffic if isinstance(traffic, dict) else {}))
 ' <<<"$fixture_payload"
)"; then
      echo "ERROR: invalid revisions fixture." >&2
      exit 1
    fi
  fi
else
  REVISIONS_JSON="$(gcloud run revisions list \
    --service "$SERVICE" \
    --region "$REGION" \
    --project "$PROJECT" \
    --sort-by='~metadata.creationTimestamp' \
    --format=json)"

  # Current per-revision traffic split lives on the service, not the revisions.
  TRAFFIC_JSON="$(gcloud run services describe "$SERVICE" \
    --region "$REGION" \
    --project "$PROJECT" \
    --format='json(status.traffic)')"
fi

echo "==> Fast revision-pin rollback"
echo "    service=${SERVICE}"
echo "    region=${REGION}"
echo "    project=${PROJECT}"
if [[ "$FIXTURE_MODE" == "true" ]]; then
  echo "    source=fixture (offline; no traffic mutation)"
fi

# ── List revisions (most recent first) ────────────────────────────────────
# Columns: name + the traffic percent currently routed to each revision.
echo ""
echo "==> Listing revisions for ${SERVICE} (most recent first)"

if [[ -z "$REVISIONS_JSON" || "$REVISIONS_JSON" == "[]" ]]; then
  echo "ERROR: no revisions found for service '${SERVICE}' in ${REGION}/${PROJECT}." >&2
  exit 1
fi

# Human-readable table: revision name + live traffic percent.
python3 - "$REVISIONS_JSON" "$TRAFFIC_JSON" <<'PY'
import json, sys
revisions = json.loads(sys.argv[1] or "[]")
traffic = json.loads(sys.argv[2] or "{}")
pct = {}
entries = (traffic.get("status", {}) or {}).get("traffic")
if entries is None:
    entries = traffic.get("traffic", [])
for t in entries or []:
    name = t.get("revisionName")
    if name:
        pct[name] = pct.get(name, 0) + int(t.get("percent") or 0)
print(f"    {'REVISION':<44} {'TRAFFIC':>8}")
for r in revisions:
    name = (r.get("metadata", {}) or {}).get("name", "")
    share = pct.get(name, 0)
    marker = "  <- serving" if share >= 100 else ""
    print(f"    {name:<44} {str(share)+'%':>8}{marker}")
PY

# ── Resolve target revision if not supplied ───────────────────────────────
if [[ -z "$TARGET_REVISION" ]]; then
  echo ""
  echo "==> No target revision given — selecting the most recent revision NOT serving 100% traffic"
  TARGET_REVISION="$(python3 - "$REVISIONS_JSON" "$TRAFFIC_JSON" <<'PY'
import json, sys
revisions = json.loads(sys.argv[1] or "[]")
traffic = json.loads(sys.argv[2] or "{}")
pct = {}
entries = (traffic.get("status", {}) or {}).get("traffic")
if entries is None:
    entries = traffic.get("traffic", [])
for t in entries or []:
    name = t.get("revisionName")
    if name:
        pct[name] = pct.get(name, 0) + int(t.get("percent") or 0)
# revisions are already sorted newest-first; pick the first one not serving 100%.
for r in revisions:
    name = (r.get("metadata", {}) or {}).get("name", "")
    if not name:
        continue
    if pct.get(name, 0) < 100:
        print(name)
        break
PY
)"
  if [[ -z "$TARGET_REVISION" ]]; then
    echo "ERROR: could not find a previous revision to roll back to (only one revision, or all share traffic)." >&2
    echo "       Pass an explicit <target-revision>, or use the slow source rollback (scripts/rollback.sh)." >&2
    exit 1
  fi
else
  # Validate the explicitly-requested revision actually exists.
  if ! python3 - "$TARGET_REVISION" "$REVISIONS_JSON" <<'PY'
import json
import sys

target = sys.argv[1]
revisions = json.loads(sys.argv[2] or "[]")
names = {
    (revision.get("metadata", {}) or {}).get("name", "")
    for revision in revisions
    if isinstance(revision, dict)
}
raise SystemExit(0 if target in names else 1)
PY
  then
    echo "ERROR: revision '${TARGET_REVISION}' not found for service '${SERVICE}'." >&2
    exit 1
  fi
fi

if [[ ! "$TARGET_REVISION" =~ ^[a-z][a-z0-9-]{0,62}$ ]]; then
  echo "ERROR: target revision must be a Cloud Run revision name." >&2
  exit 1
fi

UPDATE_CMD=(gcloud run services update-traffic "$SERVICE"
  --region "$REGION"
  --project "$PROJECT"
  "--to-revisions=${TARGET_REVISION}=100")

echo ""
echo "=== Revision-pin rollback plan ==="
echo "    service:  ${SERVICE}"
echo "    target:   ${TARGET_REVISION}  (will receive 100% traffic)"
echo "    command:  ${UPDATE_CMD[*]}"
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
  echo "DRY RUN: no traffic changed."
  exit 0
fi
if [[ "$FIXTURE_MODE" == "true" ]]; then
  echo "FIXTURE INPUT: no traffic changed and no live receipt recorded."
  exit 0
fi

# ── Confirm ───────────────────────────────────────────────────────────────
if [[ "$ASSUME_YES" != "true" ]]; then
  read -r -p "Pin 100% traffic to ${TARGET_REVISION}? [y/N] " CONFIRM
  if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Rollback cancelled."
    exit 0
  fi
fi

# ── Flip traffic ──────────────────────────────────────────────────────────
echo "==> Flipping 100% traffic to ${TARGET_REVISION} (no rebuild)"
"${UPDATE_CMD[@]}"
echo "PASS: traffic pinned to ${TARGET_REVISION}"

if [[ "$DRILL" == "true" ]]; then
  echo "==> Verifying live traffic readback"
  TRAFFIC_AFTER_JSON="$(gcloud run services describe "$SERVICE" \
    --region "$REGION" \
    --project "$PROJECT" \
    --format='json(status.traffic)')"
  if ! python3 - "$TARGET_REVISION" "$TRAFFIC_AFTER_JSON" <<'PY'
import json
import sys

target = sys.argv[1]
traffic = json.loads(sys.argv[2] or "{}")
entries = (traffic.get("status", {}) or {}).get("traffic")
if entries is None:
    entries = traffic.get("traffic", [])
percent = sum(
    int(entry.get("percent") or 0)
    for entry in entries or []
    if entry.get("revisionName") == target
)
raise SystemExit(0 if percent >= 100 else 1)
PY
  then
    echo "ERROR: live traffic readback did not confirm 100% on ${TARGET_REVISION}; no drill receipt recorded." >&2
    exit 1
  fi
  echo "PASS: live traffic readback confirmed 100% on ${TARGET_REVISION}"
fi

# ── Health check (warning-only) ───────────────────────────────────────────
echo ""
echo "==> Health check"
HEALTH_PROBE_STATUS="not-run"
SERVICE_URL="$(gcloud run services describe "$SERVICE" \
  --region "$REGION" \
  --project "$PROJECT" \
  --format='value(status.url)' 2>/dev/null || echo "")"

if [[ -z "$SERVICE_URL" ]]; then
  echo "WARN: could not resolve service URL — skipping health probe." >&2
else
  # Try a couple of common health paths; fall back to the service root.
  HEALTH_OK=false
  for path in "/healthLive" "/healthCheck" "/"; do
    HEALTH_URL="${SERVICE_URL%/}${path}"
    STATUS="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$HEALTH_URL" 2>/dev/null || echo "000")"
    echo "    GET ${HEALTH_URL} -> HTTP ${STATUS}"
    if [[ "$STATUS" =~ ^2 ]]; then
      HEALTH_OK=true
      HEALTH_PROBE_STATUS="passed"
      break
    fi
  done
  if [[ "$HEALTH_OK" != "true" ]]; then
    HEALTH_PROBE_STATUS="warning"
    echo "WARN: health probe did not return 2xx — verify manually before declaring the incident resolved." >&2
  fi
fi

if [[ "$DRILL" == "true" ]]; then
  receipt_directory="$(dirname "$DRILL_RECEIPT")"
  mkdir -p "$receipt_directory"
  receipt_tmp="$(mktemp "${DRILL_RECEIPT}.tmp.XXXXXX")"
  trap 'rm -f "$receipt_tmp"' EXIT
  python3 - "$receipt_tmp" "$SERVICE" "$REGION" "$TARGET_REVISION" "$HEALTH_PROBE_STATUS" <<'PY'
import json
import sys
from datetime import datetime, timezone

output, service, region, target_revision, health_status = sys.argv[1:]
receipt = {
    "schema": "openburnbar.rollback-drill-receipt.v1",
    "schemaVersion": 1,
    "generatedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "mode": "live",
    "liveDrill": True,
    "ok": True,
    "drill": {
        "kind": "cloud-run-revision-pin",
        "serviceName": service,
        "region": region,
        "targetRevision": target_revision,
        "trafficPercent": 100,
        "healthProbe": health_status,
    },
    "checks": {
        "revisionListLoaded": True,
        "trafficPinned": True,
        "liveGcloudSession": True,
    },
}
with open(output, "w", encoding="utf-8") as handle:
    json.dump(receipt, handle, indent=2)
    handle.write("\n")
PY
  mv "$receipt_tmp" "$DRILL_RECEIPT"
  trap - EXIT
  echo "LIVE DRILL RECEIPT: ${DRILL_RECEIPT}"
fi

echo ""
echo "=== Revision-pin rollback complete ==="
echo "    Serving: ${TARGET_REVISION} (100%)"
echo ""
echo "Next steps:"
echo "  1. Confirm error rate recovers (Cloud Monitoring / firebase functions:log)."
echo "  2. Fix forward on a branch; redeploy via the normal release path."
echo "  3. If revisions are unusable, fall back to the slow source rollback: scripts/rollback.sh"
