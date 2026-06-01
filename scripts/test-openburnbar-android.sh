#!/usr/bin/env bash
#
# test-openburnbar-android.sh — Run Android JVM unit tests for OpenBurnBar.
#
# Usage:
#   ./scripts/test-openburnbar-android.sh
#
# Environment:
#   JAVA_HOME, ANDROID_HOME, ANDROID_SDK_ROOT — required for Gradle/Android SDK.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
android_dir="$repo_root/android"

if [[ -z "${JAVA_HOME:-}" ]]; then
    for candidate in \
        "$HOME/.homebrew/opt/openjdk@21" \
        "/opt/homebrew/opt/openjdk@21" \
        "/usr/local/opt/openjdk@21"; do
        if [[ -d "$candidate" ]]; then
            export JAVA_HOME="$candidate"
            break
        fi
    done
fi

if [[ -z "${ANDROID_HOME:-}" ]]; then
    export ANDROID_HOME="${HOME}/Library/Android"
fi
export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$ANDROID_HOME}"

cd "$android_dir"

./gradlew \
    :openburnbar-iroh-relay:testDebugUnitTest \
    :app:testDebugUnitTest \
    -Pkotlin.compiler.execution.strategy=in-process \
    -Pkotlin.incremental=false \
    --no-daemon \
    --stacktrace
