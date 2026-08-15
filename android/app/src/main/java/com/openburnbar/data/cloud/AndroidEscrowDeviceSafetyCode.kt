package com.openburnbar.data.cloud

import java.security.AlgorithmParameters
import java.security.MessageDigest
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.util.Base64

/**
 * Human-comparable, key-bound safety code for escrow device approval.
 *
 * The code is derived from the first 128 bits of SHA-256(publicKeyData), while
 * [isFingerprintBoundTo] verifies that the stored fingerprint names the same
 * public key. Invalid or off-curve P-256 keys fail closed.
 */
internal object AndroidEscrowDeviceSafetyCode {
    private const val P256_X963_BYTES = 65
    private const val SAFETY_CODE_BYTES = 16
    private const val GROUP_BYTES = 2

    fun format(publicKeyData: String?): String? {
        val digest = digest(publicKeyData) ?: return null
        return digest
            .take(SAFETY_CODE_BYTES)
            .chunked(GROUP_BYTES)
            .joinToString(" ") { group ->
                group.joinToString("") { byte -> "%02X".format(byte.toInt() and 0xFF) }
            }
    }

    fun isFingerprintBoundTo(fingerprint: String?, publicKeyData: String?): Boolean {
        val digest = digest(publicKeyData) ?: return false
        val claimed =
            runCatching {
                Base64.getDecoder().decode(fingerprint?.trim().orEmpty())
            }.getOrNull() ?: return false
        return MessageDigest.isEqual(claimed, digest)
    }

    private fun digest(publicKeyData: String?): ByteArray? {
        val decoded =
            runCatching {
                Base64.getDecoder().decode(publicKeyData?.trim().orEmpty())
            }.getOrNull() ?: return null
        if (decoded.size != P256_X963_BYTES || decoded.firstOrNull() != 0x04.toByte()) return null

        val parameters =
            runCatching {
                AlgorithmParameters.getInstance("EC").apply {
                    init(ECGenParameterSpec("secp256r1"))
                }.getParameterSpec(ECParameterSpec::class.java)
            }.getOrNull() ?: return null
        val publicKey =
            runCatching {
                CloudVaultCryptoSupport.publicKeyFromX963(decoded, parameters)
            }.getOrNull() ?: return null
        runCatching {
            requireP256Point(publicKey, "Escrow device safety code")
        }.getOrNull() ?: return null

        return MessageDigest.getInstance("SHA-256").digest(decoded)
    }
}
