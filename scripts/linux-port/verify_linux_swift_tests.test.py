#!/usr/bin/env python3
from __future__ import annotations

import copy
import importlib.util
import json
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("verify_linux_swift_tests.py")
SPEC = importlib.util.spec_from_file_location("verify_linux_swift_tests", MODULE_PATH)
assert SPEC and SPEC.loader
VERIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFIER)


class LinuxSwiftTestVerifierTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.results = Path(self.temp.name)
        self.manifest = {
            "suites": [
                {
                    "id": "fixture",
                    "packagePath": "FixturePackage",
                    "target": "FixtureTests",
                    "minimumExecutedTests": 2,
                }
            ]
        }

    def tearDown(self) -> None:
        self.temp.cleanup()

    def write_xunit(self, body: str) -> None:
        (self.results / "fixture.xml").write_text(
            f"<testsuites><testsuite>{body}</testsuite></testsuites>", encoding="utf-8"
        )

    def write_graph(self, targets: list[dict]) -> None:
        path = self.results / VERIFIER.package_description_filename("FixturePackage")
        path.write_text(json.dumps({"targets": targets}), encoding="utf-8")

    def write_fake_xctest(self, body: str) -> Path:
        path = self.results / "FixturePackageTests.xctest"
        path.write_text("#!/bin/sh\nset -eu\n" + body, encoding="utf-8")
        path.chmod(0o755)
        return path

    def test_accepts_required_executed_tests(self) -> None:
        self.write_xunit('<testcase name="one"/><testcase name="two"/>')
        report = VERIFIER.verify_results(self.manifest, self.results, write_summary=False)
        self.assertEqual(report["executedTests"], 2)

    def test_rejects_missing_suite_output(self) -> None:
        with self.assertRaisesRegex(VERIFIER.VerificationError, "did not produce xUnit output"):
            VERIFIER.verify_results(self.manifest, self.results, write_summary=False)

    def test_rejects_zero_test_false_green(self) -> None:
        self.write_xunit("")
        with self.assertRaisesRegex(VERIFIER.VerificationError, "executed 0 tests"):
            VERIFIER.verify_results(self.manifest, self.results, write_summary=False)

    def test_skipped_tests_do_not_satisfy_execution_floor(self) -> None:
        self.write_xunit('<testcase name="one"><skipped/></testcase><testcase name="two"/>')
        with self.assertRaisesRegex(VERIFIER.VerificationError, "executed 1 tests"):
            VERIFIER.verify_results(self.manifest, self.results, write_summary=False)

    def test_rejects_failures_even_if_process_exit_is_lost(self) -> None:
        self.write_xunit('<testcase name="one"><failure/></testcase><testcase name="two"/>')
        with self.assertRaisesRegex(VERIFIER.VerificationError, "records 1 failed tests"):
            VERIFIER.verify_results(self.manifest, self.results, write_summary=False)

    def test_direct_executor_runs_each_exact_test_and_writes_xunit(self) -> None:
        binary = self.write_fake_xctest(r"""
if [ "${1:-}" = "--list-tests" ]; then
  echo "Listing 2 tests in debug.xctest:"
  echo "FixtureTests.Case/testOne"
  echo "FixtureTests.Case/testTwo"
  exit 0
fi
name="${1##*/}"
echo "Test Suite 'Selected tests' started"
echo "Test Case 'Case.${name}' passed (0.001 seconds)"
echo "Test Suite 'Selected tests' passed"
echo " Executed 1 test, with 0 failures (0 unexpected)"
""")
        xunit = self.results / "direct.xml"
        report = VERIFIER.execute_xctest_suite(
            "fixture",
            "FixtureTests",
            binary,
            xunit,
            per_test_timeout_seconds=1,
            termination_grace_seconds=0.1,
        )
        self.assertEqual(report["executedTests"], 2)
        self.assertEqual(len(list(ET.parse(xunit).iter("testcase"))), 2)

    def test_direct_executor_fails_closed_on_per_test_timeout(self) -> None:
        binary = self.write_fake_xctest(r"""
if [ "${1:-}" = "--list-tests" ]; then
  echo "FixtureTests.Case/testNeverReturns"
  exit 0
fi
sleep 5
""")
        xunit = self.results / "timeout.xml"
        with self.assertRaisesRegex(VERIFIER.VerificationError, "timed out"):
            VERIFIER.execute_xctest_suite(
                "fixture",
                "FixtureTests",
                binary,
                xunit,
                per_test_timeout_seconds=0.05,
                termination_grace_seconds=0.05,
            )
        self.assertEqual(len(list(ET.parse(xunit).iter("error"))), 1)

    def test_accepts_exact_active_linux_graph(self) -> None:
        self.write_graph(
            [
                {
                    "name": "FixtureTests",
                    "type": "test",
                    "sources": ["RealTests.swift"],
                }
            ]
        )
        report = VERIFIER.verify_active_graph(self.manifest, self.results)
        self.assertEqual(report["activeTestTargets"], 1)

    def test_rejects_manifest_target_omitted_from_active_graph(self) -> None:
        self.write_graph([])
        with self.assertRaisesRegex(VERIFIER.VerificationError, "omits manifest test targets"):
            VERIFIER.verify_active_graph(self.manifest, self.results)

    def test_rejects_untracked_active_test_target(self) -> None:
        self.write_graph(
            [
                {"name": "FixtureTests", "type": "test", "sources": ["RealTests.swift"]},
                {"name": "ForgottenTests", "type": "test", "sources": ["ForgottenTests.swift"]},
            ]
        )
        with self.assertRaisesRegex(VERIFIER.VerificationError, "absent from the runner manifest"):
            VERIFIER.verify_active_graph(self.manifest, self.results)

    def test_rejects_placeholder_source_in_manifest_target(self) -> None:
        self.write_graph(
            [
                {
                    "name": "FixtureTests",
                    "type": "test",
                    "sources": ["LinuxEmptyTests.swift"],
                }
            ]
        )
        with self.assertRaisesRegex(VERIFIER.VerificationError, "placeholder-only sources"):
            VERIFIER.verify_active_graph(self.manifest, self.results)

    def test_real_repository_contract_is_complete(self) -> None:
        root = MODULE_PATH.parents[2]
        report = VERIFIER.validate_contract(root, VERIFIER.load_manifest(root))
        self.assertEqual(
            report,
            {
                "suiteCount": 6,
                "minimumExecutedTests": 59,
                "executionStrategy": "direct-xctest-isolated-per-test",
                "perTestTimeoutSeconds": 300,
            },
        )

    def test_real_runner_uses_direct_isolated_xctest_execution(self) -> None:
        root = MODULE_PATH.parents[2]
        runner = (root / "scripts/linux-port/run-linux-swift-tests.sh").read_text(encoding="utf-8")
        self.assertNotIn("swift test", runner)
        self.assertIn("--build-tests", runner)
        self.assertIn("verify_linux_swift_tests.py execute", runner)
        self.assertIn('timeout --kill-after="${TERMINATION_GRACE_SECONDS}s"', runner)

    def test_real_contract_rejects_excessive_per_test_timeout(self) -> None:
        root = MODULE_PATH.parents[2]
        manifest = copy.deepcopy(VERIFIER.load_manifest(root))
        manifest["execution"]["perTestTimeoutSeconds"] = 1200
        with self.assertRaisesRegex(VERIFIER.VerificationError, "isolated execution policy"):
            VERIFIER.validate_contract(root, manifest)

    def test_real_contract_rejects_missing_forced_termination_grace(self) -> None:
        root = MODULE_PATH.parents[2]
        manifest = copy.deepcopy(VERIFIER.load_manifest(root))
        manifest["execution"]["terminationGraceSeconds"] = 0
        with self.assertRaisesRegex(VERIFIER.VerificationError, "isolated execution policy"):
            VERIFIER.validate_contract(root, manifest)

    def test_real_contract_rejects_coverage_owner_without_filters(self) -> None:
        root = MODULE_PATH.parents[2]
        manifest = copy.deepcopy(VERIFIER.load_manifest(root))
        owner = next(suite for suite in manifest["suites"] if suite["linuxCoverageOwner"])
        owner["linuxCoverageFilters"] = []
        with self.assertRaisesRegex(VERIFIER.VerificationError, "non-empty linuxCoverageFilters"):
            VERIFIER.validate_contract(root, manifest)

    def test_real_contract_requires_coverage_owner_for_every_package(self) -> None:
        root = MODULE_PATH.parents[2]
        manifest = copy.deepcopy(VERIFIER.load_manifest(root))
        package_path = next(suite["packagePath"] for suite in manifest["suites"] if suite["linuxCoverageOwner"])
        for suite in manifest["suites"]:
            if suite["packagePath"] == package_path:
                suite["linuxCoverageOwner"] = False
                suite.pop("linuxCoverageFilters", None)
        with self.assertRaisesRegex(VERIFIER.VerificationError, "must include every package"):
            VERIFIER.validate_contract(root, manifest)

    def test_real_contract_rejects_silently_shrunk_coverage_filter_set(self) -> None:
        root = MODULE_PATH.parents[2]
        manifest = copy.deepcopy(VERIFIER.load_manifest(root))
        owner = next(
            suite for suite in manifest["suites"]
            if VERIFIER.MINIMUM_LINUX_COVERAGE_FILTERS_BY_SUITE.get(suite["id"], 0) > 1
        )
        owner["linuxCoverageFilters"].pop()
        with self.assertRaisesRegex(VERIFIER.VerificationError, "filter set shrank below its pinned contract"):
            VERIFIER.validate_contract(root, manifest)

    def test_real_contract_rejects_self_attested_coverage_floor(self) -> None:
        root = MODULE_PATH.parents[2]
        manifest = copy.deepcopy(VERIFIER.load_manifest(root))
        owner = next(suite for suite in manifest["suites"] if suite["linuxCoverageOwner"])
        owner["minimumLinuxCoverageFilters"] = 1
        with self.assertRaisesRegex(VERIFIER.VerificationError, "may not self-attest"):
            VERIFIER.validate_contract(root, manifest)

    def test_real_contract_rejects_duplicate_coverage_filters(self) -> None:
        root = MODULE_PATH.parents[2]
        manifest = copy.deepcopy(VERIFIER.load_manifest(root))
        owner = next(suite for suite in manifest["suites"] if suite["linuxCoverageOwner"])
        owner["linuxCoverageFilters"].append(owner["linuxCoverageFilters"][0])
        with self.assertRaisesRegex(VERIFIER.VerificationError, "duplicate linuxCoverageFilters"):
            VERIFIER.validate_contract(root, manifest)


if __name__ == "__main__":
    unittest.main()
