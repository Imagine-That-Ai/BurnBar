#!/usr/bin/env bash
#
# End-to-end smoke for the Android Mercury 1:1 call path. Drives the
# device through the surfaces Phase 6 wires up:
#
#   1. Build a fresh debug APK.
#   2. Install it onto the active emulator / connected device.
#   3. Cold-launch BurnBar so `BurnBarApplication.onCreate` boots the
#      MediaControlStreamCoordinator and registers the FCM token.
#   4. Run the instrumented call-path suites:
#        • `com.openburnbar.ui.media.CallHUDViewTest`
#        • `com.openburnbar.data.media.MediaControlStreamCoordinatorTest`
#        • `com.openburnbar.services.media.IncomingCallActivityTest`
#        • `com.openburnbar.services.media.MercuryFcmServiceTest`
#   5. Optionally simulate a high-priority FCM data message via `adb`'s
#      `am broadcast` shim so the IncomingCallActivity opens on the
#      lock screen.
#
# Required:
#   • ANDROID_HOME / ANDROID_SDK_ROOT
#   • Java 21 (JAVA_HOME or Homebrew-shipped openjdk@21)
#   • At least one adb device online (emulator or USB-attached phone)
#
# Optional flags:
#   --no-call      Skip the simulated incoming-call broadcast.

set -euo pipefail

cd "$(dirname "$0")/../.."
ROOT="$(pwd)"
ANDROID_DIR="${ROOT}/android"
SIMULATE_CALL=1
for arg in "$@"; do
    case "${arg}" in
        --no-call) SIMULATE_CALL=0 ;;
        *) ;;
    esac
done

resolve_java_home() {
    if [[ -n "${JAVA_HOME:-}" ]] && [[ -x "${JAVA_HOME}/bin/java" ]]; then
        echo "${JAVA_HOME}"
        return
    fi
    for candidate in \
        "/opt/homebrew/opt/openjdk@21" \
        "${HOME}/.homebrew/opt/openjdk@21" \
        "/usr/local/opt/openjdk@21"; do
        if [[ -x "${candidate}/bin/java" ]]; then
            echo "${candidate}"
            return
        fi
    done
    if command -v java >/dev/null 2>&1; then
        local java_bin
        java_bin="$(command -v java)"
        java_bin="$(readlink -f "${java_bin}" 2>/dev/null || python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "${java_bin}")"
        echo "$(dirname "$(dirname "${java_bin}")")"
        return
    fi
    echo ""
}

JAVA_HOME="$(resolve_java_home)"
if [[ -z "${JAVA_HOME}" ]] || [[ ! -x "${JAVA_HOME}/bin/java" ]]; then
    echo "❌ Could not locate a Java 21 runtime. Install: brew install openjdk@21"
    exit 1
fi
export JAVA_HOME
export ANDROID_HOME="${ANDROID_HOME:-${HOME}/Library/Android}"
export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME}}"
ADB="${ANDROID_HOME}/platform-tools/adb"
if [[ ! -x "${ADB}" ]]; then
    echo "❌ adb not found at ${ADB}; ensure Android platform-tools are installed."
    exit 1
fi

echo "▶ E2E: Android Mercury 1:1 call path"
echo "  • JAVA_HOME=${JAVA_HOME}"
echo "  • ANDROID_HOME=${ANDROID_HOME}"

echo "▶ Building debug APK…"
( cd "${ANDROID_DIR}" && ./gradlew :app:assembleDebug :app:assembleDebugAndroidTest --no-daemon --quiet )

APK="${ANDROID_DIR}/app/build/outputs/apk/debug/app-debug.apk"
TEST_APK="${ANDROID_DIR}/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk"
if [[ ! -f "${APK}" ]]; then
    echo "❌ Debug APK missing: ${APK}"
    exit 1
fi
if [[ ! -f "${TEST_APK}" ]]; then
    echo "❌ Instrumented test APK missing: ${TEST_APK}"
    exit 1
fi

DEVICE_LINE="$("${ADB}" devices | awk 'NR>1 && /device$/ {print $1; exit}')"
if [[ -z "${DEVICE_LINE}" ]]; then
    echo "❌ No adb device online. Start an emulator first."
    exit 1
fi
echo "  • device=${DEVICE_LINE}"

echo "▶ Installing app + test APKs…"
"${ADB}" -s "${DEVICE_LINE}" install -r "${APK}" >/dev/null
"${ADB}" -s "${DEVICE_LINE}" install -r -t "${TEST_APK}" >/dev/null

echo "▶ Cold-launching BurnBar so app bootstraps MediaControlStreamCoordinator…"
"${ADB}" -s "${DEVICE_LINE}" shell am force-stop com.openburnbar || true
"${ADB}" -s "${DEVICE_LINE}" shell am start -n com.openburnbar/.MainActivity
sleep 4

echo "▶ Running instrumented call-path suites…"
RUNNER="com.openburnbar.test/androidx.test.runner.AndroidJUnitRunner"
"${ADB}" -s "${DEVICE_LINE}" shell am instrument -w \
    -e class \
"com.openburnbar.ui.media.CallHUDViewTest,\
com.openburnbar.data.media.MediaControlStreamCoordinatorTest,\
com.openburnbar.services.media.IncomingCallActivityTest,\
com.openburnbar.services.media.MercuryFcmServiceTest" \
    "${RUNNER}"

if [[ "${SIMULATE_CALL}" -eq 1 ]]; then
    echo "▶ Simulating an incoming-call intent (no real FCM round-trip)…"
    "${ADB}" -s "${DEVICE_LINE}" shell am start \
        -n com.openburnbar/.services.media.IncomingCallActivity \
        --es connection_id "e2e-conn-id" \
        --es caller_name "BurnBar E2E" \
        --es caller_initial "B"
    sleep 2
    # Decline the call so we don't leave a foreground service running.
    "${ADB}" -s "${DEVICE_LINE}" shell am start \
        -n com.openburnbar/.services.media.IncomingCallActivity \
        -a "com.openburnbar.media.DECLINE" \
        --es connection_id "e2e-conn-id"
fi

echo "✅ E2E call path complete."
