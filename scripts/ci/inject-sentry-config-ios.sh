#!/usr/bin/env bash
# Injects the iOS/macOS Sentry DSN into the app Info.plist files.
#
# The Sentry DSN is an ingest endpoint (not a secret in the traditional sense,
# but kept out of git to allow rotating it without a code change).
#
# Usage:
#   Called by CI before building the iOS or macOS app:
#     OPENBURNBAR_SENTRY_DSN=${{ secrets.OPENBURNBAR_SENTRY_DSN }} \
#     bash scripts/ci/inject-sentry-config-ios.sh
#
# What this does:
#   Writes the DSN to the primary Info.plist sources so the app and the
#   OpenBurnBarDaemon both pick it up at runtime:
#     - AgentLens/Resources/OpenBurnBar-Info.plist (macOS)
#     - OpenBurnBarMobile/Info.plist (iOS)
#   Also backfills GoogleService-Info.plist as a defense-in-depth fallback for
#   any code path that still reads from there.
#
# When OPENBURNBAR_SENTRY_DSN is absent or empty, Sentry remains disabled
# (no-op) for OSS/fork builds.
set -euo pipefail
cd "$(dirname "$0")/../.."

DSN="${OPENBURNBAR_SENTRY_DSN:-}"

if [[ -z "$DSN" ]]; then
    echo "::notice::OPENBURNBAR_SENTRY_DSN not set — iOS/macOS Sentry will be disabled in this build."
    exit 0
fi

# Validate it looks like a Sentry DSN.
if [[ "$DSN" != https://* ]]; then
    echo "::error::OPENBURNBAR_SENTRY_DSN does not look like a valid Sentry DSN (expected https://)."
    exit 1
fi

validate_plist() {
    local plist="$1"
    if [[ ! -f "$plist" ]]; then
        return 0
    fi
    if ! plutil -lint "$plist" >/dev/null; then
        echo "::error::Plist syntax validation failed for $plist"
        exit 1
    fi
}

inject_into_plist() {
    local plist="$1"
    if [[ ! -f "$plist" ]]; then
        echo "::warning::Sentry target plist not found: $plist"
        return 0
    fi

    # Reject pre-existing malformed plists before mutating them.
    validate_plist "$plist"

    /usr/libexec/PlistBuddy -c "Delete :sentry.dsn" "$plist" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c "Add :sentry.dsn string $DSN" "$plist"

    # Ensure the mutation did not corrupt the file.
    validate_plist "$plist"

    echo "::notice::Sentry DSN injected into $plist"
}

MAC_INFO_PLIST="AgentLens/Resources/OpenBurnBar-Info.plist"
IOS_INFO_PLIST="OpenBurnBarMobile/Info.plist"
MAC_GOOGLE_PLIST="AgentLens/Resources/GoogleService-Info.plist"
IOS_GOOGLE_PLIST="OpenBurnBarMobile/Resources/GoogleService-Info.plist"

inject_into_plist "$MAC_INFO_PLIST"
inject_into_plist "$IOS_INFO_PLIST"

# Defense-in-depth fallback: keep GoogleService-Info.plist synchronized so any
# code path that reads from there continues to work.
inject_into_plist "$MAC_GOOGLE_PLIST"
inject_into_plist "$IOS_GOOGLE_PLIST"
