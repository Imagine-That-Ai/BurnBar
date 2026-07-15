#!/usr/bin/env python3
"""Write an XCFramework Info.plist in a deterministic order and format."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import plistlib
import stat
import tempfile
from typing import Any


def canonicalize_xcframework_plist(path: Path) -> None:
    original_mode = stat.S_IMODE(path.stat().st_mode)
    with path.open("rb") as handle:
        payload: dict[str, Any] = plistlib.load(handle)

    libraries = payload.get("AvailableLibraries")
    if not isinstance(libraries, list):
        raise ValueError("AvailableLibraries must be an array")
    if any(
        not isinstance(library, dict)
        or not isinstance(library.get("LibraryIdentifier"), str)
        for library in libraries
    ):
        raise ValueError("every AvailableLibraries entry must have a string LibraryIdentifier")

    identifiers = [library["LibraryIdentifier"] for library in libraries]
    if len(identifiers) != len(set(identifiers)):
        raise ValueError("AvailableLibraries contains duplicate LibraryIdentifier values")

    payload["AvailableLibraries"] = sorted(
        libraries,
        key=lambda library: library["LibraryIdentifier"],
    )

    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as temporary:
        temporary_path = Path(temporary.name)
        plistlib.dump(payload, temporary, fmt=plistlib.FMT_XML, sort_keys=True)
    temporary_path.chmod(original_mode)
    try:
        os.replace(temporary_path, path)
    except BaseException:
        temporary_path.unlink(missing_ok=True)
        raise


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("plist", type=Path)
    arguments = parser.parse_args()
    canonicalize_xcframework_plist(arguments.plist)


if __name__ == "__main__":
    main()
