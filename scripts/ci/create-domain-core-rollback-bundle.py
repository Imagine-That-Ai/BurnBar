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
BASE_ENTRIES = (
    "manifest.json",
    "domain-core-public-production-rollback.json",
    "rollback.env",
    "rollback-payloads.json",
    "legacy-source.tar.gz",
)
ROLLBACK_CONSUMERS = {
    "apple": ("apple-rollback-settings", "macos-arm64"),
    "ios": ("ios-rollback-settings", "ios-universal"),
    "linux": ("linux-rollback-settings", "linux-x64-arm64"),
    "android": ("android-rollback-settings", "android-universal"),
    "windows": ("windows-rollback-settings", "windows-x64-arm64"),
    "console": ("console-rollback-settings", "firebase-hosting-production"),
    "functions": ("functions-rollback-settings", "firebase-functions-production"),
}
SHA256 = re.compile(r"^[0-9a-f]{64}$")
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


def canonical_sha256(value: Any) -> str:
    return hashlib.sha256(
        json.dumps(value, separators=(",", ":"), sort_keys=True, ensure_ascii=True).encode()
    ).hexdigest()


def rollback_payloads(
    *,
    candidate: dict[str, Any],
    activation: dict[str, Any],
    profile: dict[str, Any],
    version: str,
    tag: str,
    commit: str,
) -> tuple[dict[str, Any], list[tuple[str, bytes]]]:
    profile_identity = {
        "name": "public-production-rollback",
        "sha256": canonical_sha256(profile),
    }
    release = {"version": version, "tag": tag, "commit": commit}
    environment = rollback_environment(profile).decode("ascii").splitlines()
    payload_records: list[dict[str, Any]] = []
    retained: list[tuple[str, bytes]] = []
    for consumer, (artifact_kind, target) in ROLLBACK_CONSUMERS.items():
        payload_path = f"payloads/{consumer}/rollback-settings.json"
        provenance_path = f"payloads/{consumer}/provenance.json"
        payload = {
            "schemaVersion": 1,
            "action": "rebuild_and_redeploy_legacy",
            "consumer": consumer,
            "artifactKind": artifact_kind,
            "target": target,
            "candidate": candidate,
            "activation": activation,
            "profile": profile_identity,
            "release": release,
            "environment": environment,
        }
        payload_bytes = canonical(payload)
        provenance = {
            "schemaVersion": 1,
            "predicateType": "https://openburnbar.dev/attestations/domain-core-rollback-settings/v1",
            "consumer": consumer,
            "subject": {
                "path": payload_path,
                "sha256": hashlib.sha256(payload_bytes).hexdigest(),
                "size": len(payload_bytes),
            },
            "candidate": candidate,
            "profile": profile_identity,
            "release": release,
        }
        provenance_bytes = canonical(provenance)
        payload_records.append(
            {
                "consumer": consumer,
                "artifactKind": artifact_kind,
                "target": target,
                "payloadPath": payload_path,
                "payloadSha256": hashlib.sha256(payload_bytes).hexdigest(),
                "size": len(payload_bytes),
                "provenancePath": provenance_path,
                "provenanceSha256": hashlib.sha256(provenance_bytes).hexdigest(),
            }
        )
        retained.extend(((payload_path, payload_bytes), (provenance_path, provenance_bytes)))
    manifest = {
        "schemaVersion": 1,
        "candidate": candidate,
        "profile": profile_identity,
        "payloads": payload_records,
    }
    return manifest, retained


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
        **{f"OPENBURNBAR_DOMAIN_CORE_{DOMAIN_ENV_KEYS[domain]}_MODE": mode for domain, mode in modes.items()},
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
    if any(
        activation.get(key) != candidate.get(key)
        for key in ("candidateCommit", "coreVersion", "abiVersion", "sourceSha256")
    ):
        raise ValueError("rollback profile candidate and activation closure disagree")
    if version != candidate.get("coreVersion"):
        raise ValueError("rollback release version does not match the candidate core version")
    profile_release = profile.get("release")
    if (
        not isinstance(profile_release, dict)
        or profile_release.get("version") != version
        or profile_release.get("tag") != tag
        or profile_release.get("commit") != commit
    ):
        raise ValueError("rollback profile release coordinates do not match the exact release P")
    if not isinstance(profile_release.get("commit"), str) or not SHA.fullmatch(profile_release["commit"]):
        raise ValueError("rollback profile release commit must be a full lowercase Git SHA-1")
    if profile_release["commit"] == candidate.get("candidateCommit"):
        raise ValueError("rollback profile release commit must be distinct from the candidate commit")
    payload_manifest, payload_entries = rollback_payloads(
        candidate=candidate,
        activation=activation,
        profile=profile,
        version=version,
        tag=tag,
        commit=commit,
    )
    if not source_archive.is_file() or source_archive.is_symlink():
        raise ValueError("rollback source archive must be a safe regular file")
    source_bytes = source_archive.read_bytes()
    if len(source_bytes) < 128:
        raise ValueError("rollback source archive is empty or implausibly small")
    if hashlib.sha256(source_bytes).hexdigest() != candidate.get("sourceSha256"):
        raise ValueError("rollback source archive digest does not match the candidate source SHA-256")
    environment = rollback_environment(profile)
    manifest = {
        "schemaVersion": 1,
        "artifactKind": "legacy-rollback-bundle",
        "target": "all-supported-consumers",
        "candidate": candidate,
        "activation": activation,
        "release": {"version": version, "tag": tag, "commit": commit},
        "retentionPolicy": "retain_until_legacy_deletion_complete",
        "contents": list(BASE_ENTRIES) + [name for name, _ in payload_entries],
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
            "payloadInventory": {
                "path": "rollback-payloads.json",
                "sha256": canonical_sha256(payload_manifest),
                "consumers": list(ROLLBACK_CONSUMERS),
            },
        },
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_STORED, strict_timestamps=True) as archive:
        for name, contents in (
            (BASE_ENTRIES[0], canonical(manifest)),
            (BASE_ENTRIES[1], canonical(profile)),
            (BASE_ENTRIES[2], environment),
            (BASE_ENTRIES[3], canonical(payload_manifest)),
            (BASE_ENTRIES[4], source_bytes),
            *payload_entries,
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
