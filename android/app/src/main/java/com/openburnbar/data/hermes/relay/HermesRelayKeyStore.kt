package com.openburnbar.data.hermes.relay

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import com.openburnbar.irohrelay.IrohSecretKeyMaterial
import java.security.KeyStore
import java.security.KeyFactory
import java.security.KeyPair
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.spec.PKCS8EncodedKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

private const val VAL_32 = 32

/**
 * Per-app-install persistent client key store for the Hermes encrypted
 * relay. Persists both the PKCS#8 private key and the X9.63 public key
 * bytes side-by-side because Android's JCA can't derive an EC public
 * key from a private key alone.
 */
class HermesRelayKeyStore(context: Context) {
    private val prefs: SharedPreferences =
        context
            .applicationContext
            .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun loadOrCreateClientKeyPair(): KeyPair {
        val storedPublic = prefs.getString(KEY_PUBLIC_X963, null)
        val storedPrivate = loadPrivateKeyPkcs8()
        if (storedPrivate != null && storedPublic != null) {
            return runCatching { restore(storedPrivate, storedPublic) }
                .getOrElse {
                    prefs.edit().clear().apply()
                    generateAndStore()
                }
        }
        return generateAndStore()
    }

    fun clientPublicKeyX963(): ByteArray {
        val kp = loadOrCreateClientKeyPair()
        val publicKey =
            kp.public as? java.security.interfaces.ECPublicKey
                ?: error("Hermes relay client keypair must use an EC public key")
        return HermesRelayCryptoEc.encodeUncompressedPublicKey(publicKey)
    }

    /**
     * 32-byte iroh secret used to bootstrap the local iroh endpoint.
     * Generated lazily on first use and persisted alongside the relay
     * ECDH keypair. The iroh secret is INDEPENDENT from the relay
     * ECDH keypair — different algorithm (Curve25519 vs P-256), different
     * use (NodeId vs E2E sealing), so we never reuse bytes.
     */
    fun irohSecretKeyMaterial(): IrohSecretKeyMaterial {
        val raw =
            loadWrapped(KEY_WRAPPED_IROH_MATERIAL, KEY_IROH_WRAP_IV, expectedBytes = VAL_32)
                ?: migrateLegacyIrohKeyMaterial()
                ?: generateIrohSecretAndStore()
        return IrohSecretKeyMaterial(raw)
    }

    private fun generateIrohSecretAndStore(): ByteArray {
        val bytes = ByteArray(VAL_32).also { SecureRandom().nextBytes(it) }
        saveWrapped(KEY_WRAPPED_IROH_MATERIAL, KEY_IROH_WRAP_IV, bytes)
        return bytes
    }

    private fun generateAndStore(): KeyPair {
        val kp = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val privateBytes =
            kp.private.encoded
                ?: error("EC private key has no PKCS#8 encoding")
        val publicKey =
            kp.public as? java.security.interfaces.ECPublicKey
                ?: error("Hermes relay generated keypair must use an EC public key")
        val publicBytes =
            HermesRelayCryptoEc.encodeUncompressedPublicKey(
                publicKey,
            )
        saveWrapped(KEY_WRAPPED_PRIVATE_PKCS8, KEY_PRIVATE_WRAP_IV, privateBytes)
        prefs.edit()
            .putString(KEY_PUBLIC_X963, Base64.encodeToString(publicBytes, Base64.NO_WRAP))
            .apply()
        return kp
    }

    private fun restore(privateBytes: ByteArray, publicB64: String): KeyPair {
        val publicBytes = Base64.decode(publicB64, Base64.NO_WRAP)
        val privateKey: PrivateKey =
            KeyFactory.getInstance("EC")
                .generatePrivate(PKCS8EncodedKeySpec(privateBytes))
        val publicKey = HermesRelayCryptoEc.decodeUncompressedPublicKey(publicBytes)
        return KeyPair(publicKey, privateKey)
    }

    private fun loadPrivateKeyPkcs8(): ByteArray? {
        loadWrapped(KEY_WRAPPED_PRIVATE_PKCS8, KEY_PRIVATE_WRAP_IV)?.let { return it }
        val legacy = prefs.getString(KEY_PRIVATE_PKCS8, null) ?: return null
        val privateBytes = runCatching { Base64.decode(legacy, Base64.NO_WRAP) }.getOrNull() ?: return null
        saveWrapped(KEY_WRAPPED_PRIVATE_PKCS8, KEY_PRIVATE_WRAP_IV, privateBytes)
        prefs.edit().remove(KEY_PRIVATE_PKCS8).apply()
        return privateBytes
    }

    private fun migrateLegacyIrohKeyMaterial(): ByteArray? {
        val legacy = prefs.getString(KEY_IROH_SECRET, null) ?: return null
        val raw =
            runCatching {
                Base64.decode(legacy, Base64.NO_WRAP).also {
                    require(it.size == VAL_32) { "iroh secret length != 32" }
                }
            }.getOrNull() ?: return null
        saveWrapped(KEY_WRAPPED_IROH_MATERIAL, KEY_IROH_WRAP_IV, raw)
        prefs.edit().remove(KEY_IROH_SECRET).apply()
        return raw
    }

    private fun loadWrapped(wrappedKey: String, ivKey: String, expectedBytes: Int? = null): ByteArray? {
        val wrapped = prefs.getString(wrappedKey, null)?.let { runCatching { Base64.decode(it, Base64.NO_WRAP) }.getOrNull() }
        val iv = prefs.getString(ivKey, null)?.let { runCatching { Base64.decode(it, Base64.NO_WRAP) }.getOrNull() }
        val secretKey = runCatching { wrappingKey() }.getOrNull()
        if (wrapped == null || iv == null || secretKey == null) return null
        return try {
            val cipher =
                Cipher.getInstance(AES_GCM_TRANSFORM).apply {
                    init(Cipher.DECRYPT_MODE, secretKey, GCMParameterSpec(GCM_TAG_BITS, iv))
                }
            cipher.doFinal(wrapped).takeIf { expectedBytes == null || it.size == expectedBytes }
        } catch (_: Throwable) {
            null
        }
    }

    private fun saveWrapped(wrappedKey: String, ivKey: String, raw: ByteArray) {
        val secretKey = wrappingKey()
        val cipher =
            Cipher.getInstance(AES_GCM_TRANSFORM).apply {
                init(Cipher.ENCRYPT_MODE, secretKey)
            }
        val iv = cipher.iv
        require(iv.size == GCM_IV_BYTES) { "Unexpected AES-GCM IV length ${iv.size}" }
        val wrapped = cipher.doFinal(raw)
        prefs.edit()
            .putString(wrappedKey, Base64.encodeToString(wrapped, Base64.NO_WRAP))
            .putString(ivKey, Base64.encodeToString(iv, Base64.NO_WRAP))
            .apply()
    }

    private fun wrappingKey(): SecretKey {
        val store = keystore()
        store.getEntry(KEY_ALIAS, null)?.let { entry ->
            val secretEntry =
                entry as? KeyStore.SecretKeyEntry
                    ?: error("Keystore entry $KEY_ALIAS is not a secret key")
            return secretEntry.secretKey
        }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        val spec =
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(VAL_256)
                .build()
        generator.init(spec)
        return generator.generateKey()
    }

    private fun keystore(): KeyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }

    companion object {
        private const val VAL_256 = 256
        private const val PREFS_NAME = "hermes_relay_keys"
        private const val KEY_PRIVATE_PKCS8 = "************************"
        private const val KEY_PUBLIC_X963 = "**********************"

        /** Legacy plaintext base64 32-byte secret; migrated to AES-GCM-wrapped storage on read. */
        private const val KEY_IROH_SECRET = "iroh_secret_v1"
        private const val KEY_WRAPPED_PRIVATE_PKCS8 = "wrapped_private_pkcs8_v2"
        private const val KEY_PRIVATE_WRAP_IV = "private_wrap_iv_v2"
        private const val KEY_WRAPPED_IROH_MATERIAL = "iroh_material_wrapped_v2"
        private const val KEY_IROH_WRAP_IV = "iroh_wrap_iv_v2"
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val KEY_ALIAS = "ai.openburnbar.hermes-relay-keys"
        private const val AES_GCM_TRANSFORM = "AES/GCM/NoPadding"
        private const val GCM_IV_BYTES = 12
        private const val GCM_TAG_BITS = 128
    }
}
