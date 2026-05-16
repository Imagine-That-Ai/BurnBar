#!/usr/bin/env bash
#
# End-to-end smoke for the Android iroh chat path. Drives the device
# through the full chat dispatch surface that Phase 6 wires up:
#
#   1. Build a fresh debug APK.
#   2. Install it onto the active emulator / connected device.
#   3. Cold-launch BurnBar so `BurnBarApplication.onCreate` runs the
#      iroh transport + media-control coordinator bootstraps.
#   4. Run the relevant instrumented suites that cover the chat path:
#        • `com.openburnbar.ui.hermes.HermesRichBubbleTest`
#        • `com.openburnbar.ui.hermes.HermesToolCardTest`
#        • `com.openburnbar.ui.square.HermesSquareScreenTest`
#        • `com.openburnbar.ui.square.AgentBrandZoneScreenTest`
#
# The instrumented suites verify the rendering pipeline on real ART —
# combined with the JVM relay-transport unit tests they exercise the
# advertise / fetch / ack round-trip end-to-end without needing a paired
# Mac to be live (the JVM tests stand in for the Mac side).
#
# Required:
#   • ANDROID_HOME / ANDROID_SDK_ROOT
#   • Java 21 (JAVA_HOME or Homebrew-shipped openjdk@21)
#   • At least one adb device online (emulator or USB-attached phone)

set -euo pipefail

cd "$(dirname "$0")/../.."
ROOT="$(pwd)"
ANDROID_DIR="${ROOT}/android"

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

echo "▶ E2E: Android iroh chat path"
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

# Pick first online device. The script intentionally never starts an
# emulator — callers should already have one ready, or use
# `scripts/cross-platform/run-android` to launch one.
DEVICE_LINE="$("${ADB}" devices | awk 'NR>1 && /device$/ {print $1; exit}')"
if [[ -z "${DEVICE_LINE}" ]]; then
    echo "❌ No adb device online. Start an emulator first."
    exit 1
fi
echo "  • device=${DEVICE_LINE}"

echo "▶ Installing app + test APKs…"
"${ADB}" -s "${DEVICE_LINE}" install -r "${APK}" >/dev/null
"${ADB}" -s "${DEVICE_LINE}" install -r -t "${TEST_APK}" >/dev/null

echo "▶ Cold-launching BurnBar so app bootstraps the iroh transport…"
"${ADB}" -s "${DEVICE_LINE}" shell am force-stop com.openburnbar || true
"${ADB}" -s "${DEVICE_LINE}" shell am start -n com.openburnbar/.MainActivity
sleep 4

echo "▶ Running instrumented suites for the chat path…"
RUNNER="com.openburnbar.test/androidx.test.runner.AndroidJUnitRunner"
"${ADB}" -s "${DEVICE_LINE}" shell am instrument -w \
    -e class \
"com.openburnbar.ui.hermes.HermesRichBubbleTest,\
com.openburnbar.ui.hermes.HermesToolCardTest,\
com.openburnbar.ui.square.HermesSquareScreenTest,\
com.openburnbar.ui.square.AgentBrandZoneScreenTest,\
com.openburnbar.data.media.AndroidFileTransferServiceTest" \
    "${RUNNER}"

echo "✅ E2E chat path complete."
