#!/usr/bin/env python3
"""Validate the libsignal runtime-readiness manifest (fail-closed launch gate).

The manifest (third_party/libsignal/runtime-readiness.json) is the single
machine-readable answer to "is official libsignal the live runtime crypto
core?". Two consumers:

  * scripts/ci/check_burnbar_license_posture.py imports DEFAULT_MANIFEST,
    load_manifest, and check_manifest, and additionally requires the status to
    be "not_ready" until every launch gate (including counsel sign-off)
    completes — the fail-closed posture.
  * The license-posture workflow runs this file directly as a CONSISTENCY
    check: a manifest may say "not_ready" (expected today) or "ready", but it
    may never be internally dishonest — a "ready" status with incomplete
    gates, a drifted pin, a missing required gate, or a gate marked complete
    without completed evidence all fail.

Semantics mirror scripts/ci/verify-libsignal-runtime-readiness.sh (the
launch-time variant of this gate, which additionally exits non-zero while the
status is "not_ready").
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

DEFAULT_MANIFEST = Path("third_party") / "libsignal" / "runtime-readiness.json"

REQUIRED_GATE_IDS: tuple[str, ...] = (
    "rust_core_bridge",
    "swift_round_trips",
    "kotlin_round_trips",
    "node_contracts",
    "hermes_gateway_writes",
    "hermes_attachment_writes",
    "cloudvault_private_domains",
    "migration_telemetry",
    "store_and_counsel_approval",
)

# The official libsignal pin, byte-for-byte. Must match third_party/libsignal/
# manifest.json and packages/libsignal-bridge — drift here means the readiness
# evidence no longer describes the library we actually vendor.
EXPECTED_PIN = {
    "tag": "v0.94.4",
    "tagObject": "03c449017b57eccbda715b8b018dce5dff603ac6",
    "commit": "46d867c986f66201e34e7ae20ce423eec742bf3f",
}

VALID_STATUSES = ("ready", "not_ready")


def load_manifest(manifest: Path | str, repo_root: Path | str | None = None) -> dict[str, Any]:
    """Load the manifest and normalize ``requiredGates`` into a ``gates`` dict.

    Returns the parsed manifest with an added ``gates`` key mapping gate id to
    the gate object — the shape check_burnbar_license_posture.py consumes.
    """
    path = _resolve(manifest, repo_root)
    data: dict[str, Any] = json.loads(path.read_text(encoding="utf-8"))
    gates = {
        gate.get("id"): gate for gate in data.get("requiredGates", []) if isinstance(gate, dict) and gate.get("id")
    }
    data["gates"] = gates
    return data


def check_manifest(manifest: Path | str, repo_root: Path | str | None = None) -> list[str]:
    """Return every internal-consistency violation; an empty list means valid."""
    path = _resolve(manifest, repo_root)
    errors: list[str] = []

    if not path.is_file():
        return [f"missing libsignal runtime-readiness manifest: {path}"]
    try:
        data = load_manifest(path)
    except (json.JSONDecodeError, OSError) as exc:  # pragma: no cover - defensive
        return [f"unreadable libsignal runtime-readiness manifest {path}: {exc}"]

    status = data.get("status")
    if status not in VALID_STATUSES:
        errors.append(f"invalid libsignal runtime status: {status!r} (expected one of {VALID_STATUSES})")

    pin = data.get("officialLibsignalPin") or {}
    for key, expected in EXPECTED_PIN.items():
        actual = pin.get(key)
        if actual != expected:
            errors.append(f"libsignal runtime manifest pin {key} drifted: {actual!r} != {expected!r}")

    gates: dict[str, Any] = data.get("gates", {})
    missing = [gate_id for gate_id in REQUIRED_GATE_IDS if gate_id not in gates]
    if missing:
        errors.append("missing libsignal runtime gates: " + ", ".join(missing))

    for gate_id, gate in gates.items():
        if gate.get("status") not in ("pending", "complete"):
            errors.append(f"gate {gate_id} has invalid status {gate.get('status')!r}")
        if not gate.get("proof"):
            errors.append(f"gate {gate_id} is missing its proof description")

    completed_evidence_ids = {
        evidence.get("id")
        for evidence in data.get("completedEvidence", [])
        if isinstance(evidence, dict) and evidence.get("status") == "complete"
    }
    unevidenced = [
        gate_id
        for gate_id in REQUIRED_GATE_IDS
        if gates.get(gate_id, {}).get("status") == "complete" and gate_id not in completed_evidence_ids
    ]
    if unevidenced:
        errors.append("complete gates missing completed evidence: " + ", ".join(unevidenced))

    incomplete = [gate_id for gate_id in REQUIRED_GATE_IDS if gates.get(gate_id, {}).get("status") != "complete"]
    if status == "ready" and incomplete:
        errors.append("manifest says ready but gates are incomplete: " + ", ".join(incomplete))

    return errors


def _resolve(manifest: Path | str, repo_root: Path | str | None) -> Path:
    path = Path(manifest)
    if not path.is_absolute():
        root = Path(repo_root) if repo_root is not None else Path(__file__).resolve().parents[2]
        path = root / path
    return path


def main() -> int:
    errors = check_manifest(DEFAULT_MANIFEST)
    if errors:
        print("FAIL: libsignal runtime-readiness manifest is invalid")
        for error in errors:
            print(f"  - {error}")
        return 1

    data = load_manifest(DEFAULT_MANIFEST)
    status = data["status"]
    complete = sum(1 for gate in data["gates"].values() if gate.get("status") == "complete")
    total = len(data["gates"])
    if status == "ready":
        print(f"PASS: libsignal runtime readiness gate is READY ({complete}/{total} gates complete)")
    else:
        print(
            "PASS: libsignal runtime readiness manifest is consistent and FAIL-CLOSED "
            f"(status=not_ready, {complete}/{total} gates complete; launch blocked until all gates "
            "and counsel sign-off land)"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
