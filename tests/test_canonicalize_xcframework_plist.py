from __future__ import annotations

import plistlib
from pathlib import Path
import stat
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/lib/canonicalize-xcframework-plist.py"


def _write_plist(path: Path, libraries: list[dict[str, object]]) -> dict[str, object]:
    payload: dict[str, object] = {
        "XCFrameworkFormatVersion": "1.0",
        "CFBundlePackageType": "XFWK",
        "AvailableLibraries": libraries,
    }
    with path.open("wb") as handle:
        plistlib.dump(payload, handle, fmt=plistlib.FMT_XML, sort_keys=False)
    return payload


def test_canonicalizer_preserves_records_and_produces_byte_identical_output(tmp_path: Path) -> None:
    libraries = [
        {
            "LibraryIdentifier": "macos-arm64_x86_64",
            "SupportedPlatform": "macos",
            "SupportedArchitectures": ["arm64", "x86_64"],
        },
        {
            "LibraryIdentifier": "ios-arm64",
            "SupportedPlatform": "ios",
            "SupportedArchitectures": ["arm64"],
        },
        {
            "LibraryIdentifier": "ios-arm64_x86_64-simulator",
            "SupportedPlatform": "ios",
            "SupportedPlatformVariant": "simulator",
            "SupportedArchitectures": ["arm64", "x86_64"],
        },
    ]
    first_path = tmp_path / "first.plist"
    second_path = tmp_path / "second.plist"
    original = _write_plist(first_path, libraries)
    _write_plist(second_path, list(reversed(libraries)))
    first_path.chmod(0o640)
    second_path.chmod(0o640)

    for path in (first_path, second_path):
        subprocess.run([sys.executable, str(SCRIPT), str(path)], check=True)

    assert first_path.read_bytes() == second_path.read_bytes()
    assert stat.S_IMODE(first_path.stat().st_mode) == 0o640
    assert stat.S_IMODE(second_path.stat().st_mode) == 0o640
    with first_path.open("rb") as handle:
        canonical = plistlib.load(handle)
    assert canonical["CFBundlePackageType"] == original["CFBundlePackageType"]
    assert canonical["XCFrameworkFormatVersion"] == original["XCFrameworkFormatVersion"]
    assert {
        library["LibraryIdentifier"]: library
        for library in canonical["AvailableLibraries"]
    } == {
        library["LibraryIdentifier"]: library
        for library in original["AvailableLibraries"]
    }
    assert [
        library["LibraryIdentifier"]
        for library in canonical["AvailableLibraries"]
    ] == sorted(library["LibraryIdentifier"] for library in libraries)
