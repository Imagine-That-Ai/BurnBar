#!/usr/bin/env python3
"""Validate the Linux Swift test contract and fail closed on empty xUnit output."""

from __future__ import annotations

import argparse
import json
import os
import pty
import re
import select
import signal
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET
from pathlib import Path


class VerificationError(RuntimeError):
    pass


FORBIDDEN_PLACEHOLDER_SOURCES = {
    "LinuxEmptyTests.swift",
    "OpenBurnBarSignalCoreUnavailableTests.swift",
    "OBBSignalSessionTransportUnavailableTests.swift",
}

XCTEST_PASS_PATTERN = re.compile(r"Test Case '[^']+' passed \(([0-9.]+) seconds\)")

# This floor intentionally lives outside the editable manifest. A manifest-only
# minimum is self-attested and can be lowered in the same change that removes
# coverage filters.
MINIMUM_LINUX_COVERAGE_FILTERS_BY_SUITE = {
    "computer-use-linux": 1,
    "daemon-linux": 50,
}


def load_manifest(root: Path) -> dict:
    path = root / "scripts/linux-port/linux-swift-test-manifest.json"
    return json.loads(path.read_text(encoding="utf-8"))


def test_source_directory(root: Path, package_path: str, target: str) -> Path:
    return root / package_path / "Tests" / target


def declared_test_count(path: Path) -> int:
    if path.is_file():
        files = [path]
    elif path.is_dir():
        files = sorted(path.rglob("*.swift"))
    else:
        return 0
    return sum(len(re.findall(r"\bfunc\s+test[A-Za-z0-9_]*\s*\(", file.read_text(encoding="utf-8"))) for file in files)


def package_description_filename(package_path: str) -> str:
    safe_path = re.sub(r"[^A-Za-z0-9_.-]+", "__", package_path)
    return f"graph-{safe_path}.json"


def validate_contract(root: Path, manifest: dict) -> dict:
    failures: list[str] = []
    suites = manifest.get("suites")
    if manifest.get("schemaVersion") != 1 or not isinstance(suites, list) or not suites:
        raise VerificationError("Linux Swift test manifest must use schemaVersion 1 and declare at least one suite")

    execution = manifest.get("execution")
    expected_execution = {
        "strategy": "direct-xctest-isolated-per-test",
        "buildTimeoutSeconds": 1200,
        "perTestTimeoutSeconds": 300,
        "terminationGraceSeconds": 30,
    }
    if execution != expected_execution:
        failures.append(
            "Linux Swift tests must use the fail-closed isolated execution policy "
            f"{expected_execution}; found {execution}"
        )

    seen_ids: set[str] = set()
    coverage_packages: set[str] = set()
    total_minimum = 0
    for suite in suites:
        missing = [
            key
            for key in ("id", "packagePath", "target", "filter", "minimumExecutedTests", "scratchPath")
            if not suite.get(key)
        ]
        if missing:
            failures.append(f"suite {suite.get('id', '<unknown>')} is missing: {', '.join(missing)}")
            continue
        suite_id = suite["id"]
        if suite_id in seen_ids:
            failures.append(f"duplicate suite id: {suite_id}")
        seen_ids.add(suite_id)
        coverage_owner = suite.get("linuxCoverageOwner")
        if not isinstance(coverage_owner, bool):
            failures.append(f"suite {suite_id} must declare boolean linuxCoverageOwner")
        elif coverage_owner:
            coverage_packages.add(suite["packagePath"])
            coverage_filters = suite.get("linuxCoverageFilters")
            minimum_coverage_filters = MINIMUM_LINUX_COVERAGE_FILTERS_BY_SUITE.get(suite_id)
            if (
                not isinstance(coverage_filters, list)
                or not coverage_filters
                or any(not isinstance(item, str) or not item.strip() for item in coverage_filters)
            ):
                failures.append(f"coverage-owning suite {suite_id} must declare non-empty linuxCoverageFilters")
            elif len(coverage_filters) != len(set(coverage_filters)):
                failures.append(f"coverage-owning suite {suite_id} contains duplicate linuxCoverageFilters")
            if "minimumLinuxCoverageFilters" in suite:
                failures.append(
                    f"coverage-owning suite {suite_id} may not self-attest minimumLinuxCoverageFilters"
                )
            if minimum_coverage_filters is None:
                failures.append(f"coverage-owning suite {suite_id} has no pinned coverage-filter floor")
            elif isinstance(coverage_filters, list) and len(coverage_filters) < minimum_coverage_filters:
                failures.append(
                    f"coverage-owning suite {suite_id} filter set shrank below its pinned contract "
                    f"({len(coverage_filters)} < {minimum_coverage_filters})"
                )
        elif "linuxCoverageFilters" in suite:
            failures.append(f"non-coverage suite {suite_id} may not declare linuxCoverageFilters")
        elif "minimumLinuxCoverageFilters" in suite:
            failures.append(f"non-coverage suite {suite_id} may not declare minimumLinuxCoverageFilters")
        minimum = suite["minimumExecutedTests"]
        if not isinstance(minimum, int) or minimum < 1:
            failures.append(f"suite {suite_id} must require at least one executed test")
            continue
        total_minimum += minimum

        package = root / suite["packagePath"]
        package_manifest = package / "Package.swift"
        if not package_manifest.is_file():
            failures.append(f"suite {suite_id} package manifest is missing: {package_manifest}")
            continue
        source = package_manifest.read_text(encoding="utf-8")
        target_pattern = rf"\.testTarget\(\s*name:\s*\"{re.escape(suite['target'])}\""
        if re.search(target_pattern, source, re.MULTILINE) is None:
            failures.append(f"suite {suite_id} target {suite['target']} is absent from {package_manifest}")
        source_dir = test_source_directory(root, suite["packagePath"], suite["target"])
        if not source_dir.is_dir():
            failures.append(f"suite {suite_id} source directory is missing: {source_dir}")
        elif declared_test_count(source_dir) < minimum:
            failures.append(
                f"suite {suite_id} declares fewer test methods than its floor "
                f"({declared_test_count(source_dir)} < {minimum})"
            )

    expected_coverage_packages = {suite["packagePath"] for suite in suites if suite.get("packagePath")}
    if coverage_packages != expected_coverage_packages:
        failures.append(
            "Linux coverage owners must include every package in the manifest "
            f"({sorted(coverage_packages)} != {sorted(expected_coverage_packages)})"
        )

    for exclusion in manifest.get("excludedSources", []):
        required = ("packagePath", "target", "file", "declaredTests", "reason")
        if any(not exclusion.get(key) for key in required):
            failures.append(f"invalid excluded source entry: {exclusion}")
            continue
        excluded_file = test_source_directory(root, exclusion["packagePath"], exclusion["target"]) / exclusion["file"]
        actual_count = declared_test_count(excluded_file)
        if actual_count != exclusion["declaredTests"]:
            failures.append(
                f"excluded source {excluded_file} test count drifted ({actual_count} != {exclusion['declaredTests']})"
            )
        package_source = (root / exclusion["packagePath"] / "Package.swift").read_text(encoding="utf-8")
        if f'"{exclusion["file"]}"' not in package_source:
            failures.append(f"excluded source {exclusion['file']} is not explicitly excluded by Package.swift")

    runner_path = root / "scripts/linux-port/run-linux-swift-tests.sh"
    runner_source = runner_path.read_text(encoding="utf-8") if runner_path.is_file() else ""
    if "swift test" in runner_source:
        failures.append(
            "Linux Swift test runner must not delegate execution to SwiftPM's deadlocking XCTest coordinator"
        )
    if "--build-tests" not in runner_source or "verify_linux_swift_tests.py execute" not in runner_source:
        failures.append("Linux Swift test runner must build once and execute the XCTest binary per test")
    if 'timeout --kill-after="${TERMINATION_GRACE_SECONDS}s"' not in runner_source:
        failures.append("Linux Swift test runner must terminate timed-out builds fail-closed")

    runner = "bash scripts/linux-port/run-linux-swift-tests.sh"
    for relative in (".github/workflows/linux-pr-gate.yml", ".github/workflows/linux-nightly.yml"):
        workflow = root / relative
        if not workflow.is_file() or runner not in workflow.read_text(encoding="utf-8"):
            failures.append(f"{relative} does not execute the Linux Swift test runner")

    if failures:
        raise VerificationError("\n".join(failures))
    return {
        "suiteCount": len(suites),
        "minimumExecutedTests": total_minimum,
        "executionStrategy": execution["strategy"],
        "perTestTimeoutSeconds": execution["perTestTimeoutSeconds"],
    }


def run_bounded_process(
    command: list[str], timeout_seconds: float, termination_grace_seconds: float
) -> tuple[int, str, bool]:
    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        start_new_session=True,
    )
    try:
        output, _ = process.communicate(timeout=timeout_seconds)
        return process.returncode, output, False
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            output, _ = process.communicate(timeout=termination_grace_seconds)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            output, _ = process.communicate()
        return process.returncode, output, True


def run_xctest_process(
    command: list[str],
    timeout_seconds: float,
    termination_grace_seconds: float,
    expected_test_count: int,
    isolated_tmp: str,
) -> tuple[int, str, bool, bool]:
    """Run one XCTest in a PTY and reap Linux harnesses that linger after a verified pass."""
    master, slave = pty.openpty()
    process = subprocess.Popen(
        command,
        stdin=subprocess.DEVNULL,
        stdout=slave,
        stderr=slave,
        env={
            **os.environ,
            "TMPDIR": isolated_tmp,
            "XDG_RUNTIME_DIR": isolated_tmp,
        },
        start_new_session=True,
        close_fds=True,
    )
    os.close(slave)
    output = bytearray()
    deadline = time.monotonic() + timeout_seconds
    verified_at: float | None = None
    forced_teardown = False
    timed_out = False
    try:
        while process.poll() is None:
            now = time.monotonic()
            if now >= deadline:
                timed_out = True
                break
            readable, _, _ = select.select([master], [], [], min(0.1, deadline - now))
            if readable:
                try:
                    chunk = os.read(master, 65_536)
                except OSError:
                    chunk = b""
                output.extend(chunk)
                transcript = output.decode("utf-8", errors="replace")
                expected_summary = (
                    f"Executed {expected_test_count} test{'s' if expected_test_count != 1 else ''}, with 0 failures"
                )
                if (
                    verified_at is None
                    and XCTEST_PASS_PATTERN.search(transcript)
                    and expected_summary in transcript
                    and "Test Suite 'Selected tests' passed" in transcript
                ):
                    verified_at = now
            if verified_at is not None and now - verified_at >= 1.0:
                forced_teardown = True
                break

        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=termination_grace_seconds)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()

        while True:
            readable, _, _ = select.select([master], [], [], 0)
            if not readable:
                break
            try:
                chunk = os.read(master, 65_536)
            except OSError:
                break
            if not chunk:
                break
            output.extend(chunk)
    finally:
        os.close(master)

    transcript = output.decode("utf-8", errors="replace").replace("\r\n", "\n")
    expected_summary = f"Executed {expected_test_count} test{'s' if expected_test_count != 1 else ''}, with 0 failures"
    verified = bool(
        XCTEST_PASS_PATTERN.search(transcript)
        and expected_summary in transcript
        and "Test Suite 'Selected tests' passed" in transcript
    )
    return process.returncode, transcript, timed_out, forced_teardown and verified


def execute_xctest_suite(
    suite_id: str,
    test_filter: str,
    xctest_binary: Path,
    xunit_output: Path,
    per_test_timeout_seconds: float,
    termination_grace_seconds: float,
) -> dict:
    if not xctest_binary.is_file() or not os.access(xctest_binary, os.X_OK):
        raise VerificationError(f"XCTest binary is missing or not executable: {xctest_binary}")

    list_status, list_output, list_timed_out = run_bounded_process(
        [str(xctest_binary), "--list-tests"],
        30,
        termination_grace_seconds,
    )
    if list_timed_out or list_status != 0:
        raise VerificationError(f"failed to enumerate XCTest binary {xctest_binary}:\n{list_output}")
    tests = sorted(
        line.strip() for line in list_output.splitlines() if "/" in line and line.strip().startswith(test_filter)
    )
    if not tests:
        raise VerificationError(f"XCTest filter {test_filter!r} selected zero tests from {xctest_binary}")

    started = time.monotonic()
    suite = ET.Element("testsuite", name=suite_id, tests=str(len(tests)), failures="0", errors="0")
    failures: list[str] = []
    total_duration = 0.0
    for index, test in enumerate(tests, start=1):
        print(f"[{index}/{len(tests)}] Testing {test}", flush=True)
        with tempfile.TemporaryDirectory(prefix="openburnbar-xctest-") as isolated_tmp:
            status, output, timed_out, forced_teardown = run_xctest_process(
                [str(xctest_binary), test],
                per_test_timeout_seconds,
                termination_grace_seconds,
                1,
                isolated_tmp,
            )
        match = XCTEST_PASS_PATTERN.search(output)
        duration = float(match.group(1)) if match else 0.0
        total_duration += duration
        test_class, test_name = test.split("/", 1)
        case = ET.SubElement(suite, "testcase", classname=test_class, name=test_name, time=f"{duration:.3f}")
        ET.SubElement(case, "system-out").text = output
        if timed_out:
            message = f"{test} timed out after {per_test_timeout_seconds:g}s"
            ET.SubElement(case, "error", message=message, type="timeout")
            failures.append(message)
        elif (status != 0 and not forced_teardown) or match is None or "Executed 1 test, with 0 failures" not in output:
            message = f"{test} did not produce a verified one-test XCTest pass (exit {status})"
            ET.SubElement(case, "failure", message=message, type="xctest")
            failures.append(message)
        elif forced_teardown:
            print(f"PASS: {test} completed; reaped lingering XCTest harness process", flush=True)

    suite.set("failures", str(sum(child.find("failure") is not None for child in suite)))
    suite.set("errors", str(sum(child.find("error") is not None for child in suite)))
    suite.set("time", f"{total_duration:.3f}")
    root = ET.Element(
        "testsuites",
        tests=str(len(tests)),
        failures=suite.get("failures", "0"),
        errors=suite.get("errors", "0"),
        time=f"{total_duration:.3f}",
    )
    root.append(suite)
    tree = ET.ElementTree(root)
    ET.indent(tree, space="  ")
    xunit_output.parent.mkdir(parents=True, exist_ok=True)
    tree.write(xunit_output, encoding="utf-8", xml_declaration=True)

    report = {
        "suite": suite_id,
        "selectedTests": len(tests),
        "executedTests": len(tests) - len(failures),
        "durationSeconds": round(time.monotonic() - started, 3),
        "failures": failures,
        "xunit": str(xunit_output),
    }
    if failures:
        raise VerificationError("\n".join(failures))
    return report


def verify_active_graph(manifest: dict, descriptions_dir: Path) -> dict:
    """Require the Linux SwiftPM graph to equal the test runner inventory."""
    failures: list[str] = []
    rows: list[dict] = []
    suites_by_package: dict[str, list[dict]] = {}
    for suite in manifest["suites"]:
        suites_by_package.setdefault(suite["packagePath"], []).append(suite)

    for package_path, suites in sorted(suites_by_package.items()):
        description_path = descriptions_dir / package_description_filename(package_path)
        if not description_path.is_file():
            failures.append(f"package {package_path} did not produce a SwiftPM graph: {description_path}")
            continue
        try:
            description = json.loads(description_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as error:
            failures.append(f"package {package_path} produced invalid SwiftPM graph JSON: {error}")
            continue

        active_targets = {
            target["name"]: target
            for target in description.get("targets", [])
            if target.get("type") == "test" and target.get("name")
        }
        expected_targets = {suite["target"] for suite in suites}
        missing = sorted(expected_targets - active_targets.keys())
        unexpected = sorted(active_targets.keys() - expected_targets)
        if missing:
            failures.append(
                f"package {package_path} omits manifest test targets from its active Linux graph: {', '.join(missing)}"
            )
        if unexpected:
            failures.append(
                f"package {package_path} has active Linux test targets absent from the runner manifest: "
                f"{', '.join(unexpected)}"
            )

        for target_name, target in sorted(active_targets.items()):
            sources = [Path(source).name for source in target.get("sources", [])]
            placeholders = sorted(FORBIDDEN_PLACEHOLDER_SOURCES.intersection(sources))
            if placeholders:
                failures.append(
                    f"package {package_path} target {target_name} contains placeholder-only sources: "
                    f"{', '.join(placeholders)}"
                )
            rows.append(
                {
                    "packagePath": package_path,
                    "target": target_name,
                    "sources": sorted(sources),
                }
            )

    report = {
        "passed": not failures,
        "packages": len(suites_by_package),
        "activeTestTargets": len(rows),
        "targets": rows,
        "failures": failures,
    }
    if failures:
        raise VerificationError("\n".join(failures))
    return report


def verify_results(manifest: dict, results_dir: Path, write_summary: bool = True) -> dict:
    failures: list[str] = []
    rows: list[dict] = []
    for suite in manifest["suites"]:
        result_path = results_dir / f"{suite['id']}.xml"
        if not result_path.is_file():
            failures.append(f"suite {suite['id']} did not produce xUnit output: {result_path}")
            continue
        try:
            document = ET.parse(result_path)
        except ET.ParseError as error:
            failures.append(f"suite {suite['id']} produced invalid xUnit XML: {error}")
            continue

        testcases = [element for element in document.iter() if element.tag.rsplit("}", 1)[-1] == "testcase"]
        skipped = sum(any(child.tag.rsplit("}", 1)[-1] == "skipped" for child in testcase) for testcase in testcases)
        failed = sum(
            any(child.tag.rsplit("}", 1)[-1] in {"failure", "error"} for child in testcase) for testcase in testcases
        )
        executed = len(testcases) - skipped
        row = {
            "id": suite["id"],
            "target": suite["target"],
            "minimum": suite["minimumExecutedTests"],
            "testcases": len(testcases),
            "executed": executed,
            "skipped": skipped,
            "failed": failed,
            "xunit": str(result_path),
        }
        rows.append(row)
        if executed < suite["minimumExecutedTests"]:
            failures.append(
                f"suite {suite['id']} executed {executed} tests; minimum is {suite['minimumExecutedTests']}"
            )
        if failed:
            failures.append(f"suite {suite['id']} xUnit output records {failed} failed tests")

    summary = {
        "passed": not failures,
        "requiredSuites": len(manifest["suites"]),
        "reportedSuites": len(rows),
        "minimumExecutedTests": sum(suite["minimumExecutedTests"] for suite in manifest["suites"]),
        "executedTests": sum(row["executed"] for row in rows),
        "suites": rows,
        "failures": failures,
    }
    if write_summary:
        results_dir.mkdir(parents=True, exist_ok=True)
        (results_dir / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    if failures:
        raise VerificationError("\n".join(failures))
    return summary


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("contract", "graph", "results", "execute"))
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--results-dir", type=Path)
    parser.add_argument("--suite-id")
    parser.add_argument("--filter")
    parser.add_argument("--xctest-binary", type=Path)
    parser.add_argument("--xunit-output", type=Path)
    parser.add_argument("--per-test-timeout-seconds", type=float)
    parser.add_argument("--termination-grace-seconds", type=float)
    args = parser.parse_args()
    root = args.root.resolve()
    manifest = load_manifest(root)
    try:
        if args.mode == "contract":
            report = validate_contract(root, manifest)
        elif args.mode == "graph":
            if args.results_dir is None:
                parser.error("graph mode requires --results-dir")
            report = verify_active_graph(manifest, args.results_dir.resolve())
        elif args.mode == "results":
            if args.results_dir is None:
                parser.error("results mode requires --results-dir")
            report = verify_results(manifest, args.results_dir.resolve())
        else:
            required = (
                args.suite_id,
                args.filter,
                args.xctest_binary,
                args.xunit_output,
                args.per_test_timeout_seconds,
                args.termination_grace_seconds,
            )
            if any(value is None for value in required):
                parser.error("execute mode requires suite, filter, XCTest, xUnit, timeout, and grace arguments")
            report = execute_xctest_suite(
                suite_id=args.suite_id,
                test_filter=args.filter,
                xctest_binary=args.xctest_binary.resolve(),
                xunit_output=args.xunit_output.resolve(),
                per_test_timeout_seconds=args.per_test_timeout_seconds,
                termination_grace_seconds=args.termination_grace_seconds,
            )
    except VerificationError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print(json.dumps({"passed": True, **report}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
