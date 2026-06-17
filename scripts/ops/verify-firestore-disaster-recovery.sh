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
import re
import sys

db = json.loads(os.environ["DB_JSON"])
schedules = json.loads(os.environ["SCHEDULES_JSON"])
project = os.environ["PROJECT"]
database = os.environ["DATABASE_ID"]

failures = []
MIN_PITR_SECONDS = 7 * 24 * 60 * 60


def duration_seconds(value):
    if not isinstance(value, str):
        return None
    match = re.fullmatch(r"(\d+)(?:\.(\d{1,9}))?s", value)
    if not match:
        return None
    seconds = int(match.group(1))
    if match.group(2):
        seconds += int(match.group(2).ljust(9, "0")) / 1_000_000_000
    return seconds

if db.get("pointInTimeRecoveryEnablement") != "POINT_IN_TIME_RECOVERY_ENABLED":
    failures.append("pointInTimeRecoveryEnablement is not POINT_IN_TIME_RECOVERY_ENABLED")

if db.get("deleteProtectionState") != "DELETE_PROTECTION_ENABLED":
    failures.append("deleteProtectionState is not DELETE_PROTECTION_ENABLED")

version_retention_period = db.get("versionRetentionPeriod")
retention_window_seconds = duration_seconds(version_retention_period)
if retention_window_seconds is None:
    failures.append("versionRetentionPeriod is missing or unparsable")
elif retention_window_seconds < MIN_PITR_SECONDS:
    failures.append(
        f"versionRetentionPeriod is below 7 days ({retention_window_seconds:g}s)"
    )

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
    "retentionWindow": {
        "versionRetentionPeriod": version_retention_period,
        "earliestVersionTime": db.get("earliestVersionTime"),
        "seconds": retention_window_seconds,
        "minimumSeconds": MIN_PITR_SECONDS,
    },
    "backupScheduleCount": len(backup_schedules),
    "backupSchedules": [
        {
            "name": schedule.get("name"),
            "retention": schedule.get("retention"),
            "recurrence": "daily" if "dailyRecurrence" in schedule else "weekly" if "weeklyRecurrence" in schedule else "unknown",
        }
        for schedule in backup_schedules
    ],
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

if [[ "${FIRESTORE_DR_JSON_ONLY:-0}" != "1" ]]; then
  echo "PASS: Firestore disaster-recovery posture"
fi
