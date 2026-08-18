package com.openburnbar.data.cloud

internal object CloudVaultLegacyRecovery {
    private const val KEY_BYTES = 32
    private const val RECOVERY_SALT = "OpenBurnBar-Recovery-Salt-v1"
    private const val RECOVERY_WRAP_INFO = "OpenBurnBar-Recovery-Wrap-v1"

    fun recoveryWrappingKey(recoveryKey: String): ByteArray {
        val normalized = recoveryKey.uppercase().filter { it.isLetterOrDigit() }
        require(normalized.length >= 20) { "Recovery key is too short" }
        return CloudVaultLegacySearch.hkdfSha256(
            normalized.toByteArray(Charsets.UTF_8),
            RECOVERY_SALT.toByteArray(Charsets.UTF_8),
            RECOVERY_WRAP_INFO.toByteArray(Charsets.UTF_8),
            KEY_BYTES,
        )
    }

    fun recoveryWrapVaultKey(vaultKey: ByteArray, recoveryKey: String, nonce: ByteArray, sha256Hex: (ByteArray) -> String): CloudVaultRecoveryBox {
        val wrappingKey = recoveryWrappingKey(recoveryKey)
        return try {
            CloudVaultRecoveryBox(
                combined = CloudVaultLegacyCrypto.aesSealCombined(vaultKey, wrappingKey, nonce),
                verificationHash = sha256Hex(wrappingKey),
            )
        } finally {
            wrappingKey.fill(0)
        }
    }

    fun recoveryOpenVaultKey(combined: ByteArray, recoveryKey: String): ByteArray {
        val wrappingKey = recoveryWrappingKey(recoveryKey)
        return try {
            CloudVaultLegacyCrypto.aesOpenCombined(combined, wrappingKey)
        } finally {
            wrappingKey.fill(0)
        }
    }

    fun recoveryVerificationHash(recoveryKey: String, sha256Hex: (ByteArray) -> String): String {
        val wrappingKey = recoveryWrappingKey(recoveryKey)
        return try {
            sha256Hex(wrappingKey)
        } finally {
            wrappingKey.fill(0)
        }
    }
}
