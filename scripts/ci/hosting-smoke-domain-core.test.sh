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
    [[ -z "$headers" ]] || printf 'HTTP/2 200\r\ncontent-security-policy: default-src '\''self'\''\r\n\r\n' > "$headers"
    printf '200'
    ;;
  https://mock.invalid/domain-core-deployment-identity.json)
    cp "$MOCK_IDENTITY_SOURCE" "$body"
    printf '%s' "${MOCK_IDENTITY_HTTP_CODE:-200}"
    ;;
  https://mock.invalid/console/domain-core-runtime-artifact-manifest.json)
    cp "$MOCK_RUNTIME_MANIFEST_SOURCE" "$body"
    printf '200'
    ;;
  https://mock.invalid/console/*)
    relative="${url#https://mock.invalid/console/}"
    if [[ "$relative" == "404.html" ]]; then
      [[ -z "$headers" ]] || printf 'HTTP/2 301\r\nlocation: /404\r\n\r\n' > "$headers"
      : > "$body"
      printf '301'
      exit 0
    fi
    if [[ "$relative" == "robots.txt" && "${MOCK_ROBOTS_CLOUDFLARE_PREFIX:-}" == "1" ]]; then
      printf '# BEGIN Cloudflare Managed content\nUser-agent: CloudflareBrowserRenderingCrawler\nDisallow: /\n# END Cloudflare Managed Content\n\n' > "$body"
      cat "$MOCK_RUNTIME_ROOT/$relative" >> "$body"
      printf '200'
      exit 0
    fi
    if [[ "$relative" == "404" ]]; then
      cp "$MOCK_RUNTIME_ROOT/404.html" "$body"
      printf '200'
      exit 0
    fi
    if [[ -f "$MOCK_RUNTIME_ROOT/$relative" ]]; then
      cp "$MOCK_RUNTIME_ROOT/$relative" "$body"
      printf '200'
    else
      : > "$body"
      printf '404'
    fi
    ;;
  *)
    : > "$body"
    printf '404'
    ;;
esac
MOCK
chmod +x "$TMP/bin/curl"

commit="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
candidate_commit="cccccccccccccccccccccccccccccccccccccccc"
tag="v1.2.3"
profile="$TMP/domain-core-build-profile.json"
gate="$TMP/domain-core-release-gate.json"
identity="$TMP/domain-core-deployment-identity.json"
health="$TMP/console-deploy-health.json"
runtime_root="$TMP/runtime"
runtime_manifest="$TMP/domain-core-runtime-artifact-manifest.json"
mkdir -p "$runtime_root"

node - "$profile" "$gate" "$candidate_commit" "$commit" <<'NODE'
const fs = require("fs");
const [profilePath, gatePath, candidateCommit, commit] = process.argv.slice(2);
const candidate = {
  candidateCommit,
  coreVersion: "0.3.0",
  abiVersion: 3,
  sourceSha256: "b".repeat(64),
};
const profile = {
  schemaVersion: 1,
  name: "public-production",
  artifactAuthority: "signed",
  distribution: "public",
  rolloutChannel: null,
  evidenceEnabled: false,
  modes: {
    quota: "rust",
    cloudVault: "rust",
    cloudVaultRewrap: "legacy",
    cloudVaultSearch: "legacy",
    hermes: "legacy",
    pricing: "legacy",
  },
  candidateIdentity: candidate,
};
const gate = {
  schemaVersion: 2,
  verificationKind: "domain-core-release-gate",
  candidate,
  activation: {
    ...candidate,
    activationCommit: commit,
    changedPathsSha256: "f".repeat(64),
    releaseCommit: commit,
  },
  sourceRun: {
    repository: "Imagine-That-Ai/BurnBar",
    workflowPath: ".github/workflows/domain-core.yml",
    runId: 101,
    runAttempt: 2,
    event: "push",
    ref: "refs/heads/main",
    headSha: candidateCommit,
  },
  promotionProof: {
    signerWorkflow: ".github/workflows/domain-core-promotion-proof.yml",
    predicateType: "https://slsa.dev/provenance/v1",
    signerRun: { runId: 202, runAttempt: 3 },
    attestationSubject: { fileName: "domain-core-candidate-bundle.json", sha256: "c".repeat(64) },
    attestationBundleSha256: "d".repeat(64),
  },
  rollbackArtifact: {
    fileName: "domain-core-public-production-rollback.json",
    sha256: "e".repeat(64),
    candidate,
    activation: {
      ...candidate,
      activationCommit: commit,
      changedPathsSha256: "f".repeat(64),
      releaseCommit: commit,
    },
  },
};
fs.writeFileSync(profilePath, `${JSON.stringify(profile, null, 2)}\n`);
fs.writeFileSync(gatePath, `${JSON.stringify(gate, null, 2)}\n`);
NODE

node "$ROOT/scripts/ci/create-domain-core-deployment-identity.mjs" \
  --consumer console \
  --commit "$commit" \
  --tag "$tag" \
  --profile-receipt "$profile" \
  --release-gate "$gate" \
  --output "$identity"

cp "$identity" "$runtime_root/domain-core-deployment-identity.json"
cp "$profile" "$runtime_root/domain-core-build-profile.json"
printf 'domain-core-wasm-bytes\n' > "$runtime_root/domain-core.wasm"
printf 'fetch("domain-core.wasm"); domainCoreSourceFingerprint();\n' > "$runtime_root/domain-core.js"
printf 'not-found\n' > "$runtime_root/404.html"
printf '# The member console is private — never index it.\nUser-agent: *\nDisallow: /\n' > "$runtime_root/robots.txt"
node "$ROOT/scripts/ci/create-domain-core-runtime-artifact-manifest.mjs" \
  --consumer console \
  --root "$runtime_root" \
  --profile-receipt "$profile" \
  --output "$runtime_manifest" >/dev/null
cp "$runtime_root/robots.txt" "$TMP/robots.txt"

hosting_coordinates='{"schemaVersion":1,"project":"burnbar","sites":[{"target":"marketing","site":"burnbar","versionName":"sites/burnbar/versions/version-1","releaseName":"sites/burnbar/channels/live/releases/release-1"},{"target":"console","site":"burnbar-console","versionName":"sites/burnbar-console/versions/version-2","releaseName":"sites/burnbar-console/channels/live/releases/release-2"}]}'

run_smoke() {
  PATH="$TMP/bin:$PATH" \
  MOCK_IDENTITY_SOURCE="$identity" \
  MOCK_IDENTITY_HTTP_CODE="${MOCK_IDENTITY_HTTP_CODE:-200}" \
  MOCK_RUNTIME_ROOT="$runtime_root" \
  MOCK_RUNTIME_MANIFEST_SOURCE="$runtime_manifest" \
  HOSTING_SMOKE_RETRIES=1 \
  HOSTING_SMOKE_SLEEP_SEC=0 \
  HOSTING_SMOKE_EXPECTED_COMMIT="$commit" \
  HOSTING_SMOKE_EXPECTED_TAG="$tag" \
  HOSTING_SMOKE_PROFILE_RECEIPT="$profile" \
  HOSTING_SMOKE_RELEASE_GATE="$gate" \
  HOSTING_SMOKE_RUNTIME_MANIFEST="$runtime_manifest" \
  HOSTING_DEPLOY_COORDINATES_JSON="$hosting_coordinates" \
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
node - "$health" "$runtime_manifest" <<'NODE'
const crypto = require("crypto");
const fs = require("fs");
const [healthPath, manifestPath] = process.argv.slice(2);
const health = JSON.parse(fs.readFileSync(healthPath, "utf8"));
assert = require("assert/strict");
assert.deepEqual(health, {
  provider: "firebase-hosting",
  project: "burnbar",
  environment: "production",
  status: "healthy",
  healthChecks: [
    "marketing-http-200-csp",
    "console-http-200-csp",
    "console-deployment-identity-no-redirect",
    "console-runtime-manifest-no-redirect",
    "console-runtime-files-sha256",
  ],
  deployedArtifact: {
    fileName: "domain-core-runtime-artifact-manifest.json",
    sha256: crypto.createHash("sha256").update(fs.readFileSync(manifestPath)).digest("hex"),
  },
  providerCoordinates: {
    sites: [
      { target: "marketing", site: "burnbar", versionName: "sites/burnbar/versions/version-1", releaseName: "sites/burnbar/channels/live/releases/release-1" },
      { target: "console", site: "burnbar-console", versionName: "sites/burnbar-console/versions/version-2", releaseName: "sites/burnbar-console/channels/live/releases/release-2" },
    ],
  },
});
NODE

cp "$identity" "$TMP/good-identity.json"
assert_rejected() {
  local variant="$1"
  cp "$TMP/good-identity.json" "$identity"
  node - "$identity" "$variant" <<'NODE'
const fs = require("fs");
const [path, variant] = process.argv.slice(2);
const value = JSON.parse(fs.readFileSync(path, "utf8"));
if (variant === "commit") value.commit = "f".repeat(40);
else if (variant === "profile") value.profile.sha256 = "0".repeat(64);
else if (variant === "signer") value.releaseGate.promotionProof.signerRun.runAttempt += 1;
else if (variant === "rollback") value.releaseGate.rollbackArtifact.sha256 = "0".repeat(64);
else throw new Error(`unknown variant ${variant}`);
fs.writeFileSync(path, `${JSON.stringify(value)}\n`);
NODE
  rm -f "$health"
  if (cd "$ROOT" && run_smoke >/dev/null 2>&1); then
    echo "FAIL: invalid live identity variant ${variant} passed" >&2
    exit 1
  fi
  [[ ! -e "$health" ]] || { echo "FAIL: invalid identity produced health evidence" >&2; exit 1; }
}

for variant in commit profile signer rollback; do
  assert_rejected "$variant"
done

cp "$TMP/good-identity.json" "$identity"
rm -f "$health"
if (cd "$ROOT" && MOCK_IDENTITY_HTTP_CODE=302 run_smoke >/dev/null 2>&1); then
  echo "FAIL: redirected identity passed" >&2
  exit 1
fi
[[ ! -e "$health" ]] || { echo "FAIL: redirected identity produced health evidence" >&2; exit 1; }

cp "$runtime_root/domain-core.wasm" "$TMP/good-domain-core.wasm"
printf 'tampered-wasm\n' > "$runtime_root/domain-core.wasm"
rm -f "$health"
if (cd "$ROOT" && run_smoke >/dev/null 2>&1); then
  echo "FAIL: runtime WASM differing from protected manifest passed" >&2
  exit 1
fi
[[ ! -e "$health" ]] || { echo "FAIL: tampered WASM produced health evidence" >&2; exit 1; }
cp "$TMP/good-domain-core.wasm" "$runtime_root/domain-core.wasm"

rm -f "$health"
if (cd "$ROOT" && MOCK_ROBOTS_CLOUDFLARE_PREFIX=1 run_smoke >/dev/null); then
  [[ -e "$health" ]] || { echo "FAIL: Cloudflare-managed robots prefix produced no health evidence" >&2; exit 1; }
else
  echo "FAIL: Cloudflare-managed robots prefix was rejected" >&2
  exit 1
fi

echo "PASS: Console Hosting identity, runtime bytes, and immutable provider coordinates are exact and fail-closed"
