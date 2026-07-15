from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def test_release_workflow_does_not_require_or_inject_appcheck_debug_token():
    body = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")

    assert "FIREBASE_APP_CHECK_DEBUG_TOKEN" not in body
    assert "Verify Apple App Check public release policy" in body
    assert "Verify unsigned app App Check release artifact" in body
    assert "Verify packaged App Check release artifacts" in body
    assert "verify-apple-appcheck-release-artifact.sh" in body

    policy_index = body.index("Verify Apple App Check public release policy")
    inject_index = body.index("Inject Firebase config")
    unsigned_index = body.index("Verify unsigned app App Check release artifact")
    packaged_index = body.index("Verify packaged App Check release artifacts")
    feeds_index = body.index("Generate direct-download update feeds")
    checksums_index = body.index("Compute artifact checksums")
    staging_index = body.index("Stage the complete general release asset set")
    staged_verify_index = body.index(
        'bash scripts/ci/verify-apple-appcheck-release-artifact.sh "$DMG_PATH" "$ZIP_PATH"',
        staging_index,
    )
    publish_index = body.index("Publish the complete verified release set from one draft state machine")
    publisher_index = body.index(
        'node scripts/ci/publish-apple-android-release.mjs --manifest "$manifest"',
        publish_index,
    )

    assert policy_index < inject_index < unsigned_index
    assert unsigned_index < packaged_index < feeds_index < checksums_index
    assert checksums_index < staging_index < staged_verify_index < publish_index < publisher_index


def test_public_macos_release_scripts_run_appcheck_policy_and_artifact_scanner():
    website = (ROOT / "scripts/build-macos-website-release.sh").read_text(encoding="utf-8")
    mas = (ROOT / "scripts/build-macos-app-store-release.sh").read_text(encoding="utf-8")
    smoke = (ROOT / "scripts/ci/smoke-openburnbar-release-dmg.sh").read_text(encoding="utf-8")

    assert "verify-apple-appcheck-release-env.sh" in website
    assert "verify-apple-appcheck-release-env.sh" in mas
    assert "verify-apple-appcheck-release-env.sh" in smoke
    assert 'bash scripts/ci/verify-apple-appcheck-release-artifact.sh "$app_path"' in website
    assert 'bash scripts/ci/verify-apple-appcheck-release-artifact.sh "$dmg_path" "$zip_path"' in website
    assert 'bash scripts/ci/verify-apple-appcheck-release-artifact.sh "$archive_path"' in mas
    assert 'bash scripts/ci/verify-apple-appcheck-release-artifact.sh "$archive_path" "$export_path" "$export_artifact"' in mas
    assert 'bash "$script_dir/verify-apple-appcheck-release-artifact.sh" "$dmg_path"' in smoke
