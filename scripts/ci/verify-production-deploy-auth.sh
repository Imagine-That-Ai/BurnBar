#!/usr/bin/env bash
# Static policy gate for production Firebase deploy boundaries.
set -euo pipefail

DEFAULT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ROOT="${OPENBURNBAR_DEPLOY_AUTH_REPO:-$DEFAULT_ROOT}"
cd "$ROOT"

python3 - "$@" <<'PY'
from __future__ import annotations

import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path.cwd()
ARGS = sys.argv[1:]
WORKFLOWS = {
    "deploy-production": Path(".github/workflows/deploy-production.yml"),
    "deploy-hosting": Path(".github/workflows/deploy-hosting.yml"),
    "deploy-firestore": Path(".github/workflows/deploy-firestore.yml"),
    "deploy-cloud-run": Path(".github/workflows/deploy-cloud-run.yml"),
}
LEGACY_SECRET_RE = re.compile(
    r"\b(?:GCP_SA_KEY|GOOGLE_PLAY_SERVICE_ACCOUNT_JSON|FIREBASE_TOKEN|credentials_json)\b"
)
POST_AUTH_FORBIDDEN_RE = re.compile(
    r"(?im)(?:^|\s)(npm|npx)\s|npm\s+exec|npm\s+ci|npm\s+run|bash\s+scripts/|python(?:3(?:\.\d+)?)?\s+(?:\./)?scripts/|\./scripts/|uses:\s*\./"
)
DEPLOY_RE = re.compile(r"(?s)(\bfirebase\s+deploy\b|FIREBASE_TOOLS_BIN[^\n]*\bdeploy\b)")


def fail(message: str) -> None:
    FAILURES.append(message)


def read(path: Path) -> str:
    if not path.is_file():
        fail(f"{path} is missing")
        return ""
    return path.read_text(encoding="utf-8")


def top_level_text(text: str) -> str:
    marker = re.search(r"(?m)^jobs:\s*$", text)
    return text[: marker.start()] if marker else text


def extract_jobs(text: str) -> dict[str, str]:
    lines = text.splitlines()
    jobs_start = None
    for index, line in enumerate(lines):
        if line == "jobs:":
            jobs_start = index + 1
            break
    if jobs_start is None:
        return {}

    jobs: dict[str, list[str]] = {}
    current: str | None = None
    for line in lines[jobs_start:]:
        match = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
        if match:
            current = match.group(1)
            jobs[current] = [line]
            continue
        if current is not None:
            jobs[current].append(line)
    return {name: "\n".join(job_lines) for name, job_lines in jobs.items()}


def extract_steps(job_text: str) -> list[str]:
    lines = job_text.splitlines()
    steps: list[list[str]] = []
    current: list[str] | None = None
    for line in lines:
        if re.match(r"^      - (?:name|uses|run):", line):
            current = [line]
            steps.append(current)
        elif current is not None:
            current.append(line)
    return ["\n".join(step) for step in steps]


def step_label(step: str) -> str:
    match = re.search(r"(?m)^\s+- name:\s*(.+)$", step)
    if match:
        return match.group(1).strip()
    match = re.search(r"(?m)^\s+- uses:\s*(.+)$", step)
    if match:
        return match.group(1).strip()
    return step.splitlines()[0].strip() if step else "<unknown>"


def command_text(step: str) -> str:
    lines = []
    for line in step.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or stripped.startswith("echo "):
            continue
        if re.match(r"^- name:", stripped) or re.match(r"^name:", stripped):
            continue
        lines.append(line)
    return "\n".join(lines)


def contains_predeploy(value: object) -> bool:
    if isinstance(value, dict):
        return any(key == "predeploy" or contains_predeploy(child) for key, child in value.items())
    if isinstance(value, list):
        return any(contains_predeploy(child) for child in value)
    return False


def validate_generated_configs() -> None:
    generator = Path("scripts/ci/write-firebase-hosting-ci-config.mjs")
    firebase_json_path = Path("firebase.json")
    if not generator.is_file():
        fail("scripts/ci/write-firebase-hosting-ci-config.mjs is missing")
        return
    if not firebase_json_path.is_file():
        fail("firebase.json is missing")
        return

    firebase_json = json.loads(firebase_json_path.read_text(encoding="utf-8"))
    if not contains_predeploy(firebase_json):
        return

    with tempfile.TemporaryDirectory(prefix="obb-firebase-ci-config-") as tempdir:
        temp = Path(tempdir)
        for mode in ("hosting", "functions", "firestore"):
            output = temp / f"firebase-{mode}.ci.json"
            command = [
                "node",
                str(generator),
                "--mode",
                mode,
                "--output",
                str(output),
                "--check",
            ]
            if mode == "hosting":
                command.extend(["--manifest", str(temp / "firebase-hosting-public-dirs.json")])
            result = subprocess.run(
                command,
                cwd=ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
            )
            if result.returncode != 0:
                fail(f"{generator} --mode {mode} failed:\n{result.stdout.strip()}")
                continue
            generated = json.loads(output.read_text(encoding="utf-8"))
            if contains_predeploy(generated):
                fail(f"generated {output.name} contains predeploy")


def validate_workflow(name: str, path: Path, text: str) -> None:
    if LEGACY_SECRET_RE.search(text):
        fail(f"{path} references legacy long-lived deploy secrets or credentials_json")

    for marker in ("id-token: write", "google-github-actions/auth", "workload_identity_provider", "GCP_WORKLOAD_IDENTITY_PROVIDER", "GOOGLE_APPLICATION_CREDENTIALS"):
        if marker not in text:
            fail(f"{path} does not contain required WIF marker: {marker}")

    expected_service_account = (
        "GCP_HOSTING_DEPLOY_SERVICE_ACCOUNT" if name == "deploy-hosting" else "GCP_DEPLOY_SERVICE_ACCOUNT"
    )
    if expected_service_account not in text:
        fail(f"{path} does not use expected service account secret {expected_service_account}")
    if name == "deploy-hosting" and "GCP_DEPLOY_SERVICE_ACCOUNT" in text:
        fail(f"{path} must not use shared GCP_DEPLOY_SERVICE_ACCOUNT for hosting")

    jobs = extract_jobs(text)
    if not jobs:
        fail(f"{path} does not define jobs")
        return

    for job_name, job_text in jobs.items():
        steps = extract_steps(job_text)
        auth_indexes = [index for index, step in enumerate(steps) if "google-github-actions/auth" in step]
        if not auth_indexes:
            continue
        first_auth = auth_indexes[0]
        for step in steps[first_auth + 1 :]:
            if POST_AUTH_FORBIDDEN_RE.search(step):
                fail(
                    f"{path} job {job_name} runs forbidden repo/npm command after Google auth in step {step_label(step)!r}"
                )
        for step in steps:
            executable = command_text(step)
            if DEPLOY_RE.search(executable):
                if "--config" not in step:
                    fail(f"{path} job {job_name} deploy step {step_label(step)!r} omits --config")
                if re.search(r"--config\s+['\"]?firebase\.json['\"]?", step):
                    fail(f"{path} job {job_name} deploy step {step_label(step)!r} uses raw firebase.json")
                if "npm --prefix functions exec -- firebase deploy" in step:
                    fail(f"{path} job {job_name} deploy step {step_label(step)!r} uses npm exec firebase deploy")
                if re.search(r"(?m)(?:^|\s)--force(?:\s|$)", executable):
                    fail(f"{path} job {job_name} deploy step {step_label(step)!r} must not pass --force")

    if "firebase deploy" in text and "--config firebase.json" in text:
        fail(f"{path} contains firebase deploy against raw firebase.json")


def validate_hosting(text: str) -> None:
    path = WORKFLOWS["deploy-hosting"]
    top = top_level_text(text)
    if "id-token: write" in top:
        fail(f"{path} grants id-token:write at top level; only deploy-hosting may grant it")
    if "issues: write" in top:
        fail(f"{path} grants issues:write at top level; only the smoke/result job may grant it")

    jobs = extract_jobs(text)
    build_job = jobs.get("build-hosting-artifacts")
    deploy_job = jobs.get("deploy-hosting")
    result_job = jobs.get("hosting-smoke-result")
    if not build_job:
        fail(f"{path} must define build-hosting-artifacts")
    if not deploy_job:
        fail(f"{path} must define deploy-hosting")
    if not result_job:
        fail(f"{path} must define hosting-smoke-result")
    if not build_job or not deploy_job:
        return

    if "needs: build-hosting-artifacts" not in deploy_job:
        fail(f"{path} deploy-hosting must need build-hosting-artifacts")
    if "environment: production" not in deploy_job:
        fail(f"{path} deploy-hosting must be the only production-environment hosting job")
    if "id-token: write" not in deploy_job:
        fail(f"{path} deploy-hosting must grant id-token:write")
    if "service_account: ${{ secrets.GCP_HOSTING_DEPLOY_SERVICE_ACCOUNT }}" not in deploy_job:
        fail(f"{path} deploy-hosting must authenticate as GCP_HOSTING_DEPLOY_SERVICE_ACCOUNT")
    if "id: hosting_auth" not in deploy_job:
        fail(f"{path} deploy-hosting auth step must expose outputs through id: hosting_auth")
    if "node-version: 22" not in deploy_job and "node-version-file: .nvmrc" not in deploy_job:
        fail(f"{path} deploy-hosting must run the Hosting REST deployer under Node 22 (node-version: 22 or node-version-file: .nvmrc)")
    if "          token_format: access_token" not in deploy_job:
        fail(f"{path} deploy-hosting must request a WIF access token for the Hosting REST API")
    if "FIREBASE_HOSTING_REST_ACCESS_TOKEN: ${{ steps.hosting_auth.outputs.access_token }}" not in deploy_job:
        fail(f"{path} deploy-hosting must pass the WIF access token only to the Hosting REST deployer")
    if "FIREBASE_HOSTING_OIDC_ACCESS_TOKEN" in deploy_job:
        fail(f"{path} deploy-hosting must not pass WIF access tokens through Firebase CLI legacy token auth")
    if re.search(r"(?m)(?:^|\s)--token(?:\s|$)", deploy_job):
        fail(f"{path} deploy-hosting must not use Firebase CLI --token")
    if "firebase deploy" in deploy_job:
        fail(f"{path} deploy-hosting must not use Firebase CLI deploy auth")
    if "deploy-firebase-hosting-rest.mjs" not in deploy_job:
        fail(f"{path} deploy-hosting must use the artifact-bundled Hosting REST deployer")
    if '--config "$FIREBASE_HOSTING_CI_CONFIG"' not in deploy_job:
        fail(f"{path} deploy-hosting REST deployer must use the generated artifact-root CI config")
    if '--firebaserc "$ARTIFACT_ROOT/.firebaserc"' not in deploy_job:
        fail(f"{path} deploy-hosting REST deployer must use the artifact-root .firebaserc")
    if re.search(r"--config\s+['\"]?firebase\.json['\"]?", deploy_job):
        fail(f"{path} deploy-hosting must not deploy with raw firebase.json")
    if "FIREBASE_HOSTING_CI_CONFIG: ${{ runner.temp }}/hosting-artifact/firebase-hosting.ci.json" not in deploy_job:
        fail(f"{path} deploy-hosting must keep firebase-hosting.ci.json under the artifact root so .firebaserc targets resolve")
    if "actions/checkout" in deploy_job:
        fail(f"{path} deploy-hosting must not check out repository code")
    if "uses: ./.github/actions" in deploy_job:
        fail(f"{path} deploy-hosting must not use local actions")
    if "id-token: write" in build_job:
        fail(f"{path} build-hosting-artifacts must not grant id-token:write")
    if "environment:" in build_job:
        fail(f"{path} build-hosting-artifacts must not bind the production environment")
    if "secrets." in build_job:
        fail(f"{path} build-hosting-artifacts must not reference secrets")
    for marker in (
        "sha256sum -c SHA256SUMS",
        "-type l",
        "-links +1",
        "node_modules",
        "credential",
        "firebase-hosting.ci.json",
        "FIREBASE_HOSTING_REST_ACCESS_TOKEN",
    ):
        if marker not in deploy_job:
            fail(f"{path} deploy-hosting is missing artifact/config guard marker {marker!r}")
    if result_job and "id-token: write" in result_job:
        fail(f"{path} hosting-smoke-result must not grant id-token:write")
    if result_job and "issues: write" not in result_job:
        fail(f"{path} hosting-smoke-result must own issues:write for ops-failure issues")


def validate_cloud_run(text: str) -> None:
    path = WORKFLOWS["deploy-cloud-run"]
    top = top_level_text(text)
    if "id-token: write" in top:
        fail(f"{path} grants id-token:write at top level; only deploy-hosted-mcp may grant it")
    if "issues: write" in top:
        fail(f"{path} grants issues:write at top level; only cloud-run-deploy-result may grant it")

    jobs = extract_jobs(text)
    resolve_job = jobs.get("resolve-release")
    build_job = jobs.get("build-hosted-mcp-artifact")
    deploy_job = jobs.get("deploy-hosted-mcp")
    result_job = jobs.get("cloud-run-deploy-result")
    dry_run_job = jobs.get("cloud-run-dry-run-summary")

    for required_job, job_text in (
        ("resolve-release", resolve_job),
        ("build-hosted-mcp-artifact", build_job),
        ("deploy-hosted-mcp", deploy_job),
        ("cloud-run-deploy-result", result_job),
        ("cloud-run-dry-run-summary", dry_run_job),
    ):
        if not job_text:
            fail(f"{path} must define {required_job}")

    if not resolve_job or not build_job or not deploy_job or not result_job:
        return

    for marker in (
        "tag_ref=\"refs/tags/${TAG}\"",
        'if [[ "$EVENT_NAME" != "workflow_dispatch" || "$GITHUB_REF" != "refs/heads/main" || "$REF_NAME" != "main" ]]; then',
        "tag-selected dispatches and reruns are forbidden",
        'if [[ "$EVENT_NAME" != "push" || "$GITHUB_REF" != "$tag_ref" ]]; then',
        '--control-sha "$GITHUB_SHA"',
        "git fetch --force --tags origin \"+${tag_ref}:${tag_ref}\"",
        "git merge-base --is-ancestor \"$commit\" origin/main",
        "[[ ! \"$TAG\" =~ ^v[0-9]{1,3}\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?(\\+[0-9A-Za-z.-]+)?$ ]]",
    ):
        if marker not in resolve_job:
            fail(f"{path} resolve-release is missing release tag provenance guard marker {marker!r}")
    if '"${{ inputs.tag }}"' in resolve_job or "'${{ inputs.tag }}'" in resolve_job:
        fail(f"{path} resolve-release must pass workflow_dispatch tag input through env, not interpolate it into shell")

    if "id-token: write" in build_job:
        fail(f"{path} build-hosted-mcp-artifact must not grant id-token:write")
    if "environment:" in build_job:
        fail(f"{path} build-hosted-mcp-artifact must not bind the production environment")
    if "secrets." in build_job:
        fail(f"{path} build-hosted-mcp-artifact must not reference secrets")
    if "scripts/deploy-hosted-mcp.sh" in build_job:
        fail(f"{path} build-hosted-mcp-artifact must not package the post-auth deploy driver")
    for marker in (
        "npm ci --prefix services/hosted-mcp",
        "npm --prefix services/hosted-mcp test",
        "docker build -f services/hosted-mcp/Dockerfile",
        "sha256sum > \"$manifest\"",
        "mv \"$manifest\" SHA256SUMS",
        "actions/upload-artifact@",
    ):
        if marker not in build_job:
            fail(f"{path} build-hosted-mcp-artifact is missing artifact guard marker {marker!r}")

    dockerfile_path = Path("services/hosted-mcp/Dockerfile")
    dockerfile = read(dockerfile_path)
    base_images = re.findall(r"(?m)^FROM\s+(node:22-bookworm-slim@sha256:[a-f0-9]{64})(?:\s|$)", dockerfile)
    all_from_lines = re.findall(r"(?m)^FROM\s+([^\s]+)", dockerfile)
    if len(base_images) != 2 or len(all_from_lines) != 2:
        fail(f"{dockerfile_path} must pin both build stages to node:22-bookworm-slim by sha256 digest")
    elif len(set(base_images)) != 1:
        fail(f"{dockerfile_path} build and runtime stages must use the same immutable base digest")
    else:
        pinned_base = base_images[0]
        if f'image="{pinned_base}"' not in build_job:
            fail(f"{path} must prime the exact immutable base used by {dockerfile_path}")

    if "needs:" not in deploy_job or "build-hosted-mcp-artifact" not in deploy_job:
        fail(f"{path} deploy-hosted-mcp must need build-hosted-mcp-artifact")
    if "environment: production" not in deploy_job:
        fail(f"{path} deploy-hosted-mcp must bind the production environment")
    if "id-token: write" not in deploy_job:
        fail(f"{path} deploy-hosted-mcp must grant id-token:write")
    if "issues: write" in deploy_job:
        fail(f"{path} deploy-hosted-mcp must not grant issues:write")
    if "actions/checkout" in deploy_job:
        fail(f"{path} deploy-hosted-mcp must not check out repository code")
    if "uses: ./.github/actions" in deploy_job:
        fail(f"{path} deploy-hosted-mcp must not use local actions")
    if "$DEPLOY_SOURCE_DIR/scripts/deploy-hosted-mcp.sh" in deploy_job:
        fail(f"{path} deploy-hosted-mcp must not execute a deploy driver from the downloaded artifact")
    if "gcloud secrets create" in deploy_job or "gcloud secrets versions add" in deploy_job:
        fail(f"{path} deploy-hosted-mcp must not write Secret Manager values after auth")
    for marker in (
        "REMOTE_MCP_TOKEN_HMAC_SECRET: ${{ secrets.",
        "REMOTE_MCP_TOKEN_ED25519_PRIVATE_KEY_BASE64: ${{ secrets.",
        "MCP_TOKEN_ED25519_PUBLIC_KEY_BASE64: ${{ secrets.",
    ):
        if marker in deploy_job:
            fail(f"{path} deploy-hosted-mcp must not inject signer secret values via {marker.split(':', 1)[0]}")
    for marker in (
        "actions/download-artifact@",
        "sha256sum -c SHA256SUMS",
        "Deploy artifact must not carry the post-auth deploy driver.",
        "-type l",
        "-links +1",
        "DEPLOY_SOURCE_DIR",
        "gcloud builds submit \"$DEPLOY_SOURCE_DIR\"",
        "--config \"$DEPLOY_SOURCE_DIR/services/hosted-mcp/cloudbuild.yaml\"",
        "gcloud run deploy \"$SERVICE\"",
        "gcloud run services update-traffic \"$SERVICE\"",
        "roles/secretmanager.admin",
        "roles/secretmanager.secretAccessor",
        "roles/secretmanager.secretVersionAdder",
        "roles/secretmanager.secretVersionManager",
        "metadata_only_roles",
        "roles/secretmanager.viewer",
        "project-wide Secret Manager payload/write roles",
        "CLOUD_RUN_RUNTIME_SERVICE_ACCOUNT",
        "runtime_service_account",
        "Cloud Run service must pin an explicit runtime service account",
        "gcloud secrets get-iam-policy",
        "serviceAccount:{runtime_service_account}",
        "per-secret roles/secretmanager.secretAccessor",
        "verify_runtime_secret_accessor \"$SECRET_NAME\"",
        "verify_runtime_secret_accessor \"$ED25519_PRIVATE_SECRET_NAME\"",
        "verify_runtime_secret_accessor \"$ED25519_PUBLIC_SECRET_NAME\"",
        "for forbidden_secret_env in",
        "Production Cloud Run deploy must not receive signer secret values",
        "must have read-only Secret Manager metadata access",
    ):
        if marker not in deploy_job:
            fail(f"{path} deploy-hosted-mcp is missing deploy boundary marker {marker!r}")
    if not re.search(r"forbidden\s*=\s*\{[^}]*roles/secretmanager\.secretAccessor", deploy_job, re.S):
        fail(f"{path} deploy-hosted-mcp must forbid project-wide roles/secretmanager.secretAccessor on the deploy service account")
    if re.search(r"metadata_only_roles\s*=\s*\{[^}]*roles/secretmanager\.secretAccessor", deploy_job, re.S):
        fail(f"{path} deploy-hosted-mcp must not require project-wide Secret Manager payload access for the deploy service account")

    if "id-token: write" in result_job:
        fail(f"{path} cloud-run-deploy-result must not grant id-token:write")
    if "issues: write" not in result_job:
        fail(f"{path} cloud-run-deploy-result must own issues:write for ops-failure issues")
    if "if: ${{ always() && needs.deploy-hosted-mcp.result != 'success' }}" not in result_job:
        fail(f"{path} cloud-run-deploy-result must record deploy failures with always() so the issue step still runs after the fail-fast step")


def validate_production_functions(text: str) -> None:
    path = WORKFLOWS["deploy-production"]
    jobs = extract_jobs(text)
    authorization_job = jobs.get("authorize-domain-core-rollback")
    prepare_job = jobs.get("prepare-functions-deploy")
    deploy_job = jobs.get("deploy-functions")
    if not prepare_job:
        fail(f"{path} must define prepare-functions-deploy")
    if not deploy_job:
        fail(f"{path} must define deploy-functions")
    if not authorization_job:
        fail(f"{path} must define authorize-domain-core-rollback")
    if not authorization_job or not prepare_job or not deploy_job:
        return

    for marker in (
        "needs: prepare-functions-deploy",
        "needs.prepare-functions-deploy.result == 'success'",
        "needs.prepare-functions-deploy.outputs.dry_run != 'true'",
        "needs.prepare-functions-deploy.outputs.domain_core_profile == 'public-production-rollback'",
        "environment: domain-core-promotion",
    ):
        if marker not in authorization_job:
            fail(f"{path} rollback authorization job is missing {marker!r}")
    if "needs: authorize-domain-core-rollback" in prepare_job:
        fail(f"{path} prepare-functions-deploy must run before protected rollback authorization")
    for marker in (
        "default: public-production",
        "- public-production",
        "- public-production-rollback",
    ):
        if marker not in text:
            fail(f"{path} signed profile input is missing {marker!r}")

    for marker in (
        "EVENT_NAME: ${{ github.event_name }}",
        "INPUT_TAG: ${{ inputs.tag }}",
        "INPUT_DRY_RUN: ${{ inputs.dry_run }}",
        "INPUT_EXISTING_TAG_RETRY: ${{ inputs.existing_tag_retry }}",
        'tag_ref="refs/tags/${TAG}"',
        'if [[ "$EVENT_NAME" != "workflow_dispatch" || "$GITHUB_REF" != "refs/heads/main" || "$REF_NAME" != "main" ]]; then',
        "tag-selected dispatches and reruns are forbidden",
        'if [[ "$EVENT_NAME" != "push" || "$GITHUB_REF" != "$tag_ref" ]]; then',
        '--control-sha "$GITHUB_SHA"',
        'git fetch --force --tags origin "+${tag_ref}:${tag_ref}"',
        'git fetch --force origin "+refs/heads/main:refs/remotes/origin/main"',
        'git rev-list -n 1 "${tag_ref}^{commit}"',
        'if [[ -n "${GITHUB_SHA:-}" && "$commit" != "$GITHUB_SHA" ]]; then',
        'git merge-base --is-ancestor "$commit" origin/main',
        'git checkout --detach "$commit"',
        "node scripts/ci/prepare-functions-runtime-package.mjs",
        '--functions-dir "$stage/functions"',
    ):
        if marker not in prepare_job:
            fail(f"{path} prepare-functions-deploy is missing release tag provenance guard marker {marker!r}")

    for forbidden in (
        "environment: production",
        "id-token: write",
        "secrets.",
        "google-github-actions/auth@",
    ):
        if forbidden in prepare_job:
            fail(f"{path} prepare-functions-deploy must not contain {forbidden!r}")

    for marker in (
        "needs: [prepare-functions-deploy, authorize-domain-core-rollback]",
        "needs.authorize-domain-core-rollback.result == 'success'",
        "environment: production",
        "id-token: write",
        "actions/download-artifact@",
        "Verify immutable prepared deploy artifact",
        "sha256sum --check --strict SHA256SUMS",
        "find \"$stage\" -type l",
        "find \"$stage\" -type f -links +1",
        "chmod 0700 sentry-cli/node_modules/@sentry/cli/bin/sentry-cli",
        "OPENBURNBAR_SOURCE_COMMIT: ${{ needs.prepare-functions-deploy.outputs.commit }}",
    ):
        if marker not in deploy_job:
            fail(f"{path} deploy-functions is missing immutable deploy boundary marker {marker!r}")

    if "actions/checkout@" in deploy_job or "uses: ./" in deploy_job:
        fail(f"{path} credentialed deploy-functions must not check out or invoke local actions")
    if re.search(r"\bnpm\s+(?:ci|install|run|exec)\b", deploy_job):
        fail(f"{path} credentialed deploy-functions must consume prepared tools without npm")
    if "needs.prepare-functions-deploy.outputs.dry_run != 'true'" not in deploy_job:
        fail(f"{path} deploy-functions must be skipped for dry runs")

    for marker in (
        "google-github-actions/setup-gcloud@",
        "Require matching rules before Functions deploy",
        'node scripts/ci/check-firestore-deploy-drift.mjs "$FIREBASE_PROJECT"',
        "Verify parity-critical Linux callables deployed",
        "functions:list",
        '--project "$FIREBASE_PROJECT"',
        "--json",
        "node scripts/ci/verify-production-function-catalog.mjs --input",
    ):
        if marker not in deploy_job:
            fail(f"{path} deploy-functions is missing rules-first deploy guard marker {marker!r}")

    if '"${{ inputs.tag }}"' in prepare_job or "'${{ inputs.tag }}'" in prepare_job:
        fail(f"{path} prepare-functions-deploy must pass workflow_dispatch tag input through env, not interpolate it into shell")
    if "OPENBURNBAR_SOURCE_COMMIT: ${{ github.sha }}" in deploy_job:
        fail(f"{path} deploy-functions must publish the resolved release tag commit, not the workflow dispatch ref sha")


def validate_artifact_dir(path: Path) -> int:
    failures: list[str] = []
    if not path.is_dir():
        print(f"FAIL: artifact dir {path} is missing", file=sys.stderr)
        return 1

    for root, dirs, files in os.walk(path, topdown=True, followlinks=False):
        root_path = Path(root)
        entries = dirs + files
        for name in entries:
            entry = root_path / name
            rel = entry.relative_to(path).as_posix()
            try:
                mode = entry.lstat().st_mode
            except OSError as error:
                failures.append(f"{rel}: cannot lstat ({error})")
                continue
            if stat.S_ISLNK(mode):
                failures.append(f"{rel}: symlink")
            elif stat.S_ISBLK(mode) or stat.S_ISCHR(mode) or stat.S_ISFIFO(mode) or stat.S_ISSOCK(mode):
                failures.append(f"{rel}: special file")
            elif stat.S_ISREG(mode) and entry.stat().st_nlink > 1:
                failures.append(f"{rel}: hardlinked file")
            parts = rel.split("/")
            lower_rel = rel.lower()
            if "node_modules" in parts or name == ".env" or name.startswith(".env.") or "credential" in lower_rel:
                failures.append(f"{rel}: forbidden env/credential/node_modules entry")

    manifest = path / "SHA256SUMS"
    if not manifest.is_file():
        failures.append("SHA256SUMS: missing")
    else:
        for line_no, line in enumerate(manifest.read_text(encoding="utf-8").splitlines(), start=1):
            match = re.match(r"^([a-fA-F0-9]{64})  (.+)$", line)
            if not match:
                failures.append(f"SHA256SUMS:{line_no}: malformed line")
                continue
            expected, rel = match.groups()
            candidate = (path / rel).resolve()
            try:
                candidate.relative_to(path.resolve())
            except ValueError:
                failures.append(f"SHA256SUMS:{line_no}: path escapes artifact root")
                continue
            if not candidate.is_file():
                failures.append(f"{rel}: manifest target missing")
                continue
            actual = hashlib.sha256(candidate.read_bytes()).hexdigest()
            if actual.lower() != expected.lower():
                failures.append(f"{rel}: sha256 mismatch")

    if failures:
        print("FAIL: deploy artifact boundary check failed:", file=sys.stderr)
        for item in failures:
            print(f"  - {item}", file=sys.stderr)
        return 1
    print("PASS: deploy artifact contains only verified regular files.")
    return 0


if ARGS:
    if len(ARGS) == 2 and ARGS[0] == "--artifact-dir":
        sys.exit(validate_artifact_dir(Path(ARGS[1]).resolve()))
    raise SystemExit(f"Unknown arguments: {' '.join(ARGS)}")

FAILURES: list[str] = []
texts = {name: read(path) for name, path in WORKFLOWS.items()}
for name, text in texts.items():
    if text:
        validate_workflow(name, WORKFLOWS[name], text)
if texts.get("deploy-hosting"):
    validate_hosting(texts["deploy-hosting"])
if texts.get("deploy-production"):
    validate_production_functions(texts["deploy-production"])
if texts.get("deploy-cloud-run"):
    validate_cloud_run(texts["deploy-cloud-run"])
validate_generated_configs()

if FAILURES:
    print("FAIL: production deploy auth boundary drifted:", file=sys.stderr)
    for failure in FAILURES:
        print(f"  - {failure}", file=sys.stderr)
    sys.exit(1)

for path in WORKFLOWS.values():
    print(f"PASS: {path} keeps production deploy credentials outside repo-controlled build/lifecycle/predeploy code.")
print("PASS: generated Firebase CI configs contain no predeploy hooks.")
PY
