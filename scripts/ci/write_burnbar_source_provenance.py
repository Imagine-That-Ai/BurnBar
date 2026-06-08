#!/usr/bin/env python3
"""Generate and validate BurnBar corresponding-source provenance metadata."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OUTPUT = ROOT / "artifacts/source-provenance/burnbar-source-provenance.json"

REQUIRED_SOURCE_FILES = [
    "LICENSE",
    "THIRD_PARTY_NOTICES.md",
    "docs/legal/SOURCE_AVAILABILITY.md",
    "docs/legal/AGPL_RELEASE_REVIEW_PACKET.md",
    "docs/legal/HERMES_GATEWAY_SIGNAL_REQUIRED_ROLLOUT.md",
    "docs/legal/agpl-release-review.evidence.template.json",
    "third_party/libsignal/runtime-readiness.json",
    "Vendor/libsignal/LICENSE",
    "Vendor/libsignal/Cargo.toml",
    "Vendor/libsignal/node/package.json",
    "scripts/ci/check_libsignal_runtime_readiness.py",
    "scripts/ci/attach_libsignal_runtime_evidence.py",
    "scripts/ci/check_agpl_legal_release_review.py",
    "scripts/ci/check_burnbar_release_preflight.py",
    "scripts/ci/check_hermes_gateway_migration_drain.py",
    "scripts/ci/drain_hermes_gateway_legacy_records.js",
    "scripts/ci/restore_hermes_gateway_legacy_records.js",
    "scripts/ci/write_hermes_gateway_migration_drain_evidence.js",
    "scripts/ci/check_cloudvault_at_rest_runtime.py",
    "scripts/ci/check_functions_cloudvault_runtime.js",
    "scripts/ci/check_signal_envelope_contract_runtime.py",
    "scripts/ci/write_signal_envelope_contract_runtime_evidence.py",
    "scripts/ci/check_native_signal_runtime_evidence.py",
    "scripts/ci/run_android_signal_runtime_tests.py",
    "scripts/ci/write_native_signal_runtime_evidence.py",
    "scripts/ci/write_cloudvault_at_rest_runtime_evidence.py",
    "tests/test_agpl_legal_release_review.py",
    "tests/test_cloudvault_at_rest_runtime.py",
    "tests/test_cloudvault_at_rest_runtime_writer.py",
    "tests/test_burnbar_license_posture.py",
    "tests/test_hermes_gateway_legacy_drain.py",
    "tests/test_libsignal_runtime_evidence_attach.py",
    "tests/test_libsignal_runtime_readiness.py",
    "tests/test_native_signal_runtime_evidence.py",
    "tests/test_native_signal_runtime_evidence_writer.py",
    "tests/test_signal_envelope_contract_runtime.py",
    "tests/test_signal_envelope_contract_runtime_writer.py",
    "tests/test_signal_envelope_contracts_cjs_exports.py",
]


def run_git(args: list[str], *, repo_root: Path = ROOT, check: bool = True) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=repo_root,
        check=check,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return result.stdout.strip()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def required_file_entry(rel_path: str, *, repo_root: Path) -> dict[str, Any]:
    path = repo_root / rel_path
    if not path.is_file():
        raise FileNotFoundError(f"required corresponding-source file is missing: {rel_path}")
    return {
        "path": rel_path,
        "sha256": sha256_file(path),
        "bytes": path.stat().st_size,
    }


def load_runtime_readiness(repo_root: Path) -> dict[str, Any]:
    sys.path.insert(0, str(repo_root))
    try:
        from scripts.ci.check_libsignal_runtime_readiness import (
            DEFAULT_MANIFEST,
            check_manifest,
            incomplete_gate_details,
            load_manifest,
        )
    finally:
        sys.path.pop(0)
    errors = check_manifest(DEFAULT_MANIFEST, repo_root=repo_root)
    data = load_manifest(DEFAULT_MANIFEST, repo_root=repo_root)
    gates = data.get("gates", {})
    return {
        "status": data.get("status"),
        "completeGates": sorted(gate_id for gate_id, gate in gates.items() if gate.get("status") == "complete"),
        "incompleteGates": sorted(gate_id for gate_id, gate in gates.items() if gate.get("status") != "complete"),
        "incompleteGateDetails": incomplete_gate_details(data),
        "validatorErrors": errors,
    }


def build_source_provenance_manifest(*, repo_root: Path = ROOT) -> dict[str, Any]:
    dirty_paths = [line for line in run_git(["status", "--porcelain"], repo_root=repo_root).splitlines() if line]
    return {
        "schemaVersion": 1,
        "product": "BurnBar",
        "productLicense": "AGPL-3.0-only",
        "sourceAvailability": "docs/legal/SOURCE_AVAILABILITY.md",
        "git": {
            "head": run_git(["rev-parse", "HEAD"], repo_root=repo_root),
            "branch": run_git(["branch", "--show-current"], repo_root=repo_root, check=False),
            "dirty": bool(dirty_paths),
            "dirtyPaths": dirty_paths,
        },
        "runtimeReadiness": load_runtime_readiness(repo_root),
        "requiredSourceFiles": [required_file_entry(path, repo_root=repo_root) for path in REQUIRED_SOURCE_FILES],
        "excludedFromCorrespondingSource": [
            "private signing keys",
            "production secrets",
            "user data",
            "build caches",
        ],
    }


def release_preflight_blockers(manifest: dict[str, Any]) -> list[str]:
    blockers: list[str] = []
    if manifest.get("git", {}).get("dirty") is True:
        dirty = manifest.get("git", {}).get("dirtyPaths", [])
        blockers.append(f"git working tree must be clean for release provenance ({len(dirty)} dirty path(s))")
    readiness = manifest.get("runtimeReadiness", {})
    validator_errors = readiness.get("validatorErrors") or []
    if validator_errors:
        blockers.append("runtimeReadiness validator failed: " + "; ".join(str(error) for error in validator_errors))
    if readiness.get("status") != "ready":
        blockers.append(f"runtimeReadiness.status must be 'ready', found {readiness.get('status')!r}")
    incomplete = readiness.get("incompleteGates") or []
    if incomplete:
        blockers.append("runtimeReadiness has incomplete gate(s): " + ", ".join(str(gate) for gate in incomplete))
        for detail in readiness.get("incompleteGateDetails") or []:
            prefixes = ", ".join(detail.get("artifactPathPrefixes") or []) or "n/a"
            validators = ", ".join(detail.get("validatorFragments") or []) or "n/a"
            required_args = " ".join(detail.get("validatorRequiredArgs") or []) or "n/a"
            blockers.append(
                f"runtimeReadiness gate {detail.get('id')} required action: {detail.get('requiredAction')} "
                f"(proof: {detail.get('proof')}; artifact prefixes: {prefixes}; "
                f"validator: {validators}; required args: {required_args})"
            )
    return blockers


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--release-check", action="store_true")
    args = parser.parse_args(argv)

    try:
        manifest = build_source_provenance_manifest()
    except (FileNotFoundError, json.JSONDecodeError, subprocess.CalledProcessError) as exc:
        print(f"FAIL: BurnBar source provenance could not be generated: {exc}", file=sys.stderr)
        return 1

    if args.release_check:
        blockers = release_preflight_blockers(manifest)
        if blockers:
            print("FAIL: BurnBar source provenance release preflight is not ready", file=sys.stderr)
            for blocker in blockers:
                print(f"- {blocker}", file=sys.stderr)
            return 1
        print("PASS: BurnBar source provenance release preflight is ready")
        return 0

    if args.check:
        validator_errors = manifest["runtimeReadiness"].get("validatorErrors") or []
        if validator_errors:
            print("FAIL: BurnBar source provenance runtime readiness validator failed", file=sys.stderr)
            for error in validator_errors:
                print(f"- {error}", file=sys.stderr)
            return 1
        print(
            "PASS: BurnBar source provenance inputs verified "
            f"({len(manifest['requiredSourceFiles'])} required source files, "
            f"runtime={manifest['runtimeReadiness']['status']})"
        )
        return 0

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"Wrote BurnBar source provenance manifest: {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
