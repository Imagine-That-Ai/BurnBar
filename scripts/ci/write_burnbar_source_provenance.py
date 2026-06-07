#!/usr/bin/env python3
"""Generate BurnBar corresponding-source provenance metadata.

The output is a release artifact, not a substitute for the source bundle. It
records which source revision, license notices, libsignal source files, and
runtime-readiness gate were used for a Signal-enabled build.
"""

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
REQUIRED_SOURCE_PATHS = [
    "LICENSE",
    "THIRD_PARTY_NOTICES.md",
    "docs/legal/SOURCE_AVAILABILITY.md",
    "docs/legal/DEPENDENCY_LICENSE_MANIFEST.md",
    "docs/legal/AGPL_RELEASE_REVIEW_PACKET.md",
    "docs/legal/agpl-release-review.evidence.template.json",
    "docs/legal/HERMES_GATEWAY_SIGNAL_REQUIRED_ROLLOUT.md",
    "OpenBurnBarCore/Package.swift",
    "OpenBurnBarCore/Sources/OpenBurnBarCore/CloudVaultCryptoError.swift",
    "OpenBurnBarCore/Sources/OpenBurnBarSignalCore/SignalEnvelopeAAD.swift",
    "OpenBurnBarCore/Sources/OpenBurnBarSignalCore/SignalIdentity.swift",
    "OpenBurnBarCore/Sources/OpenBurnBarSignalCore/SignalPrekeyPublication.swift",
    "OpenBurnBarCore/Sources/OpenBurnBarSignalCore/SignalPrekeyPublicationStore.swift",
    "OpenBurnBarCore/Tests/OpenBurnBarSignalCoreTests/SignalEnvelopeAADTests.swift",
    "OpenBurnBarCore/Tests/OpenBurnBarSignalCoreTests/SignalPrekeyPublicationTests.swift",
    "android/gradlew",
    "android/gradle/wrapper/gradle-wrapper.properties",
    "android/settings.gradle.kts",
    "android/build.gradle.kts",
    "android/app/build.gradle.kts",
    "android/app/src/main/java/com/openburnbar/data/cloud/AndroidCloudVaultSignalPayloads.kt",
    "android/app/src/main/java/com/openburnbar/data/cloud/AndroidSignalIdentity.kt",
    "android/app/src/main/java/com/openburnbar/data/cloud/AndroidSignalPrekeyDirectory.kt",
    "android/app/src/main/java/com/openburnbar/data/cloud/CloudVaultCrypto.kt",
    "android/app/src/main/java/com/openburnbar/data/cloud/CloudVaultCryptoSupport.kt",
    "android/app/src/test/java/com/openburnbar/data/cloud/AndroidCloudVaultSignalPayloadsTest.kt",
    "android/app/src/test/java/com/openburnbar/data/cloud/AndroidSignalPrekeyDirectoryTest.kt",
    "packages/signal-envelope-contracts/lib/cloudVaultSignalEnvelope.cjs",
    "packages/signal-envelope-contracts/lib/index.cjs",
    "functions/lib/hermesGateway.js",
    "functions/lib/callables/hermesGateway.js",
    "functions/lib/__tests__/hermesGatewaySignalEnvelope.test.js",
    "scripts/ci/drain_hermes_gateway_legacy_records.js",
    "tests/test_hermes_gateway_signal_required_mode.py",
    "scripts/ci/check_agpl_legal_release_review.py",
    "scripts/ci/check_cloudvault_at_rest_runtime.py",
    "scripts/ci/check_functions_cloudvault_runtime.js",
    "scripts/ci/check_hermes_gateway_migration_drain.py",
    "scripts/ci/check_native_signal_runtime_evidence.py",
    "scripts/ci/rollout_hermes_gateway_signal_required.js",
    "scripts/ci/write_hermes_gateway_migration_drain_evidence.js",
    "tests/test_signal_envelope_contracts_cjs_exports.py",
    "tests/test_hermes_gateway_migration_drain_collector.py",
    "tests/test_hermes_gateway_legacy_drain.py",
    "tests/test_hermes_gateway_signal_required_rollout.py",
    "tests/test_hermes_gateway_signal_required_rollout_runbook.py",
    "tests/test_native_signal_runtime_evidence.py",
    "third_party/libsignal/runtime-readiness.json",
    "Vendor/libsignal/LICENSE",
    "Vendor/libsignal/Cargo.toml",
    "Vendor/libsignal/node/package.json",
    "Vendor/libsignal/rust/protocol/src/triple_ratchet.rs",
    "package-lock.json",
    "pyproject.toml",
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
    path = repo_root / "third_party/libsignal/runtime-readiness.json"
    data = json.loads(path.read_text(encoding="utf-8"))
    gates = data.get("gates", {})
    complete = sorted(name for name, gate in gates.items() if gate.get("status") == "complete")
    incomplete = sorted(name for name, gate in gates.items() if gate.get("status") != "complete")
    return {
        "status": data.get("status"),
        "completeGates": complete,
        "incompleteGates": incomplete,
    }


def build_source_provenance_manifest(*, repo_root: Path = ROOT) -> dict[str, Any]:
    dirty_paths = [line for line in run_git(["status", "--porcelain"], repo_root=repo_root).splitlines() if line]
    source_files = [required_file_entry(path, repo_root=repo_root) for path in REQUIRED_SOURCE_PATHS]
    return {
        "schemaVersion": 1,
        "product": "BurnBar",
        "productLicense": "AGPL-3.0-only",
        "sourceAvailability": "docs/legal/SOURCE_AVAILABILITY.md",
        "thirdPartyNotices": "THIRD_PARTY_NOTICES.md",
        "git": {
            "head": run_git(["rev-parse", "HEAD"], repo_root=repo_root),
            "branch": run_git(["branch", "--show-current"], repo_root=repo_root, check=False),
            "dirty": bool(dirty_paths),
            "dirtyPaths": dirty_paths,
        },
        "libsignal": {
            "sourcePath": "Vendor/libsignal",
            "license": "AGPL-3.0-only",
            "spqrEvidence": "Vendor/libsignal/rust/protocol/src/triple_ratchet.rs",
        },
        "runtimeReadiness": load_runtime_readiness(repo_root),
        "requiredSourceFiles": source_files,
        "excludedFromCorrespondingSource": [
            "private signing keys",
            "production secrets",
            "user data",
            "build caches",
            "unrelated deployment credentials",
        ],
    }


def release_preflight_blockers(manifest: dict[str, Any]) -> list[str]:
    blockers: list[str] = []
    git = manifest.get("git", {})
    if git.get("dirty") is True:
        dirty_paths = git.get("dirtyPaths", [])
        count = len(dirty_paths) if isinstance(dirty_paths, list) else "unknown"
        blockers.append(f"git working tree must be clean for release provenance ({count} dirty path(s))")

    readiness = manifest.get("runtimeReadiness", {})
    if readiness.get("status") != "ready":
        blockers.append(f"runtimeReadiness.status must be 'ready', found {readiness.get('status')!r}")
    incomplete = readiness.get("incompleteGates", [])
    if incomplete:
        blockers.append("runtimeReadiness has incomplete gate(s): " + ", ".join(str(gate) for gate in incomplete))
    return blockers


def write_manifest(output: Path, *, repo_root: Path = ROOT) -> None:
    manifest = build_source_provenance_manifest(repo_root=repo_root)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT, help="Where to write the provenance JSON")
    parser.add_argument("--check", action="store_true", help="Validate inputs and print a summary without writing")
    parser.add_argument(
        "--release-check",
        action="store_true",
        help="Fail unless the exact release source is clean and every runtime-readiness gate is complete",
    )
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
        print(
            "PASS: BurnBar source provenance release preflight is ready "
            f"({len(manifest['requiredSourceFiles'])} required source files)"
        )
        return 0

    if args.check:
        print(
            "PASS: BurnBar source provenance inputs verified "
            f"({len(manifest['requiredSourceFiles'])} required source files, "
            f"runtime={manifest['runtimeReadiness']['status']})"
        )
        return 0

    write_manifest(args.output)
    print(f"Wrote BurnBar source provenance manifest: {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
