import json
import re
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


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
    app_build_index = body.index("- name: Build Release .app (unsigned)")
    prepare_step = body[prepare_start:lockfile_index]
    app_build_end = body.index("- name: Embed daemon binary in app bundle", app_build_index)
    app_build_step = body[app_build_index:app_build_end]

    assert prepare_start < lockfile_index < app_build_index
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
    assert "prepare-openburnbar-app-swiftpm.sh" in app_build_step
    assert "openburnbar_prepare_libsignal_swift_compat" in app_build_step


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
    rpath_command = (
        'install_name_tool -add_rpath "@executable_path/../Frameworks" '
        '"$(APP_BUNDLE)/Contents/Helpers/$(DAEMON_BIN)"'
    )
    framework_guard = (
        "links SQLCipher.framework but the app bundle is missing "
        "Contents/Frameworks/SQLCipher.framework"
    )

    build_section = makefile.split("build: bootstrap preflight", 1)[1].split(
        "build-signed: bootstrap preflight", 1
    )[0]
    signed_section = makefile.split("build-signed: bootstrap preflight", 1)[1].split(
        "release-mas: preflight", 1
    )[0]

    assert rpath_command in build_section
    assert framework_guard in build_section
    assert rpath_command in signed_section
    assert framework_guard in signed_section
    assert signed_section.index(rpath_command) < signed_section.index("scripts/sign-openburnbar-local.sh")


def test_local_and_release_app_builds_share_lock_exact_swiftpm_lifecycle():
    makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
    wrapper = (ROOT / "scripts/build-openburnbar-local-app.sh").read_text(
        encoding="utf-8"
    )
    workflow = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")

    build_section = makefile.split("build: bootstrap preflight", 1)[1].split(
        "build-signed: bootstrap preflight", 1
    )[0]
    signed_section = makefile.split("build-signed: bootstrap preflight", 1)[1].split(
        "release-mas: preflight", 1
    )[0]
    release_app_section = workflow.split(
        "- name: Build Release .app (unsigned)", 1
    )[1].split("- name:", 1)[0]

    for local_section in (build_section, signed_section):
        assert "scripts/build-openburnbar-local-app.sh" in local_section
        assert "xcodebuild -resolvePackageDependencies" not in local_section

    for source in (wrapper, release_app_section):
        assert "prepare-openburnbar-app-swiftpm.sh" in source
        assert "-disableAutomaticPackageResolution" in source
        assert "-onlyUsePackageVersionsFromResolvedFile" in source
        assert "openburnbar_prepare_google_sign_in_macos_compat" in source
        assert "openburnbar_prepare_libsignal_swift_compat" in source
        assert "xcodebuild -resolvePackageDependencies" not in source

    assert 'FIREBASE_SOURCE_FIRESTORE: "1"' in workflow


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


def test_safari_host_entitlements_share_exact_app_group_and_keychain_across_channels():
    import plistlib

    expected_app_group = ["group.com.openburnbar.app"]
    expected_keychain_group = ["$(AppIdentifierPrefix)com.openburnbar.app"]
    entitlement_paths = (
        "AgentLens/Resources/OpenBurnBar.entitlements",
        "AgentLens/Resources/OpenBurnBarRelease.entitlements",
        "AgentLens/Resources/OpenBurnBarMAS.entitlements",
    )
    for entitlement_path in entitlement_paths:
        entitlements = plistlib.loads((ROOT / entitlement_path).read_bytes())
        assert (
            entitlements["com.apple.security.application-groups"]
            == expected_app_group
        ), entitlement_path
        assert (
            entitlements["keychain-access-groups"] == expected_keychain_group
        ), entitlement_path

    website_release = (
        ROOT / "scripts/build-macos-website-release.sh"
    ).read_text(encoding="utf-8")
    release_workflow = (ROOT / ".github/workflows/release.yml").read_text(
        encoding="utf-8"
    )
    public_trust = (
        ROOT / "scripts/ci/verify-public-macos-download-trust.sh"
    ).read_text(encoding="utf-8")
    mas_release = (
        ROOT / "scripts/build-macos-app-store-release.sh"
    ).read_text(encoding="utf-8")
    mas_readiness = (
        ROOT / "scripts/verify-macos-app-store-readiness.sh"
    ).read_text(encoding="utf-8")

    for direct_surface in (website_release, release_workflow, public_trust):
        assert "group.com.openburnbar.app" in direct_surface
        assert "application-groups" in direct_surface
        assert "Keychain" in direct_surface

    assert "app_profile_app_groups" in website_release
    assert "actual_app_groups" in website_release
    assert "APP_PROFILE_APP_GROUPS" in release_workflow
    assert "ACTUAL_APP_GROUPS" in release_workflow
    assert "profile_app_groups" in public_trust
    assert "actual_app_groups" in public_trust

    for mas_surface in (mas_release, mas_readiness):
        assert "com.apple.security.application-groups" in mas_surface
        assert "keychain-access-groups" in mas_surface
        assert "group.com.openburnbar.app" in mas_surface
    assert "exported-entitlements.plist" in mas_release
    assert 'codesign -d --entitlements :- "$exported_app_path"' in mas_release


def test_safari_appex_release_signing_is_explicit_profile_bound_and_nested_first():
    workflow = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
    website_release = (ROOT / "scripts/build-macos-website-release.sh").read_text(
        encoding="utf-8"
    )
    mas_release = (ROOT / "scripts/build-macos-app-store-release.sh").read_text(
        encoding="utf-8"
    )
    mas_readiness = (ROOT / "scripts/verify-macos-app-store-readiness.sh").read_text(
        encoding="utf-8"
    )
    public_trust = (
        ROOT / "scripts/ci/verify-public-macos-download-trust.sh"
    ).read_text(encoding="utf-8")
    public_trust_workflow = (
        ROOT / ".github/workflows/public-macos-download-trust.yml"
    ).read_text(encoding="utf-8")
    dmg_smoke = (ROOT / "scripts/ci/smoke-openburnbar-release-dmg.sh").read_text(
        encoding="utf-8"
    )
    makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
    project = (ROOT / "project.yml").read_text(encoding="utf-8")

    profile_secret = "OPENBURNBAR_SAFARI_EXTENSION_PROFILE_BASE64"
    sign_helper = "scripts/ci/sign-openburnbar-safari-extension.sh"
    verify_helper = "scripts/ci/verify-openburnbar-safari-extension.sh"
    development_verify_helper = (
        "scripts/ci/verify-openburnbar-development-signing.sh"
    )
    host_entitlement_variable = "OPENBURNBAR_HOST_CODE_SIGN_ENTITLEMENTS"

    assert profile_secret in workflow
    assert workflow.count(profile_secret) >= 5
    assert sign_helper in workflow
    assert verify_helper in workflow
    assert workflow.index(sign_helper) < workflow.index(
        'cp "$APP_PROFILE" "$APP_PATH/Contents/embedded.provisionprofile"'
    )
    assert website_release.index(sign_helper) < website_release.index(
        'cp "$app_profile" "$app_path/Contents/embedded.provisionprofile"'
    )
    assert "OPENBURNBAR_SAFARI_EXTENSION_PROFILE" in website_release

    assert verify_helper in public_trust
    assert "scripts/ci/verify-openburnbar-safari-extension.test.sh" in (
        public_trust_workflow
    )
    assert "scripts/ci/verify-openburnbar-safari-extension-layout\\.py" in (
        public_trust_workflow
    )
    assert "bash scripts/ci/verify-openburnbar-safari-extension.test.sh" in (
        public_trust_workflow
    )
    assert development_verify_helper in public_trust_workflow
    assert "bash scripts/ci/verify-openburnbar-development-signing.test.sh" in (
        public_trust_workflow
    )
    assert development_verify_helper in makefile
    assert "OTHER_CODE_SIGN_FLAGS: --options runtime,library" in project
    assert "$script_dir/verify-openburnbar-safari-extension.sh" in dmg_smoke
    assert mas_release.count(verify_helper) >= 2
    assert "pkgutil --expand-full" in mas_release
    assert "export-inspection" in mas_release

    assert (
        f'CODE_SIGN_ENTITLEMENTS: "$({host_entitlement_variable})"' in project
    )
    for mas_surface in (mas_release, mas_readiness):
        assert f'{host_entitlement_variable}="$entitlements"' in mas_surface
        assert re.search(
            r'(?m)^\s*CODE_SIGN_ENTITLEMENTS="\$entitlements"', mas_surface
        ) is None
        assert "scripts/test-openburnbar-safari-extension.sh" in mas_surface


def test_safari_extension_ci_uses_one_canonical_wrapper_and_fail_closed_diff_coverage():
    makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
    fast_feedback = (ROOT / ".github/workflows/fast-feedback.yml").read_text(
        encoding="utf-8"
    )
    app_gate = (ROOT / ".github/workflows/app-pr-gate.yml").read_text(
        encoding="utf-8"
    )
    diff_coverage = (ROOT / "scripts/diff-coverage-ts.sh").read_text(
        encoding="utf-8"
    )
    wrapper = (ROOT / "scripts/test-openburnbar-safari-extension.sh").read_text(
        encoding="utf-8"
    )

    assert "./scripts/test-openburnbar-safari-extension.sh" in makefile
    assert "safari-extension-fast:" in fast_feedback
    assert "needs.classify.outputs.safari == 'true'" in fast_feedback
    assert "extensions/safari/package-lock.json" in fast_feedback
    assert "./scripts/test-openburnbar-safari-extension.sh" in fast_feedback
    assert (
        "'safari-extension-fast': os.environ.get('SAFARI_REQUIRED') == 'true'"
        in fast_feedback
    )
    assert "extensions/safari/src/**/*.ts" in diff_coverage
    assert "extensions/safari/coverage/coverage-final.json" not in diff_coverage
    assert '"extensions", "safari", "coverage", "coverage-final.json"' in diff_coverage
    assert "rm -rf \"$repo_root/extensions/safari/coverage\"" in diff_coverage
    assert "npm ci --prefix \"$repo_root/extensions/safari\"" in diff_coverage
    assert 'npm run test:ci --prefix "$extension_root"' in wrapper
    assert 'npm ci --prefix "$extension_root"' in wrapper
    assert "package-lock.json" in wrapper
    assert "extensions/safari/package-lock.json" in app_gate
    assert "npm ci --prefix extensions/safari" in app_gate
    assert "npm run build --prefix extensions/safari" in app_gate


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


def test_iroh_builder_preserves_generated_swiftlint_rationale():
    builder = (ROOT / "scripts/build-iroh-xcframework.sh").read_text(
        encoding="utf-8"
    )
    generated_source = (
        ROOT
        / "OpenBurnBarCore/Sources/OpenBurnBarIroh/Generated/openburnbar_iroh.swift"
    ).read_text(encoding="utf-8")
    rationale = (
        "// swiftlint:disable all -- reason: generated UniFFI binding; "
        "regenerate from Rust sources instead of hand-editing."
    )

    assert rationale in builder
    assert (
        "generated UniFFI Swift source retained an unjustified SwiftLint suppression"
        in builder
    )
    assert rationale in generated_source
    assert "\n// swiftlint:disable all\n" not in generated_source


def test_iroh_builder_strips_fresh_staging_archives_instead_of_cargo_cache():
    builder = (ROOT / "scripts/build-iroh-xcframework.sh").read_text(
        encoding="utf-8"
    )
    archive_helper = (ROOT / "scripts/lib/apple-static-archive.sh").read_text(
        encoding="utf-8"
    )
    build_target = builder.split("build_target() {", 1)[1].split(
        "\n}\n\nmkdir -p", 1
    )[0]
    staging_helper = builder.split("stage_release_archive() {", 1)[1].split(
        "\n}\n\n# Group iOS", 1
    )[0]
    transaction_cleanup = builder.split(
        "cleanup_xcframework_transaction() {", 1
    )[1].split("\n}\n\ncleanup_on_exit()", 1)[0]
    transaction_install = builder.split("generated_needs_install=1", 1)[1].split(
        "\nTRANSACTION_COMMITTED=1", 1
    )[0]

    assert "xcrun strip" not in build_target
    assert "Cargo did not produce the expected Iroh archive" in build_target
    assert 'cp "${source_archive}" "${destination_archive}"' in staging_helper
    assert 'ZERO_AR_DATE=1 xcrun strip -S "${destination_archive}"' in staging_helper
    assert (
        'openburnbar_prune_symbol_empty_archive_members "${destination_archive}"'
        in staging_helper
    )
    assert staging_helper.index(
        'openburnbar_prune_symbol_empty_archive_members "${destination_archive}"'
    ) < staging_helper.index(
        'ZERO_AR_DATE=1 xcrun strip -S "${destination_archive}"'
    )
    assert 'if [[ -s "${strip_log}" ]]' in staging_helper
    assert "Unable to classify Apple static archive members" in archive_helper
    assert "has no symbols" in archive_helper
    assert '-filelist "$object_list"' in archive_helper
    assert (
        "Refusing to normalize an archive with duplicate member names"
        in archive_helper
    )
    assert 'PROCESS_TMPDIR="${IROH_BUILD_TMPDIR:-/tmp}"' in builder
    assert 'export TMPDIR="${PROCESS_TMPDIR%/}/"' in builder
    assert (
        'CARGO_HOME_REQUESTED="${IROH_CARGO_HOME:-'
        '${CARGO_HOME:-${HOME}/.cargo}}"'
        in builder
    )
    assert "inherited Cargo home is unavailable" in builder
    assert 'export CARGO_HOME="${CARGO_HOME_REQUESTED}"' in builder
    assert (
        'XCFRAMEWORK_STAGING="${ROOT_DIR}/build/'
        'OpenBurnBarIroh.staging.$$.xcframework"'
        in builder
    )
    assert 'XCFRAMEWORK_BACKUP="${ROOT_DIR}/build/OpenBurnBarIroh.xcframework.backup.$$"' in builder
    assert 'GENERATED_STAGING="${ROOT_DIR}/build/OpenBurnBarIrohGenerated.staging.$$"' in builder
    assert 'GENERATED_BACKUP="${ROOT_DIR}/build/OpenBurnBarIrohGenerated.backup.$$"' in builder
    assert 'UNIFFI_OUT_DIR="${GENERATED_STAGING}"' in builder
    assert 'diff -qr "${GENERATED_STAGING}" "${GENERATED_DIR}"' in builder
    assert "-output \"${XCFRAMEWORK_STAGING}\"" in builder
    assert (
        'openburnbar_verify_apple_static_archive_has_no_empty_members \\\n'
        '  "${XCFRAMEWORK_STAGING}/macos-arm64/libopenburnbar_iroh.a"'
        in builder
    )
    assert 'rm -rf "${XCFRAMEWORK}"' not in transaction_install
    assert 'rm -rf "${GENERATED_DIR}"' not in transaction_install
    assert transaction_install.index(
        'mv "${XCFRAMEWORK}" "${XCFRAMEWORK_BACKUP}"'
    ) < transaction_install.index(
        'mv "${XCFRAMEWORK_STAGING}" "${XCFRAMEWORK}"'
    )
    assert transaction_install.index(
        'mv "${GENERATED_DIR}" "${GENERATED_BACKUP}"'
    ) < transaction_install.index(
        'mv "${GENERATED_STAGING}" "${GENERATED_DIR}"'
    )
    assert transaction_cleanup.index(
        'rm -rf "${XCFRAMEWORK}"'
    ) < transaction_cleanup.index(
        'mv "${XCFRAMEWORK_BACKUP}" "${XCFRAMEWORK}"'
    )
    assert transaction_cleanup.index(
        'rm -rf "${GENERATED_DIR}"'
    ) < transaction_cleanup.index(
        'mv "${GENERATED_BACKUP}" "${GENERATED_DIR}"'
    )
    assert (
        'stage_release_archive \\\n'
        '    "${CARGO_TARGET_ROOT}/${target}/${PROFILE_DIR}/libopenburnbar_iroh.a" \\\n'
        '    "${out_dir}/libopenburnbar_iroh.a"'
    ) in builder
    assert (
        '"${SIM_ARM64_DIR}/libopenburnbar_iroh.a" \\\n'
        '    "${SIM_X86_64_DIR}/libopenburnbar_iroh.a"'
        in builder
    )


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
