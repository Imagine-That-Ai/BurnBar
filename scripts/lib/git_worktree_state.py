#!/usr/bin/env python3
"""Report a Git worktree as clean or dirty without allowing a build to hang."""

from __future__ import annotations

import argparse
import subprocess
from pathlib import Path


def detect_worktree_state(repo: Path, timeout_seconds: float) -> str:
    """Return ``clean`` only when Git proves it within the supplied deadline.

    Build provenance must fail conservative: a timeout, missing Git binary,
    invalid repository, or any other probe failure is reported as ``dirty``.
    """

    try:
        result = subprocess.run(
            [
                "git",
                "status",
                "--porcelain=v1",
                "--untracked-files=normal",
                "--ignore-submodules=all",
            ],
            cwd=repo,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=timeout_seconds,
        )
    except (OSError, subprocess.TimeoutExpired):
        return "dirty"

    if result.returncode != 0:
        return "dirty"
    return "dirty" if result.stdout else "clean"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--timeout-seconds", type=float, default=3.0)
    args = parser.parse_args()
    if args.timeout_seconds <= 0:
        parser.error("--timeout-seconds must be positive")
    return args


def main() -> int:
    args = parse_args()
    print(detect_worktree_state(args.repo, args.timeout_seconds))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
