import json
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def test_release_preflight_holds_until_signed_legal_evidence_is_approved():
    result = subprocess.run(
        ["python3", "scripts/ci/check_burnbar_release_preflight.py"],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )

    assert result.returncode != 0
    assert "HOLD: BurnBar product release preflight is not ready" in result.stderr
    assert "runtimeReadiness.status must be 'ready'" in result.stderr
    assert "legal release review is not approved" in result.stderr


def test_release_preflight_rejects_pending_legal_template_as_release_approval():
    result = subprocess.run(
        [
            "python3",
            "scripts/ci/check_burnbar_release_preflight.py",
            "--legal-evidence",
            "docs/legal/agpl-release-review.evidence.template.json",
        ],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )

    assert result.returncode != 0
    assert "HOLD: BurnBar product release preflight is not ready" in result.stderr
    assert "legal release review is not approved: 'pending'" in result.stderr


def test_release_preflight_strictly_validates_claimed_approval(tmp_path):
    evidence = tmp_path / "forged-approved.json"
    evidence.write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "reviewStatus": "approved",
                "reviewerRole": "external_counsel",
                "distributionChannels": ["hosted service"],
                "approval": {
                    "reviewerName": "Totally Fake Counsel LLP",
                    "approvedAt": "2026-06-07T00:00:00Z",
                    "documentPath": "docs/legal/AGPL_RELEASE_REVIEW_PACKET.md",
                    "documentSha256": "0" * 64,
                    "signatureFormat": "openssl-sha256-rsa",
                },
            }
        ),
        encoding="utf-8",
    )

    result = subprocess.run(
        [
            "python3",
            "scripts/ci/check_burnbar_release_preflight.py",
            "--legal-evidence",
            str(evidence),
        ],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )

    assert result.returncode != 0
    assert "approval.signaturePath is required" in result.stderr
    assert "approval.publicKeyPath is required" in result.stderr


def test_product_release_workflows_invoke_release_preflight():
    required_workflows = (
        ".github/workflows/release.yml",
        ".github/workflows/deploy-production.yml",
    )
    for workflow in required_workflows:
        body = (ROOT / workflow).read_text(encoding="utf-8")
        assert "python3 scripts/ci/check_burnbar_release_preflight.py" in body, workflow
        assert "--source-provenance-only" in body, workflow
        assert "release_hold_bypass_reason" not in body, workflow
        assert "Validate release hold bypass reason" not in body, workflow
        assert "release_hold_bypass_reason must contain non-whitespace text" not in body, workflow
        assert "Record owner-approved release hold bypass" not in body, workflow
        assert "trim(inputs.release_hold_bypass_reason)" not in body, workflow

    release_body = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
    deploy_body = (ROOT / ".github/workflows/deploy-production.yml").read_text(encoding="utf-8")
    assert "check_burnbar_release_preflight.py --allow-owner-emergency-approval" in release_body
    assert "check_burnbar_release_preflight.py --allow-owner-emergency-approval" not in deploy_body

    hosting_body = (ROOT / ".github/workflows/deploy-hosting.yml").read_text(encoding="utf-8")
    assert "check_burnbar_release_preflight.py" not in hosting_body


def test_firestore_deploy_uses_supported_firebase_cli_rules_deploy():
    body = (ROOT / ".github/workflows/deploy-firestore.yml").read_text(encoding="utf-8")
    deployer = (ROOT / "scripts/ci/deploy-firebase-rules-releases.mjs").read_text(encoding="utf-8")
    assert "--only firestore:indexes" in body
    assert "deploy-firebase-rules-releases.mjs" in body
    assert "updateMask:" not in deployer
    assert "live API rejects an" in deployer


def test_release_uses_keyless_provenance_when_legacy_gpg_is_absent():
    body = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")

    assert "Resolve release provenance policy" in body
    assert (
        "RELEASE_SIGNING_KEY is not configured; using required keyless "
        "Sigstore blob attestations for release provenance."
    ) in body
    assert "Sign checksums (legacy GPG, optional)" in body
    assert "Verify checksum GPG signature (when configured)" in body
    assert "Sigstore blob attestations (SBOM + VEX + checksums + binaries)" in body
    assert "cosign attest-blob --yes" in body
    assert "--predicate \"$predicate_path\"" in body
    assert "--bundle \"$bundle_path\"" in body
    assert "release-provenance-v${VERSION}" in body
    assert "Upload release provenance bundles artifact" in body
    assert "PROVENANCE_PATHS" in body
    assert (
        'find "$RUNNER_TEMP" -type f \\( -name "*.sigstore.json" -o -name "*.predicate.json" \\)'
        in body
    )
    assert (
        'find "$RUNNER_TEMP" -maxdepth 1 -type f \\( -name "*.sigstore.json" -o -name "*.predicate.json" \\)'
        not in body
    )
    assert "cosign attest --yes \"$CHECKSUMS_PATH\"" not in body
    assert "if: steps.provenance-policy.outputs.gpg_configured == 'true'" in body
    assert "if [[ -z \"${SIGNATURE_PATH:-}\" || ! -f \"$SIGNATURE_PATH\" ]]" in body

    assert "RELEASE_SIGNING_KEY is not set. GPG checksum signing is required" not in body
    assert "if: env.RELEASE_SIGNING_KEY == ''" not in body
    assert 'tag_ref="refs/tags/${TAG_NAME}"' in body
    assert 'Manual release dispatch for ${TAG_NAME} must run from ${tag_ref}, not ${GITHUB_REF}.' in body
    assert "keyless provenance is tag-bound" in body
    assert 'git fetch --force --tags origin "+${tag_ref}:${tag_ref}"' in body
    assert 'git fetch --force origin "+refs/heads/main:refs/remotes/origin/main"' in body
    assert 'git rev-list -n 1 "${tag_ref}^{commit}"' in body
    assert 'git merge-base --is-ancestor "$release_commit" origin/main' in body
    assert 'git checkout --detach "$RELEASE_COMMIT"' in body
    assert 'echo "release_commit=$release_commit"' in body
    assert "RELEASE_REF: ${{ steps.version.outputs.tag_ref }}" in body
    assert '"tag": os.environ["RELEASE_TAG"]' in body
    assert '"commit": release_commit' in body
    assert '"ref": os.environ["RELEASE_REF"]' in body
    assert '"ref": os.environ.get("GITHUB_REF", "")' not in body

    checksums_index = body.index("Compute artifact checksums")
    policy_index = body.index("Resolve release provenance policy")
    sbom_index = body.index("Generate SBOM")
    cosign_index = body.index("- name: Sigstore blob attestations")
    assert checksums_index < policy_index < sbom_index < cosign_index


def test_supply_chain_provenance_uses_resolved_release_tag_commit():
    body = (ROOT / ".github/workflows/supply-chain-provenance.yml").read_text(encoding="utf-8")

    assert "fetch-depth: 0" in body
    assert "EVENT_NAME: ${{ github.event_name }}" in body
    assert "INPUT_TAG: ${{ github.event.inputs.tag }}" in body
    assert "RUN_HEAD: ${{ github.event.workflow_run.head_branch }}" in body
    assert "RUN_HEAD_SHA: ${{ github.event.workflow_run.head_sha }}" in body
    assert 'tag_ref="refs/tags/${TAG}"' in body
    assert 'Manual provenance dispatch for ${TAG} must run from ${tag_ref}, not ${GITHUB_REF}.' in body
    assert "keyless provenance is tag-bound" in body
    assert 'git fetch --force --tags origin "+${tag_ref}:${tag_ref}"' in body
    assert 'git fetch --force origin "+refs/heads/main:refs/remotes/origin/main"' in body
    assert 'git rev-list -n 1 "${tag_ref}^{commit}"' in body
    assert 'git merge-base --is-ancestor "$commit" origin/main' in body
    assert 'RUN_HEAD_SHA" != "$commit"' in body
    assert "Check out release tag" in body
    assert 'git checkout --detach "$RELEASE_COMMIT"' in body
    assert 'test "$(git rev-parse HEAD)" = "$RELEASE_COMMIT"' in body
    assert 'echo "commit=$commit"' in body
    assert "Generate SBOM (PR-style fallback when artifacts missing)" not in body
    assert "^[0-9a-zA-Z._-]+$" not in body


def test_release_attestation_verifier_uses_sigstore_blob_bundles():
    body = (ROOT / "scripts/ci/verify-release-attestations.sh").read_text(encoding="utf-8")

    assert "cosign verify-blob-attestation" in body
    assert "gh attestation verify" not in body
    assert "OPENBURNBAR_RELEASE_CERTIFICATE_IDENTITY" in body
    assert "OPENBURNBAR_RELEASE_CERTIFICATE_OIDC_ISSUER" in body
    assert "OPENBURNBAR_RELEASE_PREDICATE_TYPE" in body
    assert "certificate_issuer=" in body
    assert "predicate_type=" in body
    assert "download_optional_pattern \"*.sigstore.json\"" in body
    assert "download_optional_pattern \"*.predicate.json\"" in body
    assert "signed_statement_from_bundle(bundle)" in body
    assert "release predicate sidecar does not match the signed Sigstore bundle payload" in body
    assert "\"runner.environment\": predicate.get(\"runner\", {}).get(\"environment\")" in body
    assert "artifact.sha256" in body
    assert "release.tag" in body
    assert "release.ref" in body


def test_release_smoke_uses_packaged_daemon_helper_without_persistent_install_assumption():
    workflow = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
    script = (ROOT / "scripts/ci/smoke-openburnbar-release-dmg.sh").read_text(encoding="utf-8")
    website_release = (ROOT / "scripts/build-macos-website-release.sh").read_text(encoding="utf-8")

    assert "bash scripts/ci/smoke-openburnbar-release-dmg.sh \"$DMG_PATH\"" in workflow
    assert "swift build --package-path OpenBurnBarDaemon -c release --product OpenBurnBarCLI" in workflow
    assert '--identifier "$identifier"' in workflow
    assert 'sign_one "$HELPERS_DIR/OpenBurnBarDaemon" "runtime,library" "com.openburnbar.daemon"' in workflow
    assert 'sign_one "$HELPERS_DIR/OpenBurnBarCLI" "runtime,library" "com.openburnbar.cli"' in workflow
    assert "com.openburnbar.privileged-input-execution" in workflow
    assert "com.openburnbar.virtual-hid-bridge" in workflow
    assert "--options runtime,library" in workflow
    assert "codesign --force --timestamp --deep --options runtime,library" not in workflow
    assert "assert_peer_signature" in workflow
    assert 'assert_peer_signature "$HELPERS_DIR/OpenBurnBarDaemon" "com.openburnbar.daemon"' in workflow
    assert 'assert_peer_signature "$HELPERS_DIR/OpenBurnBarCLI" "com.openburnbar.cli"' in workflow
    assert (
        'assert_peer_signature "$HELPERS_DIR/OpenBurnBarPrivilegedInputExecution" '
        '"com.openburnbar.privileged-input-execution"'
    ) in workflow
    assert (
        'assert_peer_signature "$HELPERS_DIR/OpenBurnBarVirtualHIDBridge" '
        '"com.openburnbar.virtual-hid-bridge"'
    ) in workflow
    assert 'install_name_tool -add_rpath "@executable_path/../Frameworks" "$HELPERS_DIR/OpenBurnBarDaemon"' in workflow
    assert 'install_name_tool -add_rpath "@executable_path/../Frameworks" "$HELPERS_DIR/OpenBurnBarCLI"' in workflow
    assert 'install_name_tool -add_rpath "@executable_path/../Frameworks" "$helpers_dir/OpenBurnBarDaemon"' in website_release
    assert 'install_name_tool -add_rpath "@executable_path/../Frameworks" "$helpers_dir/OpenBurnBarCLI"' in website_release
    assert 'cp -R "$DAEMON_RESOURCE_BUNDLE" "$DAEMON_HELPER_RESOURCE_BUNDLE"' in workflow
    assert 'cp -R "$daemon_resource_bundle" "$daemon_helper_resource_bundle"' in website_release
    assert 'cp -R "$PROJECT_CODE_MEMORY_DIR" "$HELPERS_DIR/ProjectCodeMemory"' not in workflow
    assert 'cp -R "$project_code_memory_dir" "$helpers_dir/ProjectCodeMemory"' not in website_release
    assert "Contents/Helpers/OpenBurnBarDaemon" in script
    assert "Contents/Helpers/OpenBurnBarCLI" in script
    assert "Contents/Helpers/OpenBurnBarCore_OpenBurnBarCore.bundle" in script
    assert "Contents/Resources/ProjectCodeMemory/secret-pattern-corpus.json" in script
    assert "Contents/Helpers/ProjectCodeMemory/secret-pattern-corpus.json" not in script
    assert 'installed_daemon_dir="$support_dir/daemon"' in script
    assert 'installed_frameworks_dir="$support_dir/Frameworks"' in script
    assert 'installed_daemon_bin="$installed_daemon_dir/OpenBurnBarDaemon"' in script
    assert 'installed_cli_bin="$installed_daemon_dir/OpenBurnBarCLI"' in script
    assert 'cp "$daemon_bin" "$installed_daemon_bin"' in script
    assert 'cp "$cli_bin" "$installed_cli_bin"' in script
    assert 'for framework in "$app_path"/Contents/Frameworks/*.framework; do' in script
    assert 'SQLCipher.framework was not mirrored to installed daemon rpath directory' in script
    assert "OPENBURNBAR_DAEMON_SUPPORT_DIR" in script
    assert "com.openburnbar.daemon.release-smoke" in script
    assert 'python3 - "$installed_cli_bin"' in script
    assert '[cli, "health"]' in script
    assert "subprocess.TimeoutExpired" in script
    assert "timeout=2" in script
    assert "health_deadline_seconds=30" in script
    assert "while [[ \"$(date +%s)\" -lt \"$health_deadline_epoch\" ]]" in script
    assert "for attempt in {1..60}" not in script
    assert '"${installed_daemon_bin}"' in script
    assert '"$cli_bin" health' not in script
    assert "Authenticated daemon health RPC passed via installed-layout OpenBurnBarCLI" in script
    assert "import socket" not in script
    assert "\"method\": \"daemon.health\"" not in script
    assert "Daemon socket not found at $DAEMON_SOCKET after 20s" not in workflow
    assert "Library/Application Support/OpenBurnBar/openburnbar-daemon.sock" not in workflow
