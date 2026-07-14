#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

body=""
headers=""
url=""
while (($#)); do
  case "$1" in
    -o) body="$2"; shift 2 ;;
    -D) headers="$2"; shift 2 ;;
    -w) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done

case "$url" in
  https://mock.invalid/marketing|https://mock.invalid/console)
    printf '<!doctype html><title>BurnBar</title>\n' > "$body"
    if [[ -n "$headers" ]]; then
      printf 'HTTP/2 200\r\ncontent-security-policy: default-src '\''self'\''\r\n\r\n' > "$headers"
    fi
    printf '200'
    ;;
  https://mock.invalid/domain-core-deployment-identity.json)
    cp "$MOCK_IDENTITY_SOURCE" "$body"
    code="${MOCK_IDENTITY_HTTP_CODE:-200}"
    [[ -z "$headers" ]] || printf 'HTTP/2 %s\r\n\r\n' "$code" > "$headers"
    printf '%s' "$code"
    ;;
  *)
    : > "$body"
    [[ -z "$headers" ]] || printf 'HTTP/2 404\r\n\r\n' > "$headers"
    printf '404'
    ;;
esac
MOCK
chmod +x "$TMP/bin/curl"

commit="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
tag="v1.2.3"
identity="$TMP/identity.json"
health="$TMP/console-deploy-health.json"
node "$ROOT/scripts/ci/create-domain-core-deployment-identity.mjs" \
  --consumer console \
  --commit "$commit" \
  --tag "$tag" \
  --output "$identity"

run_smoke() {
  PATH="$TMP/bin:$PATH" \
  MOCK_IDENTITY_SOURCE="$identity" \
  MOCK_IDENTITY_HTTP_CODE="${MOCK_IDENTITY_HTTP_CODE:-200}" \
  HOSTING_SMOKE_RETRIES=1 \
  HOSTING_SMOKE_SLEEP_SEC=0 \
  HOSTING_SMOKE_EXPECTED_COMMIT="$commit" \
  HOSTING_SMOKE_EXPECTED_TAG="$tag" \
  CONSOLE_DEPLOY_HEALTH_JSON="$health" \
  OPENBURNBAR_MARKETING_URL="https://mock.invalid/marketing" \
  OPENBURNBAR_CONSOLE_URL="https://mock.invalid/console" \
  OPENBURNBAR_CONSOLE_IDENTITY_URL="https://mock.invalid/domain-core-deployment-identity.json" \
    bash "$ROOT/scripts/ci/hosting-smoke.sh"
}

(
  cd "$ROOT"
  run_smoke >/dev/null
)
node - "$health" "$identity" "$commit" "$tag" <<'NODE'
const fs = require("fs");
const assert = require("assert/strict");
const [healthPath, identityPath, commit, tag] = process.argv.slice(2);
const health = JSON.parse(fs.readFileSync(healthPath, "utf8"));
const identity = JSON.parse(fs.readFileSync(identityPath, "utf8"));
assert.equal(health.schemaVersion, 1);
assert.equal(health.project, "burnbar");
assert.equal(health.commit, commit);
assert.equal(health.tag, tag);
assert.deepEqual(health.checks, {
  marketing: "ok",
  console: "ok",
  deploymentIdentity: "ok",
});
assert.deepEqual(health.deploymentIdentity, identity);
NODE

cp "$identity" "$TMP/good-identity.json"
assert_rejected() {
  local variant="$1"
  cp "$TMP/good-identity.json" "$identity"
  node - "$identity" "$variant" <<'NODE'
const fs = require("fs");
const path = process.argv[2];
const variant = process.argv[3];
const identity = JSON.parse(fs.readFileSync(path, "utf8"));
switch (variant) {
  case "commit": identity.commit = "b".repeat(40); break;
  case "tag": identity.tag = "v1.2.2"; break;
  case "digest": identity.profile.publicProfileSha256 = "0".repeat(64); break;
  case "repository": identity.repository = "https://github.com/example/other"; break;
  case "consumer": identity.consumer = "functions"; break;
  case "target": identity.target = "firebase-functions-production"; break;
  default: throw new Error(`unknown variant: ${variant}`);
}
fs.writeFileSync(path, `${JSON.stringify(identity, null, 2)}\n`);
NODE
  rm -f "$health"
  if (
    cd "$ROOT"
    run_smoke >/dev/null 2>&1
  ); then
    echo "FAIL: invalid Console identity variant $variant unexpectedly passed" >&2
    exit 1
  fi
  if [[ -e "$health" ]]; then
    echo "FAIL: hosting smoke wrote health evidence for invalid variant $variant" >&2
    exit 1
  fi
}

for variant in commit tag digest repository consumer target; do
  assert_rejected "$variant"
done

cp "$TMP/good-identity.json" "$identity"
rm -f "$health"
if (
  cd "$ROOT"
  MOCK_IDENTITY_HTTP_CODE=302 run_smoke >/dev/null 2>&1
); then
  echo "FAIL: redirected Console identity unexpectedly passed hosting smoke" >&2
  exit 1
fi
if [[ -e "$health" ]]; then
  echo "FAIL: hosting smoke wrote health evidence for a redirected identity" >&2
  exit 1
fi

echo "PASS: Console hosting evidence is exact and fail-closed"
