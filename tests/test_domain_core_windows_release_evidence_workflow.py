import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/openburnbar-release-windows.yml"
ARCHIVE_HELPER = ROOT / "scripts/ci/create-windows-domain-core-release-bundle.py"
PUBLISH_HELPER = ROOT / "scripts/ci/publish-windows-domain-core-release-evidence.py"


class DomainCoreWindowsReleaseEvidenceWorkflowTests(unittest.TestCase):
    def test_publisher_requires_fully_signed_release_and_supply_chain(self) -> None:
        source = WORKFLOW.read_text(encoding="utf-8")
        required = (
            "deletion_grade_release: ${{ steps.release-ready.outputs.enabled }}",
            "if: steps.config.outputs.codesign == 'true' && steps.config.outputs.updatekey == 'true'",
            "publish-domain-core-release-evidence:",
            "needs.build-sign.outputs.deletion_grade_release == 'true'",
            "- supply-chain",
            "environment: windows-release",
            "actions: read",
            "contents: write",
            "id-token: write",
            "attestations: write",
            "artifact-metadata: write",
        )
        for value in required:
            self.assertIn(value, source)

    def test_publisher_rebinds_exact_tag_ref_sha_and_release_commit(self) -> None:
        source = WORKFLOW.read_text(encoding="utf-8")
        required = (
            "ref: ${{ needs.resolve-release.outputs.release_commit }}",
            "persist-credentials: false",
            '"$GITHUB_REF" != "$RELEASE_TAG_REF"',
            '"$GITHUB_REF" != "refs/tags/$expected_tag"',
            '"$GITHUB_SHA" != "$RELEASE_COMMIT"',
            'git rev-parse "$RELEASE_TAG_REF^{commit}"',
            "Windows release tag moved after authorization",
        )
        for value in required:
            self.assertIn(value, source)

    def test_canonical_bundle_and_both_domain_predicates_are_generated(self) -> None:
        source = WORKFLOW.read_text(encoding="utf-8")
        required = (
            "scripts/ci/create-windows-domain-core-release-bundle.py",
            "OpenBurnBar-${VERSION}-windows-release.zip",
            "--consumer windows",
            "--domain quota",
            "--domain cloudVault",
            "OpenBurnBar-${VERSION}-windows-release-quota.sigstore.json",
            "OpenBurnBar-${VERSION}-windows-release-cloudvault.sigstore.json",
        )
        for value in required:
            self.assertIn(value, source)
        self.assertEqual(source.count("--consumer windows"), 2)

    def test_attestations_are_signed_by_this_workflow_and_published_last(self) -> None:
        source = WORKFLOW.read_text(encoding="utf-8")
        self.assertEqual(
            source.count("actions/attest@a1948c3f048ba23858d222213b7c278aabede763"),
            2,
        )
        self.assertEqual(
            source.count("predicate-type: https://openburnbar.dev/attestations/domain-core-release-artifact/v1"),
            2,
        )
        self.assertIn("scripts/ci/publish-windows-domain-core-release-evidence.py", source)
        self.assertIn("Publish bundles first and immutable canonical artifact last", source)
        self.assertNotIn("--clobber", source)

    def test_helpers_encode_exact_identity_and_fail_closed_publication(self) -> None:
        archive = ARCHIVE_HELPER.read_text(encoding="utf-8")
        publisher = PUBLISH_HELPER.read_text(encoding="utf-8")
        for value in (
            '"target": "windows-x64-arm64"',
            '"x64"',
            '"arm64"',
            '"appcast-windows.xml"',
            '"latest-windows.json"',
            "FIXED_ZIP_TIME",
        ):
            self.assertIn(value, archive)
        for value in (
            'SIGNER_WORKFLOW = ".github/workflows/openburnbar-release-windows.yml"',
            '"--source-digest"',
            '"--source-ref"',
            '"--signer-digest"',
            '"--deny-self-hosted-runners"',
            "cannot be published to a draft release",
            "cannot be published to a prerelease",
            "refusing to replace non-identical immutable release asset",
            "Bundles are intentionally public before their subject",
        ):
            self.assertIn(value, publisher)
        self.assertNotIn("--clobber", publisher)
        self.assertNotIn('release", "edit', publisher)


if __name__ == "__main__":
    unittest.main()
