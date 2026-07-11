#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

usage() {
  cat <<'EOF'
Usage: scripts/publish-linux-update-feed-r2.sh --publish-only|--verify-only

--publish-only atomically publishes the already-uploaded versioned feed bytes
through the repository control Worker. --verify-only verifies the subsequently
deployed public root routes and writes a separate verification receipt.
EOF
}

case "${1:-}" in
  --publish-only) mode="publish" ;;
  --verify-only) mode="verify" ;;
  -h|--help) usage; exit 0 ;;
  *) echo "publish-linux-update-feed-r2.sh requires exactly --publish-only or --verify-only" >&2; usage >&2; exit 2 ;;
esac
[[ $# -eq 1 ]] || { echo "publish-linux-update-feed-r2.sh accepts exactly one mode" >&2; exit 2; }

release_out="${OPENBURNBAR_LINUX_RELEASE_OUT:-$repo_root/.linux-release}"
public_base_url="${OPENBURNBAR_R2_PUBLIC_BASE_URL:-https://downloads.burnbar.ai}"
feed="$release_out/latest-linux.draft.json"
signature="$release_out/sidecars/latest-linux.json.ed25519.sig"
public_key="packaging/linux/openburnbar-linux-ed25519.pub.pem"
activation_receipt="$release_out/repository-activation.json"
repository_closure="$release_out/repositories/repository-closure.json"
publication_receipt="$release_out/repository-feed-publication.json"
verification_receipt="${OPENBURNBAR_LINUX_REPOSITORY_FEED_VERIFICATION_RECEIPT:-$release_out/repository-feed-verification.json}"
activation_token="${OPENBURNBAR_LINUX_REPOSITORY_ACTIVATION_TOKEN:-}"
unset OPENBURNBAR_LINUX_REPOSITORY_ACTIVATION_TOKEN || true

if [[ "$public_base_url" != 'https://downloads.burnbar.ai' ]]; then
  echo "OPENBURNBAR_R2_PUBLIC_BASE_URL must be the bare production origin https://downloads.burnbar.ai" >&2
  exit 1
fi
if ! printf '%s' "$activation_token" | node -e \
    'const fs=require("node:fs");process.exit(/^[A-Za-z0-9._~+/=-]{32,4096}$/.test(fs.readFileSync(0,"utf8"))?0:1)'; then
  echo "OPENBURNBAR_LINUX_REPOSITORY_ACTIVATION_TOKEN must contain 32 to 4096 characters from the approved token alphabet" >&2
  exit 1
fi

for required in "$feed" "$signature" "$public_key" "$activation_receipt" "$repository_closure"; do
  [[ -f "$required" ]] || { echo "required feed publication file is missing: $required" >&2; exit 1; }
done
if [[ "$mode" == "verify" && ! -f "$publication_receipt" ]]; then
  echo "required feed publication receipt is missing: $publication_receipt" >&2
  exit 1
fi

temporary="$(mktemp -d)"
cleanup() { rm -rf "$temporary"; }
trap cleanup EXIT
chmod 700 "$temporary"
auth_config="$temporary/curl-auth"
printf 'header = "Authorization: Bearer %s"\n' "$activation_token" >"$auth_config"
chmod 600 "$auth_config"
unset activation_token

authenticated_get() {
  local path="$1"
  local output="$2"
  local headers="$3"
  curl --disable --proto '=https' --max-redirs 0 --config "$auth_config" --silent --show-error \
    --dump-header "$headers" --output "$output" --write-out '%{http_code}' \
    "$public_base_url$path"
}

terminal_response_etag() {
  local headers="$1"
  local mode="$2"
  node - "$headers" "$mode" <<'NODE'
const fs = require('node:fs');
const [headersPath, mode] = process.argv.slice(2);
if (!['required', 'absent'].includes(mode)) throw new Error('invalid HTTP ETag parsing mode');
const lines = fs.readFileSync(headersPath, 'utf8').split(/\r?\n/u);
const starts = [];
for (let index = 0; index < lines.length; index += 1) {
  if (/^HTTP\/\S+\s+[1-5][0-9]{2}(?:\s|$)/u.test(lines[index])) starts.push(index);
}
if (starts.length === 0) throw new Error('curl response headers contain no HTTP status line');
const start = starts.at(-1);
let end = lines.length;
for (let index = start + 1; index < lines.length; index += 1) {
  if (lines[index] === '') { end = index; break; }
}
const etags = [];
for (const line of lines.slice(start + 1, end)) {
  if (/^[ \t]/u.test(line)) throw new Error('curl response contains a folded HTTP header');
  const separator = line.indexOf(':');
  if (separator <= 0) throw new Error('curl response contains a malformed HTTP header');
  const name = line.slice(0, separator).trim().toLowerCase();
  const value = line.slice(separator + 1).trim();
  if (name === 'etag') etags.push(value);
}
if (mode === 'absent') {
  if (etags.length !== 0) throw new Error('absent pointer response unexpectedly contains an HTTP ETag');
  process.exit(0);
}
if (etags.length !== 1 || !/^"[a-f0-9]{32,64}(?:-[1-9][0-9]*)?"$/u.test(etags[0])) {
  throw new Error('curl response must contain exactly one canonical strong HTTP ETag');
}
process.stdout.write(etags[0]);
NODE
}

capture_activation() {
  local output="$1"
  local headers="$2"
  local code
  code="$(authenticated_get "/linux/repository-admin/status?channel=$channel" "$output" "$headers")"
  [[ "$code" == 200 ]] || { echo "repository activation status failed: HTTP $code" >&2; return 1; }
  local response_etag
  response_etag="$(terminal_response_etag "$headers" required)"
  node - "$output" "$snapshot_id" "$source_commit" "$version" "$response_etag" <<'NODE'
const fs = require('node:fs');
const [statusPath, snapshotId, sourceCommit, version, responseEtag] = process.argv.slice(2);
const status = JSON.parse(fs.readFileSync(statusPath, 'utf8'));
if (status.schemaVersion !== 1 || status.status !== 'active'
    || status.activation?.snapshotId !== snapshotId || status.activation?.sourceCommit !== sourceCommit
    || status.activation?.version !== version || !Number.isSafeInteger(status.activation?.generation)
    || status.activation.generation < 1 || !/^"[a-f0-9]{32,64}(?:-[1-9][0-9]*)?"$/u.test(status.pointerEtag ?? '')
    || status.pointerEtag !== responseEtag) {
  throw new Error('live repository activation does not match the feed publication');
}
process.stdout.write(`${status.activation.generation}\t${status.pointerEtag}\n`);
NODE
}

assert_activation() {
  local output="$1"
  local headers="$2"
  local actual_generation actual_etag
  IFS=$'\t' read -r actual_generation actual_etag < <(capture_activation "$output" "$headers")
  [[ "$actual_generation" == "$expected_repository_generation" \
      && "$actual_etag" == "$expected_repository_etag" ]] || {
    echo "live repository activation generation or pointer ETag changed" >&2
    return 1
  }
}

assert_feed_status() {
  local output="$1"
  local headers="$2"
  local code
  code="$(authenticated_get "/linux/repository-admin/feed-status?channel=$channel" "$output" "$headers")"
  [[ "$code" == 200 ]] || { echo "repository feed status failed: HTTP $code" >&2; return 1; }
  local response_etag
  response_etag="$(terminal_response_etag "$headers" required)"
  node - "$output" "$publication_receipt" "$response_etag" <<'NODE'
const fs = require('node:fs');
const status = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const receipt = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
const responseEtag = process.argv[4];
if (status.schemaVersion !== 1 || status.status !== 'published'
    || status.pointerEtag !== receipt.result.pointerEtag
    || status.pointerEtag !== responseEtag
    || JSON.stringify(status.feed) !== JSON.stringify(receipt.result.feed)) {
  throw new Error('live feed pointer does not match the publication receipt');
}
NODE
}

# Bind local signed bytes and the activation receipt before making any control-plane request.
IFS=$'\t' read -r channel snapshot_id source_commit version \
  < <(node - "$feed" "$activation_receipt" "$repository_closure" <<'NODE'
const crypto = require('node:crypto');
const fs = require('node:fs');
const feed = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const receipt = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
const closureBytes = fs.readFileSync(process.argv[4]);
const closure = JSON.parse(closureBytes);
const snapshotId = crypto.createHash('sha256').update(closureBytes).digest('hex');
const activation = receipt.result?.activation;
if (receipt.dryRun !== false || !activation || activation.version !== feed.version
    || activation.channel !== feed.channel || activation.snapshotId !== snapshotId
    || activation.sourceCommit !== closure.gitCommit || closure.version !== feed.version
    || closure.channel !== feed.channel || !Number.isSafeInteger(activation.generation)
    || activation.generation < 1
    || !/^"[a-f0-9]{32,64}(?:-[1-9][0-9]*)?"$/u.test(receipt.result?.pointerEtag ?? '')) {
  throw new Error('repository activation receipt does not bind the signed update feed version and channel');
}
process.stdout.write([closure.channel, snapshotId, closure.gitCommit, closure.version].join('\t') + '\n');
NODE
)

if [[ "$mode" == "publish" ]]; then
  IFS=$'\t' read -r expected_repository_generation expected_repository_etag \
    < <(capture_activation "$temporary/activation-before.json" "$temporary/activation-before.headers")
  feed_status_code="$(authenticated_get "/linux/repository-admin/feed-status?channel=$channel" \
    "$temporary/feed-before.json" "$temporary/feed-before.headers")"
  if [[ "$feed_status_code" != 200 && "$feed_status_code" != 404 ]]; then
    echo "repository feed status failed: HTTP $feed_status_code" >&2
    exit 1
  fi
  if [[ "$feed_status_code" == 200 ]]; then
    current_feed_response_etag="$(terminal_response_etag "$temporary/feed-before.headers" required)"
  else
    terminal_response_etag "$temporary/feed-before.headers" absent >/dev/null
    current_feed_response_etag=""
  fi

  request="$temporary/feed-publication-request.json"
  node - "$request" "$feed" "$signature" "$channel" "$snapshot_id" "$source_commit" "$version" \
    "$expected_repository_generation" "$expected_repository_etag" "$feed_status_code" "$temporary/feed-before.json" \
    "$current_feed_response_etag" <<'NODE'
const crypto = require('node:crypto');
const fs = require('node:fs');
const [output, feedPath, signaturePath, channel, snapshotId, sourceCommit, version, generationText,
  repositoryPointerEtag, statusCode, statusPath, feedResponseEtag] = process.argv.slice(2);
const digest = (bytes) => crypto.createHash('sha256').update(bytes).digest('hex');
const feedBytes = fs.readFileSync(feedPath);
const signatureBytes = fs.readFileSync(signaturePath);
let expectedCurrent = { generation: null, etag: null };
if (statusCode === '200') {
  const current = JSON.parse(fs.readFileSync(statusPath, 'utf8'));
  if (current.schemaVersion !== 1 || current.status !== 'published'
      || !Number.isSafeInteger(current.feed?.generation) || current.feed.generation < 1
      || current.pointerEtag !== feedResponseEtag) {
    throw new Error('current feed pointer is invalid');
  }
  expectedCurrent = { generation: current.feed.generation, etag: current.pointerEtag };
} else {
  const current = JSON.parse(fs.readFileSync(statusPath, 'utf8'));
  if (current.schemaVersion !== 1 || current.status !== 'inactive') throw new Error('inactive feed status is invalid');
}
const releasePrefix = `linux/releases/linux-v${version}`;
const feedObjectName = `latest-linux-${channel}.json`;
const request = {
  schemaVersion: 1,
  channel,
  generation: Number(generationText),
  snapshotId,
  version,
  sourceCommit,
  repositoryPointerEtag,
  feed: {
    key: `${releasePrefix}/${feedObjectName}`,
    signatureKey: `${releasePrefix}/${feedObjectName}.ed25519.sig`,
    sha256: digest(feedBytes),
    size: feedBytes.length,
    signatureSha256: digest(signatureBytes),
    signatureSize: signatureBytes.length
  },
  expectedCurrent
};
fs.writeFileSync(output, `${JSON.stringify(request, null, 2)}\n`, { mode: 0o600 });
NODE

  publish_response="$temporary/feed-publication-response.json"
  publish_headers="$temporary/feed-publication-response.headers"
  publish_code="$(curl --disable --proto '=https' --max-redirs 0 --config "$auth_config" --silent --show-error \
    --request POST --header 'Content-Type: application/json' --data-binary "@$request" \
    --dump-header "$publish_headers" --output "$publish_response" --write-out '%{http_code}' \
    "$public_base_url/linux/repository-admin/publish-feed")"
  if [[ "$publish_code" != 200 ]]; then
    echo "feed pointer publication failed: HTTP $publish_code: $(head -c 500 "$publish_response")" >&2
    exit 1
  fi
  publish_response_etag="$(terminal_response_etag "$publish_headers" required)"

  node - "$request" "$publish_response" "$publication_receipt" "$publish_response_etag" <<'NODE'
const fs = require('node:fs');
const request = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const response = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
const responseEtag = process.argv[5];
if (response.schemaVersion !== 1 || response.status !== 'published'
    || response.pointerEtag !== responseEtag
    || response.feed?.channel !== request.channel || response.feed?.repository?.generation !== request.generation
    || response.feed?.repository?.snapshotId !== request.snapshotId
    || response.feed?.repository?.pointerEtag !== request.repositoryPointerEtag
    || response.feed?.version !== request.version || response.feed?.sourceCommit !== request.sourceCommit
    || JSON.stringify(response.feed?.feed) !== JSON.stringify(request.feed)) {
  throw new Error('feed publication response does not bind the requested repository and signed feed');
}
fs.writeFileSync(process.argv[4], `${JSON.stringify({
  schemaVersion: 1,
  requested: request,
  result: { pointerEtag: response.pointerEtag, feed: response.feed },
  publishedAt: new Date().toISOString()
}, null, 2)}\n`, { flag: 'wx' });
NODE
  assert_activation "$temporary/activation-after.json" "$temporary/activation-after.headers"
  assert_feed_status "$temporary/feed-after.json" "$temporary/feed-after.headers"
  echo "Linux update feed pointer published atomically; deploy the feed routes before verification."
  exit 0
fi

IFS=$'\t' read -r expected_repository_generation expected_repository_etag \
  < <(node - "$publication_receipt" "$channel" "$snapshot_id" "$source_commit" "$version" <<'NODE'
const fs = require('node:fs');
const [receiptPath, channel, snapshotId, sourceCommit, version] = process.argv.slice(2);
const receipt = JSON.parse(fs.readFileSync(receiptPath, 'utf8'));
const request = receipt.requested;
if (request?.channel !== channel || request?.snapshotId !== snapshotId
    || request?.sourceCommit !== sourceCommit || request?.version !== version
    || !Number.isSafeInteger(request?.generation) || request.generation < 1
    || !/^"[a-f0-9]{32,64}(?:-[1-9][0-9]*)?"$/u.test(request?.repositoryPointerEtag ?? '')) {
  throw new Error('feed publication receipt does not bind the local repository candidate');
}
process.stdout.write(`${request.generation}\t${request.repositoryPointerEtag}\n`);
NODE
)
assert_activation "$temporary/activation-before-verification.json" "$temporary/activation-before-verification.headers"
assert_feed_status "$temporary/feed-before-verification.json" "$temporary/feed-before-verification.headers"
if [[ "$channel" == stable ]]; then
  public_feed_path='/latest-linux.json'
else
  public_feed_path="/linux/update/$channel/latest-linux.json"
fi
public_signature_path="${public_feed_path}.ed25519.sig"
curl --disable --proto '=https' --max-redirs 0 -fsS -H 'Cache-Control: no-cache' \
  --dump-header "$temporary/feed.sig.headers" \
  "$public_base_url$public_signature_path" -o "$temporary/feed.sig"
curl --disable --proto '=https' --max-redirs 0 -fsS -H 'Cache-Control: no-cache' \
  --dump-header "$temporary/feed.json.headers" \
  "$public_base_url$public_feed_path" -o "$temporary/feed.json"
node - "$temporary/feed.sig.headers" "$temporary/feed.json.headers" "$snapshot_id" \
  "$publication_receipt" <<'NODE'
const fs = require('node:fs');
const [signatureHeaders, feedHeaders, snapshotId, receiptPath] = process.argv.slice(2);
const receipt = JSON.parse(fs.readFileSync(receiptPath, 'utf8'));
const expectedGeneration = String(receipt.result?.feed?.generation);
if (!/^[1-9][0-9]*$/u.test(expectedGeneration)) throw new Error('publication receipt has no valid feed generation');
for (const headersPath of [signatureHeaders, feedHeaders]) {
  const lines = fs.readFileSync(headersPath, 'utf8').split(/\r?\n/u);
  const starts = lines.flatMap((line, index) => /^HTTP\/\S+\s+200(?:\s|$)/u.test(line) ? [index] : []);
  if (starts.length !== 1) throw new Error('public feed response must contain exactly one HTTP 200 response');
  const values = new Map();
  for (const line of lines.slice(starts[0] + 1)) {
    if (line === '') break;
    if (/^[ \t]/u.test(line)) throw new Error('public feed response contains a folded header');
    const separator = line.indexOf(':');
    if (separator <= 0) throw new Error('public feed response contains a malformed header');
    const name = line.slice(0, separator).trim().toLowerCase();
    const value = line.slice(separator + 1).trim();
    const existing = values.get(name) ?? [];
    existing.push(value);
    values.set(name, existing);
  }
  const snapshots = values.get('x-openburnbar-repository-snapshot') ?? [];
  const generations = values.get('x-openburnbar-feed-generation') ?? [];
  if (snapshots.length !== 1 || snapshots[0] !== snapshotId
      || generations.length !== 1 || generations[0] !== expectedGeneration) {
    throw new Error('public feed response does not prove the expected Worker snapshot and feed generation');
  }
}
NODE
cmp "$signature" "$temporary/feed.sig"
cmp "$feed" "$temporary/feed.json"
openssl pkeyutl -verify -pubin -inkey "$public_key" -rawin -in "$temporary/feed.json" -sigfile "$temporary/feed.sig"
node scripts/linux-port/check-linux-update-feed.mjs --url "$public_base_url$public_feed_path"
assert_activation "$temporary/activation-after-verification.json" "$temporary/activation-after-verification.headers"
assert_feed_status "$temporary/feed-after-verification.json" "$temporary/feed-after-verification.headers"
node - "$publication_receipt" "$verification_receipt" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const publication = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const output = process.argv[3];
const bytes = `${JSON.stringify({
  schemaVersion: 1,
  channel: publication.requested.channel,
  version: publication.requested.version,
  snapshotId: publication.requested.snapshotId,
  repositoryGeneration: publication.requested.generation,
  repositoryPointerEtag: publication.requested.repositoryPointerEtag,
  feedGeneration: publication.result.feed.generation,
  feedPointerEtag: publication.result.pointerEtag,
  publicFeedPath: publication.requested.channel === 'stable'
    ? '/latest-linux.json'
    : `/linux/update/${publication.requested.channel}/latest-linux.json`,
  verifiedAt: new Date().toISOString()
}, null, 2)}\n`;
fs.mkdirSync(path.dirname(output), { recursive: true });
const temporary = path.join(path.dirname(output), `.${path.basename(output)}.tmp-${process.pid}-${Date.now()}`);
try {
  fs.writeFileSync(temporary, bytes, { flag: 'wx', mode: 0o600 });
  fs.linkSync(temporary, output);
} finally {
  fs.rmSync(temporary, { force: true });
}
NODE
echo "Linux update feed public routes are byte-, signature-, and pointer-verified at $public_base_url"
