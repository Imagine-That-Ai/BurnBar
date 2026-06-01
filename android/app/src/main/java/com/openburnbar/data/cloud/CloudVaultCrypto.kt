package com.openburnbar.data.cloud

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import com.openburnbar.BurnBarApplication
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.PublicKey
import java.security.interfaces.ECPrivateKey
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.PKCS8EncodedKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

data class CloudVaultSealedText(
    val algorithm: String = "AES-256-GCM",
    val keyVersion: Int = 1,
    val nonce: String = "",
    val ciphertext: String = "",
    val tag: String = "",
)

data class CloudVaultBlobEnvelope(
    val schemaVersion: Int = 1,
    val algorithm: String = "AES-256-GCM",
    val keyVersion: Int = 1,
    val plaintextSHA256: String = "",
    val sealedBoxBase64: String = "",
)

object CloudVaultCrypto {
    private const val GCM_AUTH_TAG_BITS = 128
    private const val GCM_TAG_BYTES = 16
    private const val SHA256_DIGEST_BYTES = 32
    private const val UNCOMPRESSED_POINT_PREFIX = 0x04
    private const val BYTE_MASK = 0xff
    private const val GCM_NONCE_BYTES = 12
    private const val MIN_BLOB_ENVELOPE_BYTES = 28
    private const val WRAPPED_KEY_EPHEMERAL_BYTES = 65
    private const val P256_COORDINATE_BYTES = 32
    private const val P256_Y_COORDINATE_OFFSET = 33
    private const val WRAP_INFO = "OpenBurnBar-Escrow-v1"
    const val tokenHashVersion: Int = 1
    const val semanticHashVersion: Int = 1

    fun sealText(text: String, vaultKey: ByteArray): CloudVaultSealedText {
        val plaintext = text.toByteArray(Charsets.UTF_8)
        val nonce =
            ByteArray(GCM_NONCE_BYTES).apply {
                java.security.SecureRandom().nextBytes(this)
            }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE.let { Cipher.ENCRYPT_MODE }, SecretKeySpec(vaultKey, "AES"), GCMParameterSpec(GCM_AUTH_TAG_BITS, nonce))
        val ciphertextAndTag = cipher.doFinal(plaintext)
        val tagSize = GCM_TAG_BYTES
        val ciphertext = ciphertextAndTag.copyOfRange(0, ciphertextAndTag.size - tagSize)
        val tag = ciphertextAndTag.copyOfRange(ciphertextAndTag.size - tagSize, ciphertextAndTag.size)
        return CloudVaultSealedText(
            algorithm = "AES-256-GCM",
            keyVersion = 1,
            nonce = Base64.encodeToString(nonce, Base64.NO_WRAP),
            ciphertext = Base64.encodeToString(ciphertext, Base64.NO_WRAP),
            tag = Base64.encodeToString(tag, Base64.NO_WRAP),
        )
    }

    fun openText(envelope: CloudVaultSealedText, vaultKey: ByteArray): String {
        require(envelope.algorithm == "AES-256-GCM") { "Unsupported envelope algorithm" }
        val nonce = Base64.decode(envelope.nonce, Base64.DEFAULT)
        val ciphertext = Base64.decode(envelope.ciphertext, Base64.DEFAULT)
        val tag = Base64.decode(envelope.tag, Base64.DEFAULT)
        val plaintext = CloudVaultCryptoSupport.openAesGcm(vaultKey, nonce, ciphertext + tag)
        return plaintext.toString(Charsets.UTF_8)
    }

    fun tokenHashes(text: String, vaultKey: ByteArray, limit: Int = 250): List<String> =
        CloudVaultCryptoSearch.tokenHashes(text, vaultKey, limit)

    fun semanticHashes(text: String, vaultKey: ByteArray, limit: Int = 24): List<String> =
        CloudVaultCryptoSearch.semanticHashes(text, vaultKey, limit)

    fun openBlob(envelope: CloudVaultBlobEnvelope, vaultKey: ByteArray): ByteArray {
        require(envelope.algorithm == "AES-256-GCM") { "Unsupported envelope algorithm" }
        val combined = Base64.decode(envelope.sealedBoxBase64, Base64.DEFAULT)
        require(combined.size > MIN_BLOB_ENVELOPE_BYTES) { "Invalid encrypted blob envelope" }
        val plaintext =
            CloudVaultCryptoSupport.openAesGcm(
                vaultKey,
                combined.copyOfRange(0, GCM_NONCE_BYTES),
                combined.copyOfRange(GCM_NONCE_BYTES, combined.size),
            )
        require(sha256Hex(plaintext) == envelope.plaintextSHA256) { "Encrypted blob hash mismatch" }
        return plaintext
    }

    fun unwrapVaultKey(ciphertext: ByteArray, privateKey: PrivateKey): ByteArray {
        require(ciphertext.size > WRAPPED_KEY_EPHEMERAL_BYTES) { "Invalid wrapped vault key" }
        val ecPrivateKey =
            privateKey as? ECPrivateKey
                ?: error("Vault key unwrap requires an EC private key")
        val ephemeralPublic =
            CloudVaultCryptoSupport.publicKeyFromX963(ciphertext.copyOfRange(0, WRAPPED_KEY_EPHEMERAL_BYTES), ecPrivateKey.params)
        val sharedSecret =
            KeyAgreement.getInstance("ECDH").run {
                init(privateKey)
                doPhase(ephemeralPublic, true)
                generateSecret()
            }
        val wrappingKey = CloudVaultCryptoSearch.hkdfSha256(sharedSecret, ByteArray(0), WRAP_INFO.toByteArray(), SHA256_DIGEST_BYTES)
        val combined = ciphertext.copyOfRange(WRAPPED_KEY_EPHEMERAL_BYTES, ciphertext.size)
        val plaintext =
            CloudVaultCryptoSupport.openAesGcm(
                wrappingKey,
                combined.copyOfRange(0, GCM_NONCE_BYTES),
                combined.copyOfRange(GCM_NONCE_BYTES, combined.size),
            )
        require(plaintext.size == SHA256_DIGEST_BYTES) { "Invalid vault key length" }
        return plaintext
    }

    fun publicKeyX963(publicKey: PublicKey): ByteArray {
        val ec =
            publicKey as? ECPublicKey
                ?: error("X9.63 encoding requires an EC public key")
        return byteArrayOf(UNCOMPRESSED_POINT_PREFIX.toByte()) + CloudVaultCryptoSupport.fixed32(ec.w.affineX) + CloudVaultCryptoSupport.fixed32(ec.w.affineY)
    }

    fun sha256Hex(data: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(data).joinToString("") { "%02x".format(it.toInt() and BYTE_MASK) }

    fun sha256Base64(data: ByteArray): String = Base64.encodeToString(MessageDigest.getInstance("SHA-256").digest(data), Base64.NO_WRAP)
}

class AndroidCloudVaultDeviceKeypair private constructor(
    private val privateKey: PrivateKey,
    val publicKeyData: ByteArray,
    val keyVersion: Int = 1,
) {
    val publicKeyFingerprint: String = CloudVaultCrypto.sha256Base64(publicKeyData)
    val deviceId: String = "android-${CloudVaultCrypto.sha256Hex(publicKeyData).take(32)}"

    fun decryptWrappedVaultKey(base64: String): ByteArray = CloudVaultCrypto.unwrapVaultKey(Base64.decode(base64, Base64.DEFAULT), privateKey)

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
    private const val GCM_AUTH_TAG_BITS = 128
    private const val GCM_NONCE_BYTES = 12

    fun encrypt(plaintext: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        return cipher.iv + cipher.doFinal(plaintext)
    }

    fun decrypt(sealed: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(GCM_AUTH_TAG_BITS, sealed.copyOfRange(0, GCM_NONCE_BYTES)))
        return cipher.doFinal(sealed.copyOfRange(GCM_NONCE_BYTES, sealed.size))
    }

    private fun secretKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        val spec =
            KeyGenParameterSpec.Builder(
                ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .build()
        generator.init(spec)
        return generator.generateKey()
    }
}
