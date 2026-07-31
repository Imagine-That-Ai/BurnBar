#!/usr/bin/env bash
set -euo pipefail

apk_path="${1:?usage: run-android-release-startup-smoke.sh <release.apk> [package-name]}"
package_name="${2:-com.openburnbar}"

if [[ ! -s "$apk_path" ]]; then
  echo "Android release APK is missing or empty: $apk_path" >&2
  exit 1
fi
if ! command -v adb >/dev/null 2>&1; then
  echo "adb is required for the Android release startup smoke" >&2
  exit 1
fi

dump_failure_logs() {
  echo "--- Android crash buffer ---" >&2
  adb logcat -d -b crash -v threadtime >&2 || true
  echo "--- Firebase registrar diagnostics ---" >&2
  adb logcat -d -v threadtime \
    | grep -E "Invalid component registrar|Could not instantiate com\\.google\\.firebase|NoSuchMethodException.*Firebase|AndroidRuntime" \
    | tail -n 200 >&2 || true
}

adb logcat -c
adb install -r "$apk_path"

activity="$(
  adb shell cmd package resolve-activity --brief "$package_name" \
    | tr -d '\r' \
    | tail -n 1
)"
if [[ "$activity" != */* ]]; then
  echo "Unable to resolve launcher activity for $package_name: $activity" >&2
  exit 1
fi

if ! adb shell am start -W -n "$activity"; then
  dump_failure_logs
  exit 1
fi

# Give Application.onCreate, Firebase component discovery, and the first
# Compose frame enough time to expose release-only startup failures.
sleep 8

if ! adb shell pidof "$package_name" >/dev/null; then
  echo "Android release process exited during startup: $package_name" >&2
  dump_failure_logs
  exit 1
fi

firebase_registrar_failures="$(
  adb logcat -d -v threadtime \
    | grep -E "Invalid component registrar|Could not instantiate com\\.google\\.firebase|NoSuchMethodException.*Firebase" \
    || true
)"
if [[ -n "$firebase_registrar_failures" ]]; then
  echo "Firebase registrar discovery failed in the minified release app:" >&2
  echo "$firebase_registrar_failures" >&2
  exit 1
fi

if adb logcat -d -b crash -v threadtime | grep -Fq "Process: $package_name"; then
  echo "Android release app emitted a fatal startup crash: $package_name" >&2
  dump_failure_logs
  exit 1
fi

echo "Android release startup smoke passed: package=$package_name activity=$activity"
