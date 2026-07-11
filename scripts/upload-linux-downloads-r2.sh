#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

release_out="${OPENBURNBAR_LINUX_RELEASE_OUT:-$repo_root/.linux-release}"
public_base_url="${OPENBURNBAR_R2_PUBLIC_BASE_URL:-https://downloads.burnbar.ai}"
immutable_upload_url="$public_base_url/linux/repository-upload/immutable"
upload_token="${OPENBURNBAR_LINUX_REPOSITORY_UPLOAD_TOKEN:-}"
unset OPENBURNBAR_LINUX_REPOSITORY_UPLOAD_TOKEN || true
feed="$release_out/latest-linux.draft.json"
signature="$release_out/sidecars/latest-linux.json.ed25519.sig"
verification="$release_out/release-verification.json"
public_key="packaging/linux/openburnbar-linux-ed25519.pub.pem"
repository_root="$release_out/repositories"
repository_closure="$repository_root/repository-closure.json"
repository_closure_signature="$repository_root/repository-closure.json.asc"
repository_lifecycle="$repository_root/repository-lifecycle.json"
version="$(node -e 'const value=require(process.argv[1]); if (!/^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/.test(value.version ?? "")) process.exit(1); process.stdout.write(value.version)' "$feed")"
release_prefix="linux/releases/linux-v$version"

if [[ "$public_base_url" != "https://downloads.burnbar.ai" ]]; then
  echo "OPENBURNBAR_R2_PUBLIC_BASE_URL must be https://downloads.burnbar.ai" >&2
  exit 1
fi
if ! printf '%s' "$upload_token" | node -e \
    'const fs=require("node:fs");process.exit(/^[A-Za-z0-9._~+/=-]{32,4096}$/.test(fs.readFileSync(0,"utf8"))?0:1)'; then
  echo "OPENBURNBAR_LINUX_REPOSITORY_UPLOAD_TOKEN must contain 32 to 4096 characters from the approved token alphabet" >&2
  exit 1
fi

temporary="$(mktemp -d)"
cleanup() {
  rm -rf "$temporary"
}
trap cleanup EXIT
chmod 700 "$temporary"
response_log="$temporary/immutable-upload-responses.jsonl"
: >"$response_log"
chmod 600 "$response_log"
operation_count=0
auth_config="$temporary/curl-auth"
printf 'header = "Authorization: Bearer %s"\n' "$upload_token" >"$auth_config"
chmod 600 "$auth_config"
unset upload_token

for required in \
  "$feed" \
  "$signature" \
  "$verification" \
  "$public_key" \
  "$repository_closure" \
  "$repository_closure_signature" \
  "$repository_lifecycle"; do
  if [[ ! -f "$required" ]]; then
    echo "required Linux release file is missing: $required" >&2
    exit 1
  fi
done

IFS=$'\t' read -r channel snapshot_id source_commit < <(node - "$repository_closure" "$version" <<'NODE'
const crypto = require('node:crypto');
const fs = require('node:fs');
const bytes = fs.readFileSync(process.argv[2]);
const closure = JSON.parse(bytes);
if (!['stable', 'prerelease', 'nightly'].includes(closure.channel)) throw new Error('repository closure channel is invalid');
if (closure.version !== process.argv[3]) throw new Error('repository closure version does not match update feed');
if (!/^[a-f0-9]{40}$/u.test(closure.gitCommit ?? '')) throw new Error('repository closure source commit is invalid');
process.stdout.write(`${closure.channel}\t${crypto.createHash('sha256').update(bytes).digest('hex')}\t${closure.gitCommit}\n`);
NODE
)
snapshot_prefix="linux/repository-snapshots/$channel/$snapshot_id"

node -e '
  const fs = require("node:fs");
  const report = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (report.phase !== "final" || report.passed !== true || report.failures?.length) {
    throw new Error("Linux release verification is not final and green");
  }
' "$verification"

content_type_for() {
  case "$1" in
    *.json) printf '%s\n' 'application/json; charset=utf-8' ;;
    *.repo|*.sources|*/Release|*/InRelease|*/Packages) printf '%s\n' 'text/plain; charset=utf-8' ;;
    *.xml) printf '%s\n' 'application/xml' ;;
    *.gz) printf '%s\n' 'application/gzip' ;;
    *.deb) printf '%s\n' 'application/vnd.debian.binary-package' ;;
    *.rpm) printf '%s\n' 'application/x-rpm' ;;
    *) printf '%s\n' 'application/octet-stream' ;;
  esac
}

put_object() {
  local file="$1"
  local key="$2"
  local size
  local sha256
  local response
  size="$(wc -c <"$file" | tr -d '[:space:]')"
  sha256="$(shasum -a 256 "$file" | awk '{print $1}')"
  operation_count=$((operation_count + 1))
  response="$temporary/immutable-upload-response-$operation_count.json"
  curl --disable --proto '=https' --max-redirs 0 --config "$auth_config" \
    --fail-with-body \
    --silent \
    --show-error \
    --request PUT \
    --header "X-OpenBurnBar-Object-Key: $key" \
    --header "X-OpenBurnBar-Object-Sha256: $sha256" \
    --header "Content-Type: $(content_type_for "$file")" \
    --header "Content-Length: $size" \
    --data-binary "@$file" \
    "$immutable_upload_url" >"$response"
  node - "$response" "$response_log" "$operation_count" "$key" "$sha256" "$size" <<'NODE'
const fs = require('node:fs');
const [responsePath, logPath, sequenceText, expectedKey, expectedSha256, expectedSizeText] = process.argv.slice(2);
const response = JSON.parse(fs.readFileSync(responsePath, 'utf8'));
const expectedSize = Number(expectedSizeText);
if (response.schemaVersion !== 1
    || !['created', 'unchanged', 'verified-legacy'].includes(response.status)
    || response.key !== expectedKey || response.sha256 !== expectedSha256
    || response.size !== expectedSize || typeof response.etag !== 'string' || response.etag.length === 0) {
  throw new Error(`immutable upload response did not bind object ${expectedKey}`);
}
fs.appendFileSync(logPath, `${JSON.stringify({
  sequence: Number(sequenceText),
  status: response.status,
  key: response.key,
  sha256: response.sha256,
  size: response.size,
  etag: response.etag
})}\n`);
NODE
}

declare -a release_artifacts=()
declare -a release_signatures=()
while IFS= read -r -d '' file; do release_artifacts+=("$file"); done \
  < <(find "$release_out/artifacts" -maxdepth 1 -type f -print0 | sort -z)
while IFS= read -r -d '' file; do release_signatures+=("$file"); done \
  < <(find "$release_out/sidecars" -maxdepth 1 -type f -name '*.ed25519.sig' -print0 | sort -z)
if [[ "${#release_artifacts[@]}" -ne 8 || "${#release_signatures[@]}" -ne 9 ]]; then
  echo "expected eight release artifacts and nine Ed25519 signatures, found ${#release_artifacts[@]} and ${#release_signatures[@]}" >&2
  exit 1
fi

node - "$feed" "$public_base_url/$release_prefix" <<'NODE'
const fs = require('node:fs');
const feed = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const prefix = `${process.argv[3]}/`;
const urls = [feed.signature?.url, ...(feed.artifacts ?? []).flatMap((artifact) => [artifact.url, artifact.signatureUrl])];
if (urls.some((url) => typeof url !== 'string' || !url.startsWith(prefix) || url.slice(prefix.length).includes('/'))) {
  throw new Error('signed Linux feed does not bind every artifact to the immutable R2 release prefix');
}
NODE

# Release artifacts, detached signatures, and the signed feed candidate are
# immutable. The control Worker later atomically points the root feed routes at
# these versioned bytes after repository activation.
feed_object_name="latest-linux-$channel.json"
feed_signature_object_name="$feed_object_name.ed25519.sig"
put_object "$feed" "$release_prefix/$feed_object_name"
for file in "${release_artifacts[@]}" "${release_signatures[@]}"; do
  if [[ "$file" == "$signature" ]]; then
    put_object "$file" "$release_prefix/$feed_signature_object_name"
  else
    put_object "$file" "$release_prefix/$(basename "$file")"
  fi
done

declare -a repository_packages=()
declare -a repository_files=()
declare -a shared_repository_files=()
while IFS= read -r -d '' file; do
  relative="${file#"$repository_root"/}"
  repository_files+=("$file")
  case "$relative" in
    *.deb|*.rpm|*/by-hash/*|rpm/*/*/repodata/*-*)
      repository_packages+=("$file")
      shared_repository_files+=("$file")
      ;;
  esac
done < <(find "$repository_root" -type f -print0 | sort -z)

package_count="$(printf '%s\n' "${repository_packages[@]}" | grep -Ec '\.(deb|rpm)$')"
if [[ "$package_count" -ne 4 ]]; then
  echo "expected four immutable apt/RPM repository packages, found ${#repository_packages[@]}" >&2
  exit 1
fi
if [[ ! -f "$repository_root/apt/dists/$channel/InRelease" \
  || ! -f "$repository_root/rpm/$channel/x86_64/repodata/repomd.xml" \
  || ! -f "$repository_root/rpm/$channel/aarch64/repodata/repomd.xml" ]]; then
  echo "signed apt/RPM repository snapshot is incomplete" >&2
  exit 1
fi

# Publish shared checksum-addressed leaves first. They remain at their
# conventional canonical paths so a package-manager transaction that started
# before activation can finish after the channel pointer changes.
for file in "${shared_repository_files[@]}"; do
  relative="${file#"$repository_root"/}"
  put_object "$file" "linux/$relative"
done

# The complete repository is uploaded under a closure-addressed immutable
# prefix. The Worker switches canonical apt/RPM roots only after every byte is
# public and verified; this script never changes the active channel pointer.
for file in "${repository_files[@]}"; do
  relative="${file#"$repository_root"/}"
  put_object "$file" "$snapshot_prefix/$relative"
done

tmp_dir="$temporary/public-verification"
mkdir -p "$tmp_dir"
verify_public_byte() {
  local source="$1"
  local key="$2"
  local destination="$tmp_dir/${key//\//__}"
  for attempt in 1 2 3 4 5 6; do
    if curl --disable --proto '=https' --max-redirs 0 -fsS \
      -H 'Cache-Control: no-cache' \
      "$public_base_url/$key" \
      -o "$destination" \
      && cmp "$source" "$destination"; then
      return 0
    fi
    if [[ "$attempt" -eq 6 ]]; then
      echo "published Linux object did not match origin bytes: $key" >&2
      exit 1
    fi
    sleep 10
  done
}

for file in \
  "$feed" \
  "${release_artifacts[@]}" \
  "${release_signatures[@]}" \
  "${shared_repository_files[@]}"; do
  if [[ "$file" == "$feed" ]]; then
    verify_public_byte "$file" "$release_prefix/$feed_object_name"
  elif [[ "$file" == "$signature" ]]; then
    verify_public_byte "$file" "$release_prefix/$feed_signature_object_name"
  elif [[ "$file" == "$repository_root"/* ]]; then
    relative="${file#"$repository_root"/}"
    verify_public_byte "$file" "linux/$relative"
  else
    verify_public_byte "$file" "$release_prefix/$(basename "$file")"
  fi
done

for file in "${repository_files[@]}"; do
  relative="${file#"$repository_root"/}"
  verify_public_byte "$file" "$snapshot_prefix/$relative"
done

upload_manifest="$release_out/repository-upload-manifest.json"
node - "$response_log" "$upload_manifest" <<'NODE'
const fs = require('node:fs');
const [logPath, output] = process.argv.slice(2);
const operations = fs.readFileSync(logPath, 'utf8').trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
if (operations.some((row, index) => row.sequence !== index + 1)) {
  throw new Error('immutable upload response sequence is not canonical');
}
fs.writeFileSync(output, `${JSON.stringify({ schemaVersion: 1, operations }, null, 2)}\n`, { flag: 'wx', mode: 0o600 });
NODE
upload_manifest_sha256="$(shasum -a 256 "$upload_manifest" | awk '{print $1}')"
upload_receipt="$release_out/repository-upload.json"
node - "$upload_receipt" "$channel" "$version" "$snapshot_id" "$snapshot_prefix" \
  "$source_commit" "${#release_artifacts[@]}" "${#release_signatures[@]}" "${#shared_repository_files[@]}" \
  "${#repository_files[@]}" "$operation_count" "$(basename "$upload_manifest")" "$upload_manifest_sha256" <<'NODE'
const fs = require('node:fs');
const [output, channel, version, snapshotId, snapshotPrefix, sourceCommit, artifactCount, signatureCount,
  sharedCount, snapshotCount, operationCount, manifestFile, manifestSha256] = process.argv.slice(2);
const completedAt = new Date().toISOString();
fs.writeFileSync(output, `${JSON.stringify({
  schemaVersion: 1,
  channel,
  version,
  snapshotId,
  snapshotPrefix,
  sourceCommit,
  counts: {
    release: 1 + Number(artifactCount) + Number(signatureCount),
    shared: Number(sharedCount),
    snapshot: Number(snapshotCount),
    totalOperations: Number(operationCount)
  },
  manifest: { file: manifestFile, sha256: manifestSha256 },
  uploadedAt: completedAt,
  publicVerificationCompletedAt: completedAt
}, null, 2)}\n`, { flag: 'wx' });
NODE

echo "Linux release assets and immutable repository snapshot $snapshot_id published and byte-verified at $public_base_url"
