import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]

ANDROID_CLOUDVAULT_FACADE = ROOT / ("android/app/src/main/java/com/openburnbar/data/cloud/CloudVaultCrypto.kt")
ANDROID_CLOUDVAULT_LEGACY = ROOT / ("android/app/src/main/java/com/openburnbar/data/cloud/CloudVaultLegacyCrypto.kt")
ANDROID_REWRAP_LEGACY = ROOT / (
    "android/app/src/main/java/com/openburnbar/data/cloud/CloudVaultLegacyDocumentRewrap.kt"
)
SWIFT_CLOUDVAULT_FACADE = ROOT / ("OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/CloudVaultCrypto.swift")
SWIFT_REWRAP_LEGACY = ROOT / (
    "OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/Legacy/CloudVaultLegacyDocumentRewrap.swift"
)
WINDOWS_CLOUDVAULT_LEGACY = ROOT / ("windows/cloudsync/OpenBurnBar.CloudSync.Crypto/Legacy/CloudVaultLegacyCrypto.cs")
WINDOWS_PENSIEVE_ROOT = ROOT / "windows/app/OpenBurnBar.App.CloudSync"
WINDOWS_PENSIEVE_FACADE = WINDOWS_PENSIEVE_ROOT / "Pensieve/PensieveVectorCloak.cs"
WINDOWS_PENSIEVE_LEGACY = WINDOWS_PENSIEVE_ROOT / "Legacy/PensieveVectorLegacy.cs"
WINDOWS_PENSIEVE_BRIDGE = ROOT / ("windows/cloudsync/OpenBurnBar.CloudSync.Crypto/DomainCorePensieveVectorBridge.cs")


def test_android_cloudvault_rollback_primitives_are_path_addressable() -> None:
    facade = ANDROID_CLOUDVAULT_FACADE.read_text(encoding="utf-8")
    legacy = ANDROID_CLOUDVAULT_LEGACY.read_text(encoding="utf-8")

    forbidden_facade_declarations = (
        "fun legacyDeriveRecoveryWrappingKey(",
        "fun legacySplitEscrowWire(",
        "fun legacyEscrowSeal(",
        "fun legacyEscrowOpen(",
        "fun legacyRecoveryWrapVaultKey(",
        "fun legacyRecoveryOpenVaultKey(",
        "fun legacyAesSealCombined(",
        "fun legacyAesOpenCombined(",
    )
    assert not any(symbol in facade for symbol in forbidden_facade_declarations)

    required_legacy_declarations = (
        "fun recoveryWrappingKey(",
        "fun escrowSplitWire(",
        "fun escrowSeal(",
        "fun escrowOpen(",
        "fun recoveryWrapVaultKey(",
        "fun recoveryOpenVaultKey(",
        "fun recoveryVerificationHash(",
        "private fun aesSealCombined(",
        "private fun aesOpenCombined(",
    )
    assert all(symbol in legacy for symbol in required_legacy_declarations)
    assert "wrappingKey.fill(0)" in legacy


def test_windows_opaque_hmac_fallback_has_a_shared_legacy_owner() -> None:
    legacy = WINDOWS_CLOUDVAULT_LEGACY.read_text(encoding="utf-8")

    assert "internal static string PensieveKeyedHmacHex(" in legacy


def test_windows_pensieve_non_legacy_sources_route_normalization_through_rust() -> None:
    facade = WINDOWS_PENSIEVE_FACADE.read_text(encoding="utf-8")
    bridge = WINDOWS_PENSIEVE_BRIDGE.read_text(encoding="utf-8")
    legacy = WINDOWS_PENSIEVE_LEGACY.read_text(encoding="utf-8")

    assert "DomainCorePensieveVectorBridge.Normalize(" in facade
    assert "() => PensieveVectorLegacy.Normalize(vector)" in facade
    assert "public static double[] Normalize(" in bridge
    assert "DomainCore.PensieveL2Normalize(vector.ToList()).ToArray()" in bridge
    assert '"pensieve_l2_normalize"' in bridge

    non_legacy_sources = "\n".join(
        path.read_text(encoding="utf-8")
        for path in WINDOWS_PENSIEVE_ROOT.rglob("*.cs")
        if "Legacy" not in path.relative_to(WINDOWS_PENSIEVE_ROOT).parts
    )
    hand_ported_markers = (
        "normSquared += vector[index] * vector[index]",
        "result[index] = vector[index] / norm",
        "private static double[][] DeriveReflections(",
        "private static byte[] HkdfKeyStream(",
    )
    assert not any(marker in non_legacy_sources for marker in hand_ported_markers)
    assert all(marker in legacy for marker in hand_ported_markers)


def test_pensieve_policy_consumers_match_exact_deletion_owners() -> None:
    policy = json.loads((ROOT / "config/domain-core-promotion-policy.json").read_text(encoding="utf-8"))
    ledger = json.loads((ROOT / "config/domain-core-legacy-deletion.json").read_text(encoding="utf-8"))
    owners = {
        "apple": (
            "swift-vector",
            "OpenBurnBarCore/Sources/OpenBurnBarVectorKit/Legacy/PensieveVectorLegacy.swift",
        ),
        "windows": (
            "windows-cloudsync",
            "windows/app/OpenBurnBar.App.CloudSync/Legacy/PensieveVectorLegacy.cs",
        ),
        "console": (
            "console-cloudvault",
            "apps/console/lib/legacy/pensieveVectorLegacy.ts",
        ),
        "remote-mcp": (
            "remote-mcp",
            "tools/openburnbar-mcp-remote/src/legacy/pensieveVectorLegacy.ts",
        ),
    }

    coverage = policy["domains"]["cloudvault"]["requiredCoverage"]
    consumers = {item["consumer"] for item in coverage if item["slice"] == "pensieve-vectors"}
    assert consumers == set(owners)

    row = next(item for item in ledger["rows"] if item["id"] == "cloudvault.portable_primitives")
    path_targets = {
        (target["root"], target["path"])
        for target in row["targets"]
        if target["kind"] == "path" and "pensievevectorlegacy" in target["path"].casefold()
    }
    assert path_targets == set(owners.values())


def test_document_rewrap_fallbacks_are_whole_file_deletion_targets() -> None:
    android_facade = ANDROID_CLOUDVAULT_FACADE.read_text(encoding="utf-8")
    android_legacy = ANDROID_REWRAP_LEGACY.read_text(encoding="utf-8")
    swift_facade = SWIFT_CLOUDVAULT_FACADE.read_text(encoding="utf-8")
    swift_legacy = SWIFT_REWRAP_LEGACY.read_text(encoding="utf-8")

    forbidden_facade_declarations = (
        "private fun rewrapCloudVaultDocumentLegacy(",
        "private fun openTextForRewrap(",
        "private fun openBlobForRewrap(",
        "private fun openPayloadForRewrap(",
        "private static func rewrapCloudVaultDocumentLegacy(",
        "private static func openTextForRewrap(",
        "private static func openBlobForRewrap(",
        "private static func openPayloadForRewrap(",
        "private static func sealText(",
        "private static func sealBlob(",
        "private static func sealPayload(",
        "private fun applyVaultKeyCompanionUpdates(",
        "private static func applyVaultKeyCompanionUpdates(",
    )
    assert not any(symbol in android_facade for symbol in forbidden_facade_declarations)
    assert not any(symbol in swift_facade for symbol in forbidden_facade_declarations)

    assert "CloudVaultLegacyDocumentRewrap.rewrapCloudVaultDocumentLegacy(" in android_facade
    assert "CloudVaultLegacyDocumentRewrap.rewrapCloudVaultDocumentLegacy(" in swift_facade
    assert "fun rewrapCloudVaultDocumentLegacy(" in android_legacy
    assert "func rewrapCloudVaultDocumentLegacy(" in swift_legacy
    assert "private fun applyVaultKeyCompanionUpdates(" in android_legacy
    assert "private static func applyVaultKeyCompanionUpdates(" in swift_legacy

    # Android rewrap deletion removes orchestration only. AES remains a separately
    # promoted slice, reached through the typed facade rather than duplicated here.
    android_aes_helpers = (
        "CloudVaultCrypto.sealPayloadWithNonce(",
        "CloudVaultCrypto.sealTextWithNonce(",
        "CloudVaultCrypto.sealBlobWithNonce(",
    )
    assert all(call in android_legacy for call in android_aes_helpers)
    assert all(call.removeprefix("CloudVaultCrypto.") in android_facade for call in android_aes_helpers)
