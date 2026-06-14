#!/usr/bin/env python3
"""Swift file-size debt counter.

Lists production Swift files whose line count exceeds a target, so a CI gate can
enforce SHRINK-ONLY: no new file may cross the target and no baselined file may
grow past its recorded size. This replaces the toothless SwiftLint `file_length`
ceiling (set just above the largest file, so it constrained nothing) with a real
constraint that ratchets down as the giant views are decomposed.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys

ROOTS = (
    "AgentLens",
    "OpenBurnBarCore/Sources",
    "OpenBurnBarMobile",
    "OpenBurnBarDaemon/Sources",
)

EXCLUDED_PATH_SEGMENTS = {
    ".build",
    ".build-codex",
    ".derived-data",
    ".git",
    ".swiftpm",
    "Carthage",
    "DerivedData",
    "Pods",
    "build",
    "checkouts",
}


def _is_excluded(rel: pathlib.Path) -> bool:
    if any(part in EXCLUDED_PATH_SEGMENTS for part in rel.parts):
        return True
    if any(part == "Tests" or part.endswith("Tests") for part in rel.parts):
        return True
    # Generated Swift is sized by its emitter, not by hand.
    if any(part == "Generated" for part in rel.parts):
        return True
    if rel.name.endswith(".generated.swift"):
        return True
    return False


def count_oversized(repo_root: pathlib.Path, target: int) -> dict:
    files = []
    for root in ROOTS:
        base = repo_root / root
        if not base.exists():
            continue
        for path in base.rglob("*.swift"):
            rel = path.relative_to(repo_root)
            if _is_excluded(rel):
                continue
            try:
                with path.open(encoding="utf-8", errors="ignore") as handle:
                    lines = sum(1 for _ in handle)
            except OSError:
                continue
            if lines > target:
                files.append({"path": str(rel), "lines": lines})
    files.sort(key=lambda f: (-f["lines"], f["path"]))
    return {"target": target, "total": len(files), "files": files}


def main() -> int:
    parser = argparse.ArgumentParser(description="OpenBurnBar Swift file-size debt counter")
    parser.add_argument("--repo-root", type=pathlib.Path, default=pathlib.Path.cwd())
    parser.add_argument("--target", type=int, default=2000, help="line-count threshold (exclusive)")
    parser.add_argument("--format", choices=("json", "text"), default="json")
    args = parser.parse_args()

    payload = count_oversized(args.repo_root.resolve(), args.target)
    if args.format == "text":
        print(f"swift_file_size target={payload['target']} over_target={payload['total']}")
        for f in payload["files"]:
            print(f"  {f['lines']:>6}  {f['path']}")
    else:
        json.dump(payload, sys.stdout, indent=2)
        sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
