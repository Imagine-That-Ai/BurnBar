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
  WRANGLER_BIN                    Absolute path to the provisioned Wrangler
                                  executable.
  OPENBURNBAR_WRANGLER_VERSION    Exact expected Wrangler semantic version.
  OPENBURNBAR_WRANGLER_SHA256     Exact lowercase SHA-256 of WRANGLER_BIN.

Cloudflare authentication:
  Authenticate Wrangler before running, or provide its documented non-
  interactive environment (for example CLOUDFLARE_API_TOKEN and
  CLOUDFLARE_ACCOUNT_ID). This script never reads or records secret values.

Optional environment:
  OPENBURNBAR_R2_BUCKET           Bucket name. Default: openburnbar-downloads
  OPENBURNBAR_R2_PUBLIC_BASE_URL  HTTPS base URL. Default: downloads.burnbar.ai
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
wrangler_bin="${WRANGLER_BIN:-}"
wrangler_version="${OPENBURNBAR_WRANGLER_VERSION:-}"
wrangler_sha256="${OPENBURNBAR_WRANGLER_SHA256:-}"
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
  publication_receipt \
  wrangler_bin \
  wrangler_version \
  wrangler_sha256; do
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

if [[ "$wrangler_bin" != /* || ! -f "$wrangler_bin" || -L "$wrangler_bin" || ! -x "$wrangler_bin" ]]; then
  fail "WRANGLER_BIN must be an absolute executable real file: $wrangler_bin"
fi
if [[ ! "$wrangler_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  fail "OPENBURNBAR_WRANGLER_VERSION must be an exact semantic version."
fi
if [[ ! "$wrangler_sha256" =~ ^[0-9a-f]{64}$ ]]; then
  fail "OPENBURNBAR_WRANGLER_SHA256 must be a lowercase 64-hex digest."
fi
actual_wrangler_sha256="$(shasum -a 256 "$wrangler_bin" | awk '{print $1}')"
if [[ "$actual_wrangler_sha256" != "$wrangler_sha256" ]]; then
  fail "WRANGLER_BIN SHA-256 does not match OPENBURNBAR_WRANGLER_SHA256."
fi
wrangler=("$wrangler_bin")
wrangler_version_output="$("${wrangler[@]}" --version 2>&1)"
if ! python3 - "$wrangler_version" "$wrangler_version_output" <<'PY'
import re
import sys

expected, output = sys.argv[1:]
cleaned = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", output)
versions = re.findall(
    r"(?<![0-9A-Za-z.])"
    r"([0-9]+\.[0-9]+\.[0-9]+(?:[.-][0-9A-Za-z.-]+)?)"
    r"(?![0-9A-Za-z.])",
    cleaned,
)
raise SystemExit(0 if versions == [expected] else 1)
PY
then
  fail "WRANGLER_BIN version output does not uniquely match OPENBURNBAR_WRANGLER_VERSION."
fi
if ! command -v "$curl_bin" >/dev/null 2>&1; then
  fail "curl command is unavailable: $curl_bin"
fi

support_parent="$(dirname "$publication_receipt")"
support_dir="$(mktemp -d "$support_parent/openburnbar-r2-publication.XXXXXX")"
chmod 700 "$support_dir"
preflight="$support_dir/r2-upload-preflight.json"
public_download_dir="$support_dir/public-downloads"
public_header_dir="$support_dir/public-headers"
discovery_snapshot_dir="$support_dir/discovery-snapshot"
discovery_snapshot_header_dir="$support_dir/discovery-snapshot-headers"
rollback_download_dir="$support_dir/discovery-rollback"
rollback_header_dir="$support_dir/discovery-rollback-headers"
discovery_snapshot="$support_dir/discovery-snapshot.json"
trust_site_config="$support_dir/site.ts"
mkdir -m 700 "$public_download_dir"
mkdir -m 700 "$public_header_dir"
mkdir -m 700 "$discovery_snapshot_dir"
mkdir -m 700 "$discovery_snapshot_header_dir"
mkdir -m 700 "$rollback_download_dir"
mkdir -m 700 "$rollback_header_dir"
discovery_changed=0
discovery_committed=0
rollback_in_progress=0
cleanup() {
  rm -rf "$support_dir"
}

python3 scripts/ci/verify-openburnbar-r2-publication.py preflight \
  --release-receipt "$release_receipt" \
  --downloads-dir "$downloads_dir" \
  --candidate-commit "$candidate_commit" \
  --candidate-tree "$candidate_tree" \
  --bucket "$bucket" \
  --public-base-url "$public_base_url" \
  --output "$preflight"

phase_rows() {
  local phase="$1"

  python3 - "$preflight" "$phase" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as file:
    value = json.load(file)
for artifact in value["artifacts"]:
    if artifact["publicationPhase"] != sys.argv[2]:
        continue
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
}

public_rows() {
  local phase="$1"

  python3 - "$preflight" "$phase" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as file:
    value = json.load(file)
for artifact in value["artifacts"]:
    if artifact["publicationPhase"] != sys.argv[2]:
        continue
    print(f"{artifact['fileName']}\t{artifact['publicUrl']}")
PY
}

download_public_object() {
  local file_name="$1"
  local public_url="$2"
  local destination="$3"
  local header_path="$4"
  local allow_absent="${5:-0}"
  local http_code

  http_code="$(
    "$curl_bin" \
      --location \
      --show-error \
      --silent \
      --retry 3 \
      --connect-timeout 15 \
      --max-time 300 \
      --proto '=https' \
      --tlsv1.2 \
      --dump-header "$header_path" \
      --output "$destination" \
      --write-out '%{http_code}' \
      "$public_url"
  )"
  if [[ "$http_code" == "200" ]]; then
    if [[ ! -s "$destination" ]]; then
      echo "ERROR: downloaded public artifact is empty: $public_url" >&2
      return 1
    fi
  elif [[ "$allow_absent" == "1" && "$http_code" == "404" ]]; then
    rm -f -- "$destination"
  else
    echo "ERROR: public artifact returned HTTP $http_code: $public_url" >&2
    return 1
  fi
  if [[ ! -s "$header_path" ]]; then
    echo "ERROR: public response headers are empty: $public_url" >&2
    return 1
  fi
}

publish_and_verify_phase() {
  local phase="$1"
  local marks_discovery="${2:-0}"
  local file_name
  local content_type
  local cache_control
  local public_url
  local local_path
  local destination
  local header_path
  local uploaded=0

  echo "==> Publishing R2 phase: $phase"
  while IFS=$'\t' read -r file_name content_type cache_control; do
    if [[ -z "$file_name" || -z "$content_type" || -z "$cache_control" ]]; then
      fail "R2 upload preflight emitted a malformed artifact row for $phase."
    fi
    local_path="$downloads_dir/$file_name"
    echo "Uploading exact release artifact $file_name to R2 bucket $bucket"
    if [[ "$marks_discovery" == "1" ]]; then
      discovery_changed=1
    fi
    "${wrangler[@]}" r2 object put "$bucket/$file_name" \
      --remote \
      --file "$local_path" \
      --content-type "$content_type" \
      --cache-control "$cache_control"
    uploaded=$((uploaded + 1))
  done < <(phase_rows "$phase")
  if [[ "$uploaded" -eq 0 ]]; then
    fail "R2 upload preflight emitted no artifacts for required phase $phase."
  fi

  while IFS=$'\t' read -r file_name public_url; do
    if [[ -z "$file_name" || -z "$public_url" ]]; then
      fail "R2 upload preflight emitted a malformed public row for $phase."
    fi
    destination="$public_download_dir/$file_name"
    header_path="$public_header_dir/$file_name.headers"
    echo "Downloading public release artifact for verification: $public_url"
    download_public_object "$file_name" "$public_url" "$destination" "$header_path"
  done < <(public_rows "$phase")

  python3 scripts/ci/verify-openburnbar-r2-publication.py verify-public-phase \
    --preflight "$preflight" \
    --public-download-dir "$public_download_dir" \
    --public-header-dir "$public_header_dir" \
    --phase "$phase"
}

capture_discovery_snapshot() {
  local file_name
  local public_url

  while IFS=$'\t' read -r file_name public_url; do
    download_public_object \
      "$file_name" \
      "$public_url" \
      "$discovery_snapshot_dir/$file_name" \
      "$discovery_snapshot_header_dir/$file_name.headers" \
      1
  done < <(public_rows "discovery-commit-set")

  python3 scripts/ci/verify-openburnbar-r2-publication.py snapshot-discovery \
    --preflight "$preflight" \
    --public-download-dir "$discovery_snapshot_dir" \
    --public-header-dir "$discovery_snapshot_header_dir" \
    --output "$discovery_snapshot"
}

rollback_discovery() {
  local file_name
  local state
  local content_type
  local cache_control
  local public_url
  local rollback_failed=0

  rollback_in_progress=1
  while IFS=$'\t' read -r file_name state content_type cache_control public_url; do
    if [[ "$state" == "present" ]]; then
      if ! "${wrangler[@]}" r2 object put "$bucket/$file_name" \
        --remote \
        --file "$discovery_snapshot_dir/$file_name" \
        --content-type "$content_type" \
        --cache-control "$cache_control"; then
        echo "ERROR: failed to restore discovery object: $file_name" >&2
        rollback_failed=1
      fi
    else
      if ! "${wrangler[@]}" r2 object delete "$bucket/$file_name" --remote; then
        echo "ERROR: failed to delete newly created discovery object: $file_name" >&2
        rollback_failed=1
      fi
    fi
  done < <(
    python3 - "$discovery_snapshot" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as file:
    value = json.load(file)
for item in reversed(value["objects"]):
    print(
        "\t".join(
            (
                item["fileName"],
                item["state"],
                item.get("contentType", ""),
                item.get("cacheControl", ""),
                item["publicUrl"],
            )
        )
    )
PY
  )

  if [[ "$rollback_failed" == "0" ]]; then
    while IFS=$'\t' read -r file_name public_url; do
      if ! download_public_object \
        "$file_name" \
        "$public_url" \
        "$rollback_download_dir/$file_name" \
        "$rollback_header_dir/$file_name.headers" \
        1; then
        echo "ERROR: failed to download rolled-back discovery object: $file_name" >&2
        rollback_failed=1
      fi
    done < <(public_rows "discovery-commit-set")
  fi

  if [[ "$rollback_failed" == "0" ]] \
    && ! python3 scripts/ci/verify-openburnbar-r2-publication.py verify-discovery-rollback \
      --snapshot "$discovery_snapshot" \
      --public-download-dir "$rollback_download_dir" \
      --public-header-dir "$rollback_header_dir"; then
    rollback_failed=1
  fi
  rollback_in_progress=0
  if [[ "$rollback_failed" == "0" ]]; then
    discovery_changed=0
    return 0
  fi
  return 1
}

on_exit() {
  local status=$?
  trap - EXIT
  if [[ "$status" -ne 0 \
    && "$discovery_changed" == "1" \
    && "$discovery_committed" == "0" \
    && "$rollback_in_progress" == "0" ]]; then
    if ! rollback_discovery; then
      echo "ERROR: discovery rollback failed after partial publication." >&2
      status=1
    fi
  fi
  cleanup
  exit "$status"
}
trap on_exit EXIT

# Keep discovery stable until every referenced payload and supporting record is
# publicly readable with the expected bytes and HTTP metadata.
publish_and_verify_phase "immutable-payload"
publish_and_verify_phase "supporting-metadata"

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

# appcast.xml and latest-macos.json are one logical discovery commit set. Any
# later failure restores both objects to the exact pre-publication state.
capture_discovery_snapshot
publish_and_verify_phase "discovery-commit-set" 1

python3 scripts/ci/verify-openburnbar-r2-publication.py receipt \
  --preflight "$preflight" \
  --release-receipt "$release_receipt" \
  --downloads-dir "$downloads_dir" \
  --public-download-dir "$public_download_dir" \
  --public-header-dir "$public_header_dir" \
  --discovery-snapshot "$discovery_snapshot" \
  --platform-trust-verifier "$(
    case "$platform_trust_mode" in
      canonical) printf '%s\n' "scripts/ci/verify-public-macos-download-trust.sh" ;;
      test-override) printf '%s\n' "$public_trust_verifier" ;;
    esac
  )" \
  --platform-trust-mode "$platform_trust_mode" \
  --output "$publication_receipt"

discovery_committed=1

echo "PASS: exact OpenBurnBar macOS release published and verified on Cloudflare R2."
echo "  Candidate commit: $candidate_commit"
echo "  Candidate tree:   $candidate_tree"
echo "  Public base URL:  $public_base_url"
echo "  Receipt:          $publication_receipt"
