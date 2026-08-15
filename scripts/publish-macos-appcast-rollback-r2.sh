#!/usr/bin/env bash
set -euo pipefail
umask 077

cd "$(dirname "$0")/.."

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
Usage: scripts/publish-macos-appcast-rollback-r2.sh

Publishes an audited macOS direct-download rollback to Cloudflare R2.

Environment:
  OPENBURNBAR_R2_BUCKET             R2 bucket name. Default: openburnbar-downloads
  OPENBURNBAR_R2_PUBLIC_BASE_URL    Public download base URL to verify.
  OPENBURNBAR_RELEASE_ASSET_DIR     Exact previous-good release asset directory.
  OPENBURNBAR_RELEASE_RECEIPT       Exact promotion-audit receipt for that directory.
  OPENBURNBAR_RELEASE_VERSION       Exact previous-good release version.
  OPENBURNBAR_RELEASE_TAG           Exact previous-good tag. Default: v<version>
  OPENBURNBAR_RELEASE_COMMIT        Exact previous-good release commit.
  OPENBURNBAR_ROLLBACK_APPCAST      Rolled-back appcast.xml produced by the rollback tool.
  OPENBURNBAR_ROLLBACK_CONFIRM      Must equal publish-appcast-rollback.
  OPENBURNBAR_EXPECTED_LIVE_VERSION Version currently advertised before rollback.
  OPENBURNBAR_EXPECTED_LIVE_COMMIT  Commit currently advertised before rollback.
  OPENBURNBAR_VERIFY_ATTEMPTS       Public verification attempts. Default: 10
  OPENBURNBAR_VERIFY_DELAY_MS       Delay between attempts. Default: 15000
  OPENBURNBAR_VERIFY_REQUEST_TIMEOUT_MS Per-request timeout. Default: 30000
  OPENBURNBAR_R2_CURL_BIN           Optional curl-compatible binary for public reads.
  WRANGLER_BIN                      Optional Wrangler binary path.
EOF
  exit 0
fi

bucket="${OPENBURNBAR_R2_BUCKET:-openburnbar-downloads}"
public_base_url="${OPENBURNBAR_R2_PUBLIC_BASE_URL:-https://downloads.burnbar.ai}"
asset_dir="${OPENBURNBAR_RELEASE_ASSET_DIR:-}"
receipt_path="${OPENBURNBAR_RELEASE_RECEIPT:-}"
release_version="${OPENBURNBAR_RELEASE_VERSION:-}"
release_tag="${OPENBURNBAR_RELEASE_TAG:-v${release_version}}"
release_commit="${OPENBURNBAR_RELEASE_COMMIT:-}"
appcast_path="${OPENBURNBAR_ROLLBACK_APPCAST:-}"
confirmation="${OPENBURNBAR_ROLLBACK_CONFIRM:-}"
expected_live_version="${OPENBURNBAR_EXPECTED_LIVE_VERSION:-}"
expected_live_commit="${OPENBURNBAR_EXPECTED_LIVE_COMMIT:-}"
verify_attempts="${OPENBURNBAR_VERIFY_ATTEMPTS:-10}"
verify_delay_ms="${OPENBURNBAR_VERIFY_DELAY_MS:-15000}"
verify_request_timeout_ms="${OPENBURNBAR_VERIFY_REQUEST_TIMEOUT_MS:-30000}"
curl_bin="${OPENBURNBAR_R2_CURL_BIN:-curl}"

if [[ -z "$asset_dir" || -z "$receipt_path" || -z "$appcast_path" ]]; then
  echo "OPENBURNBAR_RELEASE_ASSET_DIR, OPENBURNBAR_RELEASE_RECEIPT, and OPENBURNBAR_ROLLBACK_APPCAST are required." >&2
  exit 1
fi
if [[ -z "$release_version" || -z "$release_commit" ]]; then
  echo "OPENBURNBAR_RELEASE_VERSION and OPENBURNBAR_RELEASE_COMMIT are required." >&2
  exit 1
fi
if [[ -z "$expected_live_version" || -z "$expected_live_commit" ]]; then
  echo "OPENBURNBAR_EXPECTED_LIVE_VERSION and OPENBURNBAR_EXPECTED_LIVE_COMMIT are required." >&2
  exit 1
fi
if [[ "$confirmation" != "publish-appcast-rollback" ]]; then
  echo "Refusing R2 rollback publication without OPENBURNBAR_ROLLBACK_CONFIRM=publish-appcast-rollback." >&2
  exit 1
fi

support_dir="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-r2-rollback.XXXXXX")"
publication_manifest="$support_dir/publication-manifest.json"
derived_dir="$support_dir/derived"
snapshot_dir="$support_dir/snapshot"
race_check_dir="$support_dir/race-check"
restore_check_dir="$support_dir/restore-check"
mkdir -m 700 "$snapshot_dir" "$race_check_dir" "$restore_check_dir"
mutable_names=("release-metadata.json" "latest-macos.json" "appcast.xml")
mutation_started=false
committed=false
rollback_in_progress=false

# Validate the complete previous-good promotion receipt, immutable DMG, restored
# metadata, and locally rolled-back appcast before resolving Wrangler or making
# the first provider mutation.
node scripts/ci/macos-r2-publication.mjs rollback-preflight \
  --asset-dir "$asset_dir" \
  --receipt "$receipt_path" \
  --appcast "$appcast_path" \
  --derived-dir "$derived_dir" \
  --version "$release_version" \
  --tag "$release_tag" \
  --commit "$release_commit" \
  --public-base-url "$public_base_url" \
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
  wrangler=(npm exec --yes wrangler@latest --)
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
  url="${public_base_url%/}/${name}?openburnbar_rollback_snapshot=$(date +%s%N)"
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
      echo "Public rollback object is empty: $name" >&2
      return 1
    }
    return 0
  fi
  if [[ "$allow_absent" == "true" && "$code" == "404" ]]; then
    rm -f -- "$destination"
    return 2
  fi
  echo "Public rollback object $name returned HTTP $code." >&2
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
  node --input-type=module - \
    "$snapshot_dir/latest-macos.json" \
    "$expected_live_version" \
    "$expected_live_commit" <<'NODE'
import { readFileSync } from "node:fs";

const [path, expectedVersion, expectedCommit] = process.argv.slice(2);
const latest = JSON.parse(readFileSync(path, "utf8"));
if (
  latest.version !== expectedVersion ||
  latest.commit !== expectedCommit
) {
  throw new Error(
    `live rollback compare-and-swap mismatch: expected ${expectedVersion}/${expectedCommit}, observed ${String(latest.version)}/${String(latest.commit)}`,
  );
}
NODE
}

verify_snapshot_unchanged() {
  local name
  local state
  for name in "${mutable_names[@]}"; do
    state="$(<"$snapshot_dir/$name.state")"
    if download_public_object "$name" "$race_check_dir/$name" true; then
      if [[ "$state" != "present" ]] || ! cmp -s "$snapshot_dir/$name" "$race_check_dir/$name"; then
        echo "Live rollback pointer changed after snapshot: $name" >&2
        return 1
      fi
    elif [[ $? -eq 2 ]]; then
      [[ "$state" == "absent" ]] || {
        echo "Live rollback pointer disappeared after snapshot: $name" >&2
        return 1
      }
    else
      return 1
    fi
  done
}

restore_snapshot() {
  local name
  local state
  local content_type
  rollback_in_progress=true
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
  rollback_in_progress=false
  mutation_started=false
}

on_exit() {
  local status=$?
  trap - EXIT
  if [[ "$status" -ne 0 && "$mutation_started" == "true" && "$committed" != "true" && "$rollback_in_progress" != "true" ]]; then
    if ! restore_snapshot; then
      echo "Rollback publication failed and restoring the prior public pointers also failed." >&2
      status=1
    fi
  fi
  rm -rf -- "$support_dir"
  exit "$status"
}
trap on_exit EXIT

upload_group() {
  local group="$1"
  local plan="$support_dir/upload-$group.plan"
  node --input-type=module - "$publication_manifest" "$group" >"$plan" <<'NODE'
import { readFileSync } from "node:fs";

const [manifestPath, group] = process.argv.slice(2);
const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
if (!Array.isArray(manifest.groups?.[group])) {
  throw new Error(`invalid R2 rollback publication group: ${String(group)}`);
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
  while IFS= read -r -d '' path &&
    IFS= read -r -d '' name &&
    IFS= read -r -d '' content_type &&
    IFS= read -r -d '' cache_control; do
    echo "Uploading rollback $group asset $name to R2 bucket $bucket"
    "${wrangler[@]}" r2 object put "$bucket/$name" \
      --remote \
      --file "$path" \
      --content-type "$content_type" \
      --cache-control "$cache_control"
  done <"$plan"
}

# Restore the previous-good release metadata first, then move latest-macos.json,
# and activate the rolled-back Sparkle appcast last.
capture_snapshot
verify_snapshot_unchanged
mutation_started=true
upload_group metadata
upload_group discovery

node scripts/ci/macos-r2-publication.mjs verify-rollback-public \
  --manifest "$publication_manifest" \
  --attempts "$verify_attempts" \
  --delay-ms "$verify_delay_ms" \
  --request-timeout-ms "$verify_request_timeout_ms"

committed=true
echo "Published and exactly verified the OpenBurnBar macOS rollback to v${release_version} at ${release_commit}."
