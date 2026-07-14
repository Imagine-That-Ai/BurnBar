import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RELEASE_WORKFLOW = ROOT / ".github/workflows/release.yml"
DOMAIN_WORKFLOW = ROOT / ".github/workflows/domain-core.yml"
PUBLISHER = ROOT / "scripts/ci/publish-domain-core-native-release-evidence.sh"
SHARED_PUBLISHER = ROOT / "scripts/ci/publish-domain-core-release-evidence.mjs"
VERIFIER = ROOT / "scripts/ci/verify-domain-core-native-release-artifact.sh"


class DomainCoreNativeReleaseEvidenceWorkflowTests(unittest.TestCase):
    def test_release_builds_and_publishes_canonical_native_artifacts(self) -> None:
        source = RELEASE_WORKFLOW.read_text(encoding="utf-8")
        required = (
            'aab_name="OpenBurnBar-${VERSION}-Android.aab"',
            "aab_name: ${{ steps.android.outputs.aab_name }}",
            'sha256sum "$AAB_PATH"',
            'attest_release_blob "$AAB_PATH" "${AAB_PATH##*/}"',
            "domain-core-native-release-evidence:",
            "needs: [release-preflight, build-and-release, smoke-test]",
            "artifact-metadata: write",
            "domain-core-native-release-evidence-v${{ needs.release-preflight.outputs.version }}",
        )
        for value in required:
            self.assertIn(value, source)
        custom_publish = PUBLISHER.read_text(encoding="utf-8")
        self.assertNotIn("--clobber", custom_publish)
        self.assertIn('ASSETS=("$ZIP_PATH")', source)

    def test_exact_stable_tag_and_commit_gate_all_custom_attestations(self) -> None:
        source = RELEASE_WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("if: needs.release-preflight.outputs.is_prerelease == 'false'", source)
        self.assertIn('if [[ "$GITHUB_SHA" != "$release_commit" ]]', source)
        self.assertIn('test "$GITHUB_REF" = "$TAG_REF"', source)
        self.assertIn('test "$GITHUB_SHA" = "$RELEASE_COMMIT"', source)
        self.assertIn('test "$(git rev-parse HEAD)" = "$RELEASE_COMMIT"', source)
        self.assertIn('test "$(git rev-list -n 1 "${TAG_REF}^{commit}")" = "$RELEASE_COMMIT"', source)
        self.assertEqual(
            source.count("uses: actions/attest@a1948c3f048ba23858d222213b7c278aabede763"),
            10,
        )
        for step_id in (
            "attest-apple-quota",
            "attest-apple-cloud-vault",
            "attest-apple-cloud-vault-rewrap",
            "attest-apple-cloud-vault-search",
            "attest-apple-hermes",
            "attest-apple-pricing",
            "attest-android-cloud-vault",
            "attest-android-cloud-vault-rewrap",
            "attest-android-cloud-vault-search",
            "attest-android-hermes",
        ):
            self.assertIn(f"id: {step_id}", source)

    def test_native_artifacts_are_verified_before_predicates_are_created(self) -> None:
        source = RELEASE_WORKFLOW.read_text(encoding="utf-8")
        verify = source.index("Verify native release artifacts and embedded public profiles")
        apple = source.index("Create Apple domain-core predicates")
        android = source.index("Create Android domain-core predicates")
        self.assertLess(verify, apple)
        self.assertLess(verify, android)

        verifier = VERIFIER.read_text(encoding="utf-8")
        for value in (
            'codesign --verify --verbose=2 "$artifact"',
            'xcrun stapler validate "$artifact"',
            'codesign --verify --deep --strict --verbose=2 "$app"',
            'spctl --assess --type execute -vv "$app"',
            'if [[ "$architectures" != "arm64" ]]',
            'jarsigner -verify -verbose -certs "$artifact"',
            "base/lib/$abi/libopenburnbar_domain_ffi.so",
            '--apple-app "$app"',
            '--android-aab "$artifact"',
        ):
            self.assertIn(value, verifier)

    def test_publication_is_bundle_first_immutable_and_post_verified(self) -> None:
        adapter = PUBLISHER.read_text(encoding="utf-8")
        source = SHARED_PUBLISHER.read_text(encoding="utf-8")
        for value in (
            '"signerWorkflow": ".github/workflows/release.yml"',
            '"releaseAvailability": "draft-or-published"',
            '"artifactPath": os.path.abspath(artifact_path)',
            '"bundles": bundles',
            "node scripts/ci/publish-domain-core-release-evidence.mjs",
            '--manifest "$publication_manifest"',
        ):
            self.assertIn(value, adapter)
        required = (
            '"--signer-workflow"',
            '"--source-digest"',
            '"--source-ref"',
            "`refs/tags/${manifest.tag}`",
            '"--signer-digest"',
            '"--cert-oidc-issuer"',
            '"--deny-self-hosted-runners"',
            '"--predicate-type"',
            "does not contain its exact predicate",
            "refusing to replace non-identical immutable release asset",
            "published artifact bytes differ from the signed local artifact",
        )
        for value in required:
            self.assertIn(value, source)
        for forbidden in ("--clobber", '"create"', '"edit"'):
            self.assertNotIn(forbidden, adapter)
            self.assertNotIn(forbidden, source)
        publication = source.index("const uploaded = [];")
        bundle_upload = source.index("stagedBundles.get(bundle.assetName)", publication)
        artifact_upload = source.index("publication.artifactPath,", bundle_upload)
        self.assertLess(bundle_upload, artifact_upload)
        post_verify = source.index('const published = join(workspace, "published")', artifact_upload)
        self.assertGreater(post_verify, artifact_upload)

    def test_apple_identity_is_arm64_everywhere(self) -> None:
        predicate = json.loads((ROOT / "config/domain-core-release-predicate.schema.json").read_text())
        receipt = json.loads((ROOT / "config/domain-core-legacy-deletion-receipt.schema.json").read_text())
        generator = (ROOT / "scripts/ci/create-domain-core-release-evidence.mjs").read_text(encoding="utf-8")
        gate = (ROOT / "scripts/ci/verify-domain-core-legacy-deletion.py").read_text(encoding="utf-8")
        self.assertIn("macos-arm64", predicate["properties"]["target"]["enum"])
        self.assertNotIn("macos-universal", predicate["properties"]["target"]["enum"])
        target_enum = receipt["$defs"]["consumerRelease"]["properties"]["target"]["enum"]
        self.assertIn("macos-arm64", target_enum)
        self.assertNotIn("macos-universal", target_enum)
        self.assertIn('target: "macos-arm64"', generator)
        self.assertIn('"apple": ("macos-dmg", "macos-arm64")', gate)

    def test_domain_core_ci_runs_native_evidence_contracts(self) -> None:
        source = DOMAIN_WORKFLOW.read_text(encoding="utf-8")
        for value in (
            '"scripts/ci/create-domain-core-native-release-evidence.mjs"',
            '"scripts/ci/create-domain-core-native-release-evidence.test.mjs"',
            '"scripts/ci/verify-domain-core-native-release-artifact.sh"',
            '"scripts/ci/verify-domain-core-native-release-artifact.test.sh"',
            '"scripts/ci/publish-domain-core-native-release-evidence.sh"',
            '"scripts/ci/publish-domain-core-native-release-evidence.test.sh"',
            '"tests/test_domain_core_native_release_evidence_workflow.py"',
            "scripts/ci/create-domain-core-native-release-evidence.test.mjs",
            "bash scripts/ci/verify-domain-core-native-release-artifact.test.sh",
            "bash scripts/ci/publish-domain-core-native-release-evidence.test.sh",
            "python3 tests/test_domain_core_native_release_evidence_workflow.py",
        ):
            self.assertIn(value, source)


if __name__ == "__main__":
    unittest.main()
