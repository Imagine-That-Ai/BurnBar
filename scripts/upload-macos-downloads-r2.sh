#!/usr/bin/env bash
set -euo pipefail
umask 077

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$repo_root"
# shellcheck source=scripts/lib/exact-candidate-git.sh
source scripts/lib/exact-candidate-git.sh
openburnbar_configure_exact_candidate_git "$repo_root"

usage() {
  cat <<'EOF'
Usage: scripts/upload-macos-downloads-r2.sh

Uploads one exact, Developer ID-certified macOS direct-download release to
Cloudflare R2, downloads every public object back, verifies byte-for-byte
digest equality, runs the canonical public macOS trust verifier, and emits an
owner-only candidate-bound publication receipt.

Required environment:
  OPENBURNBAR_CANDIDATE_COMMIT    Exact lowercase 40-character candidate SHA.
  OPENBURNBAR_CANDIDATE_TREE      Exact lowercase 40-character candidate tree.
  OPENBURNBAR_DOWNLOADS_DIR       Exact local Developer ID release directory.
  OPENBURNBAR_DIRECT_RELEASE_RECEIPT
                                  developer-id-release-receipt.json from the
                                  exact local release builder.
  OPENBURNBAR_R2_PUBLICATION_RECEIPT
                                  Absolute fresh output JSON path.

Cloudflare authentication:
  Authenticate Wrangler before running, or provide its documented non-
  interactive environment (for example CLOUDFLARE_API_TOKEN and
  CLOUDFLARE_ACCOUNT_ID). This script never reads or records secret values.

Optional environment:
  OPENBURNBAR_R2_BUCKET           Bucket name. Default: openburnbar-downloads
  OPENBURNBAR_R2_PUBLIC_BASE_URL  HTTPS base URL. Default: downloads.burnbar.ai
  WRANGLER_BIN                    Optional Wrangler binary path.
  OPENBURNBAR_R2_CURL_BIN         Test-only curl override.
  OPENBURNBAR_R2_PUBLIC_TRUST_VERIFIER
                                  Test-only public trust-verifier override.
  OPENBURNBAR_R2_ALLOW_TEST_TRUST_VERIFIER=1
                                  Required with the test-only verifier override.
EOF
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
if [[ $# -ne 0 ]]; then
  usage >&2
  fail "This command accepts no positional arguments."
fi

candidate_commit="${OPENBURNBAR_CANDIDATE_COMMIT:-}"
candidate_tree="${OPENBURNBAR_CANDIDATE_TREE:-}"
downloads_dir="${OPENBURNBAR_DOWNLOADS_DIR:-}"
release_receipt="${OPENBURNBAR_DIRECT_RELEASE_RECEIPT:-}"
publication_receipt="${OPENBURNBAR_R2_PUBLICATION_RECEIPT:-}"
bucket="${OPENBURNBAR_R2_BUCKET:-openburnbar-downloads}"
public_base_url="${OPENBURNBAR_R2_PUBLIC_BASE_URL:-https://downloads.burnbar.ai}"
curl_bin="${OPENBURNBAR_R2_CURL_BIN:-curl}"
canonical_trust_verifier="$repo_root/scripts/ci/verify-public-macos-download-trust.sh"
public_trust_verifier="${OPENBURNBAR_R2_PUBLIC_TRUST_VERIFIER:-$canonical_trust_verifier}"
platform_trust_mode="canonical"

for required_name in \
  candidate_commit \
  candidate_tree \
  downloads_dir \
  release_receipt \
  publication_receipt; do
  if [[ -z "${!required_name}" ]]; then
    fail "Required environment is missing: ${required_name}"
  fi
done
if [[ ! "$candidate_commit" =~ ^[0-9a-f]{40}$ ]]; then
  fail "OPENBURNBAR_CANDIDATE_COMMIT must be a full lowercase Git SHA."
fi
if [[ ! "$candidate_tree" =~ ^[0-9a-f]{40}$ ]]; then
  fail "OPENBURNBAR_CANDIDATE_TREE must be a full lowercase Git tree SHA."
fi
if [[ "$downloads_dir" != /* || ! -d "$downloads_dir" || -L "$downloads_dir" ]]; then
  fail "OPENBURNBAR_DOWNLOADS_DIR must be an absolute real directory."
fi
downloads_dir="$(cd "$downloads_dir" && pwd -P)"
if [[ "$release_receipt" != /* || ! -f "$release_receipt" || -L "$release_receipt" ]]; then
  fail "OPENBURNBAR_DIRECT_RELEASE_RECEIPT must be an absolute real file."
fi
release_receipt="$(
  cd "$(dirname "$release_receipt")" \
    && printf '%s/%s\n' "$(pwd -P)" "$(basename "$release_receipt")"
)"
case "$release_receipt" in
  "$downloads_dir"/*) ;;
  *) fail "Developer ID release receipt must be inside OPENBURNBAR_DOWNLOADS_DIR." ;;
esac
if [[ "$publication_receipt" != /* || -e "$publication_receipt" || -L "$publication_receipt" ]]; then
  fail "OPENBURNBAR_R2_PUBLICATION_RECEIPT must be an absolute fresh path."
fi
publication_parent="$(dirname "$publication_receipt")"
if [[ ! -d "$publication_parent" || -L "$publication_parent" ]]; then
  fail "Publication receipt parent must be a real existing directory."
fi
publication_receipt="$(
  cd "$publication_parent" \
    && printf '%s/%s\n' "$(pwd -P)" "$(basename "$publication_receipt")"
)"
if [[ "$public_trust_verifier" != "$canonical_trust_verifier" ]]; then
  if [[ "${OPENBURNBAR_R2_ALLOW_TEST_TRUST_VERIFIER:-0}" != "1" ]]; then
    fail "A public trust-verifier override is allowed only for focused tests."
  fi
  platform_trust_mode="test-override"
fi
if [[ ! -f "$public_trust_verifier" || -L "$public_trust_verifier" ]]; then
  fail "Public trust verifier must be a real file: $public_trust_verifier"
fi

actual_commit="$(openburnbar_candidate_git rev-parse 'HEAD^{commit}')"
actual_tree="$(openburnbar_candidate_git rev-parse 'HEAD^{tree}')"
commit_tree="$(openburnbar_candidate_git rev-parse "$candidate_commit^{tree}")"
if [[ "$actual_commit" != "$candidate_commit" \
  || "$actual_tree" != "$candidate_tree" \
  || "$commit_tree" != "$candidate_tree" ]]; then
  fail "R2 publication candidate does not match the exact checked-out commit/tree."
fi
if [[ -n "$(
  openburnbar_candidate_git status \
    --porcelain=v1 \
    --untracked-files=all \
    --ignore-submodules=none
)" ]]; then
  fail "R2 publication requires a clean exact-candidate checkout."
fi

if [[ -d "$HOME/.homebrew/opt/node@22/bin" ]]; then
  export PATH="$HOME/.homebrew/opt/node@22/bin:$PATH"
fi
if [[ -f "$HOME/.homebrew/etc/ca-certificates/cert.pem" ]]; then
  export SSL_CERT_FILE="${SSL_CERT_FILE:-$HOME/.homebrew/etc/ca-certificates/cert.pem}"
  export NODE_EXTRA_CA_CERTS="${NODE_EXTRA_CA_CERTS:-$SSL_CERT_FILE}"
fi

if [[ -n "${WRANGLER_BIN:-}" ]]; then
  if [[ ! -x "$WRANGLER_BIN" ]]; then
    fail "WRANGLER_BIN is not executable: $WRANGLER_BIN"
  fi
  wrangler=("$WRANGLER_BIN")
elif command -v wrangler >/dev/null 2>&1; then
  wrangler=(wrangler)
else
  wrangler=(npm exec --yes wrangler@latest --)
fi
if ! command -v "$curl_bin" >/dev/null 2>&1; then
  fail "curl command is unavailable: $curl_bin"
fi

support_parent="$(dirname "$publication_receipt")"
support_dir="$(mktemp -d "$support_parent/openburnbar-r2-publication.XXXXXX")"
chmod 700 "$support_dir"
preflight="$support_dir/r2-upload-preflight.json"
public_download_dir="$support_dir/public-downloads"
trust_site_config="$support_dir/site.ts"
mkdir -m 700 "$public_download_dir"
cleanup() {
  rm -rf "$support_dir"
}
trap cleanup EXIT

python3 scripts/ci/verify-openburnbar-r2-publication.py preflight \
  --release-receipt "$release_receipt" \
  --downloads-dir "$downloads_dir" \
  --candidate-commit "$candidate_commit" \
  --candidate-tree "$candidate_tree" \
  --bucket "$bucket" \
  --public-base-url "$public_base_url" \
  --output "$preflight"

while IFS=$'\t' read -r file_name content_type cache_control; do
  if [[ -z "$file_name" || -z "$content_type" || -z "$cache_control" ]]; then
    fail "R2 upload preflight emitted a malformed artifact row."
  fi
  local_path="$downloads_dir/$file_name"
  echo "Uploading exact release artifact $file_name to R2 bucket $bucket"
  "${wrangler[@]}" r2 object put "$bucket/$file_name" \
    --remote \
    --file "$local_path" \
    --content-type "$content_type" \
    --cache-control "$cache_control"
done < <(
  python3 - "$preflight" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as file:
    value = json.load(file)
for artifact in value["artifacts"]:
    print(
        "\t".join(
            (
                artifact["fileName"],
                artifact["contentType"],
                artifact["cacheControl"],
            )
        )
    )
PY
)

while IFS=$'\t' read -r file_name public_url; do
  destination="$public_download_dir/$file_name"
  echo "Downloading public release artifact for digest verification: $public_url"
  "$curl_bin" \
    --fail \
    --location \
    --show-error \
    --silent \
    --retry 3 \
    --connect-timeout 15 \
    --max-time 300 \
    --proto '=https' \
    --tlsv1.2 \
    --output "$destination" \
    "$public_url"
  if [[ ! -s "$destination" ]]; then
    fail "Downloaded public artifact is empty: $public_url"
  fi
done < <(
  python3 - "$preflight" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as file:
    value = json.load(file)
for artifact in value["artifacts"]:
    print(f"{artifact['fileName']}\t{artifact['publicUrl']}")
PY
)

python3 - "$preflight" "$trust_site_config" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as file:
    value = json.load(file)
release = value["release"]
destination = value["destination"]
dmg = next(
    artifact
    for artifact in value["artifacts"]
    if artifact["kind"] == "dmg"
)
site = {
    "macDownloadBaseUrl": destination["publicBaseUrl"],
    "macReleaseFile": dmg["fileName"],
    "macReleaseLatest": release["version"],
}
with open(sys.argv[2], "x", encoding="utf-8") as file:
    file.write("export const SITE = ")
    json.dump(site, file, indent=2, sort_keys=True)
    file.write(" as const;\n")
PY

OPENBURNBAR_EXPECTED_PUBLIC_MACOS_CANDIDATE_COMMIT="$candidate_commit" \
OPENBURNBAR_EXPECTED_PUBLIC_MACOS_CANDIDATE_TREE="$candidate_tree" \
OPENBURNBAR_EXPECTED_PUBLIC_MACOS_RELEASE_RECEIPT="$release_receipt" \
bash "$public_trust_verifier" "$trust_site_config"

python3 scripts/ci/verify-openburnbar-r2-publication.py receipt \
  --preflight "$preflight" \
  --release-receipt "$release_receipt" \
  --downloads-dir "$downloads_dir" \
  --public-download-dir "$public_download_dir" \
  --platform-trust-verifier "$(
    case "$platform_trust_mode" in
      canonical) printf '%s\n' "scripts/ci/verify-public-macos-download-trust.sh" ;;
      test-override) printf '%s\n' "$public_trust_verifier" ;;
    esac
  )" \
  --platform-trust-mode "$platform_trust_mode" \
  --output "$publication_receipt"

echo "PASS: exact OpenBurnBar macOS release published and verified on Cloudflare R2."
echo "  Candidate commit: $candidate_commit"
echo "  Candidate tree:   $candidate_tree"
echo "  Public base URL:  $public_base_url"
echo "  Receipt:          $publication_receipt"
