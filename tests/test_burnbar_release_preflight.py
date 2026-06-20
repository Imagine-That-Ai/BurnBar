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
        assert "release_hold_bypass_reason" in body, workflow
        assert "Validate release hold bypass reason" in body, workflow
        assert "release_hold_bypass_reason must contain non-whitespace text" in body, workflow
        assert "Record owner-approved release hold bypass" in body, workflow
        assert "trim(inputs.release_hold_bypass_reason)" not in body, workflow

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

    checksums_index = body.index("Compute artifact checksums")
    policy_index = body.index("Resolve release provenance policy")
    sbom_index = body.index("Generate SBOM")
    cosign_index = body.index("- name: Sigstore blob attestations")
    assert checksums_index < policy_index < sbom_index < cosign_index


def test_release_attestation_verifier_uses_sigstore_blob_bundles():
    body = (ROOT / "scripts/ci/verify-release-attestations.sh").read_text(encoding="utf-8")

    assert "cosign verify-blob-attestation" in body
    assert "gh attestation verify" not in body
    assert "OPENBURNBAR_RELEASE_CERTIFICATE_IDENTITY" in body
    assert "OPENBURNBAR_RELEASE_CERTIFICATE_OIDC_ISSUER" in body
    assert "OPENBURNBAR_RELEASE_PREDICATE_TYPE" in body
    assert "certificate_issuer=" in body
    assert "predicate_type=" in body
    assert "download_pattern \"*.sigstore.json\"" in body
    assert "download_pattern \"*.predicate.json\"" in body
    assert "artifact.sha256" in body
    assert "release.ref" in body


def test_release_smoke_uses_packaged_daemon_helper_without_persistent_install_assumption():
    workflow = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
    script = (ROOT / "scripts/ci/smoke-openburnbar-release-dmg.sh").read_text(encoding="utf-8")
    website_release = (ROOT / "scripts/build-macos-website-release.sh").read_text(encoding="utf-8")

    assert "bash scripts/ci/smoke-openburnbar-release-dmg.sh \"$DMG_PATH\"" in workflow
    assert "swift build --package-path OpenBurnBarDaemon -c release --product OpenBurnBarCLI" in workflow
    assert "--identifier com.openburnbar.daemon" in workflow
    assert "--identifier com.openburnbar.cli" in workflow
    assert "--options runtime,library" in workflow
    assert 'install_name_tool -add_rpath "@executable_path/../Frameworks" "$HELPERS_DIR/OpenBurnBarDaemon"' in workflow
    assert 'install_name_tool -add_rpath "@executable_path/../Frameworks" "$HELPERS_DIR/OpenBurnBarCLI"' in workflow
    assert 'install_name_tool -add_rpath "@executable_path/../Frameworks" "$helpers_dir/OpenBurnBarDaemon"' in website_release
    assert 'install_name_tool -add_rpath "@executable_path/../Frameworks" "$helpers_dir/OpenBurnBarCLI"' in website_release
    assert 'cp -R "$DAEMON_RESOURCE_BUNDLE" "$DAEMON_HELPER_RESOURCE_BUNDLE"' in workflow
    assert 'cp -R "$daemon_resource_bundle" "$daemon_helper_resource_bundle"' in website_release
    assert "Contents/Helpers/OpenBurnBarDaemon" in script
    assert "Contents/Helpers/OpenBurnBarCLI" in script
    assert "Contents/Helpers/OpenBurnBarCore_OpenBurnBarCore.bundle" in script
    assert "Contents/Helpers/ProjectCodeMemory/secret-pattern-corpus.json" in script
    assert "OPENBURNBAR_DAEMON_SUPPORT_DIR" in script
    assert "com.openburnbar.daemon.release-smoke" in script
    assert '"$cli_bin" health' in script
    assert "Authenticated daemon health RPC passed via packaged OpenBurnBarCLI" in script
    assert "import socket" not in script
    assert "\"method\": \"daemon.health\"" not in script
    assert "Daemon socket not found at $DAEMON_SOCKET after 20s" not in workflow
    assert "Library/Application Support/OpenBurnBar/openburnbar-daemon.sock" not in workflow
