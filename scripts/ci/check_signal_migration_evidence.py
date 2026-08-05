#!/usr/bin/env python3
"""Fail-closed validator for aggregate-only Signal migration evidence."""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

EXPECTED_COLLECTIONS = {
    "conversations",
    "chat_threads",
    "mobile_assistant_chats",
    "cli_sessions",
    "cli_agent_mission_requests",
    "text_snippets",
    "rollback_requests",
    "approval_policies",
    "agent_identities",
    "subscription_topics",
}
EXPECTED_PRODUCERS = {"ios", "macos", "android", "unknown"}
COUNT_FIELDS = {
    "totalWrites",
    "createWrites",
    "updateWrites",
    "deleteWrites",
    "signalSealedWrites",
    "legacySealedWrites",
    "mixedEnvelopeWrites",
    "plaintextOnlyWrites",
}
SHA_RE = re.compile(r"^[0-9a-f]{40}$")


def fail(message: str) -> None:
    raise ValueError(message)


def require_record(raw: Any, label: str) -> dict[str, Any]:
    if not isinstance(raw, dict):
        fail(f"{label} must be an object")
    return raw


def require_count(record: dict[str, Any], field: str, label: str) -> int:
    value = record.get(field)
    if type(value) is not int or value < 0:
        fail(f"{label}.{field} must be a non-negative integer")
    assert isinstance(value, int)
    return value


def parse_time(raw: Any, label: str) -> datetime:
    if not isinstance(raw, str) or not raw.endswith("Z"):
        fail(f"{label} must be a UTC ISO-8601 timestamp")
    try:
        parsed = datetime.fromisoformat(raw[:-1] + "+00:00")
    except ValueError as error:
        raise ValueError(f"{label} is invalid: {error}") from error
    if parsed.tzinfo != UTC:
        fail(f"{label} must use UTC")
    return parsed


def validate_counts(record: dict[str, Any], label: str) -> dict[str, int]:
    if set(record) != COUNT_FIELDS:
        fail(f"{label} must contain only the approved aggregate counter fields")
    counts = {field: require_count(record, field, label) for field in COUNT_FIELDS}
    if counts["totalWrites"] != counts["createWrites"] + counts["updateWrites"] + counts["deleteWrites"]:
        fail(f"{label} operation counts do not sum to totalWrites")
    content_writes = counts["createWrites"] + counts["updateWrites"]
    if counts["signalSealedWrites"] > content_writes:
        fail(f"{label}.signalSealedWrites exceeds create+update writes")
    return counts


def add_counts(target: dict[str, int], source: dict[str, int]) -> None:
    for field in COUNT_FIELDS:
        target[field] += source[field]


def zero_counts() -> dict[str, int]:
    return {field: 0 for field in COUNT_FIELDS}


def validate_evidence(
    payload: dict[str, Any],
    *,
    release: str,
    source_commit: str,
    min_content_writes: int,
    max_age_hours: int,
    now: datetime | None = None,
) -> None:
    expected_top_level = {
        "schemaVersion",
        "evidenceKind",
        "release",
        "projectId",
        "sourceCommit",
        "capturedAt",
        "window",
        "privacy",
        "requiredCollections",
        "counterDocuments",
        "totals",
        "byCollection",
        "byProducer",
    }
    if set(payload) != expected_top_level:
        fail("evidence contains missing or unapproved top-level fields")
    if payload.get("schemaVersion") != 1:
        fail("schemaVersion must be 1")
    if payload.get("evidenceKind") != "aggregate_signal_migration_telemetry":
        fail("evidenceKind must be aggregate_signal_migration_telemetry")
    if payload.get("release") != release:
        fail(f"release must be {release}")
    if payload.get("projectId") != "burnbar":
        fail("projectId must be the production project burnbar")
    if not SHA_RE.fullmatch(source_commit):
        fail("expected source commit must be a lowercase 40-character git SHA")
    if payload.get("sourceCommit") != source_commit:
        fail("sourceCommit does not match the release source commit")

    captured_at = parse_time(payload.get("capturedAt"), "capturedAt")
    current = now or datetime.now(UTC)
    if captured_at > current + timedelta(minutes=5):
        fail("capturedAt is in the future")
    if current - captured_at > timedelta(hours=max_age_hours):
        fail(f"evidence is older than {max_age_hours} hours")

    window = require_record(payload.get("window"), "window")
    if set(window) != {"start", "end", "timezone"}:
        fail("window contains missing or unapproved fields")
    if window.get("timezone") != "UTC":
        fail("window.timezone must be UTC")
    for key in ("start", "end"):
        value = window.get(key)
        if not isinstance(value, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
            fail(f"window.{key} must use YYYY-MM-DD")
    if window["end"] < window["start"]:
        fail("window.end precedes window.start")

    privacy = require_record(payload.get("privacy"), "privacy")
    if set(privacy) != {
        "classification",
        "containsUserIdentifiers",
        "containsDocumentIdentifiersOrPaths",
        "containsPayloadCiphertextOrKeys",
        "producerBuckets",
    }:
        fail("privacy contains missing or unapproved fields")
    if privacy.get("classification") != "aggregate_only_no_user_or_content_data":
        fail("privacy.classification is invalid")
    for field in (
        "containsUserIdentifiers",
        "containsDocumentIdentifiersOrPaths",
        "containsPayloadCiphertextOrKeys",
    ):
        if privacy.get(field) is not False:
            fail(f"privacy.{field} must be false")
    if set(privacy.get("producerBuckets", [])) != EXPECTED_PRODUCERS:
        fail("privacy.producerBuckets must contain only ios/macos/android/unknown")
    if set(payload.get("requiredCollections", [])) != EXPECTED_COLLECTIONS:
        fail("requiredCollections does not match the ten private collections")
    if not isinstance(payload.get("counterDocuments"), int) or payload["counterDocuments"] <= 0:
        fail("counterDocuments must be positive")

    by_collection = require_record(payload.get("byCollection"), "byCollection")
    if set(by_collection) != EXPECTED_COLLECTIONS:
        fail("byCollection keys do not match requiredCollections")
    collection_sum = zero_counts()
    for collection in sorted(EXPECTED_COLLECTIONS):
        counts = validate_counts(require_record(by_collection[collection], f"byCollection.{collection}"), f"byCollection.{collection}")
        content_writes = counts["createWrites"] + counts["updateWrites"]
        if content_writes <= 0:
            fail(f"{collection} has no observed create/update traffic")
        if counts["signalSealedWrites"] != content_writes:
            fail(f"{collection} is not at 100% Signal-sealed create/update coverage")
        for forbidden in ("legacySealedWrites", "mixedEnvelopeWrites", "plaintextOnlyWrites"):
            if counts[forbidden] != 0:
                fail(f"{collection}.{forbidden} must be zero")
        add_counts(collection_sum, counts)

    totals = validate_counts(require_record(payload.get("totals"), "totals"), "totals")
    if totals != collection_sum:
        fail("totals do not equal the sum of byCollection")
    total_content = totals["createWrites"] + totals["updateWrites"]
    if total_content < min_content_writes:
        fail(f"observed content writes {total_content} is below required minimum {min_content_writes}")

    by_producer = require_record(payload.get("byProducer"), "byProducer")
    if set(by_producer) != EXPECTED_PRODUCERS:
        fail("byProducer keys must contain only ios/macos/android/unknown")
    producer_sum = zero_counts()
    for producer in sorted(EXPECTED_PRODUCERS):
        counts = validate_counts(require_record(by_producer[producer], f"byProducer.{producer}"), f"byProducer.{producer}")
        if producer != "unknown" and counts["signalSealedWrites"] <= 0:
            fail(f"producer {producer} has no Signal-sealed production traffic")
        add_counts(producer_sum, counts)
    if producer_sum != totals:
        fail("byProducer does not sum to totals")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path)
    parser.add_argument("--release", required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--min-content-writes", type=int, default=30)
    parser.add_argument("--max-age-hours", type=int, default=72)
    args = parser.parse_args()
    try:
        payload = json.loads(args.evidence.read_text(encoding="utf-8"))
        validate_evidence(
            require_record(payload, "evidence"),
            release=args.release,
            source_commit=args.source_commit,
            min_content_writes=args.min_content_writes,
            max_age_hours=args.max_age_hours,
        )
    except (OSError, json.JSONDecodeError, ValueError) as error:
        print(f"FAIL: Signal migration evidence: {error}", file=sys.stderr)
        return 1
    print("PASS: aggregate-only Signal migration evidence is release-bound and 100% sealed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
