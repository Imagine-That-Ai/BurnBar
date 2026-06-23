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

MAC_INFO_PLIST="AgentLens/Resources/OpenBurnBar-Info.plist"
IOS_INFO_PLIST="OpenBurnBarMobile/Info.plist"
MAC_GOOGLE_PLIST="AgentLens/Resources/GoogleService-Info.plist"
IOS_GOOGLE_PLIST="OpenBurnBarMobile/Resources/GoogleService-Info.plist"
PLIST_PATHS="${MAC_INFO_PLIST}:${IOS_INFO_PLIST}:${MAC_GOOGLE_PLIST}:${IOS_GOOGLE_PLIST}"

# Defense-in-depth fallback: keep GoogleService-Info.plist synchronized so any
# code path that reads from there continues to work.
python3 scripts/ci/sentry_dsn.py plist-env OPENBURNBAR_SENTRY_DSN "$PLIST_PATHS"
