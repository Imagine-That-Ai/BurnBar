#!/usr/bin/env bash
# Run a Firestore disaster-recovery drill against a throwaway database.
#
# Default mode uses PITR clone because it exercises the live point-in-time
# recovery path without restoring over production. Set FIRESTORE_DRILL_MODE=backup
# to restore from the newest READY backup instead.
set -euo pipefail

cd "$(dirname "$0")/../.."

PROJECT="${GCLOUD_PROJECT:-${GOOGLE_CLOUD_PROJECT:-burnbar}}"
DATABASE_ID="${FIRESTORE_DATABASE_ID:-(default)}"
MODE="${FIRESTORE_DRILL_MODE:-clone}"
DRILL_TS="${FIRESTORE_DRILL_TS:-$(date -u +%Y%m%d%H%M%S)}"
RESTORE_DATABASE_ID="${FIRESTORE_RESTORE_DATABASE_ID:-dr-drill-${DRILL_TS}}"
EVIDENCE_DIR="${FIRESTORE_DRILL_EVIDENCE_DIR:-launch-evidence}"
CLEANUP="${FIRESTORE_DRILL_CLEANUP:-1}"

positive_integer_env() {
  local name="$1"
  local default_value="$2"
  local max_value="$3"
  local value="${!name:-$default_value}"
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    echo "Invalid ${name}: expected a positive integer number of seconds, got '${value}'." >&2
    exit 64
  fi
  if (( value < 1 || value > max_value )); then
    echo "Invalid ${name}: expected 1..${max_value} seconds, got ${value}." >&2
    exit 64
  fi
  printf '%s\n' "$value"
}

validate_timeout_environment() {
  positive_integer_env FIRESTORE_DRILL_CLEANUP_TIMEOUT_SECONDS 900 86400 >/dev/null
  positive_integer_env FIRESTORE_DRILL_WAIT_TIMEOUT_SECONDS 14400 604800 >/dev/null
  positive_integer_env FIRESTORE_DRILL_WAIT_POLL_SECONDS 30 3600 >/dev/null
}

if [[ "${FIRESTORE_DRILL_VALIDATE_TIMEOUTS_ONLY:-0}" == "1" ]]; then
  validate_timeout_environment
  exit 0
fi

validate_timeout_environment

if [[ ! "$RESTORE_DATABASE_ID" =~ ^dr-drill-[a-z0-9-]+$ ]]; then
  echo "Refusing to operate on non-drill database id: ${RESTORE_DATABASE_ID}" >&2
  exit 64
fi

mkdir -p "$EVIDENCE_DIR"

operation_path="${EVIDENCE_DIR}/firestore-restore-drill-${DRILL_TS}.operation.json"
database_path="${EVIDENCE_DIR}/firestore-restore-drill-${DRILL_TS}.database.json"
indexes_path="${EVIDENCE_DIR}/firestore-restore-drill-${DRILL_TS}.indexes.json"
posture_path="${EVIDENCE_DIR}/firestore-restore-drill-${DRILL_TS}.posture.json"
summary_path="${EVIDENCE_DIR}/firestore-restore-drill-${DRILL_TS}.json"
latest_path="${EVIDENCE_DIR}/latest-firestore-restore-drill.json"

SOURCE_DATABASE_RESOURCE="projects/${PROJECT}/databases/${DATABASE_ID}"
SNAPSHOT_TIME="${FIRESTORE_DRILL_SNAPSHOT_TIME:-}"
BACKUP_NAME="${FIRESTORE_DRILL_BACKUP_NAME:-}"

list_firestore_backups_json() {
  if [[ -n "${FIRESTORE_DRILL_BACKUP_LIST_JSON:-}" ]]; then
    printf '%s\n' "$FIRESTORE_DRILL_BACKUP_LIST_JSON"
    return
  fi
  gcloud firestore backups list \
    --project="$PROJECT" \
    --format=json
}

select_ready_backup_for_source_database() {
  local requested_backup_name="${1:-}"
  local backups_json
  backups_json="$(list_firestore_backups_json)"
  BACKUPS_JSON="$backups_json" \
    SOURCE_DATABASE_RESOURCE="$SOURCE_DATABASE_RESOURCE" \
    REQUESTED_BACKUP_NAME="$requested_backup_name" \
    node - <<'NODE'
const sourceDatabase = process.env.SOURCE_DATABASE_RESOURCE;
const requested = process.env.REQUESTED_BACKUP_NAME || "";
let backups;
try {
  backups = JSON.parse(process.env.BACKUPS_JSON || "");
} catch (error) {
  console.error(`FAIL: invalid Firestore backup list JSON: ${error.message}`);
  process.exit(2);
}
if (!Array.isArray(backups)) {
  console.error("FAIL: Firestore backup list JSON must be an array.");
  process.exit(2);
}
const backupDatabase = (backup) => (typeof backup.database === "string" ? backup.database : "");
const backupName = (backup) => (typeof backup.name === "string" ? backup.name : "");
const readyForSource = (backup) => backup.state === "READY" && backupDatabase(backup) === sourceDatabase;
if (requested) {
  const match = backups.find((backup) => backupName(backup) === requested);
  if (!match) {
    console.error(`FAIL: requested Firestore backup was not found: ${requested}`);
    process.exit(2);
  }
  if (match.state !== "READY") {
    console.error(`FAIL: requested Firestore backup is ${match.state || "UNKNOWN"}, not READY: ${requested}`);
    process.exit(2);
  }
  if (backupDatabase(match) !== sourceDatabase) {
    console.error(
      `FAIL: requested Firestore backup belongs to ${backupDatabase(match) || "<missing database>"}, expected ${sourceDatabase}.`,
    );
    process.exit(2);
  }
  console.log(requested);
  process.exit(0);
}
const candidates = backups
  .filter(readyForSource)
  .sort((a, b) => String(b.snapshotTime || "").localeCompare(String(a.snapshotTime || ""))
    || backupName(b).localeCompare(backupName(a)));
if (candidates.length === 0) {
  console.error(`FAIL: no READY Firestore backup found for ${sourceDatabase}.`);
  process.exit(2);
}
console.log(backupName(candidates[0]));
NODE
}

if [[ "${FIRESTORE_DRILL_VALIDATE_BACKUP_SELECTION_ONLY:-0}" == "1" ]]; then
  select_ready_backup_for_source_database "$BACKUP_NAME" >/dev/null
  exit 0
fi

portable_snapshot_time() {
  date -u -v-5M +%Y-%m-%dT%H:%M:00Z 2>/dev/null || date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:00Z
}

cleanup_drill_database() {
  if [[ "$CLEANUP" != "1" ]]; then
    return
  fi
  if [[ ! "$RESTORE_DATABASE_ID" =~ ^dr-drill- ]]; then
    echo "Refusing cleanup for non-drill database id: ${RESTORE_DATABASE_ID}" >&2
    return 1
  fi
  local cleanup_timeout
  cleanup_timeout="$(positive_integer_env FIRESTORE_DRILL_CLEANUP_TIMEOUT_SECONDS 900 86400)"
  local cleanup_deadline=$(( $(date +%s) + cleanup_timeout ))
  while gcloud firestore databases describe --database="$RESTORE_DATABASE_ID" --project="$PROJECT" >/dev/null 2>&1; do
    gcloud firestore databases update \
      --database="$RESTORE_DATABASE_ID" \
      --project="$PROJECT" \
      --no-delete-protection \
      --quiet >/dev/null 2>&1 || true
    if gcloud firestore databases delete \
      --database="$RESTORE_DATABASE_ID" \
      --project="$PROJECT" \
      --quiet >/dev/null 2>&1; then
      echo "==> deleted drill database ${RESTORE_DATABASE_ID}"
      return
    fi
    if (( $(date +%s) >= cleanup_deadline )); then
      echo "FAIL: timed out cleaning up drill database ${RESTORE_DATABASE_ID}" >&2
      return 1
    fi
    sleep 30
  done
}

wait_firestore_operation() {
  local operation="$1"
  local wait_timeout
  local poll_seconds
  wait_timeout="$(positive_integer_env FIRESTORE_DRILL_WAIT_TIMEOUT_SECONDS 14400 604800)"
  poll_seconds="$(positive_integer_env FIRESTORE_DRILL_WAIT_POLL_SECONDS 30 3600)"
  local deadline=$(( $(date +%s) + wait_timeout ))
  while true; do
    local operation_json
    operation_json="$(gcloud alpha firestore operations describe "$operation" --project="$PROJECT" --format=json)"
    local status
    status="$(
      OPERATION_JSON="$operation_json" python3 - <<'PY'
import json
import os
operation = json.loads(os.environ["OPERATION_JSON"])
done = operation.get("done") is True
error = operation.get("error")
metadata = operation.get("metadata", {})
state = metadata.get("operationState", "UNKNOWN")
progress = metadata.get("progressPercentage", {})
completed = progress.get("completedWork", "?")
estimated = progress.get("estimatedWork", "?")
print(json.dumps({
    "done": done,
    "state": state,
    "completed": completed,
    "estimated": estimated,
    "error": error,
}, separators=(",", ":")))
PY
    )"
    echo "    operation status: ${status}" >&2
    if [[ "$(STATUS="$status" python3 - <<'PY'
import json
import os
print("1" if json.loads(os.environ["STATUS"])["done"] else "0")
PY
)" == "1" ]]; then
      if [[ "$(STATUS="$status" python3 - <<'PY'
import json
import os
print("1" if json.loads(os.environ["STATUS"])["error"] else "0")
PY
)" == "1" ]]; then
        echo "FAIL: Firestore restore operation failed: ${status}" >&2
        return 1
      fi
      return
    fi
    if (( $(date +%s) >= deadline )); then
      echo "FAIL: Firestore restore operation did not finish within ${wait_timeout}s: ${operation}" >&2
      return 1
    fi
    sleep "$poll_seconds"
  done
}

cleanup_completed=false
trap 'if [[ "$cleanup_completed" != "true" ]]; then cleanup_drill_database; fi' EXIT

echo "==> verify production Firestore DR posture"
FIRESTORE_DR_JSON_ONLY=1 \
  GCLOUD_PROJECT="$PROJECT" \
  FIRESTORE_DATABASE_ID="$DATABASE_ID" \
  bash scripts/ops/verify-firestore-disaster-recovery.sh >"$posture_path"

case "$MODE" in
  clone)
    SNAPSHOT_TIME="${SNAPSHOT_TIME:-$(portable_snapshot_time)}"
    echo "==> PITR clone ${SOURCE_DATABASE_RESOURCE} @ ${SNAPSHOT_TIME} -> ${RESTORE_DATABASE_ID}"
    gcloud firestore databases clone \
      --project="$PROJECT" \
      --source-database="$SOURCE_DATABASE_RESOURCE" \
      --destination-database="$RESTORE_DATABASE_ID" \
      --snapshot-time="$SNAPSHOT_TIME" \
      --format=json \
      >"$operation_path"
    ;;
  backup)
    if [[ -z "$BACKUP_NAME" ]]; then
      BACKUP_NAME="$(select_ready_backup_for_source_database)"
    else
      BACKUP_NAME="$(select_ready_backup_for_source_database "$BACKUP_NAME")"
    fi
    echo "==> backup restore ${BACKUP_NAME} -> ${RESTORE_DATABASE_ID}"
    gcloud firestore databases restore \
      --project="$PROJECT" \
      --source-backup="$BACKUP_NAME" \
      --destination-database="$RESTORE_DATABASE_ID" \
      --format=json \
      >"$operation_path"
    ;;
  *)
    echo "Unknown FIRESTORE_DRILL_MODE: ${MODE}; expected clone or backup" >&2
    exit 64
    ;;
esac

RESTORE_OPERATION="$(
  node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).name)' "$operation_path"
)"
echo "==> wait for ${RESTORE_OPERATION}"
wait_firestore_operation "$RESTORE_OPERATION"

echo "==> capture restored database and indexes"
gcloud firestore databases describe --database="$RESTORE_DATABASE_ID" \
  --project="$PROJECT" \
  --format=json \
  >"$database_path"

gcloud firestore indexes composite list \
  --project="$PROJECT" \
  --database="$RESTORE_DATABASE_ID" \
  --format=json \
  >"$indexes_path"

export PROJECT DATABASE_ID RESTORE_DATABASE_ID DRILL_TS SNAPSHOT_TIME BACKUP_NAME MODE
export operation_path database_path indexes_path posture_path
node - <<'NODE' >"$summary_path"
const fs = require("fs");
const env = process.env;
const operation = JSON.parse(fs.readFileSync(env.operation_path, "utf8"));
const database = JSON.parse(fs.readFileSync(env.database_path, "utf8"));
const indexes = JSON.parse(fs.readFileSync(env.indexes_path, "utf8"));
const posture = JSON.parse(fs.readFileSync(env.posture_path, "utf8"));
console.log(JSON.stringify({
  generatedAt: new Date().toISOString(),
  project: env.PROJECT,
  mode: env.MODE,
  sourceDatabase: env.DATABASE_ID,
  restoreDatabase: env.RESTORE_DATABASE_ID,
  snapshotTime: env.SNAPSHOT_TIME || null,
  backupName: env.BACKUP_NAME || null,
  operationName: operation.name,
  operationDone: operation.done === true,
  restoredDatabaseLocation: database.locationId,
  restoredDatabaseType: database.type,
  restoredDeleteProtectionState: database.deleteProtectionState || null,
  compositeIndexCount: Array.isArray(indexes) ? indexes.length : 0,
  sourcePostureOk: posture.ok === true,
  rtoTargetHours: 4,
  rpoTargetHours: 1,
  pitrRetentionWindowHours: 168,
  cleanupRequested: process.env.FIRESTORE_DRILL_CLEANUP !== "0"
}, null, 2));
NODE

cleanup_succeeded=false
if [[ "$CLEANUP" == "1" ]]; then
  cleanup_drill_database
  cleanup_succeeded=true
fi
cleanup_completed=true

export summary_path cleanup_succeeded
node - <<'NODE'
const fs = require("fs");
const summaryPath = process.env.summary_path;
const summary = JSON.parse(fs.readFileSync(summaryPath, "utf8"));
summary.cleanup = {
  requested: summary.cleanupRequested === true,
  databaseDeleted: process.env.cleanup_succeeded === "true",
  completedAt: new Date().toISOString(),
};
fs.writeFileSync(summaryPath, `${JSON.stringify(summary, null, 2)}\n`);
NODE

cp "$summary_path" "$latest_path"
echo "==> wrote ${summary_path}"
cat "$summary_path"
