#!/usr/bin/env python3
"""Validate Hermes Gateway migration drain evidence."""

from __future__ import annotations

import argparse
from datetime import UTC, datetime, timedelta
import json
import sys
from pathlib import Path
from typing import Any


PRIVACY_MARKER = "aggregate_counts_only_no_document_values_or_identifiers"
BLOCKING_CLASSIFICATIONS = ("unreadable", "malformed", "unknownSchema", "parserMisses")
KNOWN_LEGACY_CLASSIFICATIONS = ("knownLegacyRelay", "knownLegacyRatchet", "knownLegacyPlaintext")
ALL_CLASSIFICATIONS = ("signalRead",) + KNOWN_LEGACY_CLASSIFICATIONS + BLOCKING_CLASSIFICATIONS
REQUIRED_COLLECTIONS = {
    "events": "hermes_gateway_events",
    "messages": "hermes_gateway_messages",
    "attachments": "hermes_gateway_attachments",
}
REQUIRED_SERVICES = ("burnbarhermesgateway", "enqueuehermesgatewayevent")
MAX_EVIDENCE_AGE = timedelta(hours=24)


def _as_non_negative_int(value: Any, field: str, errors: list[str]) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        errors.append(f"{field} must be a non-negative integer")
        return 0
    if value < 0:
        errors.append(f"{field} must be a non-negative integer")
        return 0
    return value


def _validate_generated_at(value: Any, errors: list[str]) -> None:
    if not isinstance(value, str) or not value:
        errors.append("generatedAt is required")
        return
    try:
        generated_at = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        errors.append("generatedAt must be an ISO timestamp")
        return
    if generated_at.tzinfo is None:
        generated_at = generated_at.replace(tzinfo=UTC)
    if datetime.now(UTC) - generated_at.astimezone(UTC) > MAX_EVIDENCE_AGE:
        errors.append("generatedAt must be within the last 24 hours")


def validate_drain_evidence(data: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    if data.get("schemaVersion") != 1:
        errors.append("schemaVersion must be 1")
    _validate_generated_at(data.get("generatedAt"), errors)
    if data.get("privacy") != PRIVACY_MARKER:
        errors.append("evidence must be aggregate_counts_only_no_document_values_or_identifiers")
    release = data.get("release") or {}
    for field in ("deployedCommit", "sourceLocation", "dependencyLocks"):
        if not release.get(field):
            errors.append(f"release.{field} is required")
    write_path = data.get("writePath") or {}
    if write_path.get("signalRequired") is not True:
        errors.append("writePath.signalRequired must be true")
    if write_path.get("signalEnvelopeWritesEnabled") is not True:
        errors.append("writePath.signalEnvelopeWritesEnabled must be true")
    if write_path.get("legacyRelayWritesEnabled") is not False:
        errors.append("writePath.legacyRelayWritesEnabled must be false")
    if write_path.get("legacyRatchetWritesEnabled") is not False:
        errors.append("writePath.legacyRatchetWritesEnabled must be false")
    if write_path.get("legacyPlaintextWritesEnabled") is not False:
        errors.append("writePath.legacyPlaintextWritesEnabled must be false")
    if "gcloud run services describe" not in str(write_path.get("modeSource") or ""):
        errors.append("writePath.modeSource must come from gcloud service/revision inspection")
    services = {
        service.get("service"): service for service in write_path.get("services", []) if isinstance(service, dict)
    }
    for service_name in REQUIRED_SERVICES:
        service = services.get(service_name)
        if not service:
            errors.append(f"writePath.services missing {service_name}")
            continue
        if service.get("signalRequired") is not True:
            errors.append(f"writePath.services.{service_name}.signalRequired must be true")
        if not service.get("latestReadyRevision"):
            errors.append(f"writePath.services.{service_name}.latestReadyRevision is required")

    collections = data.get("collections") or {}
    if not collections:
        errors.append("collections are required")
    for name, expected_group in REQUIRED_COLLECTIONS.items():
        if name not in collections:
            errors.append(f"collections.{name} is required")
            continue
        summary = collections[name]
        if summary.get("collectionGroup") != expected_group:
            errors.append(f"{name}.collectionGroup must be {expected_group}")
        if summary.get("truncated") is True:
            errors.append(f"{name}.truncated must be false; release evidence must cover the full collection group")
        _as_non_negative_int(summary.get("sampleLimit"), f"{name}.sampleLimit", errors)
        _as_non_negative_int(summary.get("sampled"), f"{name}.sampled", errors)
        counts = summary.get("counts") or summary.get("classifications") or {}
        for field in ALL_CLASSIFICATIONS:
            _as_non_negative_int(counts.get(field, 0), f"{name}.{field}", errors)
        for field in BLOCKING_CLASSIFICATIONS:
            if _as_non_negative_int(counts.get(field, 0), f"{name}.{field}", errors) != 0:
                errors.append(
                    f"{name}.{field} must be 0 before release; preserve matching records with a private quarantine "
                    "export and investigate manually, never drain them as legacy"
                )
        if sum(_as_non_negative_int(counts.get(field, 0), f"{name}.{field}", errors) for field in KNOWN_LEGACY_CLASSIFICATIONS) != 0:
            errors.append(
                f"{name} still has known legacy records; run dry-run, review, export pre-delete bodies privately, "
                "then execute the allowlist drain"
            )
    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path)
    args = parser.parse_args(argv)
    data = json.loads(args.evidence.read_text(encoding="utf-8"))
    errors = validate_drain_evidence(data)
    if errors:
        print("FAIL: Hermes Gateway migration drain evidence is not release-ready", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print("PASS: Hermes Gateway migration drain evidence is release-ready")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
