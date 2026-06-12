#!/usr/bin/env bash
# Verifies production Firestore disaster-recovery posture from the live Admin API.
set -euo pipefail
cd "$(dirname "$0")/../.."

PROJECT="${GCLOUD_PROJECT:-${GOOGLE_CLOUD_PROJECT:-burnbar}}"
DATABASE_ID="${FIRESTORE_DATABASE_ID:-(default)}"
export PROJECT DATABASE_ID

if ! command -v gcloud >/dev/null 2>&1; then
  echo "FAIL: gcloud CLI is required to verify Firestore disaster recovery" >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "FAIL: curl is required to verify Firestore disaster recovery" >&2
  exit 1
fi

TOKEN="$(gcloud auth print-access-token)"
DATABASE_PATH="$(python3 - <<'PY'
import os, urllib.parse
project = os.environ["PROJECT"]
database = os.environ["DATABASE_ID"]
print(f"projects/{urllib.parse.quote(project, safe='')}/databases/{urllib.parse.quote(database, safe='')}")
PY
)"
BASE_URL="https://firestore.googleapis.com/v1/${DATABASE_PATH}"

DB_JSON="$(curl -fsS -H "Authorization: Bearer ${TOKEN}" "${BASE_URL}")"
SCHEDULES_JSON="$(curl -fsS -H "Authorization: Bearer ${TOKEN}" "${BASE_URL}/backupSchedules")"

export DB_JSON SCHEDULES_JSON PROJECT DATABASE_ID
python3 <<'PY'
import json
import os
import sys

db = json.loads(os.environ["DB_JSON"])
schedules = json.loads(os.environ["SCHEDULES_JSON"])
project = os.environ["PROJECT"]
database = os.environ["DATABASE_ID"]

failures = []

if db.get("pointInTimeRecoveryEnablement") != "POINT_IN_TIME_RECOVERY_ENABLED":
    failures.append("pointInTimeRecoveryEnablement is not POINT_IN_TIME_RECOVERY_ENABLED")

if db.get("deleteProtectionState") != "DELETE_PROTECTION_ENABLED":
    failures.append("deleteProtectionState is not DELETE_PROTECTION_ENABLED")

backup_schedules = schedules.get("backupSchedules", [])
if not backup_schedules:
    failures.append("no Firestore backup schedules configured")

valid_schedule = False
for schedule in backup_schedules:
    retention = schedule.get("retention", "")
    daily = "dailyRecurrence" in schedule
    weekly = "weeklyRecurrence" in schedule
    if retention and (daily or weekly):
        valid_schedule = True
        break
if backup_schedules and not valid_schedule:
    failures.append("backup schedules exist but none have recurrence and retention")

summary = {
    "project": project,
    "database": database,
    "locationId": db.get("locationId"),
    "pointInTimeRecoveryEnablement": db.get("pointInTimeRecoveryEnablement"),
    "deleteProtectionState": db.get("deleteProtectionState"),
    "backupScheduleCount": len(backup_schedules),
    "ok": not failures,
    "failures": failures,
}
print(json.dumps(summary, indent=2))

if failures:
    print("FAIL: Firestore disaster-recovery posture is incomplete", file=sys.stderr)
    for failure in failures:
        print(f" - {failure}", file=sys.stderr)
    sys.exit(1)
PY

echo "PASS: Firestore disaster-recovery posture"
