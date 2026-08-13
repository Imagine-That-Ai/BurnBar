#!/usr/bin/env bash

# Resolve a usable GoogleService-Info.plist for Apple copy phases.
#
# Isolated git worktrees do not receive the gitignored Firebase plist, so a
# development install from a worktree used to ship without cloud auth. That
# leaves the Mac anonymous: no hermes_connections heartbeat, no iroh pairing
# record, and the phone cannot see or message the Mac.
#
# Resolution order:
#   1. The preferred checkout path (first argument, when present)
#   2. OPENBURNBAR_GOOGLE_SERVICE_INFO_PLIST
#   3. ~/.openburnbar/GoogleService-Info.plist — local developer cache only
#
# The home-directory cache is skipped on CI so a laptop leftover cannot leak
# into public release artifacts.

set -euo pipefail

preferred="${1:-}"

is_usable() {
  local path="$1"
  [[ -f "$path" ]] || return 1

  local reversed app_id
  reversed="$(/usr/libexec/PlistBuddy -c "Print :REVERSED_CLIENT_ID" "$path" 2>/dev/null || true)"
  app_id="$(/usr/libexec/PlistBuddy -c "Print :GOOGLE_APP_ID" "$path" 2>/dev/null || true)"

  [[ -n "$reversed" && -n "$app_id" ]] || return 1
  [[ "$reversed" != YOUR_* && "$reversed" != *YOUR_CLIENT_ID* ]] || return 1
  [[ "$app_id" != YOUR_* ]] || return 1
  return 0
}

candidates=()
if [[ -n "$preferred" ]]; then
  candidates+=("$preferred")
fi
if [[ -n "${OPENBURNBAR_GOOGLE_SERVICE_INFO_PLIST:-}" ]]; then
  candidates+=("$OPENBURNBAR_GOOGLE_SERVICE_INFO_PLIST")
fi
if [[ -z "${CI:-}" && -z "${GITHUB_ACTIONS:-}" ]]; then
  candidates+=("${HOME}/.openburnbar/GoogleService-Info.plist")
fi

for path in "${candidates[@]}"; do
  if is_usable "$path"; then
    printf '%s\n' "$path"
    exit 0
  fi
done

exit 1
