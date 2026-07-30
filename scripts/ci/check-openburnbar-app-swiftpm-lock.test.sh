#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
script_under_test="$repo_root/scripts/check-openburnbar-app-swiftpm-lock.sh"
fixture_root="$(mktemp -d)"

cleanup() {
  rm -rf "$fixture_root"
}

trap cleanup EXIT

make_fixture() {
  local name="$1"
  local root="$fixture_root/$name"
  mkdir -p \
    "$root/scripts" \
    "$root/OpenBurnBar.xcodeproj/project.xcworkspace/xcshareddata/swiftpm" \
    "$root/fake-bin"
  cp "$script_under_test" "$root/scripts/check-openburnbar-app-swiftpm-lock.sh"
  printf 'committed-lockfile\n' \
    >"$root/OpenBurnBar.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
  git -C "$root" init -q
  git -C "$root" add OpenBurnBar.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
  git -C "$root" \
    -c user.name="OpenBurnBar CI" \
    -c user.email="ci@openburnbar.invalid" \
    commit -qm "fixture"
  cat >"$root/fake-bin/xcodebuild" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

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
    printf 'legitimate-resolver-drift\n' >"$FAKE_LOCKFILE_PATH"
    ;;
  hard-failure)
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
  printf 'committed-lockfile\n' >"$expected"
  PATH="$root/fake-bin:$PATH" \
    FAKE_MODE="$mode" \
    FAKE_LOCKFILE_PATH="$lockfile" \
    FAKE_EXPECTED_LOCKFILE_PATH="$expected" \
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

echo "SwiftPM lock retry isolation tests passed."
