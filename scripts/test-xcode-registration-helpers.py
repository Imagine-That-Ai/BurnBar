#!/usr/bin/env python3
"""Regression tests for portable, idempotent Xcode registration helpers."""
from __future__ import annotations

import os
import py_compile
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_PROJECT = ROOT / "OpenBurnBar.xcodeproj/project.pbxproj"
HELPERS = sorted(ROOT.glob("scripts/register-*-in-xcode.py"))
NOOP_ON_CURRENT_HELPERS = {
    "register-pr4-service-splits-in-xcode.py",
    "register-quota-tab-in-xcode.py",
    "register-quota-tests-in-xcode.py",
    "register-ws4-security-clients-in-xcode.py",
}


def run_helper(helper: Path, project: Path, repo: Path) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["OPENBURNBAR_REPO"] = str(repo)
    env["OPENBURNBAR_XCODEPROJ"] = str(project)
    return subprocess.run(
        [sys.executable, str(helper)],
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def assert_no_hardcoded_checkout(helper: Path) -> None:
    source = helper.read_text()
    if "/Users/albertonunez/Documents/Windsurf/BurnBar" in source:
        raise AssertionError(f"{helper} still hardcodes the local checkout path")


def assert_helper_idempotent(helper: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="openburnbar-xcode-helper-") as tmp:
        repo = Path(tmp)
        project = repo / "OpenBurnBar.xcodeproj/project.pbxproj"
        project.parent.mkdir(parents=True)
        shutil.copy2(SOURCE_PROJECT, project)
        before_first = project.read_bytes()

        first = run_helper(helper, project, repo)
        if first.returncode != 0:
            raise AssertionError(f"{helper.name} first run failed\nstdout:\n{first.stdout}\nstderr:\n{first.stderr}")

        after_first = project.read_bytes()
        if helper.name in NOOP_ON_CURRENT_HELPERS and after_first != before_first:
            raise AssertionError(f"{helper.name} changed an already-registered current project on first run")

        second = run_helper(helper, project, repo)
        if second.returncode != 0:
            raise AssertionError(f"{helper.name} second run failed\nstdout:\n{second.stdout}\nstderr:\n{second.stderr}")

        after_second = project.read_bytes()
        if after_second != after_first:
            raise AssertionError(f"{helper.name} changed project.pbxproj on the second run")


def main() -> None:
    if not HELPERS:
        raise AssertionError("No Xcode registration helpers found")
    if not SOURCE_PROJECT.exists():
        raise AssertionError(f"Missing source pbxproj fixture: {SOURCE_PROJECT}")

    for helper in HELPERS:
        py_compile.compile(str(helper), doraise=True)
        assert_no_hardcoded_checkout(helper)
        assert_helper_idempotent(helper)

    print(f"xcode registration helper regressions ok ({len(HELPERS)} helpers)")


if __name__ == "__main__":
    main()
