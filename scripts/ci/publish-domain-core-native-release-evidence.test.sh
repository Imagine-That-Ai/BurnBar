#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/domain-core-native-publish-test.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
fake_bin="$fixture/bin"
release_assets="$fixture/release-assets"
evidence="$fixture/evidence"
mkdir -p "$fake_bin" "$release_assets" "$evidence"

cat > "$fake_bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "$FAKE_GH_LOG"
if [[ "$1 $2" == "attestation verify" ]]; then
  bundle=""
  while (($#)); do
    [[ "$1" == --bundle ]] && { shift; bundle="$1"; }
    shift || true
  done
  python3 - "$bundle" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    predicate = json.load(handle)
print(json.dumps([{"verificationResult": {"statement": {"predicate": predicate}}}]))
PY
elif [[ "$1" == api ]]; then
  printf '{"tag_name":"v1.2.3","prerelease":false,"draft":true}\n'
elif [[ "$1 $2" == "release view" ]]; then
  python3 - "$FAKE_RELEASE_ASSETS" <<'PY'
import json, os, sys
print(json.dumps({"assets": [{"name": name} for name in sorted(os.listdir(sys.argv[1]))]}))
PY
elif [[ "$1 $2" == "release upload" ]]; then
  cp "$4" "$FAKE_RELEASE_ASSETS/$(basename "$4")"
elif [[ "$1 $2" == "release download" ]]; then
  pattern="" dir=""
  while (($#)); do
    case "$1" in
      --pattern) shift; pattern="$1" ;;
      --dir) shift; dir="$1" ;;
    esac
    shift || true
  done
  mkdir -p "$dir"
  cp "$FAKE_RELEASE_ASSETS/$pattern" "$dir/$pattern"
else
  echo "unexpected fake gh invocation: $*" >&2
  exit 1
fi
SH
chmod +x "$fake_bin/gh"

artifact="$fixture/OpenBurnBar-1.2.3-Android.aab"
printf 'signed aab bytes\n' > "$artifact"
sha="$(shasum -a 256 "$artifact" | awk '{print $1}')"
profile_sha="$(python3 - <<'PY'
import hashlib, json
profile = {
    "artifactAuthority": "signed",
    "distribution": "public",
    "rolloutChannel": None,
    "evidenceEnabled": False,
    "domain": "hermes",
    "mode": "rust",
}
print(hashlib.sha256(json.dumps(profile, sort_keys=True, separators=(",", ":")).encode()).hexdigest())
PY
)"
predicate_name="android-hermes.predicate.json"
bundle_name="OpenBurnBar-1.2.3-Android-hermes-domain-core-attestation.sigstore.json"
cat > "$evidence/$predicate_name" <<EOF
{"schemaVersion":1,"consumer":"android","artifactKind":"android-aab","target":"android-universal","artifact":{"fileName":"$(basename "$artifact")","sha256":"$sha"},"release":{"version":"1.2.3","tag":"v1.2.3","commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","publicProfileSha256":"$profile_sha"}}
EOF
cp "$evidence/$predicate_name" "$evidence/$bundle_name"
cat > "$evidence/android-manifest.json" <<EOF
{"schemaVersion":1,"consumer":"android","artifactKind":"android-aab","target":"android-universal","artifact":{"fileName":"$(basename "$artifact")","sha256":"$sha"},"release":{"version":"1.2.3","tag":"v1.2.3","commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"domains":[{"domain":"hermes","publicProfileSha256":"$profile_sha","predicateFileName":"$predicate_name","bundleFileName":"$bundle_name"}]}
EOF

export FAKE_GH_LOG="$fixture/gh.log"
export FAKE_RELEASE_ASSETS="$release_assets"
PATH="$fake_bin:$PATH" bash "$repo_root/scripts/ci/publish-domain-core-native-release-evidence.sh" \
  android v1.2.3 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$artifact" "$evidence"

bundle_line="$(grep -n "release upload.*$bundle_name" "$FAKE_GH_LOG" | head -1 | cut -d: -f1)"
artifact_line="$(grep -n "release upload.*$(basename "$artifact")" "$FAKE_GH_LOG" | head -1 | cut -d: -f1)"
if [[ -z "$bundle_line" || -z "$artifact_line" || "$bundle_line" -ge "$artifact_line" ]]; then
  echo "attestation bundle was not published before the Android artifact" >&2
  exit 1
fi

# An idempotent rerun verifies existing assets and never uploads or replaces them.
: > "$FAKE_GH_LOG"
PATH="$fake_bin:$PATH" bash "$repo_root/scripts/ci/publish-domain-core-native-release-evidence.sh" \
  android v1.2.3 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$artifact" "$evidence"
if grep -Fq "release upload" "$FAKE_GH_LOG"; then
  echo "idempotent rerun attempted to upload an existing immutable asset" >&2
  exit 1
fi

printf 'different aab bytes\n' > "$artifact"
if PATH="$fake_bin:$PATH" bash "$repo_root/scripts/ci/publish-domain-core-native-release-evidence.sh" \
  android v1.2.3 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$artifact" "$evidence"; then
  echo "mutated Android artifact unexpectedly passed immutable publication" >&2
  exit 1
fi

echo "native release evidence publisher tests passed"
