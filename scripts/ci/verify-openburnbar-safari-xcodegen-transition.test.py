#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name(
    "verify-openburnbar-safari-xcodegen-transition.py"
)
SPEC = importlib.util.spec_from_file_location("safari_xcodegen_transition", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class ProjectBuilder:
    def __init__(self, *, compact_objects: bool = False) -> None:
        self.next_identifier = 1
        self.objects: list[str] = []
        self.compact_objects = compact_objects

    def identifier(self) -> str:
        value = f"{self.next_identifier:024X}"
        self.next_identifier += 1
        return value

    def add(self, identifier: str, comment: str, body: str) -> None:
        if self.compact_objects:
            compact_body = " ".join(
                line.strip() for line in body.splitlines() if line.strip()
            )
            self.objects.append(
                f"\t\t{identifier} /* {comment} */ = "
                f"{{ {compact_body} }};\n"
            )
            return
        self.objects.append(
            f"\t\t{identifier} /* {comment} */ = {{\n"
            f"{body}"
            "\t\t};\n"
        )

    def target(
        self,
        name: str,
        sources: list[str],
        *,
        product_name: str | None = None,
    ) -> None:
        file_reference_ids: list[str] = []
        build_file_ids: list[str] = []
        for source in sources:
            file_reference_id = self.identifier()
            build_file_id = self.identifier()
            self.add(
                file_reference_id,
                source,
                "\t\t\tisa = PBXFileReference;\n"
                f"\t\t\tpath = {source};\n"
                "\t\t\tsourceTree = \"<group>\";\n",
            )
            self.add(
                build_file_id,
                f"{source} in Sources",
                "\t\t\tisa = PBXBuildFile;\n"
                f"\t\t\tfileRef = {file_reference_id} /* {source} */;\n",
            )
            file_reference_ids.append(file_reference_id)
            build_file_ids.append(build_file_id)

        group_id = self.identifier()
        group_files = "".join(
            f"\t\t\t\t{identifier} /* source */,\n"
            for identifier in file_reference_ids
        )
        self.add(
            group_id,
            f"{name} Sources",
            "\t\t\tisa = PBXGroup;\n"
            "\t\t\tchildren = (\n"
            f"{group_files}"
            "\t\t\t);\n",
        )
        phase_id = self.identifier()
        phase_files = "".join(
            f"\t\t\t\t{identifier} /* source in Sources */,\n"
            for identifier in build_file_ids
        )
        self.add(
            phase_id,
            "Sources",
            "\t\t\tisa = PBXSourcesBuildPhase;\n"
            "\t\t\tfiles = (\n"
            f"{phase_files}"
            "\t\t\t);\n",
        )
        target_id = self.identifier()
        self.add(
            target_id,
            name,
            "\t\t\tisa = PBXNativeTarget;\n"
            "\t\t\tbuildPhases = (\n"
            f"\t\t\t\t{phase_id} /* Sources */,\n"
            "\t\t\t);\n"
            f"\t\t\tname = {name};\n"
            + (
                f"\t\t\tproductName = {product_name};\n"
                if product_name is not None
                else ""
            ),
        )

    def text(self) -> str:
        return (
            "// !$*UTF8*$!\n"
            "{\n"
            "\tarchiveVersion = 1;\n"
            "\tobjects = {\n"
            f"{''.join(self.objects)}"
            "\t};\n"
            "}\n"
        )


def sources(prefix: str, count: int) -> list[str]:
    return [f"{prefix}{index:03d}.swift" for index in range(count)]


def project(
    *,
    daemon: list[str],
    daemon_tests: list[str],
    other: list[str] | None = None,
    daemon_product_name: str | None = None,
    compact_objects: bool = False,
) -> str:
    builder = ProjectBuilder(compact_objects=compact_objects)
    builder.target(
        "OpenBurnBarDaemon",
        daemon,
        product_name=daemon_product_name,
    )
    builder.target("OpenBurnBarDaemonTests", daemon_tests)
    builder.target("UnrelatedTarget", other or ["Unrelated.swift"])
    return builder.text()


class SafariXcodeGenTransitionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.daemon = sources("Daemon", 230)
        self.daemon_tests = sources("DaemonTest", 119)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def write(self, name: str, text: str) -> Path:
        path = self.root / name
        path.write_text(text, encoding="utf-8")
        return path

    def before(self) -> Path:
        return self.write(
            "before.pbxproj",
            project(daemon=self.daemon, daemon_tests=self.daemon_tests),
        )

    def valid_after(self) -> Path:
        return self.write(
            "after.pbxproj",
            project(
                daemon=self.daemon
                + [
                    "GatewayRequestAttribution.swift",
                    "SafariHandoffProcessSupervisor.swift",
                ],
                daemon_tests=self.daemon_tests
                + [
                    "SafariHandoffProcessSupervisorTests.swift",
                    "SafariHandoffProcessWatchdogTests.swift",
                ],
            ),
        )

    def test_parses_actual_compact_one_line_build_file_shape(self) -> None:
        body = (
            "isa = PBXBuildFile; "
            "fileRef = B74D48D00D5D2E4FCAA9FCFE "
            "/* AIInboxControlPlaneStoreTests.swift */; "
        )
        self.assertEqual(
            MODULE.scalar(body, "fileRef"),
            "B74D48D00D5D2E4FCAA9FCFE "
            "/* AIInboxControlPlaneStoreTests.swift */",
        )

    def test_ignores_scalar_decoys_inside_quoted_values(self) -> None:
        body = (
            'isa = PBXShellScriptBuildPhase; '
            'shellScript = "echo \\"; fileRef = DECOY;\\""; '
            "fileRef = B74D48D00D5D2E4FCAA9FCFE /* Real.swift */; "
        )
        self.assertEqual(
            MODULE.scalar(body, "fileRef"),
            "B74D48D00D5D2E4FCAA9FCFE /* Real.swift */",
        )

    def test_rejects_duplicate_top_level_scalar_assignments(self) -> None:
        with self.assertRaisesRegex(ValueError, "duplicate fileRef assignments"):
            MODULE.scalar(
                "fileRef = 000000000000000000000001; "
                "fileRef = 000000000000000000000002;",
                "fileRef",
            )

    def test_accepts_only_the_four_audited_additions(self) -> None:
        MODULE.verify_transition(self.before(), self.valid_after())

    def test_accepts_compact_one_line_pbx_object_bodies(self) -> None:
        before = self.write(
            "compact-before.pbxproj",
            project(
                daemon=self.daemon,
                daemon_tests=self.daemon_tests,
                compact_objects=True,
            ),
        )
        after = self.write(
            "compact-after.pbxproj",
            project(
                daemon=self.daemon
                + [
                    "GatewayRequestAttribution.swift",
                    "SafariHandoffProcessSupervisor.swift",
                ],
                daemon_tests=self.daemon_tests
                + [
                    "SafariHandoffProcessSupervisorTests.swift",
                    "SafariHandoffProcessWatchdogTests.swift",
                ],
                compact_objects=True,
            ),
        )
        MODULE.verify_transition(before, after)

    def test_rejects_unrelated_target_membership_change(self) -> None:
        after = self.write(
            "after.pbxproj",
            project(
                daemon=self.daemon
                + [
                    "GatewayRequestAttribution.swift",
                    "SafariHandoffProcessSupervisor.swift",
                ],
                daemon_tests=self.daemon_tests
                + [
                    "SafariHandoffProcessSupervisorTests.swift",
                    "SafariHandoffProcessWatchdogTests.swift",
                ],
                other=["Unrelated.swift", "Surprise.swift"],
            ),
        )
        with self.assertRaisesRegex(ValueError, "UnrelatedTarget source additions"):
            MODULE.verify_transition(self.before(), after)

    def test_rejects_allowed_source_in_the_wrong_target(self) -> None:
        after = self.write(
            "after.pbxproj",
            project(
                daemon=self.daemon
                + [
                    "GatewayRequestAttribution.swift",
                    "SafariHandoffProcessSupervisor.swift",
                    "SafariHandoffProcessWatchdogTests.swift",
                ],
                daemon_tests=self.daemon_tests
                + ["SafariHandoffProcessSupervisorTests.swift"],
            ),
        )
        with self.assertRaisesRegex(ValueError, "OpenBurnBarDaemon source additions"):
            MODULE.verify_transition(self.before(), after)

    def test_rejects_a_source_removal(self) -> None:
        after = self.write(
            "after.pbxproj",
            project(
                daemon=self.daemon[:-1]
                + [
                    "GatewayRequestAttribution.swift",
                    "SafariHandoffProcessSupervisor.swift",
                ],
                daemon_tests=self.daemon_tests
                + [
                    "SafariHandoffProcessSupervisorTests.swift",
                    "SafariHandoffProcessWatchdogTests.swift",
                ],
            ),
        )
        with self.assertRaisesRegex(ValueError, "removed source membership"):
            MODULE.verify_transition(self.before(), after)

    def test_rejects_historical_baseline_count_drift(self) -> None:
        before = self.write(
            "before.pbxproj",
            project(daemon=self.daemon[:-1], daemon_tests=self.daemon_tests),
        )
        with self.assertRaisesRegex(ValueError, "Sources count must be 230"):
            MODULE.verify_transition(before, self.valid_after())

    def test_rejects_a_missing_expected_addition(self) -> None:
        after = self.write(
            "after.pbxproj",
            project(
                daemon=self.daemon + ["GatewayRequestAttribution.swift"],
                daemon_tests=self.daemon_tests
                + [
                    "SafariHandoffProcessSupervisorTests.swift",
                    "SafariHandoffProcessWatchdogTests.swift",
                ],
            ),
        )
        with self.assertRaisesRegex(ValueError, "source additions must be exactly"):
            MODULE.verify_transition(self.before(), after)

    def test_rejects_a_duplicate_expected_addition(self) -> None:
        after = self.write(
            "after.pbxproj",
            project(
                daemon=self.daemon
                + [
                    "GatewayRequestAttribution.swift",
                    "GatewayRequestAttribution.swift",
                    "SafariHandoffProcessSupervisor.swift",
                ],
                daemon_tests=self.daemon_tests
                + [
                    "SafariHandoffProcessSupervisorTests.swift",
                    "SafariHandoffProcessWatchdogTests.swift",
                ],
            ),
        )
        with self.assertRaisesRegex(ValueError, "source additions must be exactly"):
            MODULE.verify_transition(self.before(), after)

    def test_rejects_non_source_project_drift(self) -> None:
        after = self.write(
            "after.pbxproj",
            project(
                daemon=self.daemon
                + [
                    "GatewayRequestAttribution.swift",
                    "SafariHandoffProcessSupervisor.swift",
                ],
                daemon_tests=self.daemon_tests
                + [
                    "SafariHandoffProcessSupervisorTests.swift",
                    "SafariHandoffProcessWatchdogTests.swift",
                ],
                daemon_product_name="MutatedDaemonProduct",
            ),
        )
        with self.assertRaisesRegex(ValueError, "semantic drift outside"):
            MODULE.verify_transition(self.before(), after)


if __name__ == "__main__":
    unittest.main()
