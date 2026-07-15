#!/usr/bin/env python3
"""Create the canonical deterministic legacy rollback release ZIP."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import stat
import zipfile
from pathlib import Path
from typing import Any


SHA = re.compile(r"^[0-9a-f]{40}$")
VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:\+[0-9A-Za-z.-]+)?$")
ENTRIES = (
    "manifest.json",
    "domain-core-public-production-rollback.json",
    "rollback.env",
    "legacy-source.tar.gz",
)
DOMAIN_ENV_KEYS = {
    "quota": "QUOTA",
    "cloudVault": "CLOUDVAULT",
    "cloudVaultRewrap": "CLOUDVAULT_REWRAP",
    "cloudVaultSearch": "CLOUDVAULT_SEARCH",
    "hermes": "HERMES",
    "pricing": "PRICING",
}


def load(path: Path, label: str) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"{label} must be a JSON object")
    return value


def canonical(value: dict[str, Any]) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True, ensure_ascii=True) + "\n").encode()


def rollback_environment(profile: dict[str, Any]) -> bytes:
    candidate = profile["candidateIdentity"]
    modes = profile["modes"]
    values = {
        "OPENBURNBAR_DOMAIN_CORE_BUILD_PROFILE": "public-production-rollback",
        "OPENBURNBAR_DOMAIN_CORE_BUILD_AUTHORITY": "signed",
        "OPENBURNBAR_DOMAIN_CORE_DISTRIBUTION": "public",
        "OPENBURNBAR_DOMAIN_CORE_EVIDENCE_ENABLED": "0",
        "OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT": candidate["candidateCommit"],
        "OPENBURNBAR_DOMAIN_CORE_EXPECTED_VERSION": candidate["coreVersion"],
        "OPENBURNBAR_DOMAIN_CORE_EXPECTED_ABI_VERSION": str(candidate["abiVersion"]),
        "OPENBURNBAR_DOMAIN_CORE_EXPECTED_SOURCE_SHA256": candidate["sourceSha256"],
        **{
            f"OPENBURNBAR_DOMAIN_CORE_{DOMAIN_ENV_KEYS[domain]}_MODE": mode
            for domain, mode in modes.items()
        },
    }
    return "".join(f"{key}={values[key]}\n" for key in sorted(values)).encode("ascii")


def create_bundle(
    profile_path: Path,
    activation_path: Path,
    output: Path,
    source_archive: Path,
    *,
    version: str,
    tag: str,
    commit: str,
) -> dict[str, Any]:
    if not VERSION.fullmatch(version) or tag != f"v{version}" or not SHA.fullmatch(commit):
        raise ValueError("rollback release coordinates are invalid")
    profile = load(profile_path, "rollback profile")
    if (
        profile.get("schemaVersion") != 1
        or profile.get("name") != "public-production-rollback"
        or profile.get("artifactAuthority") != "signed"
        or profile.get("distribution") != "public"
        or profile.get("rolloutChannel") is not None
        or profile.get("evidenceEnabled") is not False
    ):
        raise ValueError("rollback profile identity is not canonical")
    modes = profile.get("modes")
    if (
        not isinstance(modes, dict)
        or set(modes) != set(DOMAIN_ENV_KEYS)
        or any(mode != "legacy" for mode in modes.values())
    ):
        raise ValueError("rollback profile must restore every declared domain to legacy")
    candidate = profile.get("candidateIdentity")
    if not isinstance(candidate, dict) or candidate.get("candidateCommit") is None:
        raise ValueError("rollback profile must bind candidate C")
    activation = load(activation_path, "activation closure")
    required = {
        "candidateCommit",
        "activationCommit",
        "coreVersion",
        "abiVersion",
        "sourceSha256",
        "changedPathsSha256",
    }
    if set(activation) != required or activation["activationCommit"] != commit:
        raise ValueError("rollback activation must bind exact release commit P")
    if any(activation.get(key) != candidate.get(key) for key in ("candidateCommit", "coreVersion", "abiVersion", "sourceSha256")):
        raise ValueError("rollback profile candidate and activation closure disagree")
    if not source_archive.is_file() or source_archive.is_symlink():
        raise ValueError("rollback source archive must be a safe regular file")
    source_bytes = source_archive.read_bytes()
    if len(source_bytes) < 128:
        raise ValueError("rollback source archive is empty or implausibly small")
    environment = rollback_environment(profile)
    manifest = {
        "schemaVersion": 1,
        "artifactKind": "legacy-rollback-bundle",
        "target": "all-supported-consumers",
        "candidate": candidate,
        "activation": activation,
        "release": {"version": version, "tag": tag, "commit": commit},
        "retentionPolicy": "retain_until_legacy_deletion_complete",
        "contents": list(ENTRIES),
        "restoration": {
            "sourceCommit": candidate["candidateCommit"],
            "sourceArchive": {
                "path": "legacy-source.tar.gz",
                "sha256": hashlib.sha256(source_bytes).hexdigest(),
                "size": len(source_bytes),
            },
            "environment": {
                "path": "rollback.env",
                "sha256": hashlib.sha256(environment).hexdigest(),
                "allDomainModes": "legacy",
            },
        },
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_STORED, strict_timestamps=True) as archive:
        for name, contents in (
            (ENTRIES[0], canonical(manifest)),
            (ENTRIES[1], canonical(profile)),
            (ENTRIES[2], environment),
            (ENTRIES[3], source_bytes),
        ):
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.external_attr = (stat.S_IFREG | 0o600) << 16
            info.compress_type = zipfile.ZIP_STORED
            archive.writestr(info, contents)
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", required=True, type=Path)
    parser.add_argument("--activation", required=True, type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--source-archive", required=True, type=Path)
    args = parser.parse_args()
    try:
        create_bundle(
            args.profile,
            args.activation,
            args.output,
            args.source_archive,
            version=args.version,
            tag=args.tag,
            commit=args.commit,
        )
    except (OSError, ValueError, json.JSONDecodeError) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
