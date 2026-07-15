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

run_smoke() {
  PATH="$TMP/bin:$PATH" \
  MOCK_IDENTITY_SOURCE="$identity" \
  MOCK_IDENTITY_HTTP_CODE="${MOCK_IDENTITY_HTTP_CODE:-200}" \
  HOSTING_SMOKE_RETRIES=1 \
  HOSTING_SMOKE_SLEEP_SEC=0 \
  HOSTING_SMOKE_EXPECTED_COMMIT="$commit" \
  HOSTING_SMOKE_EXPECTED_TAG="$tag" \
  HOSTING_SMOKE_PROFILE_RECEIPT="$profile" \
  HOSTING_SMOKE_RELEASE_GATE="$gate" \
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
node - "$health" "$identity" <<'NODE'
const crypto = require("crypto");
const fs = require("fs");
const [healthPath, identityPath] = process.argv.slice(2);
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
  ],
  deployedArtifact: {
    fileName: "domain-core-deployment-identity.json",
    sha256: crypto.createHash("sha256").update(fs.readFileSync(identityPath)).digest("hex"),
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

echo "PASS: Console hosting evidence is exact, no-redirect, and fail-closed"
