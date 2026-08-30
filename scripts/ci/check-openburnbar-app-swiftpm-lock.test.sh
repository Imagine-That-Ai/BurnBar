#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
script_under_test="$repo_root/scripts/check-openburnbar-app-swiftpm-lock.sh"
fixture_root="$(mktemp -d)"

cleanup() {
  rm -rf "$fixture_root"
}

trap cleanup EXIT

write_lockfile() {
  local path="$1"
  local google_sign_in_version="${2:-9.2.0}"
  local gtm_app_auth_version="${3:-5.0.0}"
  cat >"$path" <<EOF
{
  "pins": [
    {
      "identity": "googlesignin-ios",
      "state": {
        "version": "${google_sign_in_version}"
      }
    },
    {
      "identity": "gtmappauth",
      "state": {
        "version": "${gtm_app_auth_version}"
      }
    }
  ],
  "version": 3
}
EOF
}

# Resolver drift must remain valid JSON above the Keychain-safe floor. After the
# floor parser moved under acquire_lock, a later waiter reads whatever the
# previous holder left behind.
write_drifted_lockfile() {
  write_lockfile "$1" "9.9.9" "5.9.9"
}

make_fixture() {
  local name="$1"
  local root="$fixture_root/$name"
  mkdir -p \
    "$root/scripts" \
    "$root/OpenBurnBar.xcodeproj/project.xcworkspace/xcshareddata/swiftpm" \
    "$root/fake-bin"
  cp "$script_under_test" "$root/scripts/check-openburnbar-app-swiftpm-lock.sh"
  write_lockfile \
    "$root/OpenBurnBar.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
  git -C "$root" init -q
  git -C "$root" add OpenBurnBar.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
  git -C "$root" \
    -c user.name="OpenBurnBar CI" \
    -c user.email="ci@openburnbar.invalid" \
    commit -qm "fixture"
  cat >"$root/fake-bin/xcodebuild" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${FIREBASE_SOURCE_FIRESTORE:-}" != "1" ]]; then
  echo "lockfile verifier did not force the source-built Firestore graph" >&2
  exit 87
fi

attempt=0
if [[ -f "$FAKE_ATTEMPT_FILE" ]]; then
  attempt="$(cat "$FAKE_ATTEMPT_FILE")"
fi
attempt=$((attempt + 1))
printf '%s\n' "$attempt" >"$FAKE_ATTEMPT_FILE"

case "$FAKE_MODE" in
  transient-then-success)
    if (( attempt == 1 )); then
      printf 'partial-crash-lockfile\n' >"$FAKE_LOCKFILE_PATH"
      exit 134
    fi
    cmp -s "$FAKE_EXPECTED_LOCKFILE_PATH" "$FAKE_LOCKFILE_PATH" || exit 86
    ;;
  always-transient)
    printf 'partial-crash-lockfile\n' >"$FAKE_LOCKFILE_PATH"
    exit 134
    ;;
  successful-drift)
    cp "$FAKE_DRIFTED_LOCKFILE_PATH" "$FAKE_LOCKFILE_PATH"
    ;;
  hard-failure)
    printf 'partial-hard-failure-lockfile\n' >"$FAKE_LOCKFILE_PATH"
    exit 42
    ;;
  drift-then-wait-for-peer)
    cp "$FAKE_DRIFTED_LOCKFILE_PATH" "$FAKE_LOCKFILE_PATH"
    touch "$FAKE_DRIFT_WRITTEN_FLAG"
    for _ in $(seq 1 50); do
      if [[ -f "$FAKE_PEER_DONE_FLAG" ]]; then
        break
      fi
      sleep 0.1
    done
    ;;
  success)
    cmp -s "$FAKE_EXPECTED_LOCKFILE_PATH" "$FAKE_LOCKFILE_PATH" || exit 86
    ;;
  partial-then-restore)
    printf '{ "pins": [' >"$FAKE_LOCKFILE_PATH"
    touch "$FAKE_PARTIAL_WRITTEN_FLAG"
    for _ in $(seq 1 50); do
      if [[ -f "$FAKE_WAITER_STARTED_FLAG" ]]; then
        break
      fi
      sleep 0.1
    done
    cp "$FAKE_EXPECTED_LOCKFILE_PATH" "$FAKE_LOCKFILE_PATH"
    ;;
  hard-failure-after-peer-drift)
    for _ in $(seq 1 50); do
      if [[ -f "$FAKE_DRIFT_WRITTEN_FLAG" ]]; then
        break
      fi
      sleep 0.1
    done
    printf 'partial-hard-failure-lockfile\n' >"$FAKE_LOCKFILE_PATH"
    exit 42
    ;;
  *)
    echo "Unknown FAKE_MODE: $FAKE_MODE" >&2
    exit 2
    ;;
esac
EOF
  chmod +x "$root/fake-bin/xcodebuild"
  printf '%s\n' "$root"
}

run_fixture() {
  local root="$1"
  local mode="$2"
  local lockfile="$root/OpenBurnBar.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
  local expected="$root/expected.Package.resolved"
  local attempts="$root/attempts"
  cp "$lockfile" "$expected"
  write_drifted_lockfile "$root/drifted.Package.resolved"
  FIREBASE_SOURCE_FIRESTORE=0 \
    PATH="$root/fake-bin:$PATH" \
    FAKE_MODE="$mode" \
    FAKE_LOCKFILE_PATH="$lockfile" \
    FAKE_EXPECTED_LOCKFILE_PATH="$expected" \
    FAKE_DRIFTED_LOCKFILE_PATH="$root/drifted.Package.resolved" \
    FAKE_ATTEMPT_FILE="$attempts" \
    OPENBURNBAR_LOCK_CHECK_MAX_ATTEMPTS=2 \
    bash "$root/scripts/check-openburnbar-app-swiftpm-lock.sh"
}

transient_root="$(make_fixture transient)"
run_fixture "$transient_root" transient-then-success
test "$(cat "$transient_root/attempts")" = "2"
cmp -s \
  "$transient_root/expected.Package.resolved" \
  "$transient_root/OpenBurnBar.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

exhausted_root="$(make_fixture exhausted)"
set +e
run_fixture "$exhausted_root" always-transient >/dev/null 2>&1
exhausted_status=$?
set -e
if (( exhausted_status != 134 )); then
  echo "Expected exhausted transient retries to return status 134, got ${exhausted_status}" >&2
  exit 1
fi
test "$(cat "$exhausted_root/attempts")" = "2"
cmp -s \
  "$exhausted_root/expected.Package.resolved" \
  "$exhausted_root/OpenBurnBar.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

drift_root="$(make_fixture drift)"
if run_fixture "$drift_root" successful-drift >/dev/null 2>&1; then
  echo "Expected successful resolver drift to fail the lockfile check" >&2
  exit 1
fi

failure_root="$(make_fixture failure)"
set +e
run_fixture "$failure_root" hard-failure >/dev/null 2>&1
failure_status=$?
set -e
if (( failure_status != 42 )); then
  echo "Expected hard resolution failure status 42, got ${failure_status}" >&2
  exit 1
fi
cmp -s \
  "$failure_root/expected.Package.resolved" \
  "$failure_root/OpenBurnBar.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

for floor_case in "googlesignin-ios:8.0.0:5.0.0" "gtmappauth:9.2.0:4.1.1"; do
  IFS=: read -r identity google_sign_in_version gtm_app_auth_version <<<"$floor_case"
  floor_root="$(make_fixture "below-floor-${identity}")"
  floor_lockfile="$floor_root/OpenBurnBar.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
  write_lockfile "$floor_lockfile" "$google_sign_in_version" "$gtm_app_auth_version"
  set +e
  floor_output="$(bash "$floor_root/scripts/check-openburnbar-app-swiftpm-lock.sh" 2>&1)"
  floor_status=$?
  set -e
  if (( floor_status == 0 )); then
    echo "Expected ${identity} below-floor lockfile to fail" >&2
    exit 1
  fi
  if [[ "$floor_output" != *"${identity}"*"below the macOS Keychain-safe minimum"* ]]; then
    echo "Expected ${identity} below-floor failure to name the Keychain-safe minimum" >&2
    exit 1
  fi
done

# Regression: concurrent invocations in the same checkout must serialize on the
# whole-check lock. Without it, the hard-failure invocation restores its clean
# snapshot after the drifting invocation has written legitimate resolver drift
# but before that invocation diffs, so real drift would be masked as exit 0.
concurrent_root="$(make_fixture concurrent)"
concurrent_lockfile="$concurrent_root/OpenBurnBar.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
cp "$concurrent_lockfile" "$concurrent_root/expected.Package.resolved"
write_drifted_lockfile "$concurrent_root/drifted.Package.resolved"
drift_written_flag="$concurrent_root/drift-written"
peer_done_flag="$concurrent_root/peer-done"

PATH="$concurrent_root/fake-bin:$PATH" \
  FAKE_MODE="hard-failure-after-peer-drift" \
  FAKE_LOCKFILE_PATH="$concurrent_lockfile" \
  FAKE_EXPECTED_LOCKFILE_PATH="$concurrent_root/expected.Package.resolved" \
  FAKE_DRIFTED_LOCKFILE_PATH="$concurrent_root/drifted.Package.resolved" \
  FAKE_ATTEMPT_FILE="$concurrent_root/attempts-hard-failure" \
  FAKE_DRIFT_WRITTEN_FLAG="$drift_written_flag" \
  FAKE_PEER_DONE_FLAG="$peer_done_flag" \
  OPENBURNBAR_LOCK_CHECK_MAX_ATTEMPTS=2 \
  bash "$concurrent_root/scripts/check-openburnbar-app-swiftpm-lock.sh" \
  >/dev/null 2>&1 &
hard_failure_pid=$!

PATH="$concurrent_root/fake-bin:$PATH" \
  FAKE_MODE="drift-then-wait-for-peer" \
  FAKE_LOCKFILE_PATH="$concurrent_lockfile" \
  FAKE_EXPECTED_LOCKFILE_PATH="$concurrent_root/expected.Package.resolved" \
  FAKE_DRIFTED_LOCKFILE_PATH="$concurrent_root/drifted.Package.resolved" \
  FAKE_ATTEMPT_FILE="$concurrent_root/attempts-drift" \
  FAKE_DRIFT_WRITTEN_FLAG="$drift_written_flag" \
  FAKE_PEER_DONE_FLAG="$peer_done_flag" \
  OPENBURNBAR_LOCK_CHECK_MAX_ATTEMPTS=2 \
  bash "$concurrent_root/scripts/check-openburnbar-app-swiftpm-lock.sh" \
  >/dev/null 2>&1 &
concurrent_drift_pid=$!

set +e
wait "$hard_failure_pid"
concurrent_hard_failure_status=$?
set -e
if (( concurrent_hard_failure_status != 42 )); then
  echo "Expected concurrent hard resolution failure status 42, got ${concurrent_hard_failure_status}" >&2
  exit 1
fi
touch "$peer_done_flag"
set +e
wait "$concurrent_drift_pid"
concurrent_drift_status=$?
set -e
if (( concurrent_drift_status == 0 )); then
  echo "Expected the concurrent drift check to fail; a hard-failure peer's snapshot restore masked legitimate resolver drift" >&2
  exit 1
fi
cmp -s "$concurrent_root/drifted.Package.resolved" "$concurrent_lockfile"

# Regression: a waiter must queue on the whole-check lock instead of parsing
# Package.resolved while a lock holder is mid-write. A truncated lockfile used
# to raise JSONDecodeError before acquire_lock.
partial_root="$(make_fixture partial-json-race)"
partial_lockfile="$partial_root/OpenBurnBar.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
cp "$partial_lockfile" "$partial_root/expected.Package.resolved"
partial_written_flag="$partial_root/partial-written"
waiter_started_flag="$partial_root/waiter-started"

PATH="$partial_root/fake-bin:$PATH" \
  FAKE_MODE="partial-then-restore" \
  FAKE_LOCKFILE_PATH="$partial_lockfile" \
  FAKE_EXPECTED_LOCKFILE_PATH="$partial_root/expected.Package.resolved" \
  FAKE_ATTEMPT_FILE="$partial_root/attempts-holder" \
  FAKE_PARTIAL_WRITTEN_FLAG="$partial_written_flag" \
  FAKE_WAITER_STARTED_FLAG="$waiter_started_flag" \
  OPENBURNBAR_LOCK_CHECK_MAX_ATTEMPTS=2 \
  OPENBURNBAR_LOCK_CHECK_LOCK_WAIT_SECONDS=10 \
  bash "$partial_root/scripts/check-openburnbar-app-swiftpm-lock.sh" \
  >/dev/null 2>&1 &
partial_holder_pid=$!

for _ in $(seq 1 50); do
  if [[ -f "$partial_written_flag" ]]; then
    break
  fi
  sleep 0.1
done
if [[ ! -f "$partial_written_flag" ]]; then
  echo "Expected the lock holder to truncate Package.resolved before the waiter started" >&2
  kill "$partial_holder_pid" 2>/dev/null || true
  wait "$partial_holder_pid" 2>/dev/null || true
  exit 1
fi

PATH="$partial_root/fake-bin:$PATH" \
  FAKE_MODE="success" \
  FAKE_LOCKFILE_PATH="$partial_lockfile" \
  FAKE_EXPECTED_LOCKFILE_PATH="$partial_root/expected.Package.resolved" \
  FAKE_ATTEMPT_FILE="$partial_root/attempts-waiter" \
  OPENBURNBAR_LOCK_CHECK_MAX_ATTEMPTS=2 \
  OPENBURNBAR_LOCK_CHECK_LOCK_WAIT_SECONDS=10 \
  bash "$partial_root/scripts/check-openburnbar-app-swiftpm-lock.sh" \
  >"$partial_root/waiter.stdout" 2>"$partial_root/waiter.stderr" &
partial_waiter_pid=$!
# Give the waiter time to reach acquire_lock and either queue or crash on the
# truncated JSON before the holder restores a valid lockfile.
sleep 0.6
touch "$waiter_started_flag"

set +e
wait "$partial_holder_pid"
partial_holder_status=$?
wait "$partial_waiter_pid"
partial_waiter_status=$?
set -e
if (( partial_holder_status != 0 )); then
  echo "Expected the partial-lockfile holder to restore and succeed, got ${partial_holder_status}" >&2
  exit 1
fi
if (( partial_waiter_status != 0 )); then
  echo "Expected the waiter to queue on the lock instead of crashing on truncated JSON, got ${partial_waiter_status}" >&2
  cat "$partial_root/waiter.stderr" >&2
  exit 1
fi
if grep -q 'JSONDecodeError' "$partial_root/waiter.stderr"; then
  echo "Waiter parsed a truncated Package.resolved before acquiring the whole-check lock" >&2
  cat "$partial_root/waiter.stderr" >&2
  exit 1
fi
cmp -s "$partial_root/expected.Package.resolved" "$partial_lockfile"

echo "SwiftPM lock retry isolation tests passed."
