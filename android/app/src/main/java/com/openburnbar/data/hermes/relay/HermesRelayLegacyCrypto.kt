package com.openburnbar.data.hermes.relay

import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

internal object HermesRelayLegacyCrypto {
    const val GCM_IV_BYTES = 12
    private const val GCM_TAG_BITS = 128
    private const val AAD_PREFIX = "OpenBurnBar-HermesRelay-v1"
    private const val KEY_WRAP_SHARED_INFO_PREFIX = "OpenBurnBar-HermesRelay-KeyWrap-v1|"
    private const val KEY_WRAP_SHARED_INFO_PREFIX_V2 = "OpenBurnBar-HermesRelay-KeyWrap-v2|"

    fun aad(parts: List<String>): ByteArray =
        ("$AAD_PREFIX|" + parts.joinToString("|")).toByteArray(Charsets.UTF_8)

    fun keyWrapInfoV1(aad: ByteArray): ByteArray =
        KEY_WRAP_SHARED_INFO_PREFIX.toByteArray(Charsets.UTF_8) + aad

    fun keyWrapInfoV2(aad: ByteArray, enc: ByteArray, pkR: ByteArray, pkS: ByteArray): ByteArray =
        KEY_WRAP_SHARED_INFO_PREFIX_V2.toByteArray(Charsets.UTF_8) + aad + enc + pkR + pkS

    fun sealCombined(plaintext: ByteArray, keyData: ByteArray, aad: ByteArray, nonce: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(keyData, "AES"), GCMParameterSpec(GCM_TAG_BITS, nonce))
        cipher.updateAAD(aad)
        return nonce + cipher.doFinal(plaintext)
    }

    fun openCombined(combined: ByteArray, keyData: ByteArray, aad: ByteArray): ByteArray {
        require(combined.size > GCM_IV_BYTES) { "ciphertext too short" }
        val nonce = combined.copyOfRange(0, GCM_IV_BYTES)
        val body = combined.copyOfRange(GCM_IV_BYTES, combined.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(keyData, "AES"), GCMParameterSpec(GCM_TAG_BITS, nonce))
        cipher.updateAAD(aad)
        return cipher.doFinal(body)
    }
}
