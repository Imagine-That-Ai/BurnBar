#!/usr/bin/env python3
"""Validate BurnBar native Signal runtime evidence.

The Swift and Android runtime-readiness gates must not be completed by pointing
at an arbitrary source file. They require proof-only JSON evidence that names the
native build/test command and the exact source/test artifacts that prove the
Signal/libsignal runtime is wired on that platform.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


PRIVACY_MARKER = "proof_only_no_plaintext_keys_or_user_data"
TOP_LEVEL_KEYS = {"schemaVersion", "generatedAt", "privacy", "runtime", "platform", "proofs"}
PROOF_KEYS = {"status", "command", "artifactPaths", "notes"}
ANDROID_GRADLE_PROJECT_PATHS = {
    "android/gradlew",
    "android/gradle/wrapper/gradle-wrapper.properties",
}
ANDROID_GRADLE_PROJECT_PATH_GROUPS = (
    ("android/settings.gradle", "android/settings.gradle.kts"),
    ("android/build.gradle", "android/build.gradle.kts"),
    ("android/app/build.gradle", "android/app/build.gradle.kts"),
)
SENSITIVE_KEYS = {
    "plaintext",
    "payloadCiphertextB64",
    "recipientIdentityKeyB64",
    "sealedContentKeyB64",
    "decryptedContentKey",
    "privateKey",
    "privateKeyData",
    "identityPrivateKey",
    "signedPreKeyRecord",
    "oneTimePreKeyRecords",
    "kyberPreKeyRecords",
    "sessionState",
    "ratchetState",
    "uid",
    "userId",
    "deviceId",
    "docId",
    "documentId",
}

PLATFORM_REQUIREMENTS = {
    "swift": {
        "runtime": "swift_signal_runtime",
        "proofs": {
            "native_build_tests": {
                "OpenBurnBarCore/Package.swift",
                "OpenBurnBarCore/Tests/OpenBurnBarSignalCoreTests/SignalPrekeyPublicationTests.swift",
            },
            "native_build_tests_command": (
                "swift test",
                "--package-path OpenBurnBarCore",
                "--disable-swift-testing",
                "OpenBurnBarSignalCoreTests",
            ),
            "libsignal_prekey_publication": {
                "OpenBurnBarCore/Sources/OpenBurnBarSignalCore/SignalPrekeyPublication.swift",
                "OpenBurnBarCore/Sources/OpenBurnBarSignalCore/SignalPrekeyPublicationStore.swift",
                "OpenBurnBarCore/Tests/OpenBurnBarSignalCoreTests/SignalPrekeyPublicationTests.swift",
            },
            "libsignal_prekey_publication_command": (
                "swift test",
                "--package-path OpenBurnBarCore",
                "--disable-swift-testing",
                "SignalPrekeyPublicationTests",
            ),
            "secret_state_local_only": {
                "OpenBurnBarCore/Tests/OpenBurnBarSignalCoreTests/SignalPrekeyPublicationTests.swift",
            },
            "secret_state_local_only_command": (
                "swift test",
                "--package-path OpenBurnBarCore",
                "--disable-swift-testing",
                "SignalPrekeyPublicationTests",
            ),
            "binding_aad_vectors": {
                "OpenBurnBarCore/Package.swift",
                "OpenBurnBarCore/Sources/OpenBurnBarSignalCore/SignalEnvelopeAAD.swift",
                "OpenBurnBarCore/Tests/OpenBurnBarSignalCoreTests/SignalEnvelopeAADTests.swift",
                "packages/signal-envelope-contracts/fixtures/binding-aad-vectors.json",
            },
            "binding_aad_vectors_command": (
                "swift test",
                "--package-path OpenBurnBarCore",
                "--disable-swift-testing",
                "SignalEnvelopeAADTests",
            ),
        },
    },
    "kotlin_android": {
        "runtime": "kotlin_android_signal_runtime",
        "proofs": {
            "native_build_tests": {
                *ANDROID_GRADLE_PROJECT_PATHS,
                "android/app/src/test/java/com/openburnbar/data/cloud/AndroidCloudVaultSignalPayloadsTest.kt",
                "android/app/src/test/java/com/openburnbar/data/cloud/AndroidSignalPrekeyDirectoryTest.kt",
            },
            "native_build_tests_path_groups": ANDROID_GRADLE_PROJECT_PATH_GROUPS,
            "native_build_tests_command": (
                "./gradlew",
                ":app:testDebugUnitTest",
            ),
            "libsignal_prekey_publication": {
                "android/app/src/main/java/com/openburnbar/data/cloud/AndroidSignalPrekeyDirectory.kt",
                "android/app/src/test/java/com/openburnbar/data/cloud/AndroidSignalPrekeyDirectoryTest.kt",
            },
            "libsignal_prekey_publication_command": (
                "./gradlew",
                ":app:testDebugUnitTest",
                "AndroidSignalPrekeyDirectoryTest",
            ),
            "cloudvault_signal_binding": {
                "android/app/src/main/java/com/openburnbar/data/cloud/AndroidCloudVaultSignalPayloads.kt",
                "android/app/src/test/java/com/openburnbar/data/cloud/AndroidCloudVaultSignalPayloadsTest.kt",
            },
            "cloudvault_signal_binding_command": (
                "./gradlew",
                ":app:testDebugUnitTest",
                "AndroidCloudVaultSignalPayloadsTest",
            ),
            "binding_aad_vectors": {
                "android/app/src/test/java/com/openburnbar/data/cloud/AndroidCloudVaultSignalPayloadsTest.kt",
                "packages/signal-envelope-contracts/fixtures/binding-aad-vectors.json",
            },
            "binding_aad_vectors_command": (
                "./gradlew",
                ":app:testDebugUnitTest",
                "AndroidCloudVaultSignalPayloadsTest",
            ),
        },
    },
}


def _path(path: tuple[str, ...]) -> str:
    return ".".join(path) if path else "root"


def _unexpected_keys(value: dict[str, Any], allowed: set[str], path: tuple[str, ...]) -> list[str]:
    return [f"{_path(path)} has unexpected key: {key}" for key in sorted(set(value).difference(allowed))]


def _string_list(value: Any, path: str) -> tuple[list[str], list[str]]:
    if not isinstance(value, list):
        return [], [f"{path} must be a list"]
    items: list[str] = []
    errors: list[str] = []
    for index, item in enumerate(value):
        if not isinstance(item, str) or not item.strip():
            errors.append(f"{path}[{index}] must be a non-empty string")
        elif Path(item).is_absolute() or ".." in Path(item).parts:
            errors.append(f"{path}[{index}] must be a repo-relative path")
        else:
            items.append(item)
    return items, errors


def _sensitive_key_errors(value: Any, path: tuple[str, ...] = ()) -> list[str]:
    errors: list[str] = []
    if isinstance(value, dict):
        for key, child in value.items():
            if isinstance(key, str) and key in SENSITIVE_KEYS:
                errors.append(f"{_path((*path, key))} must not be embedded in native runtime proof evidence")
            errors.extend(_sensitive_key_errors(child, (*path, str(key))))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            errors.extend(_sensitive_key_errors(child, (*path, str(index))))
    return errors


def validate_native_signal_runtime_evidence(
    data: Any,
    *,
    platform: str | None = None,
    repo_root: Path | None = None,
) -> list[str]:
    errors: list[str] = []
    if not isinstance(data, dict):
        return ["evidence root must be a JSON object"]

    errors.extend(_sensitive_key_errors(data))
    errors.extend(_unexpected_keys(data, TOP_LEVEL_KEYS, ()))
    if data.get("schemaVersion") != 1:
        errors.append(f"schemaVersion must be 1, found {data.get('schemaVersion')!r}")
    if data.get("privacy") != PRIVACY_MARKER:
        errors.append(f"privacy must be {PRIVACY_MARKER!r}")
    if not isinstance(data.get("generatedAt"), str) or not data.get("generatedAt", "").strip():
        errors.append("generatedAt must be a non-empty string")

    evidence_platform = data.get("platform")
    if evidence_platform not in PLATFORM_REQUIREMENTS:
        errors.append(f"platform must be one of {sorted(PLATFORM_REQUIREMENTS)}, found {evidence_platform!r}")
        return errors
    if platform is not None and evidence_platform != platform:
        errors.append(f"platform must be {platform!r}, found {evidence_platform!r}")

    requirements = PLATFORM_REQUIREMENTS[evidence_platform]
    if data.get("runtime") != requirements["runtime"]:
        errors.append(f"runtime must be {requirements['runtime']!r}")

    proofs = data.get("proofs")
    if not isinstance(proofs, dict):
        errors.append("proofs must be an object")
        return errors

    required_proofs = {
        proof_id: value
        for proof_id, value in requirements["proofs"].items()
        if not proof_id.endswith("_command") and not proof_id.endswith("_path_groups")
    }
    errors.extend(_unexpected_keys(proofs, set(required_proofs), ("proofs",)))
    missing = sorted(set(required_proofs).difference(proofs))
    if missing:
        errors.append("proofs missing required proof(s): " + ", ".join(missing))

    for proof_id, required_paths in sorted(required_proofs.items()):
        if proof_id not in proofs:
            continue
        proof = proofs[proof_id]
        proof_path = ("proofs", proof_id)
        if not isinstance(proof, dict):
            errors.append(f"{_path(proof_path)} must be an object")
            continue
        errors.extend(_unexpected_keys(proof, PROOF_KEYS, proof_path))
        if proof.get("status") != "passed":
            errors.append(f"{_path((*proof_path, 'status'))} must be 'passed'")
        command = proof.get("command")
        if not isinstance(command, str) or not command.strip():
            errors.append(f"{_path((*proof_path, 'command'))} must be a non-empty string")
        else:
            missing_fragments = [
                fragment for fragment in requirements["proofs"][f"{proof_id}_command"] if fragment not in command
            ]
            if missing_fragments:
                errors.append(
                    f"{_path((*proof_path, 'command'))} missing required command fragment(s): "
                    + ", ".join(missing_fragments)
                )
        artifact_paths, path_errors = _string_list(proof.get("artifactPaths"), f"{_path((*proof_path, 'artifactPaths'))}")
        errors.extend(path_errors)
        missing_paths = sorted(required_paths.difference(artifact_paths))
        if missing_paths:
            errors.append(f"{_path((*proof_path, 'artifactPaths'))} missing required path(s): " + ", ".join(missing_paths))
        for path_group in requirements["proofs"].get(f"{proof_id}_path_groups", ()):
            if not any(path in artifact_paths for path in path_group):
                errors.append(
                    f"{_path((*proof_path, 'artifactPaths'))} missing required path group: "
                    + "one of "
                    + ", ".join(path_group)
                )
        if repo_root is not None:
            for rel_path in artifact_paths:
                if not (repo_root / rel_path).is_file():
                    errors.append(f"{_path((*proof_path, 'artifactPaths'))} path does not exist: {rel_path}")
        notes = proof.get("notes")
        if notes is not None and not isinstance(notes, str):
            errors.append(f"{_path((*proof_path, 'notes'))} must be a string when present")

    return errors


def load_native_signal_runtime_evidence(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def check_native_signal_runtime_evidence(
    path: Path,
    *,
    platform: str | None = None,
    repo_root: Path | None = None,
) -> list[str]:
    if not path.is_file():
        return [f"native Signal runtime evidence file is missing: {path}"]
    try:
        data = load_native_signal_runtime_evidence(path)
    except json.JSONDecodeError as exc:
        return [f"native Signal runtime evidence is not valid JSON: {exc}"]
    return validate_native_signal_runtime_evidence(data, platform=platform, repo_root=repo_root)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path, help="Native Signal runtime JSON evidence")
    parser.add_argument("--platform", choices=sorted(PLATFORM_REQUIREMENTS), help="Expected native platform")
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path.cwd(),
        help="Repo root used to verify referenced artifact paths exist",
    )
    args = parser.parse_args(argv)

    errors = check_native_signal_runtime_evidence(args.path, platform=args.platform, repo_root=args.repo_root)
    if errors:
        print("FAIL: BurnBar native Signal runtime evidence is invalid", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    platform = f" ({args.platform})" if args.platform else ""
    print(f"PASS: BurnBar native Signal runtime evidence is valid{platform}: {args.path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
