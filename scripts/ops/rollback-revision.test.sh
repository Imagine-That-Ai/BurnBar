#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

script="scripts/ops/rollback-revision.sh"
pass=0
fail=0
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/rollback-revision-test.XXXXXX")"
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

echo "rollback-revision fixture/self-test"

revisions_json="$tmp_root/revisions.json"
no_gcloud_bin="$tmp_root/no-gcloud-bin"
mkdir -p "$no_gcloud_bin"
cat >"$revisions_json" <<'JSON'
[
  {
    "metadata": {
      "name": "searchknowledge-00042-new"
    }
  },
  {
    "metadata": {
      "name": "searchknowledge-00041-good"
    }
  }
]
JSON

run_case 0 fixture-file-is-offline-and-does-not-need-gcloud \
  env PATH="/usr/bin:/bin" \
    bash "$script" searchknowledge searchknowledge-00041-good \
    --project burnbar --revisions-json "$revisions_json" --dry-run

run_case 0 fixture-file-never-mutates-even-without-dry-run \
  env PATH="/usr/bin:/bin" \
    bash "$script" searchknowledge searchknowledge-00041-good \
    --project burnbar --revisions-json "$revisions_json"

run_case 1 fixture-cannot-record-live-drill \
  env PATH="/usr/bin:/bin" \
    bash "$script" searchknowledge searchknowledge-00041-good \
    --project burnbar --revisions-json "$revisions_json" \
    --drill --receipt "$tmp_root/fixture-live.json"

fixture_json="$(cat "$revisions_json")"
run_case 0 fixture-env-is-offline-and-does-not-need-gcloud \
  env PATH="/usr/bin:/bin" \
    ROLLBACK_REVISIONS_JSON="$fixture_json" \
    bash "$script" searchknowledge searchknowledge-00041-good \
    --project burnbar --dry-run

run_case 1 missing-gcloud-and-fixture-fails-closed \
  env PATH="$no_gcloud_bin" \
    /bin/bash "$script" searchknowledge --project burnbar

run_case 1 live-drill-without-gcloud-fails-closed \
  env PATH="$no_gcloud_bin" \
    /bin/bash "$script" searchknowledge --project burnbar \
    --drill --receipt "$tmp_root/no-gcloud-live.json"

if [[ "$fail" -ne 0 ]]; then
  echo "FAIL: ${fail} rollback-revision test case(s) failed" >&2
  exit 1
fi

echo "PASS: ${pass} rollback-revision fixture checks"
