package com.openburnbar.data.hermes.relay

import java.io.ByteArrayOutputStream
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

internal object HermesRatchetLegacyCrypto {
    const val GCM_IV_BYTES = HermesRelayLegacyCrypto.GCM_IV_BYTES
    const val ROOT_INFO = "OpenBurnBar-HermesRatchet-v1-root"
    const val CHAIN_LABEL = "OpenBurnBar-HermesRatchet-v1-chain"
    const val MESSAGE_LABEL = "OpenBurnBar-HermesRatchet-v1-message"
    private const val AAD_DOMAIN = "OpenBurnBar-HermesRatchet-v1-AAD"
    private const val BYTE_MASK = 0xffL

    fun envelopeAAD(header: HermesRatchetHeader, associatedData: ByteArray): ByteArray = ByteArrayOutputStream().apply {
        write(AAD_DOMAIN.toByteArray(Charsets.UTF_8))
        appendPart(associatedData)
        appendPart(header.algorithm.toByteArray(Charsets.UTF_8))
        appendPart(header.sessionID.toByteArray(Charsets.UTF_8))
        appendPart(header.senderDeviceID.toByteArray(Charsets.UTF_8))
        appendPart(header.receiverDeviceID.toByteArray(Charsets.UTF_8))
        appendPart(header.ratchetPublicKeyBase64.toByteArray(Charsets.UTF_8))
        appendUInt64(header.version)
        appendUInt64(header.previousChainLength)
        appendUInt64(header.messageNumber)
        appendUInt64(header.epoch)
    }.toByteArray()

    fun rootKDF(rootKey: ByteArray, dhOutput: ByteArray, outputBytes: Int): ByteArray {
        val info = ROOT_INFO.toByteArray(Charsets.UTF_8)
        val prk = HermesRelayCryptoHkdf.hkdfExtract(salt = rootKey, ikm = dhOutput)
        return HermesRelayCryptoHkdf.hkdfExpand(prk = prk, info = info, length = outputBytes)
    }

    fun nextChainKey(chainKey: ByteArray): ByteArray = hmacSha256(chainKey, CHAIN_LABEL.toByteArray(Charsets.UTF_8))

    fun messageKey(chainKey: ByteArray): ByteArray = hmacSha256(chainKey, MESSAGE_LABEL.toByteArray(Charsets.UTF_8))

    fun seal(plaintext: ByteArray, keyData: ByteArray, aad: ByteArray, nonce: ByteArray): ByteArray =
        HermesRelayLegacyCrypto.sealCombined(plaintext, keyData, aad, nonce)

    fun open(combined: ByteArray, keyData: ByteArray, aad: ByteArray): ByteArray = HermesRelayLegacyCrypto.openCombined(combined, keyData, aad)

    private fun hmacSha256(key: ByteArray, data: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(data)
    }

    private fun ByteArrayOutputStream.appendPart(part: ByteArray) {
        appendUInt64(part.size)
        write(part)
    }

    private fun ByteArrayOutputStream.appendUInt64(value: Int) {
        require(value >= 0) { "UInt64 ratchet field cannot be negative" }
        val longValue = value.toLong()
        for (shift in 56 downTo 0 step 8) {
            write((longValue ushr shift and BYTE_MASK).toInt())
        }
    }
}
