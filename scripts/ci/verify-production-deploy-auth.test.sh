#!/usr/bin/env bash
# Regression fixtures for scripts/ci/verify-production-deploy-auth.sh.
set -euo pipefail
SOURCE_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERIFY="$SOURCE_ROOT/scripts/ci/verify-production-deploy-auth.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

copy_base_fixture() {
  local dst="$1"
  mkdir -p "$dst/.github/workflows" "$dst/scripts/ci"
  cp "$SOURCE_ROOT/.github/workflows/deploy-hosting.yml" "$dst/.github/workflows/deploy-hosting.yml"
  cp "$SOURCE_ROOT/.github/workflows/deploy-production.yml" "$dst/.github/workflows/deploy-production.yml"
  cp "$SOURCE_ROOT/.github/workflows/deploy-firestore.yml" "$dst/.github/workflows/deploy-firestore.yml"
  cp "$SOURCE_ROOT/.github/workflows/deploy-cloud-run.yml" "$dst/.github/workflows/deploy-cloud-run.yml"
  cp "$SOURCE_ROOT/firebase.json" "$dst/firebase.json"
  cp "$SOURCE_ROOT/scripts/ci/write-firebase-hosting-ci-config.mjs" "$dst/scripts/ci/write-firebase-hosting-ci-config.mjs"
}

run_gate() {
  local repo="$1"
  OPENBURNBAR_DEPLOY_AUTH_REPO="$repo" bash "$VERIFY"
}

expect_pass() {
  local name="$1"
  shift
  local log="$TMP_ROOT/${name//[^A-Za-z0-9_.-]/_}.log"
  if "$@" >"$log" 2>&1; then
    echo "PASS fixture: $name"
  else
    echo "FAIL fixture expected pass: $name" >&2
    cat "$log" >&2
    exit 1
  fi
}

expect_fail() {
  local name="$1"
  shift
  local log="$TMP_ROOT/${name//[^A-Za-z0-9_.-]/_}.log"
  if "$@" >"$log" 2>&1; then
    echo "FAIL fixture expected failure: $name" >&2
    cat "$log" >&2
    exit 1
  else
    echo "PASS fixture failed closed: $name"
  fi
}

mutate_file() {
  local repo="$1"
  local path="$2"
  local script="$3"
  python3 - "$repo/$path" "$script" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
script = sys.argv[2]
text = path.read_text(encoding="utf-8")
namespace = {"text": text}
exec(script, namespace)
path.write_text(namespace["text"], encoding="utf-8")
PY
}

fixture="$TMP_ROOT/safe-split"
copy_base_fixture "$fixture"
expect_pass "safe split passes" run_gate "$fixture"

fixture="$TMP_ROOT/frozen-vulnerable-hosting"
copy_base_fixture "$fixture"
cat > "$fixture/.github/workflows/deploy-hosting.yml" <<'YML'
name: Deploy Production (Hosting)
permissions:
  contents: read
  id-token: write
  issues: write
jobs:
  deploy-hosting:
    runs-on: ubuntu-latest
    environment: production
    steps:
      - uses: actions/checkout@93cb6efe18208431cddfb8368fd83d5badbf9bfd
      - name: Install hosting dependencies
        run: |
          npm ci --prefix website
          npm ci --prefix apps/console
          npm ci --prefix functions
      - name: Authenticate to Google Cloud (WIF/OIDC only)
        uses: google-github-actions/auth@7c6bc770dae815cd3e89ee6cdf493a5fab2cc093
        with:
          workload_identity_provider: ${{ secrets.GCP_WORKLOAD_IDENTITY_PROVIDER }}
          service_account: ${{ secrets.GCP_DEPLOY_SERVICE_ACCOUNT }}
          token_format: access_token
      - name: Deploy Hosting
        run: npm --prefix functions exec -- firebase deploy --only hosting --project burnbar --non-interactive
YML
expect_fail "frozen vulnerable hosting shape fails" run_gate "$fixture"

fixture="$TMP_ROOT/raw-firebase-json-deploy"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-hosting.yml" 'text = text.replace("--config \"$FIREBASE_HOSTING_CI_CONFIG\"", "--config firebase.json", 1)'
expect_fail "raw firebase.json deploy fails" run_gate "$fixture"

fixture="$TMP_ROOT/predeploy-generated-config"
copy_base_fixture "$fixture"
cat > "$fixture/scripts/ci/write-firebase-hosting-ci-config.mjs" <<'MJS'
#!/usr/bin/env node
import { writeFileSync } from "node:fs";
const output = process.argv[process.argv.indexOf("--output") + 1];
writeFileSync(output, JSON.stringify({ hosting: [{ target: "marketing", public: "website/dist", predeploy: ["npm run build"] }] }));
MJS
expect_fail "generated config containing predeploy fails" run_gate "$fixture"

fixture="$TMP_ROOT/post-auth-website-verify"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-hosting.yml" 'text = text.replace("      - name: Deploy Hosting (marketing + console)", "      - name: Bad post-auth website verify\n        run: npm run verify --prefix website\n\n      - name: Deploy Hosting (marketing + console)", 1)'
expect_fail "post-auth website verify fails" run_gate "$fixture"

fixture="$TMP_ROOT/post-auth-console-build"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-hosting.yml" 'text = text.replace("      - name: Deploy Hosting (marketing + console)", "      - name: Bad post-auth console build\n        run: npm run build --prefix apps/console\n\n      - name: Deploy Hosting (marketing + console)", 1)'
expect_fail "post-auth console build fails" run_gate "$fixture"

fixture="$TMP_ROOT/post-auth-functions-build"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-production.yml" 'text = text.replace("      - name: Deploy Cloud Functions", "      - name: Bad post-auth functions build\n        run: npm run build --prefix functions\n\n      - name: Deploy Cloud Functions", 1)'
expect_fail "post-auth functions build fails" run_gate "$fixture"

fixture="$TMP_ROOT/post-auth-firestore-npm-ci"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-firestore.yml" 'text = text.replace("      - name: Deploy Firestore rules, indexes, and Storage rules", "      - name: Bad post-auth npm ci\n        run: npm ci --prefix functions\n\n      - name: Deploy Firestore rules, indexes, and Storage rules", 1)'
expect_fail "post-auth npm ci in firestore lane fails" run_gate "$fixture"

fixture="$TMP_ROOT/functions-predeploy-after-auth"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-production.yml" 'text = text.replace("--config \"$FIREBASE_FUNCTIONS_CI_CONFIG\"", "--config firebase.json", 1)'
expect_fail "functions predeploy after auth via raw config fails" run_gate "$fixture"

fixture="$TMP_ROOT/legacy-secrets"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-production.yml" 'text = text.replace("service_account: ${{ secrets.GCP_DEPLOY_SERVICE_ACCOUNT }}", "credentials_json: ${{ secrets.GCP_SA_KEY }}\n          service_account: ${{ secrets.GCP_DEPLOY_SERVICE_ACCOUNT }}", 1)'
expect_fail "reintroduced FIREBASE_TOKEN or credentials_json fails" run_gate "$fixture"

fixture="$TMP_ROOT/shared-sa-hosting"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-hosting.yml" 'text = text.replace("GCP_HOSTING_DEPLOY_SERVICE_ACCOUNT", "GCP_DEPLOY_SERVICE_ACCOUNT")'
expect_fail "shared deploy service account in hosting fails" run_gate "$fixture"

fixture="$TMP_ROOT/cloud-run-top-level-oidc"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-cloud-run.yml" 'text = text.replace("permissions:\n  contents: read\n", "permissions:\n  contents: read\n  id-token: write\n", 1)'
expect_fail "cloud run top-level oidc fails" run_gate "$fixture"

fixture="$TMP_ROOT/cloud-run-build-secret"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-cloud-run.yml" 'needle = "  build-hosted-mcp-artifact:\n    name: Build hosted MCP deploy artifact\n"; text = text.replace(needle, needle + "    env:\n      BAD_SECRET: ${{ secrets.GCP_DEPLOY_SERVICE_ACCOUNT }}\n", 1)'
expect_fail "cloud run build job secret fails" run_gate "$fixture"

fixture="$TMP_ROOT/cloud-run-deploy-checkout"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-cloud-run.yml" 'text = text.replace("      - name: Download deploy artifact", "      - uses: actions/checkout@93cb6efe18208431cddfb8368fd83d5badbf9bfd\n\n      - name: Download deploy artifact", 1)'
expect_fail "cloud run deploy checkout fails" run_gate "$fixture"

fixture="$TMP_ROOT/cloud-run-missing-ancestor"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-cloud-run.yml" 'text = text.replace("          if ! git merge-base --is-ancestor \"$commit\" origin/main; then", "          if false; then", 1)'
expect_fail "cloud run missing tag ancestry guard fails" run_gate "$fixture"

fixture="$TMP_ROOT/cloud-run-secret-upsert"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-cloud-run.yml" 'text = text.replace("OPENBURNBAR_HOSTED_MCP_ALLOW_SECRET_UPSERT: \"false\"", "OPENBURNBAR_HOSTED_MCP_ALLOW_SECRET_UPSERT: \"true\"", 1)'
expect_fail "cloud run secret upsert toggle fails" run_gate "$fixture"

artifact="$TMP_ROOT/special-artifact"
mkdir -p "$artifact"
printf 'ok\n' > "$artifact/index.html"
sha256sum "$artifact/index.html" | sed "s#  $artifact/#  #" > "$artifact/SHA256SUMS"
ln -s index.html "$artifact/symlink.html"
mkfifo "$artifact/pipe"
expect_fail "symlink or special-file artifact fails" bash "$VERIFY" --artifact-dir "$artifact"

echo "PASS: production deploy auth policy fixtures covered positive and negative controls."
