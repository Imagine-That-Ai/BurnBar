from scripts.ci.write_burnbar_source_provenance import build_source_provenance_manifest, release_preflight_blockers


def test_source_provenance_manifest_covers_agpl_signal_release_inputs() -> None:
    manifest = build_source_provenance_manifest()

    assert manifest["schemaVersion"] == 1
    assert manifest["productLicense"] == "AGPL-3.0-only"
    assert manifest["sourceAvailability"] == "docs/legal/SOURCE_AVAILABILITY.md"
    assert manifest["libsignal"]["license"] == "AGPL-3.0-only"
    assert manifest["runtimeReadiness"]["status"] == "not_ready"
    assert "node_contracts" in manifest["runtimeReadiness"]["completeGates"]
    assert "swift_runtime" in manifest["runtimeReadiness"]["completeGates"]
    assert "kotlin_android_runtime" in manifest["runtimeReadiness"]["completeGates"]
    assert "source_bundle_provenance" in manifest["runtimeReadiness"]["completeGates"]
    assert "hermes_gateway_write_path" in manifest["runtimeReadiness"]["completeGates"]
    assert manifest["runtimeReadiness"]["incompleteGates"] == ["legal_release_review"]

    paths = {entry["path"] for entry in manifest["requiredSourceFiles"]}
    assert {
        "LICENSE",
        "THIRD_PARTY_NOTICES.md",
        "docs/legal/AGPL_RELEASE_REVIEW_PACKET.md",
        "docs/legal/agpl-release-review.evidence.template.json",
        "docs/legal/HERMES_GATEWAY_SIGNAL_REQUIRED_ROLLOUT.md",
        "OpenBurnBarCore/Package.swift",
        "OpenBurnBarCore/Sources/OpenBurnBarCore/CloudVaultCryptoError.swift",
        "OpenBurnBarCore/Sources/OpenBurnBarSignalCore/SignalEnvelopeAAD.swift",
        "OpenBurnBarCore/Sources/OpenBurnBarSignalCore/SignalIdentity.swift",
        "OpenBurnBarCore/Sources/OpenBurnBarSignalCore/SignalPrekeyPublication.swift",
        "OpenBurnBarCore/Sources/OpenBurnBarSignalCore/SignalPrekeyPublicationStore.swift",
        "OpenBurnBarCore/Tests/OpenBurnBarSignalCoreTests/SignalEnvelopeAADTests.swift",
        "OpenBurnBarCore/Tests/OpenBurnBarSignalCoreTests/SignalPrekeyPublicationTests.swift",
        "android/gradlew",
        "android/gradle/wrapper/gradle-wrapper.properties",
        "android/settings.gradle.kts",
        "android/build.gradle.kts",
        "android/app/build.gradle.kts",
        "android/app/src/main/java/com/openburnbar/data/cloud/AndroidCloudVaultSignalPayloads.kt",
        "android/app/src/main/java/com/openburnbar/data/cloud/AndroidSignalIdentity.kt",
        "android/app/src/main/java/com/openburnbar/data/cloud/AndroidSignalPrekeyDirectory.kt",
        "android/app/src/test/java/com/openburnbar/data/cloud/AndroidCloudVaultSignalPayloadsTest.kt",
        "android/app/src/test/java/com/openburnbar/data/cloud/AndroidSignalPrekeyDirectoryTest.kt",
        "packages/signal-envelope-contracts/lib/cloudVaultSignalEnvelope.cjs",
        "packages/signal-envelope-contracts/lib/index.cjs",
        "functions/lib/hermesGateway.js",
        "functions/lib/callables/hermesGateway.js",
        "functions/lib/__tests__/hermesGatewaySignalEnvelope.test.js",
        "scripts/ci/drain_hermes_gateway_legacy_records.js",
        "tests/test_hermes_gateway_signal_required_mode.py",
        "scripts/ci/check_agpl_legal_release_review.py",
        "scripts/ci/check_cloudvault_at_rest_runtime.py",
        "scripts/ci/check_functions_cloudvault_runtime.js",
        "scripts/ci/check_hermes_gateway_migration_drain.py",
        "scripts/ci/check_native_signal_runtime_evidence.py",
        "scripts/ci/rollout_hermes_gateway_signal_required.js",
        "scripts/ci/write_hermes_gateway_migration_drain_evidence.js",
        "tests/test_signal_envelope_contracts_cjs_exports.py",
        "tests/test_hermes_gateway_migration_drain_collector.py",
        "tests/test_hermes_gateway_legacy_drain.py",
        "tests/test_hermes_gateway_signal_required_rollout.py",
        "tests/test_hermes_gateway_signal_required_rollout_runbook.py",
        "tests/test_native_signal_runtime_evidence.py",
        "third_party/libsignal/runtime-readiness.json",
        "Vendor/libsignal/LICENSE",
        "Vendor/libsignal/rust/protocol/src/triple_ratchet.rs",
    }.issubset(paths)


def test_release_preflight_blocks_dirty_or_not_ready_manifest() -> None:
    manifest = {
        "git": {
            "dirty": True,
            "dirtyPaths": [" M README.md", "?? .secrets/"],
        },
        "runtimeReadiness": {
            "status": "not_ready",
            "incompleteGates": ["swift_runtime", "legal_release_review"],
        },
    }

    assert release_preflight_blockers(manifest) == [
        "git working tree must be clean for release provenance (2 dirty path(s))",
        "runtimeReadiness.status must be 'ready', found 'not_ready'",
        "runtimeReadiness has incomplete gate(s): swift_runtime, legal_release_review",
    ]


def test_release_preflight_passes_only_for_clean_ready_manifest() -> None:
    manifest = {
        "git": {
            "dirty": False,
            "dirtyPaths": [],
        },
        "runtimeReadiness": {
            "status": "ready",
            "incompleteGates": [],
        },
    }

    assert release_preflight_blockers(manifest) == []
