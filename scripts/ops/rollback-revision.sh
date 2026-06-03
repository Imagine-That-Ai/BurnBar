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

usage() {
  sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'
}

# ── Parse arguments ───────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y) ASSUME_YES=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
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

if ! command -v gcloud >/dev/null 2>&1; then
  echo "ERROR: gcloud CLI not found. Install Cloud SDK and authenticate." >&2
  exit 1
fi

# ── Resolve project (flag → .firebaserc default → gcloud config) ───────────
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
if [[ -z "$PROJECT" ]]; then
  PROJECT="$(gcloud config get-value project 2>/dev/null || echo "")"
fi
if [[ -z "$PROJECT" ]]; then
  echo "ERROR: could not resolve GCP project. Pass --project <p> or set the .firebaserc default." >&2
  exit 1
fi

echo "==> Fast revision-pin rollback"
echo "    service=${SERVICE}"
echo "    region=${REGION}"
echo "    project=${PROJECT}"

# ── List revisions (most recent first) ────────────────────────────────────
# Columns: name + the traffic percent currently routed to each revision.
echo ""
echo "==> Listing revisions for ${SERVICE} (most recent first)"
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
for t in (traffic.get("status", {}) or {}).get("traffic", []) or []:
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
for t in (traffic.get("status", {}) or {}).get("traffic", []) or []:
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
  if ! grep -q "\"${TARGET_REVISION}\"" <<<"$REVISIONS_JSON"; then
    echo "ERROR: revision '${TARGET_REVISION}' not found for service '${SERVICE}'." >&2
    exit 1
  fi
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

# ── Health check (warning-only) ───────────────────────────────────────────
echo ""
echo "==> Health check"
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
      break
    fi
  done
  if [[ "$HEALTH_OK" != "true" ]]; then
    echo "WARN: health probe did not return 2xx — verify manually before declaring the incident resolved." >&2
  fi
fi

echo ""
echo "=== Revision-pin rollback complete ==="
echo "    Serving: ${TARGET_REVISION} (100%)"
echo ""
echo "Next steps:"
echo "  1. Confirm error rate recovers (Cloud Monitoring / firebase functions:log)."
echo "  2. Fix forward on a branch; redeploy via the normal release path."
echo "  3. If revisions are unusable, fall back to the slow source rollback: scripts/rollback.sh"
