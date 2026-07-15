from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]

ANDROID_CLOUDVAULT_FACADE = ROOT / (
    "android/app/src/main/java/com/openburnbar/data/cloud/CloudVaultCrypto.kt"
)
ANDROID_CLOUDVAULT_LEGACY = ROOT / (
    "android/app/src/main/java/com/openburnbar/data/cloud/CloudVaultLegacyCrypto.kt"
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
