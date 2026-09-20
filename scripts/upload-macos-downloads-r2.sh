#!/usr/bin/env bash
set -euo pipefail
umask 077

cd "$(dirname "$0")/.."

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
Usage: scripts/upload-macos-downloads-r2.sh

Uploads the current macOS direct-download release artifacts to Cloudflare R2.

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
EOF
  exit 0
fi

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
  wrangler=(npm exec --yes wrangler@latest --)
fi
# `wrangler r2 object put` refuses anything over 300 MiB -- it uploads in a
# single request and never starts a multipart upload. The macOS DMG is ~449 MiB,
# so the immutable group cannot go through wrangler at all; v1.0.40+repair.33
# was the first release to reach this step and it failed here. Cloudflare's own
# guidance is to use an S3-compatible client for objects this size.
#
# R2's S3 endpoint takes R2 API tokens, which are NOT the CLOUDFLARE_API_TOKEN
# wrangler uses, so the credentials are separate on purpose. Everything else
# here stays on wrangler: the mutable pointers are a few KiB and their ordering
# and rollback behaviour is what the surrounding logic is built around.
r2_single_request_limit=$((300 * 1024 * 1024))
r2_s3_endpoint=""
if [[ -n "${R2_ACCESS_KEY_ID:-}" && -n "${R2_SECRET_ACCESS_KEY:-}" ]]; then
  if [[ -z "${CLOUDFLARE_ACCOUNT_ID:-}" ]]; then
    echo "R2 S3 credentials are set but CLOUDFLARE_ACCOUNT_ID is missing" >&2
    exit 1
  fi
  r2_s3_endpoint="https://${CLOUDFLARE_ACCOUNT_ID}.r2.cloudflarestorage.com"
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

object_size() {
  # BSD stat on the macOS runner, GNU stat elsewhere.
  stat -f%z "$1" 2>/dev/null || stat -c%s "$1"
}

put_object() {
  local path="$1"
  local name="$2"
  local content_type="$3"
  local cache_control="$4"
  local size
  size="$(object_size "$path")"

  if ((size <= r2_single_request_limit)); then
    "${wrangler[@]}" r2 object put "$bucket/$name" \
      --remote \
      --file "$path" \
      --content-type "$content_type" \
      --cache-control "$cache_control"
    return
  fi

  if [[ -z "$r2_s3_endpoint" ]]; then
    echo "$name is $((size / 1024 / 1024)) MiB, above the ${r2_single_request_limit}-byte single-request limit." >&2
    echo "Set R2_ACCESS_KEY_ID and R2_SECRET_ACCESS_KEY (an R2 API token with Object Read & Write on $bucket) so it can be uploaded multipart." >&2
    return 1
  fi

  if ! command -v aws >/dev/null 2>&1; then
    echo "aws is required to upload $name multipart but is not installed" >&2
    return 1
  fi

  # The AWS CLI splits this into a multipart upload on its own and retries each
  # part, which is what makes a ~449 MiB object survive a flaky leg.
  AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" \
  AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
  AWS_DEFAULT_REGION=auto \
    aws s3 cp "$path" "s3://$bucket/$name" \
      --endpoint-url "$r2_s3_endpoint" \
      --content-type "$content_type" \
      --cache-control "$cache_control" \
      --only-show-errors
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
    put_object "$path" "$name" "$content_type" "$cache_control"
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
