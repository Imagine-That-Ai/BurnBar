#!/usr/bin/env python3
"""Create the canonical, deterministic x64 + ARM64 Windows release bundle."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path
from urllib.parse import urlsplit


VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
DIGEST_RE = re.compile(r"^[0-9a-f]{64}$")
FIXED_ZIP_TIME = (1980, 1, 1, 0, 0, 0)
SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


class BundleError(ValueError):
    pass


def sha256_path(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def require_regular_file(path: Path, label: str) -> Path:
    if path.is_symlink() or not path.is_file():
        raise BundleError(f"{label} is not a regular file: {path}")
    if path.stat().st_size <= 0:
        raise BundleError(f"{label} is empty: {path}")
    return path


def package_names(version: str) -> dict[str, dict[str, str]]:
    return {
        "x64": {
            "portable": f"OpenBurnBar-{version}-win-x64.zip",
            "msix": f"OpenBurnBar-{version}-x64.msix",
        },
        "arm64": {
            "portable": f"OpenBurnBar-{version}-win-arm64.zip",
            "msix": f"OpenBurnBar-{version}-arm64.msix",
        },
    }


def parse_checksums(path: Path, expected: set[str]) -> dict[str, str]:
    checksums: dict[str, str] = {}
    for line_number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        parts = raw_line.split()
        if len(parts) != 2 or DIGEST_RE.fullmatch(parts[0]) is None:
            raise BundleError(f"invalid checksum line {line_number} in {path.name}")
        name = parts[1].removeprefix("*")
        if "/" in name or "\\" in name or name not in expected:
            raise BundleError(f"unexpected checksum member on line {line_number}: {name}")
        if name in checksums:
            raise BundleError(f"duplicate checksum member: {name}")
        checksums[name] = parts[0]
    if set(checksums) != expected:
        missing = sorted(expected - set(checksums))
        raise BundleError(f"checksum file does not cover the exact package set; missing={missing}")
    return checksums


def load_json(path: Path, label: str) -> dict[str, object]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise BundleError(f"{label} is invalid JSON: {error}") from error
    if not isinstance(value, dict):
        raise BundleError(f"{label} must be a JSON object")
    return value


def validate_update_feed(
    path: Path,
    *,
    version: str,
    files: dict[str, Path],
    packages: dict[str, dict[str, str]],
) -> None:
    feed = load_json(path, "Windows update feed")
    if feed.get("schemaVersion") != 1 or feed.get("feed") != "openburnbar-windows":
        raise BundleError("Windows update feed has the wrong schema or feed identity")
    entries = feed.get("entries")
    if not isinstance(entries, list) or len(entries) != 2:
        raise BundleError("Windows update feed must contain exactly x64 and ARM64 entries")
    by_platform: dict[str, dict[str, object]] = {}
    for entry in entries:
        if not isinstance(entry, dict) or not isinstance(entry.get("platform"), str):
            raise BundleError("Windows update feed contains an invalid entry")
        platform = entry["platform"]
        if platform in by_platform:
            raise BundleError(f"Windows update feed duplicates platform {platform}")
        by_platform[platform] = entry
    if set(by_platform) != {"win-x64", "win-arm64"}:
        raise BundleError("Windows update feed must cover the exact win-x64 and win-arm64 set")
    for architecture, platform in (("x64", "win-x64"), ("arm64", "win-arm64")):
        entry = by_platform[platform]
        name = packages[architecture]["portable"]
        artifact = files[name]
        url = entry.get("url")
        if (
            entry.get("version") != version
            or entry.get("channel") != "stable"
            or entry.get("sha256") != sha256_path(artifact)
            or entry.get("sizeBytes") != artifact.stat().st_size
            or not isinstance(url, str)
            or urlsplit(url).scheme != "https"
            or Path(urlsplit(url).path).name != name
            or not isinstance(entry.get("ed25519Signature"), str)
            or not entry["ed25519Signature"]
        ):
            raise BundleError(f"Windows update feed does not bind the exact {platform} portable package")


def validate_latest_metadata(
    path: Path,
    *,
    version: str,
    commit: str,
    x64_msix: Path,
) -> None:
    latest = load_json(path, "latest Windows metadata")
    expected_name = x64_msix.name
    download_url = latest.get("downloadUrl")
    if (
        latest.get("version") != version
        or latest.get("commit") != commit
        or latest.get("package") != expected_name
        or latest.get("sha256") != sha256_path(x64_msix)
        or latest.get("length") != x64_msix.stat().st_size
        or not isinstance(download_url, str)
        or urlsplit(download_url).scheme != "https"
        or Path(urlsplit(download_url).path).name != expected_name
        or not isinstance(latest.get("edSignature"), str)
        or not latest["edSignature"]
        or not isinstance(latest.get("descriptorSignature"), str)
        or not latest["descriptorSignature"]
    ):
        raise BundleError("latest Windows metadata does not bind the exact signed x64 MSIX")


def validate_appcast(path: Path, *, version: str, x64_msix: Path) -> None:
    try:
        root = ET.parse(path).getroot()
    except (OSError, ET.ParseError) as error:
        raise BundleError(f"Windows appcast is invalid XML: {error}") from error
    short_versions = [
        (element.text or "").strip() for element in root.findall(f".//{{{SPARKLE_NAMESPACE}}}shortVersionString")
    ]
    enclosures = root.findall(".//enclosure")
    if short_versions != [version] or len(enclosures) != 1:
        raise BundleError("Windows appcast must contain exactly the requested stable version")
    enclosure = enclosures[0]
    url = enclosure.get("url", "")
    if (
        urlsplit(url).scheme != "https"
        or Path(urlsplit(url).path).name != x64_msix.name
        or enclosure.get("length") != str(x64_msix.stat().st_size)
        or enclosure.get(f"{{{SPARKLE_NAMESPACE}}}sha256") != sha256_path(x64_msix)
        or not enclosure.get(f"{{{SPARKLE_NAMESPACE}}}edSignature")
        or not enclosure.get(f"{{{SPARKLE_NAMESPACE}}}edDescriptorSignature")
    ):
        raise BundleError("Windows appcast does not bind the exact signed x64 MSIX")


def zip_info(name: str) -> zipfile.ZipInfo:
    info = zipfile.ZipInfo(name, FIXED_ZIP_TIME)
    info.compress_type = zipfile.ZIP_STORED
    info.create_system = 3
    info.external_attr = (stat.S_IFREG | 0o644) << 16
    return info


def write_streamed(archive: zipfile.ZipFile, name: str, path: Path) -> None:
    with path.open("rb") as source, archive.open(zip_info(name), "w") as destination:
        shutil.copyfileobj(source, destination, length=1024 * 1024)


def create_bundle(source_dir: Path, output: Path, version: str, commit: str) -> dict[str, object]:
    if VERSION_RE.fullmatch(version) is None:
        raise BundleError("version must be a stable X.Y.Z Windows release")
    if COMMIT_RE.fullmatch(commit) is None:
        raise BundleError("commit must be a full lowercase Git SHA")
    if source_dir.is_symlink() or not source_dir.is_dir():
        raise BundleError(f"source directory is not a regular directory: {source_dir}")

    packages = package_names(version)
    checksum_name = f"checksums-windows-v{version}.txt"
    feed_name = f"windows-update-feed-v{version}.json"
    metadata_names = (checksum_name, feed_name, "appcast-windows.xml", "latest-windows.json")
    ordered_names = [
        packages["x64"]["portable"],
        packages["x64"]["msix"],
        packages["arm64"]["portable"],
        packages["arm64"]["msix"],
        *metadata_names,
    ]
    files = {
        name: require_regular_file(source_dir / name, f"required Windows release member {name}")
        for name in ordered_names
    }

    package_set = {packages[architecture][kind] for architecture in ("x64", "arm64") for kind in ("portable", "msix")}
    checksums = parse_checksums(files[checksum_name], package_set)
    for name in package_set:
        if checksums[name] != sha256_path(files[name]):
            raise BundleError(f"checksum does not match signed package bytes: {name}")

    validate_update_feed(
        files[feed_name],
        version=version,
        files=files,
        packages=packages,
    )
    x64_msix = files[packages["x64"]["msix"]]
    validate_latest_metadata(
        files["latest-windows.json"],
        version=version,
        commit=commit,
        x64_msix=x64_msix,
    )
    validate_appcast(files["appcast-windows.xml"], version=version, x64_msix=x64_msix)

    def descriptor(name: str) -> dict[str, object]:
        path = files[name]
        return {"fileName": name, "sha256": sha256_path(path), "sizeBytes": path.stat().st_size}

    manifest: dict[str, object] = {
        "schemaVersion": 1,
        "artifactKind": "windows-release-bundle",
        "target": "windows-x64-arm64",
        "release": {"version": version, "tag": f"windows-v{version}", "commit": commit},
        "architectures": {
            architecture: {
                "portable": descriptor(packages[architecture]["portable"]),
                "msix": descriptor(packages[architecture]["msix"]),
            }
            for architecture in ("x64", "arm64")
        },
        "metadata": [descriptor(name) for name in metadata_names],
    }
    manifest_bytes = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode("utf-8")

    expected_output_name = f"OpenBurnBar-{version}-windows-release.zip"
    if output.name != expected_output_name:
        raise BundleError(f"output filename must be {expected_output_name}")
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(f".{output.name}.{os.getpid()}.tmp")
    try:
        with zipfile.ZipFile(temporary, "w", allowZip64=True) as archive:
            archive.writestr(zip_info("manifest.json"), manifest_bytes)
            for name in ordered_names:
                write_streamed(archive, name, files[name])
        os.replace(temporary, output)
    finally:
        temporary.unlink(missing_ok=True)
    return manifest


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--commit", required=True)
    return parser.parse_args()


def main() -> None:
    arguments = parse_arguments()
    manifest = create_bundle(
        arguments.source_dir.resolve(),
        arguments.output.resolve(),
        arguments.version,
        arguments.commit,
    )
    print(json.dumps({"output": str(arguments.output.resolve()), "manifest": manifest}, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except BundleError as error:
        raise SystemExit(f"ERROR: {error}") from error
