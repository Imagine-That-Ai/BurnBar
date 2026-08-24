#!/usr/bin/env python3
"""Create the canonical deterministic legacy rollback release ZIP."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import re
import stat
import subprocess
import sys
import tarfile
import zipfile
from pathlib import Path
from pathlib import PurePosixPath
from typing import Any

SCRIPT_DIRECTORY = str(Path(__file__).resolve().parent)
if SCRIPT_DIRECTORY not in sys.path:
    # Tests load this script directly with importlib, outside its package path.
    sys.path.insert(0, SCRIPT_DIRECTORY)

from domain_core_source_fingerprint import source_fingerprint  # noqa: E402


SHA = re.compile(r"^[0-9a-f]{40}$")
VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:\+[0-9A-Za-z.-]+)?$")
# Keep this aligned with the candidate bundle schema so prerelease and
# build-qualified domain-core versions remain valid release inputs.
CORE_VERSION = re.compile(
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"
)
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
DOMAIN_CORE_ROOT = PurePosixPath("crates/openburnbar-domain-core")


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


def normalized_archive_path(name: str) -> PurePosixPath:
    if not name or "\\" in name:
        raise ValueError(f"rollback source archive contains an unsafe path: {name!r}")
    path = PurePosixPath(name)
    if (
        path.is_absolute()
        or name != path.as_posix()
        or any(part in ("", ".", "..") for part in path.parts)
    ):
        raise ValueError(f"rollback source archive contains an unsafe path: {name!r}")
    return path


def verify_source_archive(
    source_bytes: bytes,
    *,
    candidate: dict[str, Any],
    version: str,
    expected_source_bytes: bytes,
) -> None:
    expected_root = PurePosixPath(f"OpenBurnBar-{version}-legacy-source")
    domain_core_files: dict[str, bytes] = {}
    domain_core_directories: set[str] = set()
    seen: set[str] = set()
    try:
        with tarfile.open(fileobj=io.BytesIO(source_bytes), mode="r:gz") as archive:
            if archive.pax_headers.get("comment") != candidate["candidateCommit"]:
                raise ValueError(
                    "rollback source archive does not bind the candidate commit"
                )
            for member in archive:
                path = normalized_archive_path(member.name)
                if path != expected_root and expected_root not in path.parents:
                    raise ValueError(
                        "rollback source archive does not use the exact release prefix"
                    )
                if member.name in seen:
                    raise ValueError(
                        f"rollback source archive contains a duplicate path: {member.name}"
                    )
                seen.add(member.name)
                if member.pax_headers.get("comment") != candidate["candidateCommit"]:
                    raise ValueError(
                        "rollback source archive member does not bind the candidate commit"
                    )
                if not member.isdir() and not member.isfile():
                    raise ValueError(
                        f"rollback source archive contains a linked or special entry: {member.name}"
                    )
                if path == expected_root:
                    continue
                repository_path = PurePosixPath(*path.parts[1:])
                if (
                    repository_path == DOMAIN_CORE_ROOT
                    or DOMAIN_CORE_ROOT not in repository_path.parents
                ):
                    continue
                crate_path = repository_path.relative_to(DOMAIN_CORE_ROOT).as_posix()
                if member.isdir():
                    domain_core_directories.add(crate_path)
                    continue
                extracted = archive.extractfile(member)
                if extracted is None:
                    raise ValueError(
                        f"rollback source archive cannot read regular file: {member.name}"
                    )
                domain_core_files[crate_path] = extracted.read()
    except (tarfile.TarError, EOFError, OSError) as error:
        raise ValueError(f"rollback source archive is not a valid tar.gz: {error}") from error

    manifest_bytes = domain_core_files.get("union-abi-manifest.json")
    if manifest_bytes is None:
        raise ValueError("rollback source archive omits the union ABI manifest")
    try:
        manifest = json.loads(manifest_bytes)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError("rollback source archive has an invalid union ABI manifest") from error
    if not isinstance(manifest, dict) or manifest.get("schemaVersion") != 1:
        raise ValueError("rollback source archive has an invalid union ABI manifest")
    if (
        manifest.get("coreVersion") != candidate["coreVersion"]
        or manifest.get("abiVersion") != candidate["abiVersion"]
        or manifest.get("sourceSha256") != candidate["sourceSha256"]
    ):
        raise ValueError(
            "rollback source archive union ABI identity does not match the candidate"
        )
    roots = manifest.get("sourceRoots")
    if not isinstance(roots, list) or not roots:
        raise ValueError("rollback source archive union ABI sourceRoots are invalid")
    fingerprint_files: dict[str, bytes] = {}
    for raw_root in roots:
        if not isinstance(raw_root, str):
            raise ValueError("rollback source archive union ABI sourceRoots are invalid")
        root = normalized_archive_path(raw_root)
        root_name = root.as_posix()
        if root_name in domain_core_files:
            fingerprint_files[root_name] = domain_core_files[root_name]
            continue
        if root_name not in domain_core_directories:
            raise ValueError(
                f"rollback source archive omits required source root: {root_name}"
            )
        prefix = f"{root_name}/"
        for path, contents in domain_core_files.items():
            if not path.startswith(prefix):
                continue
            descendant = PurePosixPath(path).relative_to(root)
            if "target" in descendant.parts[:-1]:
                continue
            fingerprint_files[path] = contents
    if not fingerprint_files:
        raise ValueError("rollback source archive sourceRoots resolve to no files")
    if source_fingerprint(fingerprint_files) != candidate["sourceSha256"]:
        raise ValueError(
            "rollback source archive domain-core fingerprint does not match the candidate"
        )
    if source_bytes != expected_source_bytes:
        raise ValueError(
            "rollback source archive is not the exact complete candidate git archive"
        )


def candidate_git_archive(
    repository_root: Path,
    *,
    candidate_commit: str,
    version: str,
) -> bytes:
    if not repository_root.is_dir() or repository_root.is_symlink():
        raise ValueError("rollback repository root must be a safe directory")
    result = subprocess.run(
        [
            "git",
            "-C",
            str(repository_root),
            "archive",
            "--format=tar.gz",
            f"--prefix=OpenBurnBar-{version}-legacy-source/",
            candidate_commit,
        ],
        check=False,
        capture_output=True,
    )
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise ValueError(
            f"cannot regenerate exact candidate git archive: {detail}"
        )
    if len(result.stdout) < 128:
        raise ValueError("regenerated candidate git archive is empty or implausibly small")
    return result.stdout


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
    repository_root: Path = Path("."),
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
    if not isinstance(candidate, dict):
        raise ValueError("rollback profile must bind candidate C")
    candidate_commit = candidate.get("candidateCommit")
    if not isinstance(candidate_commit, str) or not SHA.fullmatch(candidate_commit):
        raise ValueError(
            "rollback candidate commit must be a full lowercase Git SHA-1"
        )
    activation = load(activation_path, "activation closure")
    required = {
        "candidateCommit",
        "activationCommit",
        "coreVersion",
        "abiVersion",
        "sourceSha256",
        "changedPathsSha256",
    }
    if set(activation) != required:
        raise ValueError("rollback activation closure keys are not canonical")
    # activationCommit is the activation authority P, re-derived from the
    # committed authority files. It is deliberately NOT the release commit R:
    # scripts/lib/domain-core-activation.mjs states that "a release commit R is
    # release-authoritative but is not itself the activation authority once
    # path-disjoint protected-main commits land after P".
    #
    # Requiring activationCommit == commit made this function unsatisfiable.
    # When domain-core is inactive the resolver returns
    # activationCommit == candidateCommit, while the check below already
    # requires the release commit to be DISTINCT from candidateCommit — the two
    # assertions cannot both hold. Every release reached this step and failed.
    #
    # Bind the format here; the caller asserts P..R ancestry with git, next to
    # the merge-base check it already performs for the candidate.
    if not SHA.fullmatch(activation["activationCommit"]):
        raise ValueError("rollback activation commit must be a full lowercase Git SHA-1")
    if any(
        activation.get(key) != candidate.get(key)
        for key in ("candidateCommit", "coreVersion", "abiVersion", "sourceSha256")
    ):
        raise ValueError("rollback profile candidate and activation closure disagree")
    if (
        not isinstance(candidate.get("coreVersion"), str)
        or not CORE_VERSION.fullmatch(candidate["coreVersion"])
    ):
        raise ValueError("rollback candidate core version is invalid")
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
    if profile_release["commit"] == candidate_commit:
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
    expected_source_bytes = candidate_git_archive(
        repository_root,
        candidate_commit=candidate_commit,
        version=version,
    )
    verify_source_archive(
        source_bytes,
        candidate=candidate,
        version=version,
        expected_source_bytes=expected_source_bytes,
    )
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
            "sourceCommit": candidate_commit,
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
    parser.add_argument("--repository-root", type=Path, default=Path("."))
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
            repository_root=args.repository_root,
        )
    except (OSError, ValueError, json.JSONDecodeError) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
