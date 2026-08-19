package com.openburnbar.data.cloud

import java.security.MessageDigest
import java.security.spec.ECParameterSpec
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

private const val GCM_NONCE_BYTES = 12
private const val GCM_TAG_BYTES = 16
private const val KEY_BYTES = 32

internal object CloudVaultLegacyCrypto {
    private const val GCM_AUTH_TAG_BITS = 128
    private const val BYTE_MASK = 0xff
    private const val HMAC_SALT = "OpenBurnBar-CloudVault-HMAC-Salt-v1"
    private const val HMAC_INFO_PREFIX = "OpenBurnBar-CloudVault-HMAC-v1"
    private const val ESCROW_HKDF_INFO = "OpenBurnBar-Escrow-v1"
    private const val ESCROW_PUBLIC_KEY_BYTES = 65
    private const val RECOVERY_SALT = "OpenBurnBar-Recovery-Salt-v1"
    private const val RECOVERY_WRAP_INFO = "OpenBurnBar-Recovery-Wrap-v1"

    fun sha256Hex(data: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(data).toHex()

    fun vaultKeyId(key: ByteArray): String {
        CloudVaultLegacyValidation.requireVaultKey(key)
        return "v1_${sha256Hex(key).take(32)}"
    }

    fun keyedHashHex(data: ByteArray, key: ByteArray, purpose: CloudVaultHashPurpose): String {
        CloudVaultLegacyValidation.requireVaultKey(key)
        val derivedKey = CloudVaultLegacySearch.hkdfSha256(
            key,
            HMAC_SALT.toByteArray(Charsets.UTF_8),
            "$HMAC_INFO_PREFIX|${purpose.wireValue}".toByteArray(Charsets.UTF_8),
            KEY_BYTES,
        )
        return try {
            val mac = Mac.getInstance("HmacSHA256")
            mac.init(SecretKeySpec(derivedKey, "HmacSHA256"))
            mac.doFinal(data).toHex()
        } finally {
            derivedKey.fill(0)
        }
    }

    fun expectedSessionBodyHash(data: ByteArray, key: ByteArray, bodyHashVersion: Int): String = when (bodyHashVersion) {
        CloudVaultCrypto.SESSION_BODY_HASH_VERSION -> keyedHashHex(data, key, CloudVaultHashPurpose.SESSION_BODY)
        0, 1 -> sha256Hex(data)
        else -> error("Unsupported session body hash version")
    }

    fun escrowSplitWire(ciphertext: ByteArray, ecParameters: ECParameterSpec): CloudVaultEscrowParts {
        require(ciphertext.size > ESCROW_PUBLIC_KEY_BYTES) { "Invalid wrapped vault key" }
        val publicKey = ciphertext.copyOfRange(0, ESCROW_PUBLIC_KEY_BYTES)
        CloudVaultCryptoSupport.publicKeyFromX963(publicKey, ecParameters)
        return CloudVaultEscrowParts(publicKey, ciphertext.copyOfRange(ESCROW_PUBLIC_KEY_BYTES, ciphertext.size))
    }

    fun escrowSeal(plaintext: ByteArray, ephemeralPublicKey: ByteArray, sharedSecret: ByteArray, nonce: ByteArray): ByteArray {
        val wrappingKey = escrowWrappingKey(sharedSecret)
        return try {
            ephemeralPublicKey + aesSealCombined(plaintext, wrappingKey, nonce)
        } finally {
            wrappingKey.fill(0)
        }
    }

    fun escrowOpen(combined: ByteArray, sharedSecret: ByteArray): ByteArray = escrowOpen(combined, sharedSecret, ByteArray(0))

    fun escrowOpen(combined: ByteArray, sharedSecret: ByteArray, aad: ByteArray): ByteArray {
        val wrappingKey = escrowWrappingKey(sharedSecret)
        return try {
            if (aad.isEmpty()) {
                aesOpenCombined(combined, wrappingKey)
            } else {
                aesOpenCombined(combined, wrappingKey, aad)
            }
        } finally {
            wrappingKey.fill(0)
        }
    }

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
                combined = aesSealCombined(vaultKey, wrappingKey, nonce),
                verificationHash = sha256Hex(wrappingKey),
            )
        } finally {
            wrappingKey.fill(0)
        }
    }

    fun recoveryOpenVaultKey(combined: ByteArray, recoveryKey: String): ByteArray {
        val wrappingKey = recoveryWrappingKey(recoveryKey)
        return try {
            aesOpenCombined(combined, wrappingKey)
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

    fun aesSealDetached(plaintext: ByteArray, key: ByteArray, nonce: ByteArray, aad: ByteArray): CloudVaultAesDetachedBox {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(GCM_AUTH_TAG_BITS, nonce))
        if (aad.isNotEmpty()) cipher.updateAAD(aad)
        val ciphertextAndTag = cipher.doFinal(plaintext)
        val split = ciphertextAndTag.size - GCM_TAG_BYTES
        return CloudVaultAesDetachedBox(
            nonce = nonce.copyOf(),
            ciphertext = ciphertextAndTag.copyOfRange(0, split),
            tag = ciphertextAndTag.copyOfRange(split, ciphertextAndTag.size),
        )
    }

    fun aesOpenCombined(combined: ByteArray, key: ByteArray, aad: ByteArray): ByteArray {
        require(combined.size >= GCM_NONCE_BYTES + GCM_TAG_BYTES) { "Invalid AES-GCM combined envelope length" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            SecretKeySpec(key, "AES"),
            GCMParameterSpec(GCM_AUTH_TAG_BITS, combined.copyOfRange(0, GCM_NONCE_BYTES)),
        )
        if (aad.isNotEmpty()) cipher.updateAAD(aad)
        return cipher.doFinal(combined.copyOfRange(GCM_NONCE_BYTES, combined.size))
    }

    private fun escrowWrappingKey(sharedSecret: ByteArray): ByteArray = CloudVaultLegacySearch.hkdfSha256(
        sharedSecret,
        ByteArray(0),
        ESCROW_HKDF_INFO.toByteArray(),
        KEY_BYTES,
    )

    private fun aesSealCombined(plaintext: ByteArray, key: ByteArray, nonce: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(GCM_AUTH_TAG_BITS, nonce))
        return nonce + cipher.doFinal(plaintext)
    }

    private fun aesOpenCombined(combined: ByteArray, key: ByteArray): ByteArray {
        require(combined.size > GCM_NONCE_BYTES + GCM_TAG_BYTES) { "Invalid wrapped vault key" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            SecretKeySpec(key, "AES"),
            GCMParameterSpec(GCM_AUTH_TAG_BITS, combined.copyOfRange(0, GCM_NONCE_BYTES)),
        )
        return cipher.doFinal(combined.copyOfRange(GCM_NONCE_BYTES, combined.size))
    }

    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it.toInt() and BYTE_MASK) }
}

internal object CloudVaultLegacyValidation {
    fun requireAesInputs(key: ByteArray, nonce: ByteArray) {
        requireVaultKey(key)
        require(nonce.size == GCM_NONCE_BYTES) { "Invalid AES-GCM nonce length" }
    }

    fun requireTag(tag: ByteArray) {
        require(tag.size == GCM_TAG_BYTES) { "Invalid AES-GCM authentication tag length" }
    }

    fun requireVaultKey(key: ByteArray) {
        require(key.size == KEY_BYTES) { "Invalid vault key length" }
    }
}
