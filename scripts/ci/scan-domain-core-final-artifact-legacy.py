#!/usr/bin/env python3
"""Scan exact final artifact code members for deleted legacy implementations."""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import io
import json
import plistlib
import platform
import subprocess
import tempfile
import zipfile
from pathlib import Path
from typing import Any


RULES = {
    "quota": (
        b"ClaudeQuotaLegacy",
        b"CodexQuotaLegacy",
        b"CodexUsagePayload",
        b"legacyBuckets",
        b"CodexUsageQuotaParser",
        b"ParseLegacy",
    ),
    "cloudvault": (
        b"CloudVaultLegacyCrypto",
        b"CloudVaultLegacySearch",
        b"CloudVaultCryptoSearch",
        b"AesGcmBox",
    ),
    "hermes": (
        b"HermesRelayLegacyCrypto",
        b"HermesRatchetLegacyCrypto",
        b"PiAgentRelayCrypto",
    ),
    "pricing": (b"legacyTokenCost", b"priceLegacyKimiEvent", b"LEGACY_KIMI_WIRE"),
}
CONSUMER_RULES = {
    "apple": ("quota", "cloudvault", "hermes", "pricing"),
    "ios": ("cloudvault", "hermes"),
    "android": ("cloudvault", "hermes"),
    "windows": ("quota", "cloudvault"),
    "linux": ("quota", "cloudvault", "hermes", "pricing"),
    "console": ("cloudvault",),
    "functions": ("pricing",),
}
CODE_SUFFIXES = {".dex", ".dll", ".dylib", ".exe", ".js", ".mjs", ".cjs", ".node", ".so", ".wasm"}
CODE_MAGICS = (b"\x7fELF", b"MZ", b"dex\n", b"\xca\xfe\xba\xbe", b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf")


def is_code(path: str, data: bytes, executable: bool = False) -> bool:
    return Path(path).suffix.lower() in CODE_SUFFIXES or data.startswith(CODE_MAGICS) or executable


def scan_bytes(path: str, data: bytes, needles: tuple[bytes, ...], results: list[dict[str, Any]]) -> None:
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as nested:
            for info in sorted(nested.infolist(), key=lambda value: value.filename):
                if info.is_dir() or info.flag_bits & 1:
                    continue
                scan_bytes(f"{path}!/{info.filename}", nested.read(info), needles, results)
            return
    except zipfile.BadZipFile:
        pass
    if not is_code(path, data):
        return
    matches = [needle.decode("ascii") for needle in needles if needle in data]
    results.append(
        {
            "path": path,
            "sha256": hashlib.sha256(data).hexdigest(),
            "size": len(data),
            "matches": matches,
        }
    )


def scan(
    consumer: str,
    artifact: Path,
    extracted_root: Path | None = None,
) -> dict[str, Any]:
    if consumer not in CONSUMER_RULES:
        raise ValueError("unknown final artifact consumer")
    if not artifact.is_file() or artifact.is_symlink() or artifact.stat().st_size < 1:
        raise ValueError("final artifact must be a nonempty regular file")
    needles = tuple(needle for rule in CONSUMER_RULES[consumer] for needle in RULES[rule])
    members: list[dict[str, Any]] = []
    artifact_bytes = artifact.read_bytes()
    with contextlib.ExitStack() as stack:
        try:
            with zipfile.ZipFile(io.BytesIO(artifact_bytes)) as archive:
                for info in sorted(archive.infolist(), key=lambda value: value.filename):
                    if info.is_dir() or info.flag_bits & 1:
                        continue
                    scan_bytes(info.filename, archive.read(info), needles, members)
        except zipfile.BadZipFile:
            if extracted_root is None and artifact.suffix.lower() == ".dmg" and platform.system() == "Darwin":
                attached = subprocess.run(
                    ["hdiutil", "attach", "-readonly", "-nobrowse", "-plist", str(artifact)],
                    check=True,
                    capture_output=True,
                )
                plist = plistlib.loads(attached.stdout)
                mount_points = [
                    entity.get("mount-point")
                    for entity in plist.get("system-entities", [])
                    if isinstance(entity, dict) and entity.get("mount-point")
                ]
                if len(mount_points) != 1:
                    raise ValueError("DMG scan requires exactly one mounted product volume") from None
                extracted_root = Path(mount_points[0])
                stack.callback(
                    subprocess.run,
                    ["hdiutil", "detach", str(extracted_root)],
                    check=True,
                    capture_output=True,
                )
            elif extracted_root is None and artifact.name.endswith(".tar.zst"):
                temporary = Path(stack.enter_context(tempfile.TemporaryDirectory()))
                subprocess.run(["tar", "--zstd", "-xf", str(artifact), "-C", str(temporary)], check=True)
                extracted_root = temporary
            elif extracted_root is None:
                raise ValueError(
                    "non-ZIP final artifacts require --extracted-root from the verified package/deploy step"
                ) from None
        if extracted_root is not None:
            _scan_extracted_root(extracted_root, needles, members)

    unique = {(member["path"], member["sha256"]): member for member in members}
    members = [unique[key] for key in sorted(unique)]
    if not members:
        raise ValueError("final artifact scan found no executable or compiled code members")
    matches = [{"path": member["path"], "symbols": member["matches"]} for member in members if member["matches"]]
    report = {
        "schemaVersion": 1,
        "consumer": consumer,
        "artifact": {
            "fileName": artifact.name,
            "sha256": hashlib.sha256(artifact_bytes).hexdigest(),
            "size": len(artifact_bytes),
        },
        "ruleSetSha256": hashlib.sha256(b"\0".join(sorted(needles))).hexdigest(),
        "inspectedMembers": members,
        "matches": matches,
        "result": "absent" if not matches else "legacy_present",
    }
    if matches:
        raise ValueError(f"final artifact contains deleted legacy implementation markers: {matches}")
    return report


def _scan_extracted_root(
    extracted_root: Path,
    needles: tuple[bytes, ...],
    members: list[dict[str, Any]],
) -> None:
    if not extracted_root.is_dir() or extracted_root.is_symlink():
        raise ValueError("extracted final artifact root must be a safe directory")
    for path in sorted(extracted_root.rglob("*")):
        if path.is_symlink():
            raise ValueError(f"extracted final artifact contains a symlink: {path}")
        if not path.is_file():
            continue
        relative = path.relative_to(extracted_root).as_posix()
        data = path.read_bytes()
        executable = bool(path.stat().st_mode & 0o111)
        if is_code(relative, data, executable):
            scan_bytes(relative, data, needles, members)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--consumer", required=True)
    parser.add_argument("--artifact", required=True, type=Path)
    parser.add_argument("--extracted-root", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        result = scan(args.consumer, args.artifact, args.extracted_root)
        args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    except (OSError, ValueError, zipfile.BadZipFile) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
