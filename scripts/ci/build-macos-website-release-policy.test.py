#!/usr/bin/env python3

from __future__ import annotations

import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "build-macos-website-release.sh"


class WebsiteReleasePolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = SCRIPT.read_text(encoding="utf-8")

    def test_notary_key_is_ephemeral_and_not_written_to_release_output(self) -> None:
        self.assertIn('local key_file="$notary_work_dir/AuthKey.p8"', self.source)
        self.assertNotIn('$release_dir/AuthKey.p8', self.source)
        self.assertIn('chmod 700 "$notary_work_dir"', self.source)
        self.assertIn('rm -rf "$notary_work_dir" || notary_cleanup_status=$?', self.source)
        self.assertIn("Ephemeral notarization credentials must be stored outside", self.source)
        self.assertIn('"the release output directory."', self.source)

    def test_release_does_not_mutate_shared_notary_cache(self) -> None:
        self.assertNotIn("com.apple.gke.notary.tool", self.source)
        self.assertNotRegex(self.source, r"rm\s+-f\s+.*Library/Caches")

    def test_notarization_is_structured_and_fail_closed(self) -> None:
        self.assertEqual(self.source.count("--output-format json"), 2)
        self.assertEqual(self.source.count("write_notary_receipt \\"), 2)
        self.assertIn("status must be 'Accepted'", self.source)
        self.assertIn("release certification fails closed", self.source)
        self.assertIn("from exclusive_json import write_exclusive_json", self.source)
        self.assertNotIn("receipt_path.write_text", self.source)

    def test_sbom_and_mounted_dmg_smoke_are_mandatory(self) -> None:
        sbom_command = (
            'python3 scripts/generate-sbom.py --version "$version" '
            '--repo-root "$repo_root" --output "$sbom_path"'
        )
        self.assertIn(sbom_command, self.source)
        self.assertNotIn(f"{sbom_command} || true", self.source)
        self.assertIn(
            'bash scripts/ci/smoke-openburnbar-release-dmg.sh "$dmg_path"',
            self.source,
        )

    def test_exact_candidate_identity_and_cleanliness_are_required(self) -> None:
        self.assertIn(
            'candidate_commit="${OPENBURNBAR_CANDIDATE_COMMIT:-}"',
            self.source,
        )
        self.assertIn(
            'candidate_tree="${OPENBURNBAR_CANDIDATE_TREE:-}"',
            self.source,
        )
        self.assertIn(
            "require full lowercase OPENBURNBAR_CANDIDATE_COMMIT and "
            "OPENBURNBAR_CANDIDATE_TREE values",
            self.source,
        )
        self.assertNotIn(
            'OPENBURNBAR_CANDIDATE_COMMIT:-$(openburnbar_candidate_git rev-parse HEAD)',
            self.source,
        )
        self.assertNotIn(
            "OPENBURNBAR_CANDIDATE_TREE:-$(openburnbar_candidate_git rev-parse 'HEAD^{tree}')",
            self.source,
        )
        self.assertIn('git status --porcelain=v1 --untracked-files=all', self.source)
        self.assertIn('git rev-parse "$candidate_commit^{tree}"', self.source)
        self.assertNotIn(
            "identity=\"$(security find-identity",
            self.source,
        )
        self.assertIn(
            "first-identity fallback is forbidden",
            self.source,
        )
        self.assertNotIn("OPENBURNBAR_SKIP_XCODE_BUILD", self.source)
        self.assertNotIn("reusing existing app", self.source)

    def test_corresponding_source_is_built_from_detached_exact_candidate(self) -> None:
        self.assertIn(
            "bash scripts/ci/build-corresponding-source-archive.sh \\",
            self.source,
        )
        self.assertNotIn(
            "bash scripts/create-corresponding-source.sh --version",
            self.source,
        )

    def test_artifacts_are_unique_and_receipt_is_candidate_bound(self) -> None:
        self.assertIn("require_unique_release_artifact", self.source)
        self.assertIn("--candidate-commit", self.source)
        self.assertIn("--candidate-tree", self.source)
        self.assertIn("--app-notary-artifact-sha256", self.source)
        self.assertIn("--dmg-notary-artifact-sha256", self.source)
        self.assertIn("--artifact dmg", self.source)

    def test_release_output_is_fresh_and_never_recursively_replaced(self) -> None:
        self.assertIn("resolve_fresh_release_output_dir", self.source)
        self.assertIn("create_fresh_release_output_dir", self.source)
        self.assertIn('"Developer ID release directory"', self.source)
        self.assertNotIn('mkdir -p "$release_dir"', self.source)
        self.assertNotIn('chmod 700 "$release_dir"', self.source)
        self.assertNotIn('rm -rf "$release_dir"', self.source)


if __name__ == "__main__":
    unittest.main()
