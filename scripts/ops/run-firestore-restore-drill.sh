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

portable_snapshot_time() {
  date -u -v-5M +%Y-%m-%dT%H:%M:00Z 2>/dev/null || date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:00Z
}

cleanup_drill_database() {
  if [[ "$CLEANUP" != "1" ]]; then
    return
  fi
  if [[ ! "$RESTORE_DATABASE_ID" =~ ^dr-drill- ]]; then
    echo "Refusing cleanup for non-drill database id: ${RESTORE_DATABASE_ID}" >&2
    return
  fi
  if gcloud firestore databases describe --database="$RESTORE_DATABASE_ID" --project="$PROJECT" >/dev/null 2>&1; then
    gcloud firestore databases update \
      --database="$RESTORE_DATABASE_ID" \
      --project="$PROJECT" \
      --no-delete-protection \
      --quiet >/dev/null 2>&1 || true
    gcloud firestore databases delete \
      --database="$RESTORE_DATABASE_ID" \
      --project="$PROJECT" \
      --quiet >/dev/null 2>&1 || true
  fi
}

wait_firestore_operation() {
  local operation="$1"
  if gcloud firestore operations wait --help >/dev/null 2>&1; then
    gcloud firestore operations wait "$operation" --project="$PROJECT"
  else
    gcloud alpha firestore operations wait "$operation" --project="$PROJECT"
  fi
}

trap cleanup_drill_database EXIT

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
      BACKUP_NAME="$(
        gcloud firestore backups list \
          --project="$PROJECT" \
          --format=json |
          node -e 'const fs=require("fs"); const backups=JSON.parse(fs.readFileSync(0,"utf8")).filter((b)=>b.state==="READY").sort((a,b)=>String(b.snapshotTime).localeCompare(String(a.snapshotTime))); if (!backups.length) process.exit(2); console.log(backups[0].name);'
      )"
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

cp "$summary_path" "$latest_path"
echo "==> wrote ${summary_path}"
cat "$summary_path"
