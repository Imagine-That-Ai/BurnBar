#!/bin/sh
# Stamps a stable Firebase App Check debug token into the local
# GoogleService-Info.plist files used by AgentLens (macOS) and
# OpenBurnBarMobile (iOS). Generates a new UUID on first run and
# persists it in ~/.openburnbar/qa.env so subsequent runs reuse it.
#
# This token must also be registered in the Firebase console
# (App Check → "Manage debug tokens") before it will be accepted by
# the App Check service. Adding the token to the plist alone is not
# enough — the console list is the source of truth for what App Check
# accepts during local QA.
#
# Usage:
#   tools/qa/inject-app-check-debug-token.sh
#   tools/qa/inject-app-check-debug-token.sh --rotate

set -eu

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
qa_dir="$HOME/.openburnbar"
qa_env="$qa_dir/qa.env"

mkdir -p "$qa_dir"
chmod 700 "$qa_dir"
touch "$qa_env"
chmod 600 "$qa_env"

rotate=0
case "${1:-}" in
  --rotate) rotate=1 ;;
  -h|--help)
    sed -n '1,/^set -eu$/p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

token=""
if [ "$rotate" -eq 0 ]; then
    token=$(grep '^FIREBASE_APP_CHECK_DEBUG_TOKEN=' "$qa_env" 2>/dev/null | sed -E "s/^FIREBASE_APP_CHECK_DEBUG_TOKEN=//;s/^'(.*)'$/\1/" || true)
fi

if [ -z "$token" ]; then
    token=$(uuidgen)
    # Remove any previous token line then append a fresh one.
    if [ -s "$qa_env" ]; then
        tmp=$(mktemp)
        grep -v '^FIREBASE_APP_CHECK_DEBUG_TOKEN=' "$qa_env" > "$tmp" || true
        mv "$tmp" "$qa_env"
    fi
    printf "FIREBASE_APP_CHECK_DEBUG_TOKEN='%s'\n" "$token" >> "$qa_env"
    chmod 600 "$qa_env"
fi

for plist in \
    "$repo_root/AgentLens/Resources/GoogleService-Info.plist" \
    "$repo_root/OpenBurnBarMobile/Resources/GoogleService-Info.plist"; do
    if [ ! -f "$plist" ]; then
        echo "[warn] missing $plist — skipping" >&2
        continue
    fi
    /usr/libexec/PlistBuddy -c "Delete :FirebaseAppCheckDebugToken" "$plist" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c "Add :FirebaseAppCheckDebugToken string $token" "$plist"
    echo "[ok] stamped App Check debug token into $plist"
done

echo "[ok] App Check debug token persisted in $qa_env (chmod 0600)"
echo
echo "Next step: register this token in the Firebase console under"
echo "  App Check → Apps → com.openburnbar.app → Manage debug tokens"
echo "If this is a new token, App Check requests will be rejected until it is registered."
