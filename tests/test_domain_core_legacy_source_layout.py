from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]

ANDROID_CLOUDVAULT_FACADE = ROOT / (
    "android/app/src/main/java/com/openburnbar/data/cloud/CloudVaultCrypto.kt"
)
ANDROID_CLOUDVAULT_LEGACY = ROOT / (
    "android/app/src/main/java/com/openburnbar/data/cloud/CloudVaultLegacyCrypto.kt"
)
ANDROID_REWRAP_LEGACY = ROOT / (
    "android/app/src/main/java/com/openburnbar/data/cloud/Legacy/"
    "CloudVaultLegacyDocumentRewrap.kt"
)
SWIFT_CLOUDVAULT_FACADE = ROOT / (
    "OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/CloudVaultCrypto.swift"
)
SWIFT_REWRAP_LEGACY = ROOT / (
    "OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/Legacy/"
    "CloudVaultLegacyDocumentRewrap.swift"
)
WINDOWS_CLOUDVAULT_LEGACY = ROOT / (
    "windows/cloudsync/OpenBurnBar.CloudSync.Crypto/Legacy/CloudVaultLegacyCrypto.cs"
)


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
