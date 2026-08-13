#!/usr/bin/env python3
"""Safely promote app-hosted snapshot recordings back into the source tree.

OpenBurnBar's macOS XCTest host can run without the terminal process's
Documents-folder TCC grant. Snapshot references therefore live inside the
OpenBurnBarTests bundle while XCTest is running. This helper is the only bridge
back to the checkout:

* the source snapshot directory is the allowlist;
* every source basename must be unique;
* every allowlisted basename must resolve to exactly one regular bundle file;
* unrelated bundle images are ignored;
* ``never`` mode rejects every bundle/source byte drift before staging;
* all replacements are staged and hashed before the first source mutation;
* a failed multi-file install rolls back every replacement already made.

The helper never creates, removes, or renames canonical snapshot paths. Adding
or deleting a baseline remains an explicit source change.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import shutil
import sys
import tempfile
from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from pathlib import Path


class SnapshotPromotionError(RuntimeError):
    """Raised when snapshot promotion cannot be proved safe."""


SNAPSHOT_RECORD_MODE_INFO_KEY = "OpenBurnBarSnapshotRecordMode"
SUPPORTED_SNAPSHOT_RECORD_MODES = frozenset({"all", "failed", "missing", "never"})


@dataclass(frozen=True)
class SnapshotPromotionResult:
    total: int
    changed: tuple[str, ...]

    @property
    def unchanged(self) -> int:
        return self.total - len(self.changed)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _regular_pngs(root: Path) -> list[Path]:
    if not root.is_dir():
        raise SnapshotPromotionError(f"snapshot directory is missing: {root}")

    paths = sorted(
        (path for path in root.rglob("*.png") if path.is_file()),
        key=lambda path: path.relative_to(root).as_posix(),
    )
    if not paths:
        raise SnapshotPromotionError(f"snapshot directory contains no PNG references: {root}")
    for path in paths:
        if path.is_symlink():
            raise SnapshotPromotionError(f"snapshot reference must not be a symlink: {path}")
    return paths


def _unique_by_basename(
    paths: Iterable[Path],
    *,
    label: str,
) -> dict[str, Path]:
    grouped: dict[str, list[Path]] = {}
    for path in paths:
        grouped.setdefault(path.name, []).append(path)

    duplicates = {basename: matches for basename, matches in grouped.items() if len(matches) != 1}
    if duplicates:
        detail = "; ".join(
            f"{basename}: {', '.join(str(path) for path in matches)}"
            for basename, matches in sorted(duplicates.items())
        )
        raise SnapshotPromotionError(f"{label} basenames are ambiguous: {detail}")

    return {basename: matches[0] for basename, matches in grouped.items()}


def source_snapshot_allowlist(source_directory: Path) -> dict[str, Path]:
    return _unique_by_basename(
        _regular_pngs(source_directory),
        label="source snapshot",
    )


def test_bundle_info_plist(test_bundle: Path) -> Path:
    candidates = (
        test_bundle / "Contents" / "Info.plist",
        test_bundle / "Info.plist",
    )
    existing = [candidate for candidate in candidates if candidate.is_file()]
    if len(existing) != 1:
        rendered = ", ".join(str(candidate) for candidate in candidates)
        raise SnapshotPromotionError(
            "test bundle must contain exactly one Info.plist "
            f"from the supported locations ({rendered}); found {len(existing)}"
        )

    info_plist = existing[0]
    if info_plist.is_symlink():
        raise SnapshotPromotionError(f"test bundle Info.plist must not be a symlink: {info_plist}")
    return info_plist


def validate_test_bundle_record_mode(
    test_bundle: Path,
    expected_record_mode: str,
) -> None:
    if expected_record_mode not in SUPPORTED_SNAPSHOT_RECORD_MODES:
        raise SnapshotPromotionError(
            "expected snapshot record mode must be one of: " + ", ".join(sorted(SUPPORTED_SNAPSHOT_RECORD_MODES))
        )

    info_plist = test_bundle_info_plist(test_bundle)
    try:
        with info_plist.open("rb") as handle:
            bundle_info = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as error:
        raise SnapshotPromotionError(f"could not parse test bundle Info.plist: {info_plist}: {error}") from error

    actual_record_mode = bundle_info.get(SNAPSHOT_RECORD_MODE_INFO_KEY)
    if not isinstance(actual_record_mode, str):
        raise SnapshotPromotionError(f"test bundle Info.plist is missing string key {SNAPSHOT_RECORD_MODE_INFO_KEY}")
    actual_record_mode = actual_record_mode.strip()
    if actual_record_mode != expected_record_mode:
        raise SnapshotPromotionError(
            "test bundle snapshot record mode does not match the requested mode "
            f"(expected={expected_record_mode!r}, actual={actual_record_mode!r})"
        )


def test_bundle_resources(test_bundle: Path) -> Path:
    candidates = (
        test_bundle / "Contents" / "Resources",
        test_bundle / "Resources",
    )
    existing = [candidate for candidate in candidates if candidate.is_dir()]
    if len(existing) != 1:
        rendered = ", ".join(str(candidate) for candidate in candidates)
        raise SnapshotPromotionError(
            "test bundle must contain exactly one resource directory "
            f"from the supported locations ({rendered}); found {len(existing)}"
        )
    return existing[0]


def bundled_snapshot_references(
    resources: Path,
    expected_basenames: Iterable[str],
) -> dict[str, Path]:
    expected = frozenset(expected_basenames)
    candidates = [path for path in resources.rglob("*.png") if path.is_file() and path.name in expected]
    for path in candidates:
        if path.is_symlink():
            raise SnapshotPromotionError(f"bundled snapshot must not be a symlink: {path}")

    bundled = _unique_by_basename(candidates, label="bundled snapshot")
    missing = sorted(expected.difference(bundled))
    if missing:
        raise SnapshotPromotionError("test bundle is missing allowlisted snapshot references: " + ", ".join(missing))
    return bundled


def changed_snapshot_references(
    source: Mapping[str, Path],
    bundled: Mapping[str, Path],
) -> list[tuple[str, Path, Path]]:
    changes: list[tuple[str, Path, Path]] = []
    for basename in sorted(source):
        source_path = source[basename]
        bundled_path = bundled[basename]
        if sha256_file(source_path) != sha256_file(bundled_path):
            changes.append((basename, source_path, bundled_path))
    return changes


def _copy_and_sync(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)
    with destination.open("rb") as handle:
        os.fsync(handle.fileno())


def _transactionally_replace(
    source_directory: Path,
    changes: list[tuple[str, Path, Path]],
) -> None:
    if not changes:
        return

    transaction_root = Path(
        tempfile.mkdtemp(
            prefix=".snapshot-promotion-",
            dir=source_directory.parent,
        )
    )
    staged_root = transaction_root / "staged"
    backup_root = transaction_root / "backups"
    prepared: list[tuple[Path, Path, Path]] = []
    installed: list[tuple[Path, Path]] = []

    try:
        for _basename, source_path, bundled_path in changes:
            relative_path = source_path.relative_to(source_directory)
            staged_path = staged_root / relative_path
            backup_path = backup_root / relative_path
            _copy_and_sync(bundled_path, staged_path)
            _copy_and_sync(source_path, backup_path)
            if sha256_file(staged_path) != sha256_file(bundled_path):
                raise SnapshotPromotionError(f"staged snapshot hash mismatch before promotion: {source_path}")
            prepared.append((source_path, staged_path, backup_path))

        for source_path, staged_path, backup_path in prepared:
            os.replace(staged_path, source_path)
            installed.append((source_path, backup_path))
    except Exception as install_error:
        rollback_errors: list[str] = []
        for source_path, backup_path in reversed(installed):
            try:
                os.replace(backup_path, source_path)
            except OSError as rollback_error:
                rollback_errors.append(f"{source_path}: {rollback_error}")

        if rollback_errors:
            raise SnapshotPromotionError(
                "snapshot promotion failed and rollback was incomplete: "
                f"{install_error}; rollback errors: {'; '.join(rollback_errors)}"
            ) from install_error
        if isinstance(install_error, SnapshotPromotionError):
            raise
        raise SnapshotPromotionError(
            f"snapshot promotion failed; every installed file was rolled back: {install_error}"
        ) from install_error
    finally:
        shutil.rmtree(transaction_root, ignore_errors=True)


def promote_snapshot_recordings(
    source_directory: Path,
    test_bundle: Path,
    expected_record_mode: str,
) -> SnapshotPromotionResult:
    source_directory = source_directory.resolve(strict=False)
    test_bundle = test_bundle.resolve(strict=False)

    validate_test_bundle_record_mode(test_bundle, expected_record_mode)
    source = source_snapshot_allowlist(source_directory)
    resources = test_bundle_resources(test_bundle)
    bundled = bundled_snapshot_references(resources, source.keys())
    changes = changed_snapshot_references(source, bundled)
    if expected_record_mode == "never" and changes:
        changed_basenames = ", ".join(basename for basename, _source, _bundled in changes)
        raise SnapshotPromotionError(
            f"test bundle changed snapshot references while record mode is 'never': {changed_basenames}"
        )
    _transactionally_replace(source_directory, changes)

    return SnapshotPromotionResult(
        total=len(source),
        changed=tuple(basename for basename, _source, _bundled in changes),
    )


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--source-directory",
        required=True,
        type=Path,
        help="Canonical __Snapshots__ directory whose existing PNGs form the allowlist.",
    )
    parser.add_argument(
        "--test-bundle",
        required=True,
        type=Path,
        help="Built OpenBurnBarTests.xctest bundle containing flattened PNG resources.",
    )
    parser.add_argument(
        "--expected-record-mode",
        required=True,
        choices=sorted(SUPPORTED_SNAPSHOT_RECORD_MODES),
        help=(
            "Validated record mode that must be stamped into the built test bundle "
            f"under {SNAPSHOT_RECORD_MODE_INFO_KEY}."
        ),
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        result = promote_snapshot_recordings(
            source_directory=args.source_directory,
            test_bundle=args.test_bundle,
            expected_record_mode=args.expected_record_mode,
        )
    except (OSError, SnapshotPromotionError) as error:
        print(f"error: snapshot recording promotion failed: {error}", file=sys.stderr)
        return 65

    print(
        json.dumps(
            {
                "kind": "openburnbar-snapshot-promotion",
                "total": result.total,
                "changed": len(result.changed),
                "unchanged": result.unchanged,
                "changedBasenames": list(result.changed),
                "recordMode": args.expected_record_mode,
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
