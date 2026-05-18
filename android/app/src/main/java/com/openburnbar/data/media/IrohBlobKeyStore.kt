package com.openburnbar.data.media

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import com.openburnbar.irohrelay.IrohSecretKeyMaterial
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Android-side persistence of the iroh BLOB endpoint's 32-byte secret
 * key. 1:1 port of `IrohBlobKeyStore.swift`. Distinct from the chat
 * `HermesRelayKeyStore`'s iroh secret because Mercury needs a second
 * iroh endpoint (different ALPN, different NodeId) so discovery can
 * resolve the blob listener independently from the chat listener.
 *
 * Implementation note: Android Keystore can't store raw 32-byte secrets
 * directly the way iOS Keychain can — it stores key handles. So we
 * persist an AES-GCM-wrapped copy of the iroh secret in SharedPreferences,
 * with the wrapping key materialized inside the AndroidKeyStore. The
 * wrapping key is hardware-backed where available; the wrapped secret is
 * pure ciphertext at rest, satisfying the same security model the
 * iOS `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` flag gives us.
 */
class IrohBlobKeyStore(context: Context) {

    private val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun secretKeyMaterial(): IrohSecretKeyMaterial {
        val existing = loadFromStore()
        if (existing != null) return IrohSecretKeyMaterial(existing)
        val fresh = ByteArray(32).also { SecureRandom().nextBytes(it) }
        saveToStore(fresh)
        return IrohSecretKeyMaterial(fresh)
    }

    fun resetSecret() {
        prefs.edit().clear().apply()
        runCatching { keystore().deleteEntry(KEY_ALIAS) }
    }

    private fun loadFromStore(): ByteArray? {
        val wrappedB64 = prefs.getString(KEY_WRAPPED_SECRET, null) ?: return null
        val ivB64 = prefs.getString(KEY_WRAP_IV, null) ?: return null
        val wrapped = runCatching { Base64.decode(wrappedB64, Base64.NO_WRAP) }.getOrNull() ?: return null
        val iv = runCatching { Base64.decode(ivB64, Base64.NO_WRAP) }.getOrNull() ?: return null
        val secretKey = runCatching { wrappingKey() }.getOrNull() ?: return null
        return try {
            val cipher = Cipher.getInstance(AES_GCM_TRANSFORM).apply {
                init(Cipher.DECRYPT_MODE, secretKey, GCMParameterSpec(GCM_TAG_BITS, iv))
            }
            val plain = cipher.doFinal(wrapped)
            if (plain.size == 32) plain else null
        } catch (_: Throwable) {
            null
        }
    }

    private fun saveToStore(raw: ByteArray) {
        val secretKey = wrappingKey()
        val iv = ByteArray(GCM_IV_BYTES).also { SecureRandom().nextBytes(it) }
        val cipher = Cipher.getInstance(AES_GCM_TRANSFORM).apply {
            init(Cipher.ENCRYPT_MODE, secretKey, GCMParameterSpec(GCM_TAG_BITS, iv))
        }
        val wrapped = cipher.doFinal(raw)
        prefs.edit()
            .putString(KEY_WRAPPED_SECRET, Base64.encodeToString(wrapped, Base64.NO_WRAP))
            .putString(KEY_WRAP_IV, Base64.encodeToString(iv, Base64.NO_WRAP))
            .apply()
    }

    private fun wrappingKey(): SecretKey {
        val store = keystore()
        store.getEntry(KEY_ALIAS, null)?.let { entry ->
            return (entry as KeyStore.SecretKeyEntry).secretKey
        }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        val spec = KeyGenParameterSpec.Builder(
            KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .build()
        generator.init(spec)
        return generator.generateKey()
    }

    private fun keystore(): KeyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }

    companion object {
        private const val PREFS_NAME = "iroh_blob_keystore"
        private const val KEY_WRAPPED_SECRET = "wrapped_secret_v1"
        private const val KEY_WRAP_IV = "wrap_iv_v1"
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val KEY_ALIAS = "ai.openburnbar.iroh-blob-secret"
        private const val AES_GCM_TRANSFORM = "AES/GCM/NoPadding"
        private const val GCM_IV_BYTES = 12
        private const val GCM_TAG_BITS = 128
    }
}
