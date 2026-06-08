#!/usr/bin/env python3
"""Generate privacy-preserving Node Signal-envelope contract evidence."""

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
PRIVACY_MARKER = "proof_only_no_plaintext_keys_ciphertext_or_user_data"

PACKAGE_ASSERTIONS = [
    "signal_envelope_contracts_package_tests_pass",
    "transport_and_at_rest_envelope_sanitizers",
    "export_sanitizer_fails_closed",
    "deterministic_binding_aad_vectors",
    "aad_delimiter_and_control_guard",
    "unicode_normalization_fixture",
]
FUNCTIONS_VITEST_ASSERTIONS = [
    "functions_gateway_signal_envelope_tests",
    "functions_export_sanitization_tests",
    "functions_sealed_event_contract_tests",
]

COMMAND_SPECS = [
    {
        "argv": ["npm", "ci", "--prefix", "packages/signal-envelope-contracts"],
        "assertions": [],
    },
    {
        "argv": ["npm", "test", "--prefix", "packages/signal-envelope-contracts"],
        "assertions": PACKAGE_ASSERTIONS,
    },
    {
        "argv": ["npm", "ci", "--prefix", "functions"],
        "assertions": [],
    },
    {
        "argv": ["npm", "run", "build", "--prefix", "functions"],
        "assertions": ["functions_typescript_builds_with_contracts"],
    },
    {
        "argv": [
            "npx",
            "vitest",
            "run",
            "src/__tests__/hermesGatewaySignalEnvelope.test.ts",
            "src/__tests__/dataExport.test.ts",
            "src/__tests__/hermesGatewaySealedEvent.test.ts",
            "--reporter=verbose",
        ],
        "cwd": "functions",
        "assertions": FUNCTIONS_VITEST_ASSERTIONS,
    },
    {
        "argv": ["npm", "run", "test:hermes-gateway", "--prefix", "functions"],
        "assertions": ["functions_hermes_gateway_script_tests"],
    },
    {
        "argv": ["npm", "ci", "--prefix", "services/hosted-mcp"],
        "assertions": [],
    },
    {
        "argv": ["npm", "test", "--prefix", "services/hosted-mcp"],
        "assertions": ["hosted_mcp_signal_contract_tests"],
    },
    {
        "argv": ["npm", "ci", "--prefix", "services/hermes-realtime-relay"],
        "assertions": [],
    },
    {
        "argv": ["npm", "test", "--prefix", "services/hermes-realtime-relay"],
        "assertions": ["hermes_realtime_relay_signal_contract_tests"],
    },
]


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


def build_signal_envelope_contract_runtime_evidence(
    *,
    repo_root: Path = ROOT,
    command_runner: CommandRunner = run_command,
    generated_at: str | None = None,
) -> dict[str, Any]:
    command_evidence: list[dict[str, Any]] = []
    for spec in COMMAND_SPECS:
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
        if assertions and exit_code == 0:
            entry["assertions"] = assertions
        command_evidence.append(entry)

    return {
        "schemaVersion": 1,
        "generatedAt": generated_at or _iso_now(),
        "generatedBy": "scripts/ci/write_signal_envelope_contract_runtime_evidence.py",
        "privacy": PRIVACY_MARKER,
        "commandEvidence": command_evidence,
    }


def write_evidence(evidence: dict[str, Any], output: Path | None) -> None:
    payload = json.dumps(evidence, indent=2, sort_keys=True) + "\n"
    if output is None:
        sys.stdout.write(payload)
        return
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(payload, encoding="utf-8")
    print(f"wrote Node Signal-envelope contract evidence: {output}")


def validate_if_requested(evidence: dict[str, Any]) -> int:
    if str(ROOT) not in sys.path:
        sys.path.insert(0, str(ROOT))
    from scripts.ci.check_signal_envelope_contract_runtime import (  # noqa: E402
        validate_signal_envelope_contract_runtime_evidence,
    )

    errors = validate_signal_envelope_contract_runtime_evidence(evidence)
    if errors:
        print("HOLD: generated Node Signal-envelope contract evidence is not release-ready", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print("PASS: generated Node Signal-envelope contract evidence is release-ready")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=ROOT)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--check", action="store_true", help="Run the release validator on the generated packet")
    args = parser.parse_args(argv)

    evidence = build_signal_envelope_contract_runtime_evidence(repo_root=args.repo_root)
    write_evidence(evidence, args.output)
    if args.check:
        return validate_if_requested(evidence)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
