#!/usr/bin/env python3
"""Generate CloudVault at-rest runtime evidence.

This writer intentionally separates "runtime checks passed" from "release-ready".
It runs the real Functions/contract checks and records privacy-preserving command
evidence, then detects whether any private data-domain is actually configured for
Signal at-rest writes. In the current product state that enablement can remain
false, so the generated packet is useful evidence but still fails the release
validator until the runtime is truly cut over.
"""

from __future__ import annotations

import argparse
from datetime import UTC, datetime
import hashlib
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time
from typing import Any, Callable


ROOT = Path(__file__).resolve().parents[2]
PRIVACY_MARKER = "proof_only_no_plaintext_keys_ciphertext_or_document_identifiers"
SIGNAL_AT_REST_SCHEME = "signal-hpke-identity-seal-v1"

FUNCTIONS_ASSERTIONS = [
    "compiled_functions_imports_signal_at_rest_write",
    "admin_write_validator_accepts_strict_cloudvault_envelope",
    "admin_write_validator_derives_canonical_aad",
    "admin_write_validator_rejects_wrong_binding",
    "admin_write_validator_rejects_plaintext",
    "contract_sanitizer_rejects_gateway_transport_as_cloudvault",
    "sanitized_envelope_drops_plaintext_siblings",
    "signal_at_rest_policy_mirrors_registry",
]
CJS_ASSERTIONS = ["cjs_runtime_import_validates_signal_at_rest_write"]


class CommandResult(dict):
    pass


CommandRunner = Callable[[list[str], Path], CommandResult]


def _iso_now() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def _sha256_text(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8", errors="replace")).hexdigest()


def _normalize_command_output(value: str) -> str:
    normalized = re.sub(r"\b\d+\.\d+s\b", "<duration>s", value)
    normalized = re.sub(r"\b\d+s\b", "<duration>s", normalized)
    normalized = re.sub(r"\(\d+:\d{2}:\d{2}\)", "(<duration>)", normalized)
    return normalized


def _command_string(argv: list[str]) -> str:
    return " ".join(shlex.quote(part) for part in argv)


def run_command(argv: list[str], repo_root: Path) -> CommandResult:
    started = time.monotonic()
    result = subprocess.run(
        argv,
        cwd=repo_root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    stdout = result.stdout
    stderr = result.stderr
    return CommandResult(
        exitCode=result.returncode,
        durationMs=max(0, int((time.monotonic() - started) * 1000)),
        stdoutSha256=_sha256_text(stdout),
        stderrSha256=_sha256_text(stderr),
        stdoutNormalizedSha256=_sha256_text(_normalize_command_output(stdout)),
        stderrNormalizedSha256=_sha256_text(_normalize_command_output(stderr)),
    )


def detect_signal_at_rest_enablement(repo_root: Path) -> dict[str, Any]:
    registry_path = repo_root / "packages/data-domains/registry.json"
    registry = json.loads(registry_path.read_text(encoding="utf-8"))
    domains = registry.get("domains", [])
    signal_domains = [
        domain
        for domain in domains
        if isinstance(domain, dict) and domain.get("sealingScheme") == SIGNAL_AT_REST_SCHEME
    ]
    enabled = [domain.get("id") for domain in signal_domains]
    enabled = sorted(domain_id for domain_id in enabled if isinstance(domain_id, str))
    required_collections = sorted(
        {
            collection
            for domain in signal_domains
            for collection in domain.get("signalSealedCollections", [])
            if isinstance(collection, str)
        }
    )
    return {
        "scheme": SIGNAL_AT_REST_SCHEME,
        "enabledDomainCount": len(enabled),
        "enabledDomains": enabled,
        "requiredCollectionCount": len(required_collections),
        "requiredCollections": required_collections,
        "source": "packages/data-domains/registry.json sealingScheme + signalSealedCollections",
        "sourceSha256": _sha256_file(registry_path),
    }


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _function_assertions(enablement: dict[str, Any]) -> list[str]:
    assertions = list(FUNCTIONS_ASSERTIONS)
    if int(enablement.get("requiredCollectionCount", 0)) > 0:
        assertions.append("signal_at_rest_policy_requires_enabled_collection")
    else:
        assertions.append("signal_at_rest_policy_evaluates_future_required_collection")
    return assertions


def _command_specs(enablement: dict[str, Any]) -> list[dict[str, Any]]:
    return [
        {
            "argv": ["npm", "run", "build", "--prefix", "functions"],
            "assertions": [],
        },
        {
            "argv": ["node", "scripts/ci/check_functions_cloudvault_runtime.js"],
            "assertions": _function_assertions(enablement),
        },
        {
            "argv": ["python3", "-m", "pytest", "tests/test_signal_envelope_contracts_cjs_exports.py", "-q"],
            "assertions": CJS_ASSERTIONS,
        },
    ]


def build_cloudvault_at_rest_runtime_evidence(
    *,
    repo_root: Path = ROOT,
    command_runner: CommandRunner = run_command,
    generated_at: str | None = None,
) -> dict[str, Any]:
    enablement = detect_signal_at_rest_enablement(repo_root)
    command_evidence: list[dict[str, Any]] = []
    for spec in _command_specs(enablement):
        argv = list(spec["argv"])
        result = command_runner(argv, repo_root)
        exit_code = int(result.get("exitCode", 1))
        entry = {
            "command": _command_string(argv),
            "status": "pass" if exit_code == 0 else "fail",
            "exitCode": exit_code,
            "durationMs": int(result.get("durationMs", 0)),
            "stdoutSha256": str(result.get("stdoutSha256", "")),
            "stderrSha256": str(result.get("stderrSha256", "")),
            "stdoutNormalizedSha256": str(result.get("stdoutNormalizedSha256", result.get("stdoutSha256", ""))),
            "stderrNormalizedSha256": str(result.get("stderrNormalizedSha256", result.get("stderrSha256", ""))),
        }
        assertions = list(spec["assertions"])
        if assertions:
            entry["assertions"] = assertions
        command_evidence.append(entry)

    return {
        "schemaVersion": 1,
        "generatedAt": generated_at or _iso_now(),
        "generatedBy": "scripts/ci/write_cloudvault_at_rest_runtime_evidence.py",
        "privacy": PRIVACY_MARKER,
        "signalAtRestWritesEnabled": enablement["enabledDomainCount"] > 0,
        "signalAtRestEnablement": enablement,
        "commandEvidence": command_evidence,
    }


def write_evidence(evidence: dict[str, Any], output: Path | None) -> None:
    payload = json.dumps(evidence, indent=2, sort_keys=True) + "\n"
    if output is None:
        sys.stdout.write(payload)
        return
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(payload, encoding="utf-8")
    print(f"wrote CloudVault at-rest runtime evidence: {output}")


def validate_if_requested(evidence: dict[str, Any], *, repo_root: Path) -> int:
    if str(ROOT) not in sys.path:
        sys.path.insert(0, str(ROOT))
    from scripts.ci.check_cloudvault_at_rest_runtime import validate_cloudvault_at_rest_evidence

    errors = validate_cloudvault_at_rest_evidence(evidence, repo_root=repo_root)
    if errors:
        print("HOLD: generated CloudVault at-rest runtime evidence is not release-ready", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print("PASS: generated CloudVault at-rest runtime evidence is release-ready")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=ROOT)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--check", action="store_true", help="Run the release validator on the generated packet")
    args = parser.parse_args(argv)

    evidence = build_cloudvault_at_rest_runtime_evidence(repo_root=args.repo_root)
    write_evidence(evidence, args.output)
    if args.check:
        return validate_if_requested(evidence, repo_root=args.repo_root)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
