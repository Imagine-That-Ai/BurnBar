package com.openburnbar.data.hermes.relay

import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

internal object HermesRelayCryptoHkdf {
    private const val BYTE_MASK = 255
    private const val AES_KEY_BYTES = 32

    fun hkdfDeriveSymmetricKey(sharedSecret: ByteArray, sharedInfo: ByteArray, length: Int): ByteArray {
        val prk = hkdfExtract(salt = ByteArray(0), ikm = sharedSecret)
        return hkdfExpand(prk = prk, info = sharedInfo, length = length)
    }

    fun hkdfExtract(salt: ByteArray, ikm: ByteArray): ByteArray {
        val saltKey = if (salt.isEmpty()) ByteArray(AES_KEY_BYTES) else salt
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(saltKey, "HmacSHA256"))
        return mac.doFinal(ikm)
    }

    fun hkdfExpand(prk: ByteArray, info: ByteArray, length: Int): ByteArray {
        require(length <= AES_KEY_BYTES * BYTE_MASK) { "HKDF output too long" }
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(prk, "HmacSHA256"))
        val output = ByteArray(length)
        var previous = ByteArray(0)
        var generated = 0
        var counter = 1
        while (generated < length) {
            mac.reset()
            mac.update(previous)
            mac.update(info)
            mac.update(counter.toByte())
            previous = mac.doFinal()
            val toCopy = minOf(previous.size, length - generated)
            System.arraycopy(previous, 0, output, generated, toCopy)
            generated += toCopy
            counter += 1
        }
        return output
    }

    fun leftPadTo(bytes: ByteArray, size: Int): ByteArray {
        if (bytes.size == size) return bytes
        if (bytes.size > size) return bytes.copyOfRange(bytes.size - size, bytes.size)
        val out = ByteArray(size)
        System.arraycopy(bytes, 0, out, size - bytes.size, bytes.size)
        return out
    }
}
