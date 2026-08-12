#!/usr/bin/env bash
set -euo pipefail
umask 077

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$repo_root"

usage() {
  cat <<'EOF'
Usage: scripts/upload-macos-downloads-r2.sh

Publishes macOS direct-download release artifacts to Cloudflare R2 through one
of two mutually exclusive, fully verified lanes:

1) Audited CI handoff lane (default). Consumes the exact asset directory and
   promotion-audit receipt emitted by promote-github-release.mjs audit,
   compare-and-swaps against the operator-declared live release, publishes
   immutable bytes before metadata and discovery, and exactly verifies the
   public bytes. Selected when no exact-candidate environment is present.

   Environment:
     OPENBURNBAR_R2_BUCKET           R2 bucket name. Default: openburnbar-downloads
     OPENBURNBAR_R2_PUBLIC_BASE_URL Public download base URL to verify after upload.
     OPENBURNBAR_RELEASE_ASSET_DIR   Exact asset directory emitted by the audited
                                     GitHub release promotion lane.
     OPENBURNBAR_RELEASE_RECEIPT     Exact promotion-audit receipt for that directory.
     OPENBURNBAR_RELEASE_VERSION     Exact release version. Default: project.yml MARKETING_VERSION
     OPENBURNBAR_RELEASE_TAG         Exact tag. Default: v<release version>
     OPENBURNBAR_RELEASE_COMMIT      Exact release commit. Default: current HEAD
     OPENBURNBAR_EXPECTED_LIVE_VERSION Version currently advertised before publication,
                                       or absent for an empty download host.
     OPENBURNBAR_EXPECTED_LIVE_COMMIT  Commit currently advertised before publication,
                                       or absent for an empty download host.
     OPENBURNBAR_VERIFY_ATTEMPTS     Public verification attempts. Default: 10
     OPENBURNBAR_VERIFY_DELAY_MS     Delay between attempts. Default: 15000
     OPENBURNBAR_VERIFY_REQUEST_TIMEOUT_MS Per-request timeout. Default: 30000
     OPENBURNBAR_R2_CURL_BIN         Optional curl-compatible binary for public reads.
     WRANGLER_BIN                    Optional Wrangler binary path.

2) Exact-candidate operator lane. Uploads one exact, Developer ID-certified
   macOS direct-download release (including the verified Safari appex payload),
   downloads every public object back, verifies byte-for-byte digest equality,
   runs the canonical public macOS trust verifier, and emits an owner-only
   candidate-bound publication receipt. Selected when any of
   OPENBURNBAR_CANDIDATE_COMMIT, OPENBURNBAR_CANDIDATE_TREE, or
   OPENBURNBAR_DOWNLOADS_DIR is set.

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

# ── Exact-candidate operator lane ────────────────────────────────────────────
if [[ -n "${OPENBURNBAR_CANDIDATE_COMMIT:-}${OPENBURNBAR_CANDIDATE_TREE:-}${OPENBURNBAR_DOWNLOADS_DIR:-}" ]]; then
# shellcheck source=scripts/lib/exact-candidate-git.sh
source scripts/lib/exact-candidate-git.sh
openburnbar_configure_exact_candidate_git "$repo_root"

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
exit 0
fi
# ── Audited CI handoff lane (promote-github-release.mjs producer) ────────────

bucket="${OPENBURNBAR_R2_BUCKET:-openburnbar-downloads}"
public_base_url="${OPENBURNBAR_R2_PUBLIC_BASE_URL:-https://downloads.burnbar.ai}"
release_version="${OPENBURNBAR_RELEASE_VERSION:-$(
  grep -E '^[[:space:]]+MARKETING_VERSION:' project.yml \
    | head -1 \
    | sed 's/.*: *//' \
    | tr -d ' "'
)}"
release_tag="${OPENBURNBAR_RELEASE_TAG:-v${release_version}}"
release_commit="${OPENBURNBAR_RELEASE_COMMIT:-$(git rev-parse HEAD)}"
asset_dir="${OPENBURNBAR_RELEASE_ASSET_DIR:-}"
receipt_path="${OPENBURNBAR_RELEASE_RECEIPT:-}"
expected_live_version="${OPENBURNBAR_EXPECTED_LIVE_VERSION:-}"
expected_live_commit="${OPENBURNBAR_EXPECTED_LIVE_COMMIT:-}"
verify_attempts="${OPENBURNBAR_VERIFY_ATTEMPTS:-10}"
verify_delay_ms="${OPENBURNBAR_VERIFY_DELAY_MS:-15000}"
verify_request_timeout_ms="${OPENBURNBAR_VERIFY_REQUEST_TIMEOUT_MS:-30000}"
curl_bin="${OPENBURNBAR_R2_CURL_BIN:-curl}"

if [[ ! "$release_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]]; then
  echo "Invalid OpenBurnBar release version: ${release_version:-<empty>}" >&2
  exit 1
fi
if [[ -z "$asset_dir" || -z "$receipt_path" ]]; then
  echo "OPENBURNBAR_RELEASE_ASSET_DIR and OPENBURNBAR_RELEASE_RECEIPT are required." >&2
  echo "Use the exact asset directory and receipt emitted by promote-github-release.mjs audit." >&2
  exit 1
fi
if [[ -z "$expected_live_version" || -z "$expected_live_commit" ]]; then
  echo "OPENBURNBAR_EXPECTED_LIVE_VERSION and OPENBURNBAR_EXPECTED_LIVE_COMMIT are required." >&2
  exit 1
fi
if [[ "$expected_live_version" == "absent" || "$expected_live_commit" == "absent" ]]; then
  if [[ "$expected_live_version" != "absent" || "$expected_live_commit" != "absent" ]]; then
    echo "The expected live version and commit must both be absent for an empty host." >&2
    exit 1
  fi
elif [[ ! "$expected_live_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ||
  ! "$expected_live_commit" =~ ^[0-9a-f]{40}$ ]]; then
  echo "The expected live version/commit must be canonical release coordinates." >&2
  exit 1
fi

support_dir="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-r2-publication.XXXXXX")"
preflight_manifest="$support_dir/preflight-manifest.json"
publication_manifest="$support_dir/publication-manifest.json"
sealed_dir="$support_dir/sealed"
snapshot_dir="$support_dir/snapshot"
race_check_dir="$support_dir/race-check"
restore_check_dir="$support_dir/restore-check"
mkdir -m 700 "$sealed_dir" "$snapshot_dir" "$race_check_dir" "$restore_check_dir"
mutable_names=("release-metadata.json" "latest-macos.json" "appcast.xml")
mutation_started=false
committed=false
restore_in_progress=false

# The authoritative producer/consumer handoff is the immutable promotion-audit
# receipt plus the exact downloaded GitHub Release asset directory. This
# validates every receipt asset and every macOS cross-binding before Wrangler is
# resolved or the first provider mutation can occur.
node scripts/ci/macos-r2-publication.mjs preflight \
  --asset-dir "$asset_dir" \
  --receipt "$receipt_path" \
  --version "$release_version" \
  --tag "$release_tag" \
  --commit "$release_commit" \
  --public-base-url "$public_base_url" \
  --output "$preflight_manifest"

# Copy every audited input into a private, read-only publication snapshot. The
# provider never reads the operator's mutable handoff directory after this
# point, so a local replacement race cannot substitute unaudited bytes.
node scripts/ci/macos-r2-publication.mjs seal \
  --manifest "$preflight_manifest" \
  --sealed-dir "$sealed_dir" \
  --output "$publication_manifest"

if [[ -d "$HOME/.homebrew/opt/node@22/bin" ]]; then
  export PATH="$HOME/.homebrew/opt/node@22/bin:$PATH"
fi

if [[ -f "$HOME/.homebrew/etc/ca-certificates/cert.pem" ]]; then
  export SSL_CERT_FILE="${SSL_CERT_FILE:-$HOME/.homebrew/etc/ca-certificates/cert.pem}"
  export NODE_EXTRA_CA_CERTS="${NODE_EXTRA_CA_CERTS:-$SSL_CERT_FILE}"
fi

if [[ -n "${WRANGLER_BIN:-}" ]]; then
  wrangler=("$WRANGLER_BIN")
elif command -v wrangler >/dev/null 2>&1; then
  wrangler=(wrangler)
else
  # Never float on the provider's newest publish tooling: when no Wrangler is
  # provisioned, resolve a major-pinned release instead of the moving latest.
  wrangler=(npx --yes wrangler@4 --)
fi
if ! command -v "$curl_bin" >/dev/null 2>&1; then
  echo "curl-compatible command is unavailable: $curl_bin" >&2
  exit 1
fi

download_public_object() {
  local name="$1"
  local destination="$2"
  local allow_absent="${3:-false}"
  local url
  local code
  url="${public_base_url%/}/${name}?openburnbar_publication_snapshot=$(date +%s%N)"
  code="$(
    "$curl_bin" \
      --location \
      --show-error \
      --silent \
      --connect-timeout 10 \
      --max-time 30 \
      --header "cache-control: no-cache, no-store, max-age=0" \
      --header "pragma: no-cache" \
      --output "$destination" \
      --write-out '%{http_code}' \
      "$url"
  )"
  if [[ "$code" == "200" ]]; then
    [[ -s "$destination" ]] || {
      echo "Public release object is empty: $name" >&2
      return 1
    }
    return 0
  fi
  if [[ "$allow_absent" == "true" && "$code" == "404" ]]; then
    rm -f -- "$destination"
    return 2
  fi
  echo "Public release object $name returned HTTP $code." >&2
  return 1
}

capture_snapshot() {
  local name
  for name in "${mutable_names[@]}"; do
    if download_public_object "$name" "$snapshot_dir/$name" true; then
      printf 'present\n' >"$snapshot_dir/$name.state"
    elif [[ $? -eq 2 ]]; then
      printf 'absent\n' >"$snapshot_dir/$name.state"
    else
      return 1
    fi
  done
  if [[ "$expected_live_version" == "absent" ]]; then
    local state
    for name in "${mutable_names[@]}"; do
      state="$(<"$snapshot_dir/$name.state")"
      if [[ "$state" != "absent" ]]; then
        echo "Live release compare-and-swap mismatch: expected an empty host, but $name exists." >&2
        return 1
      fi
    done
    return 0
  fi
  if [[ "$(<"$snapshot_dir/latest-macos.json.state")" != "present" ]]; then
    echo "Live release compare-and-swap mismatch: latest-macos.json is absent." >&2
    return 1
  fi
  node --input-type=module - \
    "$snapshot_dir/latest-macos.json" \
    "$expected_live_version" \
    "$expected_live_commit" \
    "$release_version" \
    "$release_commit" <<'NODE'
import { readFileSync } from "node:fs";

const [
  path,
  expectedVersion,
  expectedCommit,
  candidateVersion,
  candidateCommit,
] =
  process.argv.slice(2);
const latest = JSON.parse(readFileSync(path, "utf8"));
if (
  latest.version !== expectedVersion ||
  latest.commit !== expectedCommit
) {
  throw new Error(
    `live release compare-and-swap mismatch: expected ${expectedVersion}/${expectedCommit}, observed ${String(latest.version)}/${String(latest.commit)}`,
  );
}
if (
  candidateVersion === expectedVersion &&
  candidateCommit === expectedCommit
) {
  process.exit(0);
}
const parts = (version) =>
  version
    .split(/[+-]/u, 1)[0]
    .split(".")
    .map((part) => Number.parseInt(part, 10));
const current = parts(expectedVersion);
const candidate = parts(candidateVersion);
for (let index = 0; index < 3; index += 1) {
  if (candidate[index] > current[index]) process.exit(0);
  if (candidate[index] < current[index]) {
    throw new Error(
      `forward R2 publication cannot downgrade ${expectedVersion} to ${candidateVersion}; use the rollback lane`,
    );
  }
}
throw new Error(
  `forward R2 publication requires a version newer than ${expectedVersion}, or the exact same version and commit for an idempotent retry`,
);
NODE
}

verify_snapshot_unchanged() {
  local name
  local state
  for name in "${mutable_names[@]}"; do
    state="$(<"$snapshot_dir/$name.state")"
    if download_public_object "$name" "$race_check_dir/$name" true; then
      if [[ "$state" != "present" ]] || ! cmp -s "$snapshot_dir/$name" "$race_check_dir/$name"; then
        echo "Live release pointer changed after snapshot: $name" >&2
        return 1
      fi
    elif [[ $? -eq 2 ]]; then
      if [[ "$state" != "absent" ]]; then
        echo "Live release pointer disappeared after snapshot: $name" >&2
        return 1
      fi
    else
      return 1
    fi
  done
}

restore_snapshot() {
  local name
  local state
  local content_type
  restore_in_progress=true
  for ((index=${#mutable_names[@]} - 1; index >= 0; index -= 1)); do
    name="${mutable_names[$index]}"
    state="$(<"$snapshot_dir/$name.state")"
    content_type="application/json; charset=utf-8"
    [[ "$name" == "appcast.xml" ]] && content_type="application/xml; charset=utf-8"
    if [[ "$state" == "present" ]]; then
      "${wrangler[@]}" r2 object put "$bucket/$name" \
        --remote \
        --file "$snapshot_dir/$name" \
        --content-type "$content_type" \
        --cache-control "public, max-age=300" || return 1
    else
      "${wrangler[@]}" r2 object delete "$bucket/$name" --remote || return 1
    fi
  done
  for name in "${mutable_names[@]}"; do
    state="$(<"$snapshot_dir/$name.state")"
    if download_public_object "$name" "$restore_check_dir/$name" true; then
      if [[ "$state" != "present" ]] || ! cmp -s "$snapshot_dir/$name" "$restore_check_dir/$name"; then
        return 1
      fi
    elif [[ $? -eq 2 ]]; then
      [[ "$state" == "absent" ]] || return 1
    else
      return 1
    fi
  done
  restore_in_progress=false
  mutation_started=false
}

on_exit() {
  local status=$?
  trap - EXIT
  if [[ "$status" -ne 0 && "$mutation_started" == "true" && "$committed" != "true" && "$restore_in_progress" != "true" ]]; then
    if ! restore_snapshot; then
      echo "Release publication failed and restoring the prior public pointers also failed." >&2
      status=1
    fi
  fi
  rm -rf -- "$support_dir"
  exit "$status"
}
trap on_exit EXIT

render_upload_plan() {
  local group="$1"
  local plan="$2"
  node --input-type=module - "$publication_manifest" "$group" >"$plan" <<'NODE'
import { readFileSync } from "node:fs";

const [manifestPath, group] = process.argv.slice(2);
const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
if (!Array.isArray(manifest.groups?.[group])) {
  throw new Error(`invalid R2 publication group: ${String(group)}`);
}
for (const entry of manifest.groups[group]) {
  for (const value of [
    entry.path,
    entry.name,
    entry.contentType,
    entry.cacheControl,
  ]) {
    process.stdout.write(`${value}\0`);
  }
}
NODE
}

upload_group() {
  local group="$1"
  local plan="$support_dir/upload-$group.plan"
  render_upload_plan "$group" "$plan"
  while IFS= read -r -d '' path &&
    IFS= read -r -d '' name &&
    IFS= read -r -d '' content_type &&
    IFS= read -r -d '' cache_control; do
    echo "Uploading $group asset $name to R2 bucket $bucket"
    "${wrangler[@]}" r2 object put "$bucket/$name" \
      --remote \
      --file "$path" \
      --content-type "$content_type" \
      --cache-control "$cache_control"
  done <"$plan"
}

# Publication is ordered so immutable versioned bytes become available first,
# descriptive metadata follows, latest-macos.json moves next, and appcast.xml
# activates the release last. Any partial mutable publication is compensated
# with the exact pre-publication public bytes.
capture_snapshot
upload_group immutable
verify_snapshot_unchanged
mutation_started=true
upload_group metadata
upload_group discovery

node scripts/ci/macos-r2-publication.mjs verify-public \
  --manifest "$publication_manifest" \
  --attempts "$verify_attempts" \
  --delay-ms "$verify_delay_ms" \
  --request-timeout-ms "$verify_request_timeout_ms"

committed=true
echo "Uploaded and exactly verified OpenBurnBar macOS release v${release_version} at ${release_commit}."
