#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

script="scripts/ops/run-firestore-restore-drill.sh"
pass=0
fail=0
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/firestore-drill-test.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT

run_case() {
  local want="$1"
  local label="$2"
  shift 2
  local output="$tmp_root/${label}.out"
  local got
  set +e
  "$@" >"$output" 2>&1
  got=$?
  set -e
  if [[ "$got" == "$want" ]]; then
    pass=$((pass + 1))
    printf '  ok   (exit %s) %s\n' "$got" "$label"
  else
    fail=$((fail + 1))
    printf '  FAIL (exit %s, want %s) %s\n' "$got" "$want" "$label" >&2
    cat "$output" >&2
  fi
}

echo "run-firestore-restore-drill timeout validation self-test"

run_case 0 valid-default-timeouts \
  env FIRESTORE_DRILL_VALIDATE_TIMEOUTS_ONLY=1 bash "$script"

run_case 0 valid-custom-timeouts \
  env FIRESTORE_DRILL_VALIDATE_TIMEOUTS_ONLY=1 \
    FIRESTORE_DRILL_CLEANUP_TIMEOUT_SECONDS=120 \
    FIRESTORE_DRILL_WAIT_TIMEOUT_SECONDS=3600 \
    FIRESTORE_DRILL_WAIT_POLL_SECONDS=5 \
    bash "$script"

run_case 64 arithmetic-expression-timeout-fails \
  env FIRESTORE_DRILL_VALIDATE_TIMEOUTS_ONLY=1 \
    FIRESTORE_DRILL_WAIT_TIMEOUT_SECONDS='1+1' \
    bash "$script"

run_case 64 zero-poll-timeout-fails \
  env FIRESTORE_DRILL_VALIDATE_TIMEOUTS_ONLY=1 \
    FIRESTORE_DRILL_WAIT_POLL_SECONDS=0 \
    bash "$script"

run_case 64 oversized-cleanup-timeout-fails \
  env FIRESTORE_DRILL_VALIDATE_TIMEOUTS_ONLY=1 \
    FIRESTORE_DRILL_CLEANUP_TIMEOUT_SECONDS=999999 \
    bash "$script"

backup_list='[
  {
    "name": "projects/burnbar/locations/us-central1/backups/wrong-newest",
    "database": "projects/burnbar/databases/staging",
    "state": "READY",
    "snapshotTime": "2026-06-17T20:00:00Z"
  },
  {
    "name": "projects/burnbar/locations/us-central1/backups/default-newest",
    "database": "projects/burnbar/databases/(default)",
    "state": "READY",
    "snapshotTime": "2026-06-17T19:00:00Z"
  },
  {
    "name": "projects/burnbar/locations/us-central1/backups/default-old",
    "database": "projects/burnbar/databases/(default)",
    "state": "READY",
    "snapshotTime": "2026-06-17T18:00:00Z"
  }
]'

run_case 0 backup-selection-filters-source-database \
  env FIRESTORE_DRILL_VALIDATE_BACKUP_SELECTION_ONLY=1 \
    FIRESTORE_DRILL_MODE=backup \
    FIRESTORE_DRILL_BACKUP_LIST_JSON="$backup_list" \
    bash "$script"

run_case 2 explicit-wrong-database-backup-fails \
  env FIRESTORE_DRILL_VALIDATE_BACKUP_SELECTION_ONLY=1 \
    FIRESTORE_DRILL_MODE=backup \
    FIRESTORE_DRILL_BACKUP_NAME="projects/burnbar/locations/us-central1/backups/wrong-newest" \
    FIRESTORE_DRILL_BACKUP_LIST_JSON="$backup_list" \
    bash "$script"

run_case 2 no-source-database-backup-fails \
  env FIRESTORE_DRILL_VALIDATE_BACKUP_SELECTION_ONLY=1 \
    FIRESTORE_DRILL_MODE=backup \
    FIRESTORE_DATABASE_ID=missing \
    FIRESTORE_DRILL_BACKUP_LIST_JSON="$backup_list" \
    bash "$script"

fake_bin="$tmp_root/bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/gcloud" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_GCLOUD_LOG:?}"
case "${FAKE_GCLOUD_MODE:-ga-success}:$*" in
  ga-success:firestore\ operations\ describe*)
    printf '{"name":"operations/test","done":true,"metadata":{"operationState":"SUCCESS"}}\n'
    ;;
  alpha-fallback:firestore\ operations\ describe*)
    exit 2
    ;;
  alpha-fallback:alpha\ firestore\ operations\ describe*)
    printf '{"name":"operations/test","done":true,"metadata":{"operationState":"SUCCESS","progressPercentage":{"completedWork":1,"estimatedWork":1}}}\n'
    ;;
  *)
    echo "unexpected fake gcloud invocation: $*" >&2
    exit 2
    ;;
esac
SH
chmod +x "$fake_bin/gcloud"

operation_evidence="$tmp_root/operation-evidence"
gcloud_log="$tmp_root/gcloud.log"
run_case 0 operation-wait-prefers-ga-describe-and-persists-final-json \
  env PATH="$fake_bin:$PATH" \
    FAKE_GCLOUD_MODE=ga-success \
    FAKE_GCLOUD_LOG="$gcloud_log" \
    FIRESTORE_DRILL_VALIDATE_OPERATION_WAIT_ONLY=1 \
    FIRESTORE_DRILL_WAIT_TIMEOUT_SECONDS=5 \
    FIRESTORE_DRILL_WAIT_POLL_SECONDS=1 \
    FIRESTORE_DRILL_EVIDENCE_DIR="$operation_evidence" \
    FIRESTORE_DRILL_TS=ga \
    bash "$script"
if ! grep -q '"done":true' "$operation_evidence/firestore-restore-drill-ga.operation.json"; then
  fail=$((fail + 1))
  echo "FAIL: operation wait did not persist final GA operation JSON" >&2
fi

operation_evidence="$tmp_root/operation-evidence-alpha"
gcloud_log="$tmp_root/gcloud-alpha.log"
run_case 0 operation-wait-falls-back-to-alpha-describe \
  env PATH="$fake_bin:$PATH" \
    FAKE_GCLOUD_MODE=alpha-fallback \
    FAKE_GCLOUD_LOG="$gcloud_log" \
    FIRESTORE_DRILL_VALIDATE_OPERATION_WAIT_ONLY=1 \
    FIRESTORE_DRILL_WAIT_TIMEOUT_SECONDS=5 \
    FIRESTORE_DRILL_WAIT_POLL_SECONDS=1 \
    FIRESTORE_DRILL_EVIDENCE_DIR="$operation_evidence" \
    FIRESTORE_DRILL_TS=alpha \
    bash "$script"
if ! grep -q '^alpha firestore operations describe' "$gcloud_log"; then
  fail=$((fail + 1))
  echo "FAIL: operation wait did not use alpha fallback after GA describe failure" >&2
fi

if [[ "$fail" -ne 0 ]]; then
  echo "FAIL: ${fail} Firestore restore-drill timeout validation test(s) failed" >&2
  exit 1
fi

echo "PASS: ${pass} Firestore restore-drill validation checks"
