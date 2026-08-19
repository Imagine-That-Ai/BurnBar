#!/usr/bin/env bash
# Fail fast, with a human diagnosis, when a provisioning profile demands a
# certificate whose private key is not present in the login keychain.
#
# August 2026: the app profile authorized only a 2031 Developer ID certificate
# whose private key existed nowhere -- not this Mac, not the vault, not CI.
# Local packaging failed at the very last signing step with an inscrutable
# "no identity found" after a 30-minute build. This preflight turns that into
# a 5-second, named failure before any compilation starts.
#
# Usage: check-signing-identity-coherence.sh <profile.provisionprofile>...
#        (no args: checks every *.provisionprofile under build/)
set -euo pipefail

profiles=("$@")
if [[ ${#profiles[@]} -eq 0 ]]; then
  while IFS= read -r -d '' p; do profiles+=("$p"); done \
    < <(find build -name '*.provisionprofile' -print0 2>/dev/null)
fi
if [[ ${#profiles[@]} -eq 0 ]]; then
  echo "check-signing-identity-coherence: no provisioning profiles found under build/" >&2
  exit 1
fi

# SHA-256 fingerprints of certificates whose PRIVATE KEY is usable here.
signable="$(
  security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*[0-9]) \([0-9A-F]\{40\}\) .*/\1/p' \
    | while IFS= read -r sha1; do
        security find-certificate -a -Z /Library/Keychains/System.keychain ~/Library/Keychains/login.keychain-db 2>/dev/null \
          | awk -v want="$sha1" '
              /^SHA-256 hash:/ { s256=$3 }
              /^SHA-1 hash:/   { if ($3==want) print s256 }'
      done | sort -u
)"

failed=0
for profile in "${profiles[@]}"; do
  plist="$(mktemp)"
  security cms -D -i "$profile" > "$plist" 2>/dev/null || {
    echo "FAIL: cannot decode $profile" >&2; failed=1; rm -f "$plist"; continue; }
  name="$(/usr/libexec/PlistBuddy -c 'Print :Name' "$plist" 2>/dev/null || echo '?')"
  appid="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$plist" 2>/dev/null || echo '?')"
  ok=0
  allowed="$(python3 - "$plist" <<'PY'
import plistlib, hashlib, sys
d = plistlib.load(open(sys.argv[1], 'rb'))
for c in d.get('DeveloperCertificates', []):
    print(hashlib.sha256(c).hexdigest().upper())
PY
)"
  while IFS= read -r fp; do
    [[ -n "$fp" ]] && grep -qx "$fp" <<<"$signable" && ok=1
  done <<<"$allowed"
  if [[ "$ok" -eq 1 ]]; then
    echo "OK:   $name ($appid) is signable with a key in this keychain"
  else
    failed=1
    echo "FAIL: $name ($appid)" >&2
    echo "      profile authorizes cert(s): $(tr '\n' ' ' <<<"$allowed")" >&2
    echo "      but no private key for any of them exists in this keychain." >&2
    echo "      Signable Developer ID certs here: ${signable:-none}" >&2
    echo "      Fix: regenerate the profile in the Apple portal selecting a" >&2
    echo "      certificate whose key you hold, or import the matching .p12." >&2
    echo "      See docs/CI_RELEASE_RUNBOOK.md section 10." >&2
  fi
  rm -f "$plist"
done
exit "$failed"
