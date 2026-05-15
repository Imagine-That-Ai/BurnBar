package com.openburnbar.data.cloud

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import com.openburnbar.BurnBarApplication
import java.math.BigInteger
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.PublicKey
import java.security.interfaces.ECPrivateKey
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec
import java.security.spec.PKCS8EncodedKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.KeyGenerator
import javax.crypto.Mac
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

data class CloudVaultSealedText(
    val algorithm: String = "AES-256-GCM",
    val keyVersion: Int = 1,
    val nonce: String = "",
    val ciphertext: String = "",
    val tag: String = ""
)

data class CloudVaultBlobEnvelope(
    val schemaVersion: Int = 1,
    val algorithm: String = "AES-256-GCM",
    val keyVersion: Int = 1,
    val plaintextSHA256: String = "",
    val sealedBoxBase64: String = ""
)

object CloudVaultCrypto {
    private const val SEARCH_SALT = "OpenBurnBar-CloudSearch-Salt-v1"
    private const val SEARCH_INFO = "OpenBurnBar-CloudSearch-TokenHash-v1"
    private const val SEMANTIC_SEARCH_SALT = "OpenBurnBar-CloudSearch-Semantic-Salt-v1"
    private const val SEMANTIC_SEARCH_INFO = "OpenBurnBar-CloudSearch-SemanticHash-v1"
    private const val WRAP_INFO = "OpenBurnBar-Escrow-v1"
    const val tokenHashVersion: Int = 1
    const val semanticHashVersion: Int = 1
    private val stopwords = setOf(
        "the", "and", "for", "with", "that", "this", "from", "how", "what", "where",
        "when", "why", "are", "was", "were", "you", "your", "have", "has", "had",
        "into", "onto", "can", "could", "should", "would"
    )

    fun openText(envelope: CloudVaultSealedText, vaultKey: ByteArray): String {
        require(envelope.algorithm == "AES-256-GCM") { "Unsupported envelope algorithm" }
        val nonce = Base64.decode(envelope.nonce, Base64.DEFAULT)
        val ciphertext = Base64.decode(envelope.ciphertext, Base64.DEFAULT)
        val tag = Base64.decode(envelope.tag, Base64.DEFAULT)
        val plaintext = openAesGcm(vaultKey, nonce, ciphertext + tag)
        return plaintext.toString(Charsets.UTF_8)
    }

    fun tokenHashes(text: String, vaultKey: ByteArray, limit: Int = 250): List<String> {
        val searchKey = hkdfSha256(vaultKey, SEARCH_SALT.toByteArray(), SEARCH_INFO.toByteArray(), 32)
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(searchKey, "HmacSHA256"))
        val seen = linkedSetOf<String>()
        val hashes = mutableListOf<String>()
        for (token in normalizedTokens(text)) {
            if (!seen.add(token)) continue
            hashes += mac.doFinal(token.toByteArray()).take(16).joinToString("") { "%02x".format(it.toInt() and 0xff) }
            if (hashes.size >= limit) break
        }
        return hashes
    }

    fun semanticHashes(text: String, vaultKey: ByteArray, limit: Int = 24): List<String> {
        val tokens = normalizedTokens(text)
        if (tokens.isEmpty() || limit <= 0) return emptyList()
        val searchKey = hkdfSha256(
            vaultKey,
            SEMANTIC_SEARCH_SALT.toByteArray(),
            SEMANTIC_SEARCH_INFO.toByteArray(),
            32
        )
        val features = semanticFeatures(tokens)
        if (features.isEmpty()) return emptyList()

        val mac = Mac.getInstance("HmacSHA256")
        val dimensions = 64
        val accumulator = DoubleArray(dimensions)
        for (feature in features) {
            mac.init(SecretKeySpec(searchKey, "HmacSHA256"))
            val bytes = mac.doFinal(feature.name.toByteArray())
            val index = (((bytes[0].toInt() and 0xff) shl 8) or (bytes[1].toInt() and 0xff)) % dimensions
            val sign = if ((bytes[2].toInt() and 1) == 0) 1.0 else -1.0
            accumulator[index] += sign * feature.weight
        }

        val hashes = mutableListOf<String>()
        val seen = linkedSetOf<String>()
        fun appendBucket(bucket: String) {
            if (hashes.size >= limit) return
            mac.init(SecretKeySpec(searchKey, "HmacSHA256"))
            val hash = mac.doFinal(bucket.toByteArray())
                .take(16)
                .joinToString("") { "%02x".format(it.toInt() and 0xff) }
            if (seen.add(hash)) hashes += hash
        }

        val bandSize = 8
        val bandCount = dimensions / bandSize
        for (band in 0 until bandCount) {
            var value = 0
            for (bit in 0 until bandSize) {
                val index = band * bandSize + bit
                if (accumulator[index] >= 0) value = value or (1 shl bit)
            }
            appendBucket("simhash:v1:band:$band:%02x".format(value))
        }

        for (feature in features.take(maxOf(0, limit - hashes.size))) {
            appendBucket("feature:v1:${feature.name}")
        }
        return hashes
    }

    fun openBlob(envelope: CloudVaultBlobEnvelope, vaultKey: ByteArray): ByteArray {
        require(envelope.algorithm == "AES-256-GCM") { "Unsupported envelope algorithm" }
        val combined = Base64.decode(envelope.sealedBoxBase64, Base64.DEFAULT)
        require(combined.size > 28) { "Invalid encrypted blob envelope" }
        val plaintext = openAesGcm(
            vaultKey,
            combined.copyOfRange(0, 12),
            combined.copyOfRange(12, combined.size)
        )
        require(sha256Hex(plaintext) == envelope.plaintextSHA256) { "Encrypted blob hash mismatch" }
        return plaintext
    }

    fun normalizedTokens(text: String): List<String> =
        text.lowercase()
            .split(Regex("[^a-z0-9]+"))
            .filter { it.length >= 2 && it !in stopwords }

    fun unwrapVaultKey(ciphertext: ByteArray, privateKey: PrivateKey): ByteArray {
        require(ciphertext.size > 65) { "Invalid wrapped vault key" }
        val ephemeralPublic = publicKeyFromX963(ciphertext.copyOfRange(0, 65), (privateKey as ECPrivateKey).params)
        val sharedSecret = KeyAgreement.getInstance("ECDH").run {
            init(privateKey)
            doPhase(ephemeralPublic, true)
            generateSecret()
        }
        val wrappingKey = hkdfSha256(sharedSecret, ByteArray(0), WRAP_INFO.toByteArray(), 32)
        val combined = ciphertext.copyOfRange(65, ciphertext.size)
        val plaintext = openAesGcm(wrappingKey, combined.copyOfRange(0, 12), combined.copyOfRange(12, combined.size))
        require(plaintext.size == 32) { "Invalid vault key length" }
        return plaintext
    }

    fun publicKeyX963(publicKey: PublicKey): ByteArray {
        val ec = publicKey as ECPublicKey
        return byteArrayOf(0x04) + fixed32(ec.w.affineX) + fixed32(ec.w.affineY)
    }

    fun sha256Hex(data: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(data).joinToString("") { "%02x".format(it.toInt() and 0xff) }

    fun sha256Base64(data: ByteArray): String =
        Base64.encodeToString(MessageDigest.getInstance("SHA-256").digest(data), Base64.NO_WRAP)

    private fun openAesGcm(key: ByteArray, nonce: ByteArray, ciphertextAndTag: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        return cipher.doFinal(ciphertextAndTag)
    }

    private fun hkdfSha256(input: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        val effectiveSalt = if (salt.isEmpty()) ByteArray(32) else salt
        val extractMac = Mac.getInstance("HmacSHA256")
        extractMac.init(SecretKeySpec(effectiveSalt, "HmacSHA256"))
        val prk = extractMac.doFinal(input)
        val output = ByteArray(length)
        var previous = ByteArray(0)
        var written = 0
        var counter = 1
        while (written < length) {
            val expandMac = Mac.getInstance("HmacSHA256")
            expandMac.init(SecretKeySpec(prk, "HmacSHA256"))
            expandMac.update(previous)
            expandMac.update(info)
            expandMac.update(counter.toByte())
            previous = expandMac.doFinal()
            val copy = minOf(previous.size, length - written)
            System.arraycopy(previous, 0, output, written, copy)
            written += copy
            counter += 1
        }
        return output
    }

    private fun publicKeyFromX963(bytes: ByteArray, params: java.security.spec.ECParameterSpec): PublicKey {
        require(bytes.size == 65 && bytes[0] == 0x04.toByte()) { "Invalid P-256 public key" }
        val x = BigInteger(1, bytes.copyOfRange(1, 33))
        val y = BigInteger(1, bytes.copyOfRange(33, 65))
        return KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(ECPoint(x, y), params))
    }

    private fun fixed32(value: BigInteger): ByteArray {
        val raw = value.toByteArray()
        val positive = if (raw.size > 32) raw.copyOfRange(raw.size - 32, raw.size) else raw
        return ByteArray(32 - positive.size) + positive
    }

    private data class SemanticFeature(val name: String, val weight: Double)

    private fun semanticFeatures(tokens: List<String>): List<SemanticFeature> {
        val features = mutableListOf<SemanticFeature>()
        val seen = linkedSetOf<String>()
        fun append(name: String, weight: Double) {
            if (name.isBlank() || !seen.add(name)) return
            features += SemanticFeature(name, weight)
        }

        for (token in tokens) {
            append("token:$token", 2.4)
            val stem = simpleSemanticStem(token)
            if (stem != token) append("stem:$stem", 1.8)
            if (token.length >= 5) append("prefix:${token.take(5)}", 0.8)
        }
        if (tokens.size >= 2) {
            for (index in 0 until tokens.lastIndex) {
                append("bigram:${tokens[index]}_${tokens[index + 1]}", 1.3)
            }
        }
        return features
    }

    private fun simpleSemanticStem(token: String): String {
        val suffixes = listOf("ization", "ations", "ation", "ments", "ment", "ingly", "edly", "ing", "ies", "ied", "ers", "er", "ed", "s")
        for (suffix in suffixes) {
            if (token.length > suffix.length + 3 && token.endsWith(suffix)) {
                val stem = token.dropLast(suffix.length)
                return if (suffix == "ies" || suffix == "ied") stem + "y" else stem
            }
        }
        return token
    }
}

class AndroidCloudVaultDeviceKeypair private constructor(
    private val privateKey: PrivateKey,
    val publicKeyData: ByteArray,
    val keyVersion: Int = 1
) {
    val publicKeyFingerprint: String = CloudVaultCrypto.sha256Base64(publicKeyData)
    val deviceId: String = "android-${CloudVaultCrypto.sha256Hex(publicKeyData).take(32)}"

    fun decryptWrappedVaultKey(base64: String): ByteArray =
        CloudVaultCrypto.unwrapVaultKey(Base64.decode(base64, Base64.DEFAULT), privateKey)

    companion object {
        private const val PREFS = "openburnbar_cloud_vault_device"
        private const val PRIVATE_KEY = "private_key"
        private const val PUBLIC_KEY = "public_key"

        fun loadOrCreate(): AndroidCloudVaultDeviceKeypair {
            val prefs = BurnBarApplication.appContext.getSharedPreferences(PREFS, 0)
            val storedPrivate = prefs.getString(PRIVATE_KEY, null)
            val storedPublic = prefs.getString(PUBLIC_KEY, null)
            if (!storedPrivate.isNullOrBlank() && !storedPublic.isNullOrBlank()) {
                val privateBytes = AndroidLocalSecretBox.decrypt(Base64.decode(storedPrivate, Base64.DEFAULT))
                val privateKey = KeyFactory.getInstance("EC").generatePrivate(PKCS8EncodedKeySpec(privateBytes))
                return AndroidCloudVaultDeviceKeypair(privateKey, Base64.decode(storedPublic, Base64.DEFAULT))
            }

            val generator = KeyPairGenerator.getInstance("EC")
            generator.initialize(ECGenParameterSpec("secp256r1"))
            val pair = generator.generateKeyPair()
            val publicX963 = CloudVaultCrypto.publicKeyX963(pair.public)
            prefs.edit()
                .putString(PRIVATE_KEY, Base64.encodeToString(AndroidLocalSecretBox.encrypt(pair.private.encoded), Base64.NO_WRAP))
                .putString(PUBLIC_KEY, Base64.encodeToString(publicX963, Base64.NO_WRAP))
                .apply()
            return AndroidCloudVaultDeviceKeypair(pair.private, publicX963)
        }
    }
}

private object AndroidLocalSecretBox {
    private const val ALIAS = "openburnbar-cloud-vault-device-secret"

    fun encrypt(plaintext: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        return cipher.iv + cipher.doFinal(plaintext)
    }

    fun decrypt(sealed: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(128, sealed.copyOfRange(0, 12)))
        return cipher.doFinal(sealed.copyOfRange(12, sealed.size))
    }

    private fun secretKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        val spec = KeyGenParameterSpec.Builder(
            ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setRandomizedEncryptionRequired(true)
            .build()
        generator.init(spec)
        return generator.generateKey()
    }
}
