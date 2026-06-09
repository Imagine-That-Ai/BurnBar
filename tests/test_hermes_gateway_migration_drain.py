from scripts.ci.check_hermes_gateway_migration_drain import validate_drain_evidence


def clean_evidence() -> dict[str, object]:
    def collection(name: str) -> dict[str, object]:
        return {
            "collectionGroup": name,
            "sampleLimit": 50,
            "sampled": 2,
            "truncated": False,
            "counts": {
                "total": 2,
                "signalRead": 2,
                "legacyHermesRelayRead": 0,
                "legacyHermesRatchetRead": 0,
                "legacyPlaintextRead": 0,
                "unreadable": 0,
            },
        }

    return {
        "schemaVersion": 1,
        "generatedAt": "2026-06-06T00:00:00Z",
        "privacy": "aggregate_counts_only_no_document_values_or_identifiers",
        "release": {
            "deployedCommit": "0123456789abcdef0123456789abcdef01234567",
            "sourceLocation": "https://example.com/openburnbar/source/0123456789abcdef0123456789abcdef01234567",
            "sourceAvailability": "docs/legal/SOURCE_AVAILABILITY.md",
            "dependencyLocks": ["functions/package-lock.json", "packages/signal-envelope-contracts/package-lock.json"],
        },
        "writePath": {
            "signalRequired": True,
            "signalEnvelopeWritesEnabled": True,
            "legacyRelayWritesEnabled": False,
            "legacyRatchetWritesEnabled": False,
            "legacyPlaintextWritesEnabled": False,
            "modeSource": "OPENBURNBAR_GATEWAY_SIGNAL_REQUIRED=true release env readback",
            "services": [
                {
                    "service": "burnbarhermesgateway",
                    "latestReadyRevision": "burnbarhermesgateway-00001-test",
                    "url": "https://burnbarhermesgateway.example.com",
                    "signalRequired": True,
                },
                {
                    "service": "enqueuehermesgatewayevent",
                    "latestReadyRevision": "enqueuehermesgatewayevent-00001-test",
                    "url": "https://enqueuehermesgatewayevent.example.com",
                    "signalRequired": True,
                },
            ],
        },
        "collections": {
            "events": collection("hermes_gateway_events"),
            "messages": collection("hermes_gateway_messages"),
            "attachments": collection("hermes_gateway_attachments"),
        },
    }


def test_validates_clean_aggregate_only_drain_evidence() -> None:
    assert validate_drain_evidence(clean_evidence()) == []


def test_rejects_legacy_plaintext_or_unreadable_records() -> None:
    data = clean_evidence()
    events = data["collections"]["events"]  # type: ignore[index]
    counts = events["counts"]  # type: ignore[index]
    counts["total"] = 3  # type: ignore[index]
    counts["signalRead"] = 2  # type: ignore[index]
    counts["legacyPlaintextRead"] = 1  # type: ignore[index]
    events["sampled"] = 3  # type: ignore[index]

    errors = validate_drain_evidence(data)

    assert "collections.events.counts.legacyPlaintextRead must be 0 before the write-path gate is complete" in errors
    assert "collections.events.counts.signalRead must equal counts.total after migration drain" in errors


def test_rejects_document_level_fields() -> None:
    data = clean_evidence()
    data["documentIds"] = ["users/alice/messages/1"]

    assert validate_drain_evidence(data) == ["root has unexpected key: documentIds"]


def test_rejects_missing_release_record() -> None:
    data = clean_evidence()
    del data["release"]

    assert validate_drain_evidence(data) == ["release must be an object"]


def test_rejects_non_signal_required_write_path() -> None:
    data = clean_evidence()
    data["writePath"] = {
        "signalRequired": False,
        "signalEnvelopeWritesEnabled": False,
        "legacyRelayWritesEnabled": True,
        "legacyRatchetWritesEnabled": True,
        "legacyPlaintextWritesEnabled": False,
        "modeSource": "",
        "services": [
            {
                "service": "burnbarhermesgateway",
                "latestReadyRevision": "burnbarhermesgateway-00001-test",
                "url": "https://burnbarhermesgateway.example.com",
                "signalRequired": False,
            }
        ],
    }

    errors = validate_drain_evidence(data)

    assert "writePath.signalRequired must be true before the write-path gate is complete" in errors
    assert "writePath.signalEnvelopeWritesEnabled must be true before the write-path gate is complete" in errors
    assert "writePath.legacyRelayWritesEnabled must be false before the write-path gate is complete" in errors
    assert "writePath.legacyRatchetWritesEnabled must be false before the write-path gate is complete" in errors
    assert "writePath.modeSource must describe the deployed Signal-required mode readback" in errors
    assert "writePath.services.0.signalRequired must be true before the write-path gate is complete" in errors
    assert "writePath.services missing required gateway service(s): enqueuehermesgatewayevent" in errors


def test_rejects_incomplete_hosted_release_metadata() -> None:
    data = clean_evidence()
    data["release"] = {
        "deployedCommit": "not-a-sha",
        "sourceLocation": "file:///private/source",
        "sourceAvailability": "README.md",
        "dependencyLocks": ["functions/package-lock.json"],
    }

    errors = validate_drain_evidence(data)

    assert "release.deployedCommit must be a 40-character lowercase git commit SHA" in errors
    assert "release.sourceLocation must be an https:// source URL users can access" in errors
    assert "release.sourceAvailability must be 'docs/legal/SOURCE_AVAILABILITY.md'" in errors
    assert "release.dependencyLocks missing required lockfile(s): packages/signal-envelope-contracts/package-lock.json" in errors


def test_validates_dependency_lock_paths_exist_when_repo_root_is_supplied(tmp_path) -> None:
    data = clean_evidence()

    errors = validate_drain_evidence(data, repo_root=tmp_path)

    assert "release.dependencyLocks path does not exist: functions/package-lock.json" in errors
    assert (
        "release.dependencyLocks path does not exist: packages/signal-envelope-contracts/package-lock.json" in errors
    )


def test_rejects_truncated_sample_evidence() -> None:
    data = clean_evidence()
    events = data["collections"]["events"]  # type: ignore[index]
    events["truncated"] = True  # type: ignore[index]
    events["sampled"] = 1  # type: ignore[index]

    errors = validate_drain_evidence(data)

    assert "collections.events.truncated must be false for release evidence" in errors
    assert "collections.events.sampled must equal counts.total for non-truncated release evidence" in errors
