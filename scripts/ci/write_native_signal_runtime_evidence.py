#!/usr/bin/env python3
"""Generate privacy-preserving native libsignal runtime evidence packets."""

from __future__ import annotations

import argparse
from datetime import UTC, datetime
import hashlib
import json
from pathlib import Path
import shlex
import subprocess
import sys
import time
from typing import Any, Callable


ROOT = Path(__file__).resolve().parents[2]
PRIVACY_MARKER = "proof_only_no_plaintext_keys_or_user_data"

PLATFORM_ASSERTIONS = {
    "rust": [
        "official_libsignal_rust_bridge_builds",
        "ffi_contracts_exported",
        "swift_ffi_surface_present",
        "kotlin_jni_surface_present",
        "node_napi_surface_present",
        "no_plaintext_keys_or_user_data",
    ],
    "swift": [
        "official_libsignal_session_round_trip",
        "persistence_reload_round_trip",
        "replay_or_skipped_key_negative",
        "identity_or_safety_number_change_negative",
        "no_plaintext_keys_or_user_data",
    ],
    "kotlin": [
        "official_libsignal_session_round_trip",
        "swift_interop_kat_open",
        "replay_or_skipped_key_negative",
        "identity_key_store_negative",
        "no_plaintext_keys_or_user_data",
    ],
}

GATE_PLATFORM = {
    "rust_core_bridge": "rust",
    "swift_round_trips": "swift",
    "kotlin_round_trips": "kotlin",
}

COMMAND_SPECS = {
    "rust": [
        {
            "argv": ["cargo", "test", "-p", "openburnbar-libsignal-ffi"],
            "assertions": PLATFORM_ASSERTIONS["rust"],
        },
    ],
    "swift": [
        {
            "argv": [
                "env",
                "OPENBURNBAR_CORE_SWIFT_FILTER=OBBSignalProtocolStoreSessionTests",
                "OPENBURNBAR_SKIP_DAEMON_SWIFT_TESTS=1",
                "bash",
                "scripts/test-openburnbar-swift.sh",
            ],
            "assertions": [
                "official_libsignal_session_round_trip",
                "persistence_reload_round_trip",
                "replay_or_skipped_key_negative",
                "identity_or_safety_number_change_negative",
                "no_plaintext_keys_or_user_data",
            ],
        },
        {
            "argv": [
                "env",
                "OPENBURNBAR_CORE_SWIFT_FILTER=OBBSignalSessionOverIrohTests",
                "OPENBURNBAR_SKIP_DAEMON_SWIFT_TESTS=1",
                "bash",
                "scripts/test-openburnbar-swift.sh",
            ],
            "assertions": ["official_libsignal_session_round_trip", "no_plaintext_keys_or_user_data"],
        },
    ],
    "kotlin": [
        {
            "argv": [
                "./gradlew",
                ":app:testDebugUnitTest",
                "--tests",
                "*AndroidSignalSession*",
                "--tests",
                "*AndroidSignalInteropKatTest",
                "--tests",
                "*AndroidCloudVaultSignalPayloadsTest",
                "--tests",
                "*AndroidSignalIdentityKeyStoreTest",
                "--no-daemon",
            ],
            "cwd": "android",
            "assertions": PLATFORM_ASSERTIONS["kotlin"],
        },
    ],
}


class CommandResult(dict):
    pass


CommandRunner = Callable[[list[str], Path], CommandResult]


def _iso_now() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def _sha256_text(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8", errors="replace")).hexdigest()


def _command_string(argv: list[str]) -> str:
    return " ".join(shlex.quote(part) for part in argv)


def run_command(argv: list[str], cwd: Path) -> CommandResult:
    started = time.monotonic()
    result = subprocess.run(
        argv,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    return CommandResult(
        exitCode=result.returncode,
        durationMs=max(0, int((time.monotonic() - started) * 1000)),
        stdoutSha256=_sha256_text(result.stdout),
        stderrSha256=_sha256_text(result.stderr),
    )


def build_native_signal_runtime_evidence(
    *,
    gate: str,
    repo_root: Path = ROOT,
    command_runner: CommandRunner = run_command,
    generated_at: str | None = None,
) -> dict[str, Any]:
    if gate not in GATE_PLATFORM:
        raise ValueError(f"unsupported native runtime gate: {gate}")
    platform = GATE_PLATFORM[gate]
    command_evidence: list[dict[str, Any]] = []
    for spec in COMMAND_SPECS[platform]:
        argv = list(spec["argv"])
        cwd = repo_root / spec.get("cwd", ".")
        result = command_runner(argv, cwd)
        exit_code = int(result.get("exitCode", 1))
        entry = {
            "command": _command_string(argv),
            "status": "pass" if exit_code == 0 else "fail",
            "exitCode": exit_code,
            "durationMs": int(result.get("durationMs", 0)),
            "stdoutSha256": str(result.get("stdoutSha256", "")),
            "stderrSha256": str(result.get("stderrSha256", "")),
        }
        assertions = list(spec["assertions"])
        if assertions:
            entry["assertions"] = assertions
        command_evidence.append(entry)

    return {
        "schemaVersion": 1,
        "generatedAt": generated_at or _iso_now(),
        "generatedBy": "scripts/ci/write_native_signal_runtime_evidence.py",
        "privacy": PRIVACY_MARKER,
        "gate": gate,
        "platforms": {
            platform: {
                "commandEvidence": command_evidence,
            },
        },
    }


def write_evidence(evidence: dict[str, Any], output: Path | None) -> None:
    payload = json.dumps(evidence, indent=2, sort_keys=True) + "\n"
    if output is None:
        sys.stdout.write(payload)
        return
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(payload, encoding="utf-8")
    print(f"wrote native Signal runtime evidence: {output}")


def validate_if_requested(evidence: dict[str, Any], *, gate: str, repo_root: Path) -> int:
    if str(repo_root) not in sys.path:
        sys.path.insert(0, str(repo_root))
    from scripts.ci.check_native_signal_runtime_evidence import validate_native_signal_runtime_evidence

    errors = validate_native_signal_runtime_evidence(evidence, gate=gate, repo_root=repo_root)
    if errors:
        print("HOLD: generated native Signal runtime evidence is not release-ready", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print("PASS: generated native Signal runtime evidence is release-ready")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gate", choices=tuple(GATE_PLATFORM), required=True)
    parser.add_argument("--repo-root", type=Path, default=ROOT)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--check", action="store_true", help="Run the release validator on the generated packet")
    args = parser.parse_args(argv)

    evidence = build_native_signal_runtime_evidence(gate=args.gate, repo_root=args.repo_root)
    write_evidence(evidence, args.output)
    if args.check:
        return validate_if_requested(evidence, gate=args.gate, repo_root=args.repo_root)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
