#!/usr/bin/env python3
"""Focused tests for Gradle dependency extraction in generate-sbom.py."""

import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[1]
GENERATOR_PATH = REPO_ROOT / "scripts" / "generate-sbom.py"

spec = importlib.util.spec_from_file_location("generate_sbom", GENERATOR_PATH)
assert spec and spec.loader
generate_sbom = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generate_sbom)


class GradleDependencyExtractionTests(unittest.TestCase):
    def test_collect_gradle_dependencies_resolves_variables_and_bom_managed_coordinates(self) -> None:
        with tempfile.TemporaryDirectory(prefix="obb-sbom-gradle-") as tmp:
            root = Path(tmp)
            app_gradle = root / "android" / "app" / "build.gradle.kts"
            app_gradle.parent.mkdir(parents=True)
            app_gradle.write_text(
                """
plugins {
    id("com.android.application") version "8.13.1"
}

dependencies {
    val cameraXVersion = "1.4.0"
    val roomVersion = "2.8.4"
    val composeBom = platform("androidx.compose:compose-bom:2024.12.01")

    implementation(composeBom)
    implementation(platform("com.google.firebase:firebase-bom:33.7.0"))
    implementation("androidx.compose.ui:ui")
    implementation("com.google.firebase:firebase-auth-ktx")
    implementation("androidx.camera:camera-core:$cameraXVersion")
    implementation("androidx.room:room-runtime:${roomVersion}")
    api("net.java.dev.jna:jna:5.19.0@aar")
    implementation("com.example:unmanaged")

    // implementation("com.comment:ignored:1.0.0")
}
""",
                encoding="utf-8",
            )
            subprocess.run(["git", "init"], cwd=root, check=True, capture_output=True, text=True)
            subprocess.run(["git", "add", "."], cwd=root, check=True, capture_output=True, text=True)

            deps = generate_sbom.collect_gradle_dependencies(root)
            by_name = {dep["name"]: dep for dep in deps}

            self.assertEqual(by_name["com.android.application"]["version"], "8.13.1")
            self.assertEqual(by_name["androidx.camera:camera-core"]["version"], "1.4.0")
            self.assertEqual(by_name["androidx.room:room-runtime"]["version"], "2.8.4")
            self.assertEqual(by_name["net.java.dev.jna:jna"]["version"], "5.19.0")
            self.assertEqual(by_name["androidx.compose:compose-bom"]["version"], "2024.12.01")
            self.assertEqual(by_name["com.google.firebase:firebase-bom"]["version"], "33.7.0")
            self.assertEqual(
                by_name["androidx.compose.ui:ui"]["version"],
                "managed-by-bom:androidx.compose:compose-bom@2024.12.01",
            )
            self.assertEqual(
                by_name["com.google.firebase:firebase-auth-ktx"]["version"],
                "managed-by-bom:com.google.firebase:firebase-bom@33.7.0",
            )
            self.assertEqual(by_name["com.example:unmanaged"]["version"], "NOASSERTION")
            self.assertNotIn("com.comment:ignored", by_name)


class PackageOriginPreservationTests(unittest.TestCase):
    def test_dedupe_keeps_same_package_version_from_distinct_origins(self) -> None:
        deps = generate_sbom.dedupe_packages(
            [
                {
                    "type": "cargo",
                    "name": "shared-lib",
                    "version": "1.2.3",
                    "url": "https://mirror.example/shared-lib-1.2.3.tar.gz",
                    "source": "Cargo.lock",
                },
                {
                    "type": "cargo",
                    "name": "shared-lib",
                    "version": "1.2.3",
                    "url": "https://crates.io/crates/shared-lib",
                    "source": "crates/tool/Cargo.lock",
                },
                {
                    "type": "cargo",
                    "name": "shared-lib",
                    "version": "1.2.3",
                    "url": "https://crates.io/crates/shared-lib",
                    "source": "duplicate/Cargo.lock",
                },
            ]
        )

        self.assertEqual(len(deps), 2)
        self.assertEqual(
            {dep["url"] for dep in deps},
            {
                "https://crates.io/crates/shared-lib",
                "https://mirror.example/shared-lib-1.2.3.tar.gz",
            },
        )

    def test_spdx_document_emits_each_preserved_origin_download_location(self) -> None:
        deps = generate_sbom.dedupe_packages(
            [
                {
                    "type": "npm",
                    "name": "@openburnbar/example",
                    "version": "4.5.6",
                    "url": "https://registry.npmjs.org/@openburnbar/example/-/example-4.5.6.tgz",
                    "source": "package-lock.json",
                },
                {
                    "type": "npm",
                    "name": "@openburnbar/example",
                    "version": "4.5.6",
                    "url": "https://mirror.example/npm/@openburnbar/example-4.5.6.tgz",
                    "source": "tools/package-lock.json",
                },
            ]
        )

        doc = generate_sbom.build_spdx_document("test", REPO_ROOT, [], deps, [], [])
        packages = [pkg for pkg in doc["packages"] if pkg["name"] == "@openburnbar/example"]

        self.assertEqual(len(packages), 2)
        self.assertEqual(
            {pkg["downloadLocation"] for pkg in packages},
            {
                "https://registry.npmjs.org/@openburnbar/example/-/example-4.5.6.tgz",
                "https://mirror.example/npm/@openburnbar/example-4.5.6.tgz",
            },
        )


class ExactCandidateGitAuthorityTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory(prefix="openburnbar-sbom-git-")
        self.root = Path(self.tempdir.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        subprocess.run(["git", "init", "-q"], cwd=self.repo, check=True)
        subprocess.run(
            ["git", "config", "user.name", "OpenBurnBar Fixture"],
            cwd=self.repo,
            check=True,
        )
        subprocess.run(
            ["git", "config", "user.email", "fixture@openburnbar.invalid"],
            cwd=self.repo,
            check=True,
        )
        (self.repo / "README.md").write_text("base\n", encoding="utf-8")
        subprocess.run(["git", "add", "README.md"], cwd=self.repo, check=True)
        subprocess.run(["git", "commit", "-qm", "base"], cwd=self.repo, check=True)

        self.git_dir = self.root / "candidate.git"
        subprocess.run(
            ["git", "clone", "--bare", "-q", str(self.repo), str(self.git_dir)],
            check=True,
        )
        self.index = self.git_dir / "candidate-index"
        self.git_env = {
            "GIT_DIR": str(self.git_dir),
            "GIT_WORK_TREE": str(self.repo),
            "GIT_INDEX_FILE": str(self.index),
        }
        subprocess.run(["git", "read-tree", "HEAD"], env={**os.environ, **self.git_env}, check=True)

        resolved = self.repo / "Candidate" / "Package.resolved"
        resolved.parent.mkdir()
        resolved.write_text(
            json.dumps(
                {
                    "version": 2,
                    "pins": [
                        {
                            "identity": "candidate-only",
                            "kind": "remoteSourceControl",
                            "location": "https://example.invalid/candidate-only.git",
                            "state": {"revision": "1" * 40, "version": "1.2.3"},
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )
        subprocess.run(
            ["git", "add", "Candidate/Package.resolved"],
            env={**os.environ, **self.git_env},
            check=True,
        )
        tree = subprocess.run(
            ["git", "write-tree"],
            env={**os.environ, **self.git_env},
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        parent = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            env={**os.environ, **self.git_env},
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        self.commit = subprocess.run(
            ["git", "commit-tree", tree, "-p", parent, "-m", "candidate"],
            env={**os.environ, **self.git_env},
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        subprocess.run(
            ["git", "update-ref", "refs/heads/candidate", self.commit],
            env={**os.environ, **self.git_env},
            check=True,
        )
        subprocess.run(
            ["git", "symbolic-ref", "HEAD", "refs/heads/candidate"],
            env={**os.environ, **self.git_env},
            check=True,
        )

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def test_collectors_and_document_use_inherited_alternate_index_authority(self) -> None:
        with mock.patch.dict(os.environ, self.git_env, clear=False):
            self.assertEqual(generate_sbom.validate_git_authority(self.repo), self.commit)
            dependencies = generate_sbom.collect_spm_dependencies(self.repo)
            document = generate_sbom.build_spdx_document(
                "1.2.3",
                self.repo,
                dependencies,
                [],
                [],
                [],
            )

        self.assertEqual([dependency["name"] for dependency in dependencies], ["candidate-only"])
        self.assertIn(f"Tool: git+{self.commit[:12]}", document["creationInfo"]["creators"])

    def test_mismatched_work_tree_fails_closed(self) -> None:
        other = self.root / "other"
        other.mkdir()
        with mock.patch.dict(os.environ, self.git_env, clear=False):
            with self.assertRaisesRegex(
                generate_sbom.CommandError,
                "instead of requested",
            ):
                generate_sbom.validate_git_authority(other)

    def test_git_failure_raises_instead_of_emitting_empty_inventory(self) -> None:
        bad_env = {
            **self.git_env,
            "GIT_DIR": str(self.root / "missing.git"),
        }
        with mock.patch.dict(os.environ, bad_env, clear=False):
            with self.assertRaises(generate_sbom.CommandError):
                generate_sbom.git_tracked_files(self.repo, "**/Package.resolved")


if __name__ == "__main__":
    unittest.main()
