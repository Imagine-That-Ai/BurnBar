#!/usr/bin/env python3
"""Prove an exported iOS Mach-O contains the linked Rust identity section."""

from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import re
import subprocess
from pathlib import Path
from typing import Any


IDENTITY_PATTERN = re.compile(
    r"^openburnbar-domain-core-identity-v1\|"
    r"candidateCommit=(?P<candidateCommit>[0-9a-f]{40})\|"
    r"coreVersion=(?P<coreVersion>[0-9]+\.[0-9]+\.[0-9]+(?:\+[0-9A-Za-z.-]+)?)\|"
    r"abiVersion=(?P<abiVersion>[1-9][0-9]*)\|"
    r"sourceSha256=(?P<sourceSha256>[0-9a-f]{64})$"
)
IDENTITY_SYMBOL = "OPENBURNBAR_DOMAIN_CORE_IDENTITY_V1"
FFI_IDENTITY_SYMBOLS = {
    "uniffi_openburnbar_domain_ffi_fn_func_domain_core_abi_version",
    "uniffi_openburnbar_domain_ffi_fn_func_domain_core_source_fingerprint",
    "uniffi_openburnbar_domain_ffi_fn_func_domain_core_version",
}


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def run(*command: str, timeout: int = 60) -> str:
    return subprocess.run(
        list(command),
        check=True,
        capture_output=True,
        text=True,
        timeout=timeout,
    ).stdout


def parse_identity_section(output: str) -> bytes:
    collecting = False
    decoded = bytearray()
    for line in output.splitlines():
        if "Contents of (__TEXT,__obb_core_id) section" in line:
            collecting = True
            continue
        if not collecting:
            continue
        fields = line.split()
        if len(fields) < 2 or not re.fullmatch(r"[0-9a-fA-F]+", fields[0]):
            if decoded:
                break
            continue
        groups = [field for field in fields[1:] if re.fullmatch(r"(?:[0-9a-fA-F]{2})+", field)]
        if not groups:
            break
        for group in groups:
            value = bytes.fromhex(group)
            decoded.extend(value[::-1] if len(value) == 4 else value)
    if not decoded:
        raise ValueError("iOS executable has no __TEXT,__obb_core_id Rust identity section")
    return bytes(decoded).rstrip(b"\0")


def parse_observed_identity(section: bytes) -> dict[str, Any]:
    try:
        wire = section.decode("ascii")
    except UnicodeDecodeError as error:
        raise ValueError("iOS Rust identity section is not canonical ASCII") from error
    match = IDENTITY_PATTERN.fullmatch(wire)
    if match is None:
        raise ValueError("iOS Rust identity section is malformed")
    observed: dict[str, Any] = match.groupdict()
    observed["abiVersion"] = int(observed["abiVersion"])
    return observed


def verify(app: Path, candidate_path: Path, output: Path) -> dict[str, Any]:
    candidate = json.loads(candidate_path.read_text())
    required = {"candidateCommit", "coreVersion", "abiVersion", "sourceSha256"}
    if not isinstance(candidate, dict) or set(candidate) != required:
        raise ValueError("candidate identity must contain the exact four canonical fields")
    plist = plistlib.loads((app / "Info.plist").read_bytes())
    executable = app / plist["CFBundleExecutable"]
    if not executable.is_file() or executable.is_symlink():
        raise ValueError("iOS app executable is missing or unsafe")

    file_kind = run("file", "-b", str(executable), timeout=30).strip()
    if "Mach-O" not in file_kind:
        raise ValueError("iOS executable is not a Mach-O binary")
    architectures = run("lipo", "-archs", str(executable), timeout=30).split()
    if "arm64" not in architectures:
        raise ValueError("iOS executable has no arm64 device slice")

    symbols = {
        symbol.strip().lstrip("_")
        for symbol in run("nm", "-arch", "arm64", "-j", str(executable)).splitlines()
        if symbol.strip()
    }
    missing = ({IDENTITY_SYMBOL} | FFI_IDENTITY_SYMBOLS) - symbols
    if missing:
        raise ValueError("iOS executable is missing linked Rust identity symbols: " + ", ".join(sorted(missing)))

    section = parse_identity_section(run("otool", "-arch", "arm64", "-s", "__TEXT", "__obb_core_id", str(executable)))
    observed = parse_observed_identity(section)
    if observed != candidate:
        differing = sorted(field for field in required if observed.get(field) != candidate.get(field))
        raise ValueError("loaded iOS Rust slice identity differs from protected candidate: " + ", ".join(differing))

    result = {
        "schemaVersion": 1,
        "verificationKind": "ios-loaded-rust-slice-identity",
        "bundleId": plist.get("CFBundleIdentifier"),
        "version": plist.get("CFBundleShortVersionString"),
        "buildNumber": plist.get("CFBundleVersion"),
        "executable": executable.name,
        "architectures": architectures,
        "executableSha256": sha256(executable),
        "identitySectionSha256": sha256_bytes(section),
        "identitySymbols": sorted({IDENTITY_SYMBOL} | FFI_IDENTITY_SYMBOLS),
        "candidate": candidate,
        "observed": observed,
    }
    output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--candidate", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        verify(args.app, args.candidate, args.output)
    except (
        OSError,
        ValueError,
        KeyError,
        json.JSONDecodeError,
        plistlib.InvalidFileException,
        subprocess.SubprocessError,
    ) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
