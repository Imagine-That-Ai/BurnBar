import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LEDGER = ROOT / "config" / "domain-core-legacy-deletion.json"


def _target_paths(row: dict[str, object]) -> set[str]:
    return {
        target["path"]
        for target in row["targets"]
        if target["role"] == "legacy_implementation"
    }


def _target_symbols(row: dict[str, object]) -> set[tuple[str, str]]:
    return {
        (target["path"], target["symbol"])
        for target in row["targets"]
        if target["role"] == "legacy_implementation" and target["kind"] == "source_symbol"
    }


def test_source_distributed_consumers_are_owned_by_the_deletion_ledger() -> None:
    ledger = json.loads(LEDGER.read_text())
    rows = {row["id"]: row for row in ledger["rows"]}

    assert {
        "swift-vector",
        "windows-cloudsync",
        "android-square",
        "local-mcp",
        "remote-mcp",
        "hermes-plugin",
    } <= ledger["sourceRoots"].keys()

    portable = _target_paths(rows["cloudvault.portable_primitives"])
    assert {
        "OpenBurnBarCore/Sources/OpenBurnBarVectorKit/Legacy/PensieveVectorLegacy.swift",
        "windows/app/OpenBurnBar.App.CloudSync/Legacy/PensieveVectorLegacy.cs",
        "apps/console/lib/legacy/pensieveVectorLegacy.ts",
        "android/app/src/main/java/com/openburnbar/data/square/AgentSubscriptionTopicDocumentIDLegacy.kt",
        "tools/openburnbar-mcp/cloudvault_primitives_legacy.py",
        "tools/openburnbar-mcp-remote/src/legacy/cloudVaultPrimitivesLegacy.ts",
        "tools/openburnbar-mcp-remote/src/legacy/pensieveVectorLegacy.ts",
    } <= portable
    assert (
        "OpenBurnBarCore/Sources/OpenBurnBarVectorKit/SharedModels/PensieveVectorCloak.swift",
        "legacyNormalize",
    ) in _target_symbols(rows["cloudvault.portable_primitives"])

    search = _target_paths(rows["cloudvault.search"])
    assert {
        "tools/openburnbar-mcp/cloudvault_search_legacy.py",
        "tools/openburnbar-mcp-remote/src/legacy/cloudVaultSearchLegacy.ts",
    } <= search

    ratchet = _target_paths(rows["hermes.ratchet_transforms"])
    assert "tools/hermes-platform-burnbar/legacy/hermes_ratchet_legacy.py" in ratchet


def test_source_distributed_consumers_keep_named_rollback_controls() -> None:
    ledger = json.loads(LEDGER.read_text())
    shared = {
        (tuple(item["rowIds"]), item["target"]["path"], item["target"].get("literal"))
        for item in ledger["sharedTargets"]
    }
    assert (
        ("cloudvault.portable_primitives", "cloudvault.search"),
        "tools/openburnbar-mcp/domain_core_cloudvault.py",
        "OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE",
    ) in shared
    assert (
        ("cloudvault.portable_primitives", "cloudvault.search"),
        "tools/openburnbar-mcp-remote/src/domainCoreCloudVault.ts",
        "OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE",
    ) in shared

    rows = {row["id"]: row for row in ledger["rows"]}
    portable_controls = {
        (target["path"], target.get("literal"))
        for target in rows["cloudvault.portable_primitives"]["targets"]
        if target["role"] == "rollback_control"
    }
    assert (
        "tools/openburnbar-mcp-remote/src/domainCoreOpaqueIdentifiers.ts",
        "OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE",
    ) in portable_controls

    hermes_controls = {
        (target["path"], target.get("literal"))
        for target in rows["hermes.ratchet_transforms"]["targets"]
        if target["role"] == "rollback_control"
    }
    assert (
        "tools/hermes-platform-burnbar/domain_core_hermes.py",
        "OPENBURNBAR_DOMAIN_CORE_HERMES_MODE",
    ) in hermes_controls
