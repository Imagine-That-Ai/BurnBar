#!/usr/bin/env python3
"""Validate BurnBar CloudVault at-rest runtime evidence.

This release artifact is intentionally aggregate/proof-only. It records which
CloudVault at-rest checks passed without embedding user plaintext, document IDs,
keys, ciphertext, wrapped content keys, or other secret material.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


PRIVACY_MARKER = "proof_only_no_plaintext_keys_ciphertext_or_document_identifiers"
REQUIRED_PROOFS = {
    "signal_envelope_contracts": {
        "packages/signal-envelope-contracts/lib/index.test.js",
        "packages/signal-envelope-contracts/lib/cloudVaultSignalEnvelope.test.js",
        "packages/signal-envelope-contracts/fixtures/binding-aad-vectors.json",
    },
    "libsignal_at_rest_roundtrip": {
        "packages/libsignal-protocol/lib/index.test.js",
    },
    "functions_admin_write_guard": {
        "scripts/ci/check_functions_cloudvault_runtime.js",
        "functions/lib/signalAtRestWrite.js",
        "functions/lib/__tests__/signalAtRestWrite.test.js",
        "tests/test_signal_envelope_contracts_cjs_exports.py",
    },
    "privacy_backfill_guard": {
        "scripts/ci/check_functions_cloudvault_runtime.js",
        "functions/lib/callables/privacyBackfill.js",
        "functions/lib/__tests__/privacyBackfill.test.js",
    },
}
REQUIRED_COMMAND_FRAGMENTS = {
    "signal_envelope_contracts": (
        "node --test",
        "packages/signal-envelope-contracts/lib/index.test.js",
        "packages/signal-envelope-contracts/lib/cloudVaultSignalEnvelope.test.js",
    ),
    "libsignal_at_rest_roundtrip": (
        "node --test",
        "packages/libsignal-protocol/lib/index.test.js",
    ),
    "functions_admin_write_guard": (
        "node scripts/ci/check_functions_cloudvault_runtime.js",
        "--signal-at-rest-write",
        "python3 -m pytest",
        "tests/test_signal_envelope_contracts_cjs_exports.py",
    ),
    "privacy_backfill_guard": (
        "node scripts/ci/check_functions_cloudvault_runtime.js",
        "--privacy-backfill",
    ),
}
TOP_LEVEL_KEYS = {"schemaVersion", "generatedAt", "privacy", "runtime", "proofs"}
PROOF_KEYS = {"status", "command", "artifactPaths", "notes"}
SENSITIVE_KEYS = {
    "plaintext",
    "payloadCiphertextB64",
    "recipientIdentityKeyB64",
    "sealedContentKeyB64",
    "decryptedContentKey",
    "privateKey",
    "privateKeyData",
    "wrappedKey",
    "documentId",
    "docId",
    "uid",
    "userId",
    "rootPath",
    "sourceSlug",
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
                errors.append(f"{_path((*path, key))} must not be embedded in proof evidence")
            errors.extend(_sensitive_key_errors(child, (*path, str(key))))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            errors.extend(_sensitive_key_errors(child, (*path, str(index))))
    return errors


def validate_cloudvault_at_rest_evidence(data: Any, *, repo_root: Path | None = None) -> list[str]:
    errors: list[str] = []
    if not isinstance(data, dict):
        return ["evidence root must be a JSON object"]

    errors.extend(_sensitive_key_errors(data))
    errors.extend(_unexpected_keys(data, TOP_LEVEL_KEYS, ()))
    if data.get("schemaVersion") != 1:
        errors.append(f"schemaVersion must be 1, found {data.get('schemaVersion')!r}")
    if data.get("privacy") != PRIVACY_MARKER:
        errors.append(f"privacy must be {PRIVACY_MARKER!r}")
    if data.get("runtime") != "cloudvault_at_rest":
        errors.append("runtime must be 'cloudvault_at_rest'")
    if not isinstance(data.get("generatedAt"), str) or not data.get("generatedAt", "").strip():
        errors.append("generatedAt must be a non-empty string")

    proofs = data.get("proofs")
    if not isinstance(proofs, dict):
        errors.append("proofs must be an object")
        return errors
    errors.extend(_unexpected_keys(proofs, set(REQUIRED_PROOFS), ("proofs",)))

    missing = sorted(set(REQUIRED_PROOFS).difference(proofs))
    if missing:
        errors.append("proofs missing required proof(s): " + ", ".join(missing))

    for proof_id, required_paths in sorted(REQUIRED_PROOFS.items()):
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
                fragment for fragment in REQUIRED_COMMAND_FRAGMENTS[proof_id] if fragment not in command
            ]
            if missing_fragments:
                errors.append(
                    f"{_path((*proof_path, 'command'))} missing required command fragment(s): "
                    + ", ".join(missing_fragments)
                )
        artifact_paths, path_errors = _string_list(
            proof.get("artifactPaths"), f"{_path((*proof_path, 'artifactPaths'))}"
        )
        errors.extend(path_errors)
        missing_paths = sorted(required_paths.difference(artifact_paths))
        if missing_paths:
            errors.append(
                f"{_path((*proof_path, 'artifactPaths'))} missing required path(s): " + ", ".join(missing_paths)
            )
        if repo_root is not None:
            for rel_path in artifact_paths:
                if not (repo_root / rel_path).is_file():
                    errors.append(f"{_path((*proof_path, 'artifactPaths'))} path does not exist: {rel_path}")
        notes = proof.get("notes")
        if notes is not None and not isinstance(notes, str):
            errors.append(f"{_path((*proof_path, 'notes'))} must be a string when present")

    return errors


def load_cloudvault_at_rest_evidence(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def check_cloudvault_at_rest_evidence(path: Path, *, repo_root: Path | None = None) -> list[str]:
    if not path.is_file():
        return [f"CloudVault at-rest evidence file is missing: {path}"]
    try:
        data = load_cloudvault_at_rest_evidence(path)
    except json.JSONDecodeError as exc:
        return [f"CloudVault at-rest evidence is not valid JSON: {exc}"]
    return validate_cloudvault_at_rest_evidence(data, repo_root=repo_root)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path, help="CloudVault at-rest runtime JSON evidence")
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path.cwd(),
        help="Repo root used to verify referenced artifact paths exist",
    )
    args = parser.parse_args(argv)

    errors = check_cloudvault_at_rest_evidence(args.path, repo_root=args.repo_root)
    if errors:
        print("FAIL: BurnBar CloudVault at-rest runtime evidence is invalid", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print(f"PASS: BurnBar CloudVault at-rest runtime evidence is valid: {args.path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
