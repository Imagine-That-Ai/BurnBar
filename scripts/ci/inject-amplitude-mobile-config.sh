#!/usr/bin/env bash
# Injects the Amplitude ingestion API key into the BUILT iOS Info.plists (app,
# widget, keyboard) after Xcode compiles them, so the opt-in analytics wrapper can
# read `amplitude.apiKey` at runtime. This is the iOS sibling of
# scripts/ci/inject-amplitude-config.sh (which does source substitution for the
# macOS target); the iOS trio reads the key from Info.plist (parallel to the
# Sentry DSN), so we patch the built plists instead of source.
#
# Amplitude client-side keys are write-only ingestion identifiers (like a Sentry
# DSN), not secrets — but we still NEVER commit one. The project ships the
# placeholder build setting BURNBAR_AMPLITUDE_API_KEY="" so a clean checkout
# builds with an empty key and the wrapper stays dark (AnalyticsConfig returns
# nil → the Amplitude client is never constructed).
#
# Two ways to supply a real key in CI:
#   A) Pass it as a build setting to xcodebuild (simplest):
#        xcodebuild ... BURNBAR_AMPLITUDE_API_KEY="$KEY"
#      project.yml already wires that build setting into each target's Info.plist.
#   B) Run this script AFTER the build to patch the produced .app / .appex plists
#      (use when the key isn't available at build-setting evaluation time):
#        BURNBAR_AMPLITUDE_API_KEY="$KEY" \
#        APP_PRODUCTS_DIR="$BUILT_PRODUCTS_DIR" \
#          bash scripts/ci/inject-amplitude-mobile-config.sh
#
# If the env var is unset, every plist is left with its (empty) placeholder and
# analytics stays dark — so unkeyed local/dev builds are safe.
set -euo pipefail

KEY="${BURNBAR_AMPLITUDE_API_KEY:-}"
PRODUCTS_DIR="${APP_PRODUCTS_DIR:-${BUILT_PRODUCTS_DIR:-}}"

if [[ -z "$KEY" ]]; then
  echo "::notice::BURNBAR_AMPLITUDE_API_KEY not set — Amplitude key not baked into iOS plists (analytics stays dark)."
  exit 0
fi

# Reject obviously-wrong values (must look like an Amplitude key, no whitespace).
if [[ "$KEY" =~ [[:space:]] ]] || [[ ${#KEY} -lt 16 ]]; then
  echo "::error::BURNBAR_AMPLITUDE_API_KEY does not look like a valid Amplitude key."
  exit 1
fi

if [[ -z "$PRODUCTS_DIR" || ! -d "$PRODUCTS_DIR" ]]; then
  echo "::error::Set APP_PRODUCTS_DIR (or BUILT_PRODUCTS_DIR) to the built products directory."
  exit 1
fi

patch_plist() {
  local plist="$1"
  [[ -f "$plist" ]] || return 0
  /usr/libexec/PlistBuddy -c "Delete :amplitude.apiKey" "$plist" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :amplitude.apiKey string ${KEY}" "$plist"
  echo "::notice::Amplitude API key injected into ${plist}."
}

# App + both app-extension Info.plists.
patch_plist "${PRODUCTS_DIR}/OpenBurnBarMobile.app/Info.plist"
patch_plist "${PRODUCTS_DIR}/OpenBurnBarMobile.app/PlugIns/OpenBurnBarWidget.appex/Info.plist"
patch_plist "${PRODUCTS_DIR}/OpenBurnBarMobile.app/PlugIns/OpenBurnBarKeyboard.appex/Info.plist"
