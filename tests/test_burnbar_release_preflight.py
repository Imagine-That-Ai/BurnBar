import importlib.util
import json
import re
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def load_release_preflight_module():
    path = ROOT / "scripts/ci/check_burnbar_release_preflight.py"
    spec = importlib.util.spec_from_file_location("burnbar_release_preflight_test", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def current_release_tag() -> str:
    project_yml = (ROOT / "project.yml").read_text(encoding="utf-8")
    match = re.search(r'MARKETING_VERSION:\s*"?([0-9]+(?:\.[0-9]+)+)"?', project_yml)
    assert match is not None, "project.yml must declare MARKETING_VERSION"
    return f"v{match.group(1)}"


def test_release_preflight_holds_until_signed_legal_evidence_is_approved():
    result = subprocess.run(
        ["python3", "scripts/ci/check_burnbar_release_preflight.py"],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )

    assert result.returncode != 0
    assert "HOLD: BurnBar product release preflight is not ready" in result.stderr
    assert "legal release review is not approved: 'owner_attested_soft_approval'" in result.stderr
    assert "legal release review pending evidence must explicitly say it is not legal approval" in result.stderr


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
        capture_output=True,
        check=False,
    )

    assert result.returncode != 0
    assert "HOLD: BurnBar product release preflight is not ready" in result.stderr
    assert "legal release review is not approved: 'pending'" in result.stderr


def test_current_owner_emergency_packet_is_bound_to_current_release_tag():
    evidence = ROOT / "launch-evidence/latest-agpl-store-legal-packet.json"
    data = json.loads(evidence.read_text(encoding="utf-8"))
    expected_release_tag = current_release_tag()

    assert data["repo"]["releaseTag"] == expected_release_tag

    result = subprocess.run(
        [
            "python3",
            "scripts/ci/check_burnbar_release_preflight.py",
            "--allow-owner-emergency-approval",
            "--expected-release-tag",
            expected_release_tag,
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )

    assert "owner emergency approval: repo.releaseTag" not in result.stderr


def test_owner_emergency_lane_never_claims_normal_release_readiness():
    module = load_release_preflight_module()
    stdout_lines, stderr_lines = module.success_posture(
        source_provenance_only=False,
        owner_emergency_approval=True,
        owner_emergency_runtime_hold=True,
    )

    stdout = "\n".join(stdout_lines)
    stderr = "\n".join(stderr_lines)
    assert "emergency artifact release preflight is authorized" in stdout
    assert "product release preflight is ready" not in stdout
    assert "not signed external-counsel approval" in stderr
    assert "Runtime readiness remains HOLD" in stderr
    assert "Normal BurnBar release readiness still requires" in stderr


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
        capture_output=True,
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
    assert "check_burnbar_release_preflight.py" in release_body
    assert "--allow-owner-emergency-approval" in release_body
    assert '--expected-release-tag "${{ steps.version.outputs.tag_name }}"' in release_body
    assert "--allow-owner-emergency-approval" not in deploy_body
    # Real tag deploys still run the full product preflight; dry-runs keep only
    # source-provenance so they can prove tag/candidate binding before counsel
    # and runtime readiness are GO.
    assert "if: steps.tag.outputs.dry_run != 'true'" in deploy_body
    product_step = deploy_body.split("- name: BurnBar product release preflight", 1)[1]
    product_step = product_step.split("- name:", 1)[0]
    assert "if: steps.tag.outputs.dry_run != 'true'" in product_step
    assert "check_burnbar_release_preflight.py" in product_step
    assert "--source-provenance-only" not in product_step

    hosting_body = (ROOT / ".github/workflows/deploy-hosting.yml").read_text(encoding="utf-8")
    assert "check_burnbar_release_preflight.py" not in hosting_body


def test_release_workflow_uses_bounded_release_critical_app_gate():
    body = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
    smoke = (ROOT / "scripts/test-openburnbar-release-smoke.sh").read_text(encoding="utf-8")
    filters = (ROOT / "scripts/lib/openburnbar-release-app-test-filters.sh").read_text(encoding="utf-8")

    step_start = body.index("- name: Run OpenBurnBar release-critical app tests")
    step_end = body.index("- name: Verify SQLCipher codec in Release configuration")
    app_step = body[step_start:step_end]

    assert "timeout-minutes: 75" in app_step
    assert "cold GitHub macOS runners still compile the" in app_step
    assert "source scripts/lib/openburnbar-release-app-test-filters.sh" in app_step
    assert 'OPENBURNBAR_APP_TEST_FILTERS="$(openburnbar_release_app_test_filters_env)"' in app_step
    assert "./scripts/test-openburnbar-app.sh" in app_step
    assert "- name: Run OpenBurnBar app tests" not in body
    assert "timeout-minutes: 180" not in app_step
    assert "run: ./scripts/test-openburnbar-app.sh" not in body

    assert 'source "$repo_root/scripts/lib/openburnbar-release-app-test-filters.sh"' in smoke
    assert (
        'OPENBURNBAR_APP_TEST_FILTERS="${OPENBURNBAR_APP_TEST_FILTERS:-$(openburnbar_release_app_test_filters_env)}"'
        in smoke
    )
    assert 'support_dir="$(mktemp -d "/tmp/openburnbar-release-smoke-support-$uid.XXXXXX")"' in smoke
    assert '"OPENBURNBAR_DAEMON_SUPPORT_DIR": "${support_dir}"' in smoke
    assert '"WorkingDirectory": "${installed_daemon_dir}"' in smoke

    for required_filter in (
        "OpenBurnBarTests/DirectDownloadReleaseMetadataTests",
        "OpenBurnBarTests/OpenBurnBarAppCheckProviderFactoryTests",
        "OpenBurnBarTests/OpenBurnBarRuntimeTests",
        "OpenBurnBarTests/PopoverContentPrewarmerTests",
        "OpenBurnBarTests/PaneWorkspaceModelTests",
        "OpenBurnBarTests/ChatSessionControllerPaneModeTests",
    ):
        assert required_filter in filters


def test_release_build_and_release_job_has_packaging_headroom():
    body = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")

    build_start = body.index("  build-and-release:")
    build_end = body.index("  smoke-test:")
    build_job = body[build_start:build_end]

    assert "timeout-minutes: 300" in build_job
    assert "Cold-runner worst case stays well under five hours" in build_job
    assert "Build signed Android release bundle" in build_job
    assert ":app:bundleRelease :app:assembleRelease" in build_job
    assert "run-android-release-startup-smoke.sh" in build_job
    assert "Notarize and staple DMG" in build_job
    # Codex P1 on PR #1281: the fail-hard signing-secret check must live in the
    # environment-bound packaging job, where environment-scoped secrets resolve.
    assert "Validate strict release secrets" in build_job


def test_android_release_proguard_preserves_reflective_firebase_registrars():
    rules = (ROOT / "android/app/proguard-rules.pro").read_text(encoding="utf-8")

    assert "-keep class com.google.firebase.**Registrar" in rules
    assert (
        "-keep class * implements com.google.firebase.components.ComponentRegistrar"
        in rules
    )
    assert rules.count("public <init>();") >= 2


def test_release_workflow_keeps_quiet_xcode_build_alive():
    body = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")

    step_start = body.index("- name: Build Release .app (unsigned)")
    step_end = body.index("- name: Embed daemon binary in app bundle", step_start)
    app_build_step = body[step_start:step_end]

    assert "openburnbar-release-app-xcodebuild.log" in app_build_step
    assert "xcodebuild_pid" in app_build_step
    assert "xcodebuild Release .app still running" in app_build_step
    assert "xcodebuild Release .app recent output" in app_build_step
    assert 'tail -n 40 "$xcodebuild_log"' in app_build_step
    assert 'tail -n 200 "$xcodebuild_log"' in app_build_step
    assert 'wait "$xcodebuild_pid"' in app_build_step


def test_release_workflow_prepares_signal_ffi_before_xcode_release_build():
    body = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")

    prepare_start = body.index("- name: Prepare Signal FFI XCFramework for release app")
    lockfile_index = body.index("- name: Verify OpenBurnBar app SwiftPM lockfile")
    resolve_index = body.index("- name: Resolve Xcode packages")
    app_build_index = body.index("- name: Build Release .app (unsigned)")
    prepare_step = body[prepare_start:lockfile_index]

    assert prepare_start < lockfile_index < resolve_index < app_build_index
    assert "SIGNAL_FFI_BUILD_PROFILE: release" in prepare_step
    targets = re.search(r'SIGNAL_FFI_BUILD_TARGETS: "([^"]+)"', prepare_step)
    assert targets is not None
    assert targets.group(1).split() == [
        "aarch64-apple-darwin",
        "x86_64-apple-darwin",
        "aarch64-apple-ios",
        "aarch64-apple-ios-sim",
        "x86_64-apple-ios",
    ]
    assert 'CARGO_BUILD_JOBS: "2"' in prepare_step
    assert "bash scripts/lib/prepare-signal-ffi-xcframework.sh" in prepare_step


def test_release_workflow_guards_owner_approved_validation_bypass():
    body = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")

    assert "run_release_validation_gates:" in body
    assert "release_validation_bypass_reason:" in body
    assert "Validate release validation bypass reason" in body
    assert "run_release_validation_gates=false requires release_validation_bypass_reason" in body
    assert "release_validation_bypass_reason must name owner approval" in body
    assert "release_validation_bypass_reason must include the prior GitHub Actions run URL" in body
    assert "Record owner-approved release validation bypass" in body

    build_start = body.index("  build-and-release:")
    build_end = body.index("  smoke-test:")
    build_job = body[build_start:build_end]

    # The slow validation gates run in parallel lane jobs; every gated step
    # still honors the owner-approved bypass input, and none of them remain in
    # the packaging job.
    for job_header, next_job_header, step_name in (
        ("  release-swift-gate:", "  release-app-gate:", "- name: Run Swift tests"),
        (
            "  release-swift-gate:",
            "  release-app-gate:",
            "- name: Run retrieval replay evals",
        ),
        (
            "  release-app-gate:",
            "  release-sqlcipher-gate:",
            "- name: Run OpenBurnBar release-critical app tests",
        ),
        (
            "  release-sqlcipher-gate:",
            "  release-mobile-gate:",
            "- name: Verify SQLCipher codec in Release configuration",
        ),
        (
            "  release-android-gate:",
            "  build-and-release:",
            "- name: Run Android unit tests",
        ),
    ):
        gate_job = body[body.index(job_header) : body.index(next_job_header)]
        step_start = gate_job.index(step_name)
        step_end = gate_job.find("\n      - name:", step_start + 1)
        if step_end == -1:
            step_end = len(gate_job)
        step = gate_job[step_start:step_end]
        assert "inputs.run_release_validation_gates" in step
        assert step_name not in build_job

    packaging_start = build_job.index("- name: Build signed Android release bundle")
    packaging_step_end = build_job.find("\n      - name:", packaging_start + 1)
    packaging_step = build_job[packaging_start:packaging_step_end]
    assert "inputs.run_release_validation_gates" not in packaging_step


def test_release_workflow_uses_bounded_release_critical_mobile_gate():
    body = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
    filters = (ROOT / "scripts/lib/openburnbar-release-mobile-test-filters.sh").read_text(encoding="utf-8")

    step_start = body.index("- name: Run OpenBurnBar mobile unit tests")
    step_end = body.index("  release-android-gate:")
    mobile_step = body[step_start:step_end]

    assert "timeout-minutes: 75" in mobile_step
    assert "source scripts/lib/openburnbar-release-mobile-test-filters.sh" in mobile_step
    assert 'OPENBURNBAR_MOBILE_TEST_FILTER="$(openburnbar_release_mobile_test_filters_env)"' in mobile_step
    assert "./scripts/test-openburnbar-mobile.sh" in mobile_step
    assert "full mobile suite is a PR/CI responsibility" in mobile_step
    assert "AgentLiveStagePresenterTests" not in filters

    for required_filter in (
        "OpenBurnBarMobileTests/AppStoreReviewComplianceTests",
        "OpenBurnBarMobileTests/AuthStoreTests",
        "OpenBurnBarMobileTests/ConversationCockpitAuthTests",
        "OpenBurnBarMobileTests/iPadNavigationUITests",
        "OpenBurnBarMobileTests/MobileBackdropKernelTests",
        "OpenBurnBarMobileTests/MobileSentryScrubberTests",
        "OpenBurnBarMobileTests/MobileThemeTests",
        "OpenBurnBarMobileTests/PulseWindowMetricsTests",
    ):
        assert required_filter in filters


def test_release_workflow_bounds_sqlcipher_release_codec_gate():
    body = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")

    step_start = body.index("- name: Verify SQLCipher codec in Release configuration")
    step_end = body.index("  release-mobile-gate:")
    sqlcipher_step = body[step_start:step_end]

    # 130 minutes: the gate legitimately ran 55.9 of its previous 60-minute cap
    # on a cold runner (v1.0.29) and later overran 75 as well; the cap is a
    # hang guard, not a quality gate (bumped alongside release.yml in the
    # SQLCipher gate-timeout extension).
    assert "timeout-minutes: 130" in sqlcipher_step
    assert "OPENBURNBAR_REQUIRE_SQLCIPHER_CODEC=1 ./scripts/ci/verify-sqlcipher-codec.sh" in sqlcipher_step


def test_release_workflow_parallelizes_independent_publish_gates():
    body = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")

    assert "release-functions-gate:" in body
    assert "release-extension-gate:" in body
    assert "release-supply-chain-gate:" in body
    assert "name: Release Functions Gate" in body
    assert "name: Release Extension and TS Gate" in body
    assert "name: Release Supply Chain Gate" in body

    functions_start = body.index("  release-functions-gate:")
    extension_start = body.index("  release-extension-gate:")
    supply_chain_start = body.index("  release-supply-chain-gate:")
    build_start = body.index("  build-and-release:")
    for gate_job in (
        body[functions_start:extension_start],
        body[extension_start:supply_chain_start],
        body[supply_chain_start:build_start],
    ):
        assert "permissions:\n      contents: read" in gate_job
        assert "id-token: write" not in gate_job
        assert "attestations: write" not in gate_job

    smoke_start = body.index("  smoke-test:")
    build_job = body[build_start:smoke_start]
    assert "npm --prefix functions run lint" not in build_job
    assert "npm --prefix functions run build" not in build_job
    assert "npm --prefix functions test" not in build_job
    assert "./scripts/test-openburnbar-ts.sh" not in build_job
    assert "./scripts/test-openburnbar-extension-host.sh" not in build_job
    assert "npm --prefix functions run test:firestore-rules" not in build_job
    assert "./scripts/supply-chain-audit.sh" not in build_job
    assert "Inject extension Sentry DSN" in build_job
    assert "Build extension" in build_job

    for lane_job in (
        "  release-preflight:",
        "  release-swift-gate:",
        "  release-app-gate:",
        "  release-sqlcipher-gate:",
        "  release-mobile-gate:",
        "  release-android-gate:",
    ):
        assert lane_job in body

    prepare_publication_start = body.index("  prepare-release-publication:")
    publish_start = body.index("  domain-core-native-release-evidence:")
    verify_start = body.index("  verify-live-update-feed:")
    prepare_publication_job = body[prepare_publication_start:publish_start]
    publish_job = body[publish_start:verify_start]
    for lane in (
        "release-preflight",
        "release-swift-gate",
        "release-app-gate",
        "release-sqlcipher-gate",
        "release-mobile-gate",
        "release-android-gate",
        "release-functions-gate",
        "release-extension-gate",
        "release-supply-chain-gate",
        "build-and-release",
        "smoke-test",
    ):
        assert f"      - {lane}\n" in prepare_publication_job
    assert "name: Atomically publish verified Apple and Android release set" in publish_job
    assert "      - prepare-release-publication\n" in publish_job
    assert "Publish the complete verified release set from one draft state machine" in publish_job


def test_app_test_wrapper_supports_multiple_normalized_filters():
    result = subprocess.run(
        [
            "bash",
            "-lc",
            (
                "OPENBURNBAR_APP_TEST_FILTERS=$'AgentLensTests/Foo\\n"
                "OpenBurnBarTests/Bar,OpenBurnBarTests/Baz;AgentLensTests' "
                "scripts/test-openburnbar-app.sh --print-xcodebuild-filters"
            ),
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=True,
    )

    filters = [line for line in result.stdout.splitlines() if line.startswith("OpenBurnBarTests")]
    assert filters == [
        "OpenBurnBarTests/Foo",
        "OpenBurnBarTests/Bar",
        "OpenBurnBarTests/Baz",
        "OpenBurnBarTests",
    ]


def test_firestore_deploy_matches_firebase_tools_release_patch_shape():
    body = (ROOT / ".github/workflows/deploy-firestore.yml").read_text(encoding="utf-8")
    # The bespoke REST rules-release helper (deploy-firebase-rules-releases.mjs)
    # 400'd on every push for ~3 weeks and was removed in favor of firebase-tools'
    # proven release path. Assert the new shape, not the deleted helper.
    assert "--only firestore,storage" in body
    assert "--only firestore:indexes,storage" not in body
    assert "node scripts/ci/deploy-firebase-rules-releases.mjs" not in body
    assert "compact-firestore-rules-inplace.mjs firestore.rules" in body

    # rulesSourceForDeploy moved into the shared firebase-rules-source.mjs module
    # so both the in-place compactor and the drift check agree on what gets
    # shipped.
    rules_source = (
        ROOT / "scripts/ci/firebase-rules-source.mjs"
    ).read_text(encoding="utf-8")
    assert "rulesSourceForDeploy" in rules_source

    drift_checker = (
        ROOT / "scripts/ci/check-firestore-deploy-drift.mjs"
    ).read_text(encoding="utf-8")
    assert "rulesSourceForDeploy" in drift_checker

    # Secondary Storage bucket coverage: the old helper enumerated every
    # firebase.storage/ release and propagated rules to each.  firebase deploy
    # --only storage only covers the default bucket, so the workflow must run a
    # propagation step for secondary buckets (or the drift gate would catch
    # them).
    assert "propagate-storage-rules-secondary-buckets.mjs" in body


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
    assert '--predicate "$predicate_path"' in body
    assert '--bundle "$bundle_path"' in body
    assert "release-provenance-v${VERSION}" in body
    assert "Upload release provenance bundles artifact" in body
    assert "PROVENANCE_PATHS" in body
    assert 'find "$RUNNER_TEMP" -type f \\( -name "*.sigstore.json" -o -name "*.predicate.json" \\)' in body
    assert (
        'find "$RUNNER_TEMP" -maxdepth 1 -type f \\( -name "*.sigstore.json" -o -name "*.predicate.json" \\)'
        not in body
    )
    assert 'cosign attest --yes "$CHECKSUMS_PATH"' not in body
    assert "if: steps.provenance-policy.outputs.gpg_configured == 'true'" in body
    assert 'if [[ -z "${SIGNATURE_PATH:-}" || ! -f "$SIGNATURE_PATH" ]]' in body

    assert "RELEASE_SIGNING_KEY is not set. GPG checksum signing is required" not in body
    assert "if: env.RELEASE_SIGNING_KEY == ''" not in body
    assert 'tag_ref="refs/tags/${TAG_NAME}"' in body
    assert "Manual release dispatch for ${TAG_NAME} must run from ${tag_ref}, not ${GITHUB_REF}." in body
    assert "keyless provenance is tag-bound" in body
    assert 'git fetch --force --tags origin "+${tag_ref}:${tag_ref}"' in body
    assert 'git fetch --force origin "+refs/heads/main:refs/remotes/origin/main"' in body
    assert 'git rev-list -n 1 "${tag_ref}^{commit}"' in body
    assert 'git merge-base --is-ancestor "$release_commit" origin/main' in body
    assert 'git checkout --detach "$RELEASE_COMMIT"' in body
    assert 'echo "release_commit=$release_commit"' in body
    assert "RELEASE_REF: ${{ needs.release-preflight.outputs.tag_ref }}" in body
    assert "RELEASE_COMMIT: ${{ needs.release-preflight.outputs.release_commit }}" in body
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
    assert "Manual provenance dispatch for ${TAG} must run from ${tag_ref}, not ${GITHUB_REF}." in body
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
    assert 'download_optional_pattern "*.sigstore.json"' in body
    assert 'download_optional_pattern "*.predicate.json"' in body
    assert "signed_statement_from_bundle(bundle)" in body
    assert "release predicate sidecar does not match the signed Sigstore bundle payload" in body
    assert '"runner.environment": predicate.get("runner", {}).get("environment")' in body
    assert "artifact.sha256" in body
    assert "release.tag" in body
    assert "release.ref" in body


def test_release_smoke_uses_packaged_daemon_helper_without_persistent_install_assumption():
    workflow = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
    script = (ROOT / "scripts/ci/smoke-openburnbar-release-dmg.sh").read_text(encoding="utf-8")
    website_release = (ROOT / "scripts/build-macos-website-release.sh").read_text(encoding="utf-8")

    assert 'bash scripts/ci/smoke-openburnbar-release-dmg.sh "$DMG_PATH"' in workflow
    assert "swift build --package-path OpenBurnBarDaemon -c release --product OpenBurnBarCLI" in workflow
    assert '--identifier "$identifier"' in workflow
    assert 'sign_one "$HELPERS_DIR/OpenBurnBarDaemon" "runtime,library" "com.openburnbar.app"' in workflow
    assert 'sign_one "$HELPERS_DIR/OpenBurnBarCLI" "runtime,library" "com.openburnbar.cli"' in workflow
    assert "com.openburnbar.privileged-input-execution" in workflow
    assert "com.openburnbar.virtual-hid-bridge" in workflow
    assert "--options runtime,library" in workflow
    assert "codesign --force --timestamp --deep --options runtime,library" not in workflow
    assert "assert_peer_signature" in workflow
    assert 'assert_peer_signature "$HELPERS_DIR/OpenBurnBarDaemon" "com.openburnbar.app"' in workflow
    assert 'assert_peer_signature "$HELPERS_DIR/OpenBurnBarCLI" "com.openburnbar.cli"' in workflow
    assert (
        'bash scripts/ci/verify-daemon-release-signing.sh "$APP_PATH" "$APP_PROFILE_TEAM_ID"'
        in workflow
    )
    assert (
        'assert_peer_signature "$HELPERS_DIR/OpenBurnBarPrivilegedInputExecution" '
        '"com.openburnbar.privileged-input-execution"'
    ) in workflow
    assert (
        'assert_peer_signature "$HELPERS_DIR/OpenBurnBarVirtualHIDBridge" "com.openburnbar.virtual-hid-bridge"'
    ) in workflow
    assert 'install_name_tool -add_rpath "@executable_path/../Frameworks" "$HELPERS_DIR/OpenBurnBarDaemon"' in workflow
    assert 'install_name_tool -add_rpath "@executable_path/../Frameworks" "$HELPERS_DIR/OpenBurnBarCLI"' in workflow
    assert (
        'install_name_tool -add_rpath "@executable_path/../Frameworks" "$helpers_dir/OpenBurnBarDaemon"'
        in website_release
    )
    assert (
        'install_name_tool -add_rpath "@executable_path/../Frameworks" "$helpers_dir/OpenBurnBarCLI"' in website_release
    )
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
    assert "SQLCipher.framework was not mirrored to installed daemon rpath directory" in script
    assert "OPENBURNBAR_DAEMON_SUPPORT_DIR" in script
    assert "com.openburnbar.daemon.release-smoke" in script
    assert 'python3 - "$installed_cli_bin"' in script
    assert '[cli, "health"]' in script
    assert "subprocess.TimeoutExpired" in script
    assert "OPENBURNBAR_RELEASE_SMOKE_CLI_TIMEOUT_SECONDS" in script
    assert "timeout=timeout" in script
    assert "OpenBurnBarCLI health timed out after {timeout}s" in script
    assert "OPENBURNBAR_RELEASE_SMOKE_HEALTH_DEADLINE_SECONDS" in script
    assert 'positive_integer_or_default "${OPENBURNBAR_RELEASE_SMOKE_CLI_TIMEOUT_SECONDS:-}" 45' in script
    assert 'positive_integer_or_default "${OPENBURNBAR_RELEASE_SMOKE_HEALTH_DEADLINE_SECONDS:-}" 180' in script
    assert '[[ "${GITHUB_ACTIONS:-}" == "true" ]]' in script
    assert 'echo "::add-mask::$socket_auth_token"' in script
    assert "--socket-auth-token-file" in script
    assert 'OPENBURNBAR_DAEMON_SOCKET_PATH="$socket_path"' in script
    assert 'OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN": "${socket_auth_token}"' not in script
    assert "<redacted>" in script
    assert 'while [[ "$(date +%s)" -lt "$health_deadline_epoch" ]]' in script
    assert "for attempt in {1..60}" not in script
    assert "launchctl print" in script
    assert "stat -f" in script
    assert '"${installed_daemon_bin}"' in script
    assert '"$cli_bin" health' not in script
    assert "Authenticated daemon health RPC passed via installed-layout OpenBurnBarCLI" in script
    assert "import socket" not in script
    assert '"method": "daemon.health"' not in script
    assert "Daemon socket not found at $DAEMON_SOCKET after 20s" not in workflow
    assert "Library/Application Support/OpenBurnBar/openburnbar-daemon.sock" not in workflow


def test_local_source_builds_package_daemon_sqlcipher_runtime_before_signing():
    makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
    website_release = (ROOT / "scripts/build-macos-website-release.sh").read_text(encoding="utf-8")
    sqlcipher_verifier = (ROOT / "scripts/ci/verify-sqlcipher-codec.sh").read_text(encoding="utf-8")
    daemon_rpath_command = (
        'install_name_tool -add_rpath "@executable_path/../Frameworks" '
        '"$(APP_BUNDLE)/Contents/Helpers/$(DAEMON_BIN)"'
    )
    cli_rpath_command = (
        'install_name_tool -add_rpath "@executable_path/../Frameworks" '
        '"$(APP_BUNDLE)/Contents/Helpers/$(DAEMON_CLI_BIN)"'
    )

    build_section = makefile.split("build: bootstrap preflight", 1)[1].split(
        "build-signed: bootstrap preflight", 1
    )[0]
    signed_section = makefile.split("build-signed: bootstrap preflight", 1)[1].split(
        "release-mas: preflight", 1
    )[0]

    for section in (build_section, signed_section):
        assert (
            "swift build --package-path $(DAEMON_PACKAGE) -c release "
            "--product $(DAEMON_BIN)"
        ) in section
        assert (
            "swift build --package-path $(DAEMON_PACKAGE) -c release "
            "--product $(DAEMON_CLI_BIN)"
        ) in section
        assert (
            'cp "$(DAEMON_PACKAGE)/.build/release/$(DAEMON_CLI_BIN)" '
            '"$(APP_BUNDLE)/Contents/Helpers/$(DAEMON_CLI_BIN)"'
        ) in section
        assert "$(DAEMON_BIN) links SQLCipher.framework" in section
        assert "$(DAEMON_CLI_BIN) links SQLCipher.framework" in section
        assert daemon_rpath_command in section
        assert cli_rpath_command in section
        assert "links an external libsqlcipher dylib" in section

    signing_index = signed_section.index("scripts/sign-openburnbar-local.sh")
    assert signed_section.index(daemon_rpath_command) < signing_index
    assert signed_section.index(cli_rpath_command) < signing_index
    assert signed_section.index("links an external libsqlcipher dylib") < signing_index
    assert "Apple releases must use the embedded SQLCipher.framework only" in website_release
    assert "external_sqlcipher_loaders=()" in sqlcipher_verifier
    assert "Release app bundle still links an external SQLCipher dylib" in sqlcipher_verifier


def test_local_release_smoke_uses_signed_installed_layout_daemon_and_cli():
    smoke = (ROOT / "scripts/test-openburnbar-release-smoke.sh").read_text(encoding="utf-8")

    assert "requires an Apple Development code-signing identity" in smoke
    assert 'make -C "$repo_root" build-signed' in smoke
    assert 'cli_bin="$app_path/Contents/Helpers/OpenBurnBarCLI"' in smoke
    assert 'installed_daemon_dir="$support_dir/daemon"' in smoke
    assert 'installed_cli_bin="$installed_daemon_dir/OpenBurnBarCLI"' in smoke
    assert 'cp "$cli_bin" "$installed_cli_bin"' in smoke
    assert "--socket-auth-token-file" in smoke
    assert 'OPENBURNBAR_DAEMON_SOCKET_PATH="$socket_path"' in smoke
    assert 'OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN_FILE="$socket_auth_token_file"' in smoke
    assert 'python3 - "$installed_cli_bin"' in smoke
    assert '[cli, "health"]' in smoke
    assert "Authenticated daemon health RPC passed via installed-layout OpenBurnBarCLI" in smoke
    assert "import socket" not in smoke
    assert '"method": "daemon.health"' not in smoke
    assert '"OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN": "${socket_auth_token}"' not in smoke


def test_macos_release_does_not_require_unsupported_app_attest_entitlement():
    import plistlib

    local = plistlib.loads((ROOT / "AgentLens/Resources/OpenBurnBar.entitlements").read_bytes())
    direct = plistlib.loads((ROOT / "AgentLens/Resources/OpenBurnBarRelease.entitlements").read_bytes())
    app_store = plistlib.loads((ROOT / "AgentLens/Resources/OpenBurnBarMAS.entitlements").read_bytes())
    website_release = (ROOT / "scripts/build-macos-website-release.sh").read_text(encoding="utf-8")
    release_workflow = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")

    key = "com.apple.developer.devicecheck.appattest-environment"
    assert key not in local
    assert key not in direct
    assert key not in app_store

    for release_surface in (website_release, release_workflow):
        assert key not in release_surface


def test_signal_ffi_builder_clears_provenance_from_generated_rustc_wrapper():
    builder = (ROOT / "scripts/build-signal-ffi-xcframework.sh").read_text(encoding="utf-8")
    wrapper_function = builder.split("write_rustc_wrapper() {", 1)[1].split(
        "\n}\n\nensure_rust_target()", 1
    )[0]

    chmod = 'chmod +x "${RUSTC_WRAPPER_SCRIPT}"'
    clear_provenance = (
        '/usr/bin/xattr -d com.apple.provenance "${RUSTC_WRAPPER_SCRIPT}" '
        "2>/dev/null || true"
    )
    assert chmod in wrapper_function
    assert clear_provenance in wrapper_function
    assert wrapper_function.index(chmod) < wrapper_function.index(clear_provenance)


def test_local_app_signing_uses_same_privileged_peer_policy_as_release():
    script = (ROOT / "scripts/sign-openburnbar-local.sh").read_text(encoding="utf-8")

    assert (
        'sign_path "$APP_BUNDLE/Contents/Helpers/OpenBurnBarDaemon" "runtime,library" "com.openburnbar.app"'
        in script
    )
    assert 'sign_path "$APP_BUNDLE/Contents/Helpers/OpenBurnBarCLI" "runtime,library" "com.openburnbar.cli"' in script
    assert '"com.openburnbar.privileged-input-execution"' in script
    assert '"com.openburnbar.virtual-hid-bridge"' in script
    assert '"com.openburnbar.privileged-input-killswitch-watchdog"' in script
    assert "--options runtime,library" in script
    assert "assert_peer_signature" in script
    assert 'assert_peer_signature "$APP_BUNDLE" "com.openburnbar.app"' in script
    assert 'assert_peer_signature "$APP_BUNDLE/Contents/Helpers/OpenBurnBarDaemon" "com.openburnbar.app"' in script
    assert 'assert_peer_signature "$APP_BUNDLE/Contents/Helpers/OpenBurnBarCLI" "com.openburnbar.cli"' in script
    assert (
        'bash scripts/ci/verify-daemon-release-signing.sh "$APP_BUNDLE" "$TEAM_ID"'
        in script
    )
    assert (
        "assert_peer_signature \\\n"
        '  "$APP_BUNDLE/Contents/Helpers/OpenBurnBarPrivilegedInputExecution" \\\n'
        '  "com.openburnbar.privileged-input-execution"'
    ) in script
    assert (
        'assert_peer_signature "$APP_BUNDLE/Contents/Helpers/OpenBurnBarVirtualHIDBridge" '
        '"com.openburnbar.virtual-hid-bridge"'
    ) in script
    assert 'args+=(--preserve-metadata="$preserve_metadata")' in script
    assert "--preserve-metadata=entitlements,requirements" in script
    assert "--preserve-metadata=entitlements,requirements,flags" not in script
    assert 'codesign --force --sign "$IDENTITY" --timestamp=none "$path"' not in script


def test_daemon_token_file_arguments_override_inherited_environment():
    daemon_main = (
        ROOT / "OpenBurnBarDaemon/Sources/OpenBurnBarDaemonExecutable/OpenBurnBarDaemonMain.swift"
    ).read_text(encoding="utf-8")

    assert 'var socketAuthToken = environment["OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN"]' in daemon_main
    assert 'var gatewayAuthToken = environment["OPENBURNBAR_GATEWAY_AUTH_TOKEN"]' in daemon_main
    assert "gatewayAuthToken = try readTokenFile(arguments[index], argument: argument)" in daemon_main
    assert "socketAuthToken = try readTokenFile(arguments[index], argument: argument)" in daemon_main
    assert "if gatewayAuthToken == nil" not in daemon_main
    assert "if socketAuthToken == nil" not in daemon_main
