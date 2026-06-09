from pathlib import Path

from scripts.ci.write_burnbar_source_provenance import (
    REQUIRED_SOURCE_PATHS,
    build_source_provenance_manifest,
    release_preflight_blockers,
)

REPO_ROOT = Path(__file__).resolve().parents[1]


def test_source_provenance_manifest_covers_agpl_signal_release_inputs() -> None:
    manifest = build_source_provenance_manifest(repo_root=REPO_ROOT)

    assert manifest["schemaVersion"] == 1
    assert manifest["productLicense"] == "AGPL-3.0-only"
    assert manifest["sourceAvailability"] == "docs/legal/SOURCE_AVAILABILITY.md"
    assert manifest["libsignal"]["license"] == "AGPL-3.0-only"
    assert manifest["runtimeReadiness"]["status"] == "not_ready"
    assert "node_contracts" in manifest["runtimeReadiness"]["completeGates"]
    assert "swift_round_trips" in manifest["runtimeReadiness"]["completeGates"]
    assert "kotlin_round_trips" in manifest["runtimeReadiness"]["completeGates"]
    # Launch stays fail-closed until counsel signs off.
    assert "store_and_counsel_approval" in manifest["runtimeReadiness"]["incompleteGates"]

    paths = {entry["path"] for entry in manifest["requiredSourceFiles"]}
    assert {
        "LICENSE",
        "THIRD_PARTY_NOTICES.md",
        "docs/legal/AGPL_RELEASE_REVIEW_PACKET.md",
        "docs/legal/agpl-release-review.evidence.template.json",
        "docs/legal/HERMES_GATEWAY_SIGNAL_REQUIRED_ROLLOUT.md",
        "OpenBurnBarCore/Package.swift",
        "OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CloudVaultCrypto.swift",
        "OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/SignalEnvelopeAAD.swift",
        "OpenBurnBarCore/Sources/OpenBurnBarSignalCore/OBBSignalProtocolStore.swift",
        "OpenBurnBarCore/Sources/OpenBurnBarSignalCore/SignalAtRestSealer.swift",
        "OpenBurnBarCore/Tests/OpenBurnBarCoreTests/SignalEnvelopeAADTests.swift",
        "OpenBurnBarCore/Tests/OpenBurnBarSignalCoreTests/CryptoKitAtRestInteropTests.swift",
        "android/app/src/main/java/com/openburnbar/data/cloud/CloudVaultCrypto.kt",
        "android/app/src/main/java/com/openburnbar/data/cloud/signalsession/AndroidSignalProtocolStore.kt",
        "packages/signal-envelope-contracts/src/cloudVaultSignalEnvelope.ts",
        "packages/signal-envelope-contracts/package-lock.json",
        "functions/src/hermesGateway.ts",
        "functions/package-lock.json",
        "scripts/ci/drain_hermes_gateway_legacy_records.js",
        "scripts/ci/check_hermes_gateway_migration_drain.py",
        "tests/test_hermes_gateway_signal_required_rollout.py",
        "third_party/libsignal/runtime-readiness.json",
        "Vendor/libsignal/LICENSE",
        "Vendor/libsignal/rust/protocol/src/triple_ratchet.rs",
    }.issubset(paths)


def test_required_source_paths_are_committed_sources_not_build_output() -> None:
    # Gitignored build output (functions/lib, packages/*/lib) can never be a
    # provenance input — CI does not build before this gate runs.
    for rel_path in REQUIRED_SOURCE_PATHS:
        assert "/lib/" not in rel_path, f"provenance must hash committed sources, not build output: {rel_path}"

    # The repo root is the MIT upstream graft point: no root manifests.
    assert "package-lock.json" not in REQUIRED_SOURCE_PATHS
    assert "pyproject.toml" not in REQUIRED_SOURCE_PATHS


def test_every_required_source_path_exists() -> None:
    missing = [rel for rel in REQUIRED_SOURCE_PATHS if not (REPO_ROOT / rel).is_file()]
    assert missing == []


def test_release_preflight_blocks_dirty_or_not_ready_manifest() -> None:
    manifest = {
        "git": {
            "dirty": True,
            "dirtyPaths": [" M README.md", "?? .secrets/"],
        },
        "runtimeReadiness": {
            "status": "not_ready",
            "incompleteGates": ["rust_core_bridge", "store_and_counsel_approval"],
        },
    }

    assert release_preflight_blockers(manifest) == [
        "git working tree must be clean for release provenance (2 dirty path(s))",
        "runtimeReadiness.status must be 'ready', found 'not_ready'",
        "runtimeReadiness has incomplete gate(s): rust_core_bridge, store_and_counsel_approval",
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
