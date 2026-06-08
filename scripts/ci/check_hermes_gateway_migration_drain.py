#!/usr/bin/env python3
"""Validate Hermes Gateway migration drain evidence."""

from __future__ import annotations

import argparse
from datetime import UTC, datetime, timedelta
import json
import re
import subprocess
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
MAX_CLOCK_SKEW = timedelta(minutes=5)
GIT_SHA_RE = re.compile(r"^[0-9a-f]{40}$")
PRODUCTION_SIGNAL_SET_RE = re.compile(
    r"HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS\s*=\s*(?:"
    r"new Set(?:<number>)?\(\s*\[\s*(?:HERMES_GATEWAY_RELAY_KEY_VERSION_SIGNAL|4)\s*\]\s*\)"
    r"|productionSignalEnvelopeVersionsFromEnv\(\s*\)"
    r")"
)


def _git_show(repo_root: Path, commit: str, path: str) -> str | None:
    result = subprocess.run(
        ["git", "-C", str(repo_root), "show", f"{commit}:{path}"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    return result.stdout if result.returncode == 0 else None


def _commit_exists(repo_root: Path, commit: str) -> bool:
    result = subprocess.run(
        ["git", "-C", str(repo_root), "cat-file", "-e", f"{commit}^{{commit}}"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return result.returncode == 0


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
    now = datetime.now(UTC)
    generated_at = generated_at.astimezone(UTC)
    if generated_at - now > MAX_CLOCK_SKEW:
        errors.append("generatedAt must not be in the future")
    if now - generated_at > MAX_EVIDENCE_AGE:
        errors.append("generatedAt must be within the last 24 hours")


def _validate_deployed_source(data: dict[str, Any], errors: list[str], *, repo_root: Path) -> None:
    release = data.get("release") or {}
    deployed_commit = release.get("deployedCommit")
    if not isinstance(deployed_commit, str) or not GIT_SHA_RE.fullmatch(deployed_commit):
        return
    if not _commit_exists(repo_root, deployed_commit):
        errors.append("release.deployedCommit must exist as a commit in --repo-root")
        return

    gateway_source = _git_show(repo_root, deployed_commit, "functions/src/hermesGateway.ts")
    if gateway_source is None:
        errors.append("deployed source is missing functions/src/hermesGateway.ts")
    else:
        if "requireProductionGatewaySignalEnvelope" not in gateway_source:
            errors.append("deployed source functions/src/hermesGateway.ts is missing requireProductionGatewaySignalEnvelope")
        if not PRODUCTION_SIGNAL_SET_RE.search(gateway_source):
            errors.append(
                "deployed source functions/src/hermesGateway.ts must enable "
                "HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS for v4 Signal writes"
            )
        if "SIGNAL_ENVELOPE_V4_DISABLED" not in gateway_source:
            errors.append("deployed source functions/src/hermesGateway.ts is missing SIGNAL_ENVELOPE_V4_DISABLED rollback kill switch")

    callable_source = _git_show(repo_root, deployed_commit, "functions/src/callables/hermesGateway.ts")
    if callable_source is None:
        errors.append("deployed source is missing functions/src/callables/hermesGateway.ts")
    else:
        required_tokens = (
            "signalEnvelope?: unknown",
            "request.data.signalEnvelope",
            "resolveGatewayWriteBody",
        )
        missing = [token for token in required_tokens if token not in callable_source]
        if missing:
            errors.append(
                "deployed source functions/src/callables/hermesGateway.ts is missing signalEnvelope write plumbing: "
                + ", ".join(missing)
            )


def validate_drain_evidence(data: dict[str, Any], *, repo_root: Path | None = None) -> list[str]:
    errors: list[str] = []
    repo_root = repo_root or Path.cwd()
    if data.get("schemaVersion") != 1:
        errors.append("schemaVersion must be 1")
    _validate_generated_at(data.get("generatedAt"), errors)
    if data.get("privacy") != PRIVACY_MARKER:
        errors.append("evidence must be aggregate_counts_only_no_document_values_or_identifiers")
    release = data.get("release") or {}
    for field in ("deployedCommit", "sourceLocation", "dependencyLocks"):
        if not release.get(field):
            errors.append(f"release.{field} is required")
    deployed_commit = release.get("deployedCommit")
    source_location = release.get("sourceLocation")
    if not isinstance(deployed_commit, str) or not GIT_SHA_RE.fullmatch(deployed_commit):
        errors.append("release.deployedCommit must be the 40-character git commit deployed to the live services")
    if not isinstance(source_location, str) or not source_location.startswith(("https://", "git@")):
        errors.append("release.sourceLocation must be an https:// or git@ source URL")
    _validate_deployed_source(data, errors, repo_root=repo_root)
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
        firebase_hash = service.get("firebaseFunctionsHash")
        if not isinstance(firebase_hash, str) or not GIT_SHA_RE.fullmatch(firebase_hash):
            errors.append(f"writePath.services.{service_name}.firebaseFunctionsHash must be the live Firebase functions hash")
        if not service.get("functionVersion"):
            errors.append(f"writePath.services.{service_name}.functionVersion is required")
        source_commit = service.get("sourceCommit")
        if source_commit != deployed_commit:
            errors.append(f"writePath.services.{service_name}.sourceCommit must match release.deployedCommit")
        corresponding_source_url = service.get("correspondingSourceUrl")
        if corresponding_source_url != source_location:
            errors.append(f"writePath.services.{service_name}.correspondingSourceUrl must match release.sourceLocation")

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
        sample_limit = _as_non_negative_int(summary.get("sampleLimit"), f"{name}.sampleLimit", errors)
        sampled = _as_non_negative_int(summary.get("sampled"), f"{name}.sampled", errors)
        if sampled > sample_limit:
            errors.append(f"{name}.sampled must be <= {name}.sampleLimit")
        counts = summary.get("counts") or summary.get("classifications") or {}
        if not isinstance(counts, dict):
            errors.append(f"{name}.counts must be an object")
            counts = {}
        unknown_count_keys = sorted(str(field) for field in counts if field not in ALL_CLASSIFICATIONS)
        if unknown_count_keys:
            errors.append(f"{name}.counts has unknown classification(s): " + ", ".join(unknown_count_keys))
        for field in ALL_CLASSIFICATIONS:
            _as_non_negative_int(counts.get(field, 0), f"{name}.{field}", errors)
        counted_total = sum(_as_non_negative_int(counts.get(field, 0), f"{name}.{field}", errors) for field in ALL_CLASSIFICATIONS)
        if counted_total != sampled:
            errors.append(f"{name}.sampled must equal the sum of classification counts ({counted_total})")
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
    parser.add_argument("--repo-root", type=Path, default=Path.cwd())
    parser.add_argument("evidence", type=Path)
    args = parser.parse_args(argv)
    try:
        data = json.loads(args.evidence.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"FAIL: unreadable Hermes Gateway migration drain evidence: {exc}", file=sys.stderr)
        return 1
    errors = validate_drain_evidence(data, repo_root=args.repo_root)
    if errors:
        print("FAIL: Hermes Gateway migration drain evidence is not release-ready", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print("PASS: Hermes Gateway migration drain evidence is release-ready")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
