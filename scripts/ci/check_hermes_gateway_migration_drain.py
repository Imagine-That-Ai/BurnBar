#!/usr/bin/env python3
"""Validate aggregate Hermes Gateway migration-drain evidence.

This release artifact proves the hosted write path has drained legacy Hermes
Gateway records before BurnBar marks the Signal/libsignal runtime ready. It must
contain counts only: no document IDs, user IDs, ciphertext, wrapped keys, or
payload fields.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


PRIVACY_MARKER = "aggregate_counts_only_no_document_values_or_identifiers"
REQUIRED_COLLECTIONS = {
    "events": "hermes_gateway_events",
    "messages": "hermes_gateway_messages",
    "attachments": "hermes_gateway_attachments",
}
COUNT_FIELDS = (
    "total",
    "signalRead",
    "legacyHermesRelayRead",
    "legacyHermesRatchetRead",
    "legacyPlaintextRead",
    "unreadable",
)
NON_SIGNAL_FIELDS = (
    "legacyHermesRelayRead",
    "legacyHermesRatchetRead",
    "legacyPlaintextRead",
    "unreadable",
)
TOP_LEVEL_KEYS = {"schemaVersion", "generatedAt", "privacy", "release", "writePath", "collections"}
RELEASE_KEYS = {"deployedCommit", "sourceLocation", "sourceAvailability", "dependencyLocks"}
WRITE_PATH_KEYS = {
    "signalRequired",
    "signalEnvelopeWritesEnabled",
    "legacyRelayWritesEnabled",
    "legacyRatchetWritesEnabled",
    "legacyPlaintextWritesEnabled",
    "modeSource",
    "services",
}
WRITE_PATH_SERVICE_KEYS = {"service", "latestReadyRevision", "url", "signalRequired"}
REQUIRED_WRITE_PATH_SERVICES = {"burnbarhermesgateway", "enqueuehermesgatewayevent"}
COLLECTION_KEYS = {"collectionGroup", "sampleLimit", "sampled", "truncated", "counts"}
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
REQUIRED_DEPENDENCY_LOCKS = {"package-lock.json", "pyproject.toml"}


def _path(path: tuple[str, ...]) -> str:
    if not path:
        return "root"
    return ".".join(path)


def _is_nonnegative_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


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


def _validate_release(data: Any, *, repo_root: Path | None) -> list[str]:
    path = ("release",)
    if not isinstance(data, dict):
        return ["release must be an object"]

    errors = _unexpected_keys(data, RELEASE_KEYS, path)
    deployed_commit = data.get("deployedCommit")
    if not isinstance(deployed_commit, str) or not COMMIT_RE.fullmatch(deployed_commit):
        errors.append("release.deployedCommit must be a 40-character lowercase git commit SHA")

    source_location = data.get("sourceLocation")
    if not isinstance(source_location, str) or not source_location.startswith("https://"):
        errors.append("release.sourceLocation must be an https:// source URL users can access")

    if data.get("sourceAvailability") != "docs/legal/SOURCE_AVAILABILITY.md":
        errors.append("release.sourceAvailability must be 'docs/legal/SOURCE_AVAILABILITY.md'")

    dependency_locks, dependency_lock_errors = _string_list(data.get("dependencyLocks"), "release.dependencyLocks")
    errors.extend(dependency_lock_errors)
    missing_locks = sorted(REQUIRED_DEPENDENCY_LOCKS.difference(dependency_locks))
    if missing_locks:
        errors.append("release.dependencyLocks missing required lockfile(s): " + ", ".join(missing_locks))
    if repo_root is not None:
        for rel_path in dependency_locks:
            if not (repo_root / rel_path).is_file():
                errors.append(f"release.dependencyLocks path does not exist: {rel_path}")
    return errors


def _validate_write_path(data: Any) -> list[str]:
    path = ("writePath",)
    if not isinstance(data, dict):
        return ["writePath must be an object"]

    errors = _unexpected_keys(data, WRITE_PATH_KEYS, path)
    expected = {
        "signalRequired": True,
        "signalEnvelopeWritesEnabled": True,
        "legacyRelayWritesEnabled": False,
        "legacyRatchetWritesEnabled": False,
        "legacyPlaintextWritesEnabled": False,
    }
    for key, value in expected.items():
        if data.get(key) is not value:
            errors.append(f"{_path((*path, key))} must be {str(value).lower()} before the write-path gate is complete")

    mode_source = data.get("modeSource")
    if not isinstance(mode_source, str) or not mode_source.strip():
        errors.append("writePath.modeSource must describe the deployed Signal-required mode readback")

    services = data.get("services")
    if not isinstance(services, list) or not services:
        errors.append("writePath.services must be a non-empty list of deployed gateway service readbacks")
        return errors

    seen_services: set[str] = set()
    for index, service in enumerate(services):
        service_path = (*path, "services", str(index))
        if not isinstance(service, dict):
            errors.append(f"{_path(service_path)} must be an object")
            continue
        errors.extend(_unexpected_keys(service, WRITE_PATH_SERVICE_KEYS, service_path))
        service_name = service.get("service")
        if not isinstance(service_name, str) or not service_name.strip():
            errors.append(f"{_path((*service_path, 'service'))} must be a non-empty string")
        else:
            seen_services.add(service_name)
        latest_ready_revision = service.get("latestReadyRevision")
        if not isinstance(latest_ready_revision, str) or not latest_ready_revision.strip():
            errors.append(f"{_path((*service_path, 'latestReadyRevision'))} must be a non-empty string")
        url = service.get("url")
        if not isinstance(url, str) or not url.startswith("https://"):
            errors.append(f"{_path((*service_path, 'url'))} must be an https:// URL")
        if service.get("signalRequired") is not True:
            errors.append(f"{_path((*service_path, 'signalRequired'))} must be true before the write-path gate is complete")

    missing_services = sorted(REQUIRED_WRITE_PATH_SERVICES.difference(seen_services))
    if missing_services:
        errors.append("writePath.services missing required gateway service(s): " + ", ".join(missing_services))
    return errors


def _validate_collection(name: str, data: Any, expected_group: str) -> list[str]:
    path = ("collections", name)
    if not isinstance(data, dict):
        return [f"{_path(path)} must be an object"]

    errors = _unexpected_keys(data, COLLECTION_KEYS, path)
    if data.get("collectionGroup") != expected_group:
        errors.append(f"{_path(path)}.collectionGroup must be {expected_group!r}")

    sample_limit = data.get("sampleLimit")
    sampled = data.get("sampled")
    truncated = data.get("truncated")
    if not _is_nonnegative_int(sample_limit) or sample_limit <= 0:
        errors.append(f"{_path(path)}.sampleLimit must be a positive integer")
    if not _is_nonnegative_int(sampled):
        errors.append(f"{_path(path)}.sampled must be a non-negative integer")
    if truncated is not False:
        errors.append(f"{_path(path)}.truncated must be false for release evidence")

    counts = data.get("counts")
    count_path = (*path, "counts")
    if not isinstance(counts, dict):
        errors.append(f"{_path(count_path)} must be an object")
        return errors

    errors.extend(_unexpected_keys(counts, set(COUNT_FIELDS), count_path))
    missing = sorted(set(COUNT_FIELDS).difference(counts))
    if missing:
        errors.append(f"{_path(count_path)} missing required count(s): {', '.join(missing)}")
        return errors

    count_value_errors: list[str] = []
    for field in COUNT_FIELDS:
        if not _is_nonnegative_int(counts.get(field)):
            count_value_errors.append(f"{_path((*count_path, field))} must be a non-negative integer")
    errors.extend(count_value_errors)
    if count_value_errors:
        return errors

    total = counts["total"]
    classified_total = sum(counts[field] for field in COUNT_FIELDS if field != "total")
    if classified_total != total:
        errors.append(f"{_path(count_path)} classified counts must sum to total")
    if sampled != total:
        errors.append(f"{_path(path)}.sampled must equal counts.total for non-truncated release evidence")
    if isinstance(sample_limit, int) and not isinstance(sample_limit, bool) and sample_limit < total:
        errors.append(f"{_path(path)}.sampleLimit must be at least counts.total")

    for field in NON_SIGNAL_FIELDS:
        if counts[field] != 0:
            errors.append(f"{_path((*count_path, field))} must be 0 before the write-path gate is complete")
    if counts["signalRead"] != total:
        errors.append(f"{_path((*count_path, 'signalRead'))} must equal counts.total after migration drain")

    return errors


def validate_drain_evidence(data: Any, *, repo_root: Path | None = None) -> list[str]:
    errors: list[str] = []
    if not isinstance(data, dict):
        return ["evidence root must be a JSON object"]

    errors.extend(_unexpected_keys(data, TOP_LEVEL_KEYS, ()))
    if data.get("schemaVersion") != 1:
        errors.append(f"schemaVersion must be 1, found {data.get('schemaVersion')!r}")
    if data.get("privacy") != PRIVACY_MARKER:
        errors.append(f"privacy must be {PRIVACY_MARKER!r}")
    if not isinstance(data.get("generatedAt"), str) or not data.get("generatedAt", "").strip():
        errors.append("generatedAt must be a non-empty string")

    errors.extend(_validate_release(data.get("release"), repo_root=repo_root))
    errors.extend(_validate_write_path(data.get("writePath")))

    collections = data.get("collections")
    if not isinstance(collections, dict):
        errors.append("collections must be an object")
        return errors
    errors.extend(_unexpected_keys(collections, set(REQUIRED_COLLECTIONS), ("collections",)))

    missing = sorted(set(REQUIRED_COLLECTIONS).difference(collections))
    if missing:
        errors.append("collections missing required collection(s): " + ", ".join(missing))
    for name, expected_group in REQUIRED_COLLECTIONS.items():
        if name in collections:
            errors.extend(_validate_collection(name, collections[name], expected_group))

    return errors


def load_drain_evidence(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def check_drain_evidence(path: Path, *, repo_root: Path | None = None) -> list[str]:
    if not path.is_file():
        return [f"drain evidence file is missing: {path}"]
    try:
        data = load_drain_evidence(path)
    except json.JSONDecodeError as exc:
        return [f"drain evidence is not valid JSON: {exc}"]
    return validate_drain_evidence(data, repo_root=repo_root)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path, help="Aggregate Hermes Gateway migration-drain JSON evidence")
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path.cwd(),
        help="Repo root used to verify referenced dependency lock paths exist",
    )
    args = parser.parse_args(argv)

    errors = check_drain_evidence(args.path, repo_root=args.repo_root)
    if errors:
        print("FAIL: Hermes Gateway migration-drain evidence is invalid", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print(f"PASS: Hermes Gateway migration-drain evidence is valid: {args.path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
