from __future__ import annotations

from copy import deepcopy
from datetime import datetime, timedelta, timezone
from typing import cast

import pytest

from scripts.ci.check_signal_migration_evidence import (
    COUNT_FIELDS,
    EXPECTED_COLLECTIONS,
    EXPECTED_PRODUCERS,
    validate_evidence,
)

NOW = datetime(2026, 8, 4, 12, 0, 0, tzinfo=timezone.utc)
SOURCE_COMMIT = "a" * 40


def counts() -> dict[str, int]:
    return {
        "totalWrites": 3,
        "createWrites": 2,
        "updateWrites": 1,
        "deleteWrites": 0,
        "signalSealedWrites": 3,
        "legacySealedWrites": 0,
        "mixedEnvelopeWrites": 0,
        "plaintextOnlyWrites": 0,
    }


def zero_counts() -> dict[str, int]:
    return {field: 0 for field in COUNT_FIELDS}


def add(target: dict[str, int], source: dict[str, int]) -> None:
    for field in COUNT_FIELDS:
        target[field] += source[field]


def valid_evidence() -> dict[str, object]:
    collections = sorted(EXPECTED_COLLECTIONS)
    producers = ["ios", "macos", "android", "unknown"]
    by_collection = {collection: counts() for collection in collections}
    by_producer = {producer: zero_counts() for producer in sorted(EXPECTED_PRODUCERS)}
    for index, collection in enumerate(collections):
        add(by_producer[producers[index % len(producers)]], by_collection[collection])
    totals = zero_counts()
    for item in by_collection.values():
        add(totals, item)
    return {
        "schemaVersion": 1,
        "evidenceKind": "aggregate_signal_migration_telemetry",
        "release": "v1.0.30",
        "projectId": "burnbar",
        "sourceCommit": SOURCE_COMMIT,
        "capturedAt": NOW.isoformat().replace("+00:00", "Z"),
        "window": {"start": "2026-08-01", "end": "2026-08-04", "timezone": "UTC"},
        "privacy": {
            "classification": "aggregate_only_no_user_or_content_data",
            "containsUserIdentifiers": False,
            "containsDocumentIdentifiersOrPaths": False,
            "containsPayloadCiphertextOrKeys": False,
            "producerBuckets": sorted(EXPECTED_PRODUCERS),
        },
        "requiredCollections": collections,
        "counterDocuments": len(collections),
        "totals": totals,
        "byCollection": by_collection,
        "byProducer": by_producer,
    }


def validate(payload: dict[str, object], now: datetime = NOW) -> None:
    validate_evidence(
        payload,
        release="v1.0.30",
        source_commit=SOURCE_COMMIT,
        min_content_writes=30,
        max_age_hours=72,
        now=now,
    )


def test_accepts_release_bound_aggregate_only_full_coverage() -> None:
    validate(valid_evidence())


def test_rejects_any_unapproved_field_even_when_counts_are_valid() -> None:
    payload = valid_evidence()
    payload["uid"] = "secret-user"
    with pytest.raises(ValueError, match="unapproved top-level"):
        validate(payload)

    payload = valid_evidence()
    by_collection = cast(dict[str, dict[str, object]], payload["byCollection"])
    by_collection["cli_sessions"]["documentPath"] = "users/u/cli_sessions/private"
    with pytest.raises(ValueError, match="approved aggregate counter fields"):
        validate(payload)


def test_rejects_non_signal_or_mixed_private_collection_traffic() -> None:
    payload = valid_evidence()
    by_collection = cast(dict[str, dict[str, int]], payload["byCollection"])
    row = by_collection["rollback_requests"]
    row["signalSealedWrites"] = 2
    row["legacySealedWrites"] = 1
    with pytest.raises(ValueError, match="100% Signal-sealed"):
        validate(payload)

    payload = valid_evidence()
    by_collection = cast(dict[str, dict[str, int]], payload["byCollection"])
    row = by_collection["approval_policies"]
    row["mixedEnvelopeWrites"] = 1
    with pytest.raises(ValueError, match="mixedEnvelopeWrites must be zero"):
        validate(payload)


def test_rejects_missing_collection_or_platform_coverage() -> None:
    payload = valid_evidence()
    by_collection = cast(dict[str, dict[str, int]], payload["byCollection"])
    row = by_collection["agent_identities"]
    for field in COUNT_FIELDS:
        row[field] = 0
    with pytest.raises(ValueError, match="no observed create/update traffic"):
        validate(payload)

    payload = valid_evidence()
    by_producer = cast(dict[str, dict[str, int]], payload["byProducer"])
    row = by_producer["android"]
    for field in COUNT_FIELDS:
        row[field] = 0
    with pytest.raises(ValueError, match="producer android has no Signal-sealed"):
        validate(payload)


def test_rejects_stale_or_wrong_source_evidence() -> None:
    payload = valid_evidence()
    with pytest.raises(ValueError, match="older than"):
        validate(payload, NOW + timedelta(hours=73))

    payload = valid_evidence()
    payload["sourceCommit"] = "b" * 40
    with pytest.raises(ValueError, match="does not match"):
        validate(payload)


def test_rejects_inconsistent_totals_and_low_traffic() -> None:
    payload = valid_evidence()
    totals = cast(dict[str, int], payload["totals"])
    totals["totalWrites"] = 29
    with pytest.raises(ValueError, match="operation counts"):
        validate(payload)

    payload = deepcopy(valid_evidence())
    with pytest.raises(ValueError, match="below required minimum"):
        validate_evidence(
            payload,
            release="v1.0.30",
            source_commit=SOURCE_COMMIT,
            min_content_writes=31,
            max_age_hours=72,
            now=NOW,
        )
