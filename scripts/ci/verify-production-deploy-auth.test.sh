#!/usr/bin/env bash
# Regression fixtures for scripts/ci/verify-production-deploy-auth.sh.
set -euo pipefail
SOURCE_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERIFY="$SOURCE_ROOT/scripts/ci/verify-production-deploy-auth.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

copy_base_fixture() {
  local dst="$1"
  mkdir -p "$dst/.github/workflows" "$dst/scripts/ci" "$dst/functions" "$dst/services/hosted-mcp"
  cp "$SOURCE_ROOT/.github/workflows/deploy-hosting.yml" "$dst/.github/workflows/deploy-hosting.yml"
  cp "$SOURCE_ROOT/.github/workflows/deploy-production.yml" "$dst/.github/workflows/deploy-production.yml"
  cp "$SOURCE_ROOT/.github/workflows/deploy-firestore.yml" "$dst/.github/workflows/deploy-firestore.yml"
  cp "$SOURCE_ROOT/.github/workflows/deploy-cloud-run.yml" "$dst/.github/workflows/deploy-cloud-run.yml"
  cp "$SOURCE_ROOT/firebase.json" "$dst/firebase.json"
  cp "$SOURCE_ROOT/firestore.rules" "$dst/firestore.rules"
  cp "$SOURCE_ROOT/firestore.indexes.json" "$dst/firestore.indexes.json"
  cp "$SOURCE_ROOT/storage.rules" "$dst/storage.rules"
  cp "$SOURCE_ROOT/services/hosted-mcp/Dockerfile" "$dst/services/hosted-mcp/Dockerfile"
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

fixture="$TMP_ROOT/post-auth-python-helper"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-production.yml" 'text = text.replace("      - name: Deploy Cloud Functions", "      - name: Bad post-auth Python helper\n        run: python3 scripts/ci/check_burnbar_release_preflight.py\n\n      - name: Deploy Cloud Functions", 1)'
expect_fail "post-auth Python repository helper fails" run_gate "$fixture"

fixture="$TMP_ROOT/post-auth-firestore-npm-ci"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-firestore.yml" 'text = text.replace("      - name: Deploy Firestore rules, indexes, and Storage rules", "      - name: Bad post-auth npm ci\n        run: npm ci --prefix functions\n\n      - name: Deploy Firestore rules, indexes, and Storage rules", 1)'
expect_fail "post-auth npm ci in firestore lane fails" run_gate "$fixture"

fixture="$TMP_ROOT/functions-predeploy-after-auth"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-production.yml" 'text = text.replace("--config \"$FIREBASE_FUNCTIONS_CI_CONFIG\"", "--config firebase.json", 1)'
expect_fail "functions predeploy after auth via raw config fails" run_gate "$fixture"

fixture="$TMP_ROOT/functions-forced-deploy"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-production.yml" 'text = text.replace("--non-interactive", "--non-interactive \\\n            --force", 1)'
expect_fail "functions forced deploy fails" run_gate "$fixture"

fixture="$TMP_ROOT/functions-missing-rules-first-readback"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-production.yml" 'text = text.replace("node scripts/ci/check-firestore-deploy-drift.mjs \"$FIREBASE_PROJECT\"", "echo rules-readback-skipped", 1)'
expect_fail "functions missing rules-first readback fails" run_gate "$fixture"

fixture="$TMP_ROOT/functions-raw-dispatch-tag"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-production.yml" 'text = text.replace("TAG=\"$INPUT_TAG\"", "TAG=\"${{ inputs.tag }}\"", 1)'
expect_fail "functions raw dispatch tag interpolation fails" run_gate "$fixture"

fixture="$TMP_ROOT/functions-missing-main-only-control"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-production.yml" 'text = text.replace("            if [[ \"$EVENT_NAME\" != \"workflow_dispatch\" || \"$GITHUB_REF\" != \"refs/heads/main\" || \"$REF_NAME\" != \"main\" ]]; then\n              echo \"::error::Manual release control must be dispatched from main; tag-selected reruns are forbidden.\"\n              exit 1\n            fi\n\n", "", 1)'
expect_fail "functions missing main-only release-control guard fails" run_gate "$fixture"

fixture="$TMP_ROOT/functions-missing-ancestor"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-production.yml" 'text = text.replace("          if ! git merge-base --is-ancestor \"$commit\" origin/main; then", "          if false; then", 1)'
expect_fail "functions missing tag ancestry guard fails" run_gate "$fixture"

fixture="$TMP_ROOT/functions-dispatch-ref-source-commit"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-production.yml" 'text = text.replace("OPENBURNBAR_SOURCE_COMMIT: ${{ needs.prepare-functions-deploy.outputs.commit }}", "OPENBURNBAR_SOURCE_COMMIT: ${{ github.sha }}", 1)'
expect_fail "functions source commit from dispatch ref fails" run_gate "$fixture"

fixture="$TMP_ROOT/functions-prepare-oidc"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-production.yml" 'needle = "      statuses: write\n"; text = text.replace(needle, needle + "      id-token: write\n", 1)'
expect_fail "functions prepare job OIDC fails" run_gate "$fixture"

fixture="$TMP_ROOT/functions-prepare-production-environment"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-production.yml" 'needle = "    timeout-minutes: 60\n"; text = text.replace(needle, needle + "    environment: production\n", 1)'
expect_fail "functions prepare production environment fails" run_gate "$fixture"

fixture="$TMP_ROOT/functions-deploy-checkout"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-production.yml" 'text = text.replace("      - name: Download immutable prepared deploy artifact", "      - uses: actions/checkout@93cb6efe18208431cddfb8368fd83d5badbf9bfd\n\n      - name: Download immutable prepared deploy artifact", 1)'
expect_fail "functions credentialed checkout fails" run_gate "$fixture"

fixture="$TMP_ROOT/functions-missing-artifact-checksum"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-production.yml" 'text = text.replace("sha256sum --check --strict SHA256SUMS", "echo checksum-skipped", 1)'
expect_fail "functions missing immutable artifact checksum fails" run_gate "$fixture"

fixture="$TMP_ROOT/functions-missing-event-sha-guard"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-production.yml" 'text = text.replace("            if [[ -n \"${GITHUB_SHA:-}\" && \"$commit\" != \"$GITHUB_SHA\" ]]; then", "            if false; then", 1)'
expect_fail "functions missing workflow event SHA guard fails" run_gate "$fixture"

fixture="$TMP_ROOT/functions-broken-rollback-routing"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-production.yml" 'text = text.replace("|| needs.authorize-domain-core-rollback.result == '"'"'success'"'"'", "|| true", 1)'
expect_fail "functions unprotected rollback routing fails" run_gate "$fixture"

fixture="$TMP_ROOT/legacy-secrets"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-production.yml" 'text = text.replace("service_account: ${{ secrets.GCP_DEPLOY_SERVICE_ACCOUNT }}", "credentials_json: ${{ secrets.GCP_SA_KEY }}\n          service_account: ${{ secrets.GCP_DEPLOY_SERVICE_ACCOUNT }}", 1)'
expect_fail "reintroduced FIREBASE_TOKEN or credentials_json fails" run_gate "$fixture"

fixture="$TMP_ROOT/shared-sa-hosting"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-hosting.yml" 'text = text.replace("GCP_HOSTING_DEPLOY_SERVICE_ACCOUNT", "GCP_DEPLOY_SERVICE_ACCOUNT")'
expect_fail "shared deploy service account in hosting fails" run_gate "$fixture"

fixture="$TMP_ROOT/hosting-legacy-token-auth"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-hosting.yml" 'text = text.replace("          FIREBASE_HOSTING_REST_ACCESS_TOKEN: ${{ steps.hosting_auth.outputs.access_token }}\n", "          FIREBASE_HOSTING_REST_ACCESS_TOKEN: ${{ steps.hosting_auth.outputs.access_token }}\n          FIREBASE_HOSTING_OIDC_ACCESS_TOKEN: ${{ steps.hosting_auth.outputs.access_token }}\n", 1).replace("          node \"$ARTIFACT_ROOT/scripts/ci/deploy-firebase-hosting-rest.mjs\" \\\n            --project burnbar \\\n            --config \"$FIREBASE_HOSTING_CI_CONFIG\" \\\n            --firebaserc \"$ARTIFACT_ROOT/.firebaserc\" \\\n            --message \"GitHub Actions ${GITHUB_SHA}\"", "          firebase deploy --only hosting --project burnbar --config \"$FIREBASE_HOSTING_CI_CONFIG\" --token \"$FIREBASE_HOSTING_OIDC_ACCESS_TOKEN\"", 1)'
expect_fail "hosting legacy Firebase token auth fails" run_gate "$fixture"

fixture="$TMP_ROOT/hosting-missing-rest-token-format"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-hosting.yml" 'text = text.replace("          token_format: access_token\n", "", 1)'
expect_fail "hosting missing REST token format fails" run_gate "$fixture"

fixture="$TMP_ROOT/hosting-missing-rest-token-env"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-hosting.yml" 'text = text.replace("          FIREBASE_HOSTING_REST_ACCESS_TOKEN: ${{ steps.hosting_auth.outputs.access_token }}\n", "")'
expect_fail "hosting missing REST token env fails" run_gate "$fixture"

fixture="$TMP_ROOT/hosting-config-outside-artifact-root"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-hosting.yml" 'text = text.replace("${{ runner.temp }}/hosting-artifact/firebase-hosting.ci.json", "${{ runner.temp }}/firebase-hosting.ci.json")'
expect_fail "hosting config outside artifact root fails" run_gate "$fixture"

fixture="$TMP_ROOT/hosting-node24-firebase-cli"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-hosting.yml" 'text = text.replace("node-version: 22", "node-version: 24", 1); text = text.replace("node-version-file: .nvmrc", "node-version: 24", 1)'
expect_fail "hosting REST deployer under Node 24 fails" run_gate "$fixture"

fixture="$TMP_ROOT/cloud-run-top-level-oidc"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-cloud-run.yml" 'text = text.replace("permissions:\n  contents: read\n", "permissions:\n  contents: read\n  id-token: write\n", 1)'
expect_fail "cloud run top-level oidc fails" run_gate "$fixture"

fixture="$TMP_ROOT/cloud-run-build-secret"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-cloud-run.yml" 'needle = "  build-hosted-mcp-artifact:\n    name: Build hosted MCP deploy artifact\n"; text = text.replace(needle, needle + "    env:\n      BAD_SECRET: ${{ secrets.GCP_DEPLOY_SERVICE_ACCOUNT }}\n", 1)'
expect_fail "cloud run build job secret fails" run_gate "$fixture"

fixture="$TMP_ROOT/cloud-run-mutable-base"
copy_base_fixture "$fixture"
mutate_file "$fixture" "services/hosted-mcp/Dockerfile" 'import re; text = re.sub(r"(node:22-bookworm-slim)@sha256:[a-f0-9]{64}", r"\1", text)'
expect_fail "cloud run mutable Docker base fails" run_gate "$fixture"

fixture="$TMP_ROOT/cloud-run-base-mismatch"
copy_base_fixture "$fixture"
mutate_file "$fixture" "services/hosted-mcp/Dockerfile" 'import re; text = re.sub(r"sha256:[a-f0-9]{64}", "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", text, count=1)'
expect_fail "cloud run Docker stage digest mismatch fails" run_gate "$fixture"

fixture="$TMP_ROOT/cloud-run-prime-mismatch"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-cloud-run.yml" 'import re; text = re.sub(r"sha256:[a-f0-9]{64}", "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", text, count=1)'
expect_fail "cloud run primed base digest mismatch fails" run_gate "$fixture"

fixture="$TMP_ROOT/cloud-run-deploy-checkout"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-cloud-run.yml" 'text = text.replace("      - name: Download deploy artifact", "      - uses: actions/checkout@93cb6efe18208431cddfb8368fd83d5badbf9bfd\n\n      - name: Download deploy artifact", 1)'
expect_fail "cloud run deploy checkout fails" run_gate "$fixture"

fixture="$TMP_ROOT/cloud-run-artifact-deploy-driver"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-cloud-run.yml" 'text = text.replace("            scripts/build-signal-envelope-contracts.sh \\\n", "            scripts/build-signal-envelope-contracts.sh \\\n            scripts/deploy-hosted-mcp.sh \\\n", 1)'
expect_fail "cloud run artifact deploy driver fails" run_gate "$fixture"

fixture="$TMP_ROOT/cloud-run-post-auth-artifact-driver"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-cloud-run.yml" 'text = text.replace("gcloud builds submit \"$DEPLOY_SOURCE_DIR\"", "bash \"$DEPLOY_SOURCE_DIR/scripts/deploy-hosted-mcp.sh\"", 1)'
expect_fail "cloud run post-auth artifact driver fails" run_gate "$fixture"

fixture="$TMP_ROOT/cloud-run-missing-ancestor"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-cloud-run.yml" 'text = text.replace("          if ! git merge-base --is-ancestor \"$commit\" origin/main; then", "          if false; then", 1)'
expect_fail "cloud run missing tag ancestry guard fails" run_gate "$fixture"

fixture="$TMP_ROOT/cloud-run-missing-main-only-control"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-cloud-run.yml" 'text = text.replace("            if [[ \"$EVENT_NAME\" != \"workflow_dispatch\" || \"$GITHUB_REF\" != \"refs/heads/main\" || \"$REF_NAME\" != \"main\" ]]; then\n              echo \"::error::Manual release control must be dispatched from main; tag-selected reruns are forbidden.\"\n              exit 1\n            fi\n\n", "", 1)'
expect_fail "cloud-run missing main-only release-control guard fails" run_gate "$fixture"

fixture="$TMP_ROOT/cloud-run-loose-tag-grammar"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-cloud-run.yml" 'text = text.replace("^v[0-9]{1,3}\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?(\\+[0-9A-Za-z.-]+)?$", "^v[0-9][0-9A-Za-z._-]*$", 1)'
expect_fail "cloud run loose tag grammar fails" run_gate "$fixture"

fixture="$TMP_ROOT/cloud-run-accessor-only"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-cloud-run.yml" 'text = text.replace("roles/secretmanager.viewer", "roles/secretmanager.metadataReader_removed", 1)'
expect_fail "cloud run secret metadata role missing fails" run_gate "$fixture"

fixture="$TMP_ROOT/cloud-run-project-wide-payload-required"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-cloud-run.yml" 'text = text.replace("metadata_only_roles = {\n              \"roles/secretmanager.viewer\",", "metadata_only_roles = {\n              \"roles/secretmanager.viewer\",\n              \"roles/secretmanager.secretAccessor\",", 1)'
expect_fail "cloud run project-wide payload role requirement fails" run_gate "$fixture"

fixture="$TMP_ROOT/cloud-run-project-wide-payload-not-forbidden"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-cloud-run.yml" 'text = text.replace("              \"roles/secretmanager.secretAccessor\",\n", "", 1)'
expect_fail "cloud run missing project-wide payload denylist fails" run_gate "$fixture"

fixture="$TMP_ROOT/cloud-run-runtime-secret-iam-check"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-cloud-run.yml" 'text = text.replace("            verify_runtime_secret_accessor \"$SECRET_NAME\"\n", "", 1)'
expect_fail "cloud run missing runtime secret accessor check fails" run_gate "$fixture"

fixture="$TMP_ROOT/cloud-run-signer-secret-env"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-cloud-run.yml" 'text = text.replace("          OPENBURNBAR_CORRESPONDING_SOURCE_URL: https://burnbar.ai/legal/source\n", "          OPENBURNBAR_CORRESPONDING_SOURCE_URL: https://burnbar.ai/legal/source\n          REMOTE_MCP_TOKEN_HMAC_SECRET: ${{ secrets.REMOTE_MCP_TOKEN_HMAC_SECRET }}\n", 1)'
expect_fail "cloud run signer secret env injection fails" run_gate "$fixture"

fixture="$TMP_ROOT/cloud-run-secret-write-command"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-cloud-run.yml" 'text = text.replace("          build_output=\"$(gcloud builds submit", "          gcloud secrets versions add REMOTE_MCP_TOKEN_HMAC_SECRET --data-file=- --project \"$GOOGLE_CLOUD_PROJECT\"\n          build_output=\"$(gcloud builds submit", 1)'
expect_fail "cloud run secret write command fails" run_gate "$fixture"

fixture="$TMP_ROOT/cloud-run-secret-write-role"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-cloud-run.yml" 'text = text.replace("roles/secretmanager.secretVersionAdder", "roles/secretmanager.versionWriter_removed", 1)'
expect_fail "cloud run missing secret write-role denylist fails" run_gate "$fixture"

fixture="$TMP_ROOT/cloud-run-unreachable-failure-issue"
copy_base_fixture "$fixture"
mutate_file "$fixture" ".github/workflows/deploy-cloud-run.yml" 'text = text.replace("if: ${{ always() && needs.deploy-hosted-mcp.result != '"'"'success'"'"' }}", "if: ${{ needs.deploy-hosted-mcp.result != '"'"'success'"'"' }}", 1)'
expect_fail "cloud run unreachable failure issue fails" run_gate "$fixture"

artifact="$TMP_ROOT/special-artifact"
mkdir -p "$artifact"
printf 'ok\n' > "$artifact/index.html"
sha256sum "$artifact/index.html" | sed "s#  $artifact/#  #" > "$artifact/SHA256SUMS"
ln -s index.html "$artifact/symlink.html"
mkfifo "$artifact/pipe"
expect_fail "symlink or special-file artifact fails" bash "$VERIFY" --artifact-dir "$artifact"

echo "PASS: production deploy auth policy fixtures covered positive and negative controls."
