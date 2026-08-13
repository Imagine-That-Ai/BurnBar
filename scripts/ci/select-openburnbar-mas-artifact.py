#!/usr/bin/env python3
"""Select exactly one Mac App Store release artifact without first-match fallbacks."""

from __future__ import annotations

import argparse
import plistlib
import sys
from pathlib import Path


KINDS = {
    "app": ("OpenBurnBar.app", True),
    "archive": ("*.xcarchive", False),
    "pkg": ("*.pkg", False),
}


def fail(message: str) -> None:
    raise ValueError(message)


def real_candidates(root: Path, kind: str, recursive: bool) -> list[Path]:
    pattern, is_directory = KINDS[kind]
    iterator = root.rglob(pattern) if recursive else root.glob(pattern)
    candidates: list[Path] = []
    for candidate in iterator:
        if candidate.is_symlink():
            fail(f"{kind} candidate must not be a symlink: {candidate}")
        if is_directory and not candidate.is_dir():
            continue
        if not is_directory and not candidate.is_file() and kind != "archive":
            continue
        if kind == "archive" and not candidate.is_dir():
            continue
        candidates.append(candidate)
    return sorted(candidates, key=lambda path: str(path))


def app_metadata(path: Path) -> tuple[str, str, str]:
    info_path = path / "Contents" / "Info.plist"
    if not info_path.is_file() or info_path.is_symlink():
        fail(f"app candidate has no real Contents/Info.plist: {path}")
    with info_path.open("rb") as file:
        info = plistlib.load(file)
    bundle_id = info.get("CFBundleIdentifier")
    version = info.get("CFBundleShortVersionString")
    build = info.get("CFBundleVersion")
    if not all(isinstance(value, str) and value for value in (bundle_id, version, build)):
        fail(f"app candidate is missing bundle identifier/version/build metadata: {path}")
    return bundle_id, version, build


def select(
    *,
    root: Path,
    kind: str,
    recursive: bool,
    expected: Path | None,
    bundle_id: str | None,
    version: str | None,
    build: str | None,
) -> Path:
    if not root.is_dir() or root.is_symlink():
        fail(f"selection root must be a real directory: {root}")
    candidates = real_candidates(root, kind, recursive)
    if len(candidates) != 1:
        rendered = ", ".join(str(path) for path in candidates) or "none"
        fail(f"expected exactly one {kind} candidate under {root}; found {len(candidates)}: {rendered}")
    selected = candidates[0].resolve()
    if expected is not None and selected != expected.resolve():
        fail(f"selected {kind} {selected} does not equal expected path {expected.resolve()}")
    if kind == "app":
        actual_bundle_id, actual_version, actual_build = app_metadata(selected)
        expected_values = (
            ("bundle identifier", actual_bundle_id, bundle_id),
            ("version", actual_version, version),
            ("build", actual_build, build),
        )
        for label, actual, wanted in expected_values:
            if wanted is not None and actual != wanted:
                fail(f"selected app {label} must be {wanted!r}; found {actual!r}")
    return selected


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--kind", required=True, choices=sorted(KINDS))
    parser.add_argument("--recursive", action="store_true")
    parser.add_argument("--expected", type=Path)
    parser.add_argument("--bundle-id")
    parser.add_argument("--version")
    parser.add_argument("--build")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        selected = select(
            root=args.root,
            kind=args.kind,
            recursive=args.recursive,
            expected=args.expected,
            bundle_id=args.bundle_id,
            version=args.version,
            build=args.build,
        )
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print(selected)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
