package com.openburnbar.data.computeruse

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Android-local Remote Unlock credential persistence. The Mac never receives
 * anything at rest from this store: passwords are AES-GCM wrapped with an
 * AndroidKeyStore key, scoped per Remote Unlock recipient, and decrypted only
 * after the caller has completed BiometricPrompt / device-credential auth.
 */
class RemoteUnlockSavedCredentialStore(context: Context) {

    private val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun hasCredential(storeKey: String): Boolean {
        val key = scopedKey(storeKey)
        return prefs.contains(ciphertextPreferenceKey(key)) && prefs.contains(ivPreferenceKey(key))
    }

    fun save(storeKey: String, credential: String) {
        val secretKey = wrappingKey()
        val cipher = Cipher.getInstance(AES_GCM_TRANSFORM).apply {
            init(Cipher.ENCRYPT_MODE, secretKey)
        }
        val iv = cipher.iv
        require(iv.size == GCM_IV_BYTES) { "Unexpected AES-GCM IV length ${iv.size}" }
        val wrapped = cipher.doFinal(credential.toByteArray(Charsets.UTF_8))
        val key = scopedKey(storeKey)
        prefs.edit()
            .putString(ciphertextPreferenceKey(key), Base64.encodeToString(wrapped, Base64.NO_WRAP))
            .putString(ivPreferenceKey(key), Base64.encodeToString(iv, Base64.NO_WRAP))
            .apply()
    }

    fun load(storeKey: String): String? {
        val key = scopedKey(storeKey)
        val wrappedB64 = prefs.getString(ciphertextPreferenceKey(key), null) ?: return null
        val ivB64 = prefs.getString(ivPreferenceKey(key), null) ?: return null
        val wrapped = runCatching { Base64.decode(wrappedB64, Base64.NO_WRAP) }.getOrNull() ?: return null
        val iv = runCatching { Base64.decode(ivB64, Base64.NO_WRAP) }.getOrNull() ?: return null
        val secretKey = runCatching { wrappingKey() }.getOrNull() ?: return null
        return try {
            val cipher = Cipher.getInstance(AES_GCM_TRANSFORM).apply {
                init(Cipher.DECRYPT_MODE, secretKey, GCMParameterSpec(GCM_TAG_BITS, iv))
            }
            cipher.doFinal(wrapped).toString(Charsets.UTF_8)
        } catch (_: Throwable) {
            null
        }
    }

    fun delete(storeKey: String) {
        val key = scopedKey(storeKey)
        prefs.edit()
            .remove(ciphertextPreferenceKey(key))
            .remove(ivPreferenceKey(key))
            .apply()
    }

    private fun wrappingKey(): SecretKey {
        val store = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        store.getEntry(KEY_ALIAS, null)?.let { entry ->
            val secretEntry = entry as? KeyStore.SecretKeyEntry
                ?: error("Keystore entry $KEY_ALIAS is not a secret key")
            return secretEntry.secretKey
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

    private fun scopedKey(storeKey: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(storeKey.toByteArray(Charsets.UTF_8))
        return Base64.encodeToString(digest, Base64.NO_WRAP or Base64.URL_SAFE or Base64.NO_PADDING)
    }

    private fun ciphertextPreferenceKey(scopedKey: String): String = "credential.$scopedKey"

    private fun ivPreferenceKey(scopedKey: String): String = "iv.$scopedKey"

    companion object {
        private const val PREFS_NAME = "remote_unlock_saved_credentials"
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val KEY_ALIAS = "ai.openburnbar.remote-unlock.saved-credential"
        private const val AES_GCM_TRANSFORM = "AES/GCM/NoPadding"
        private const val GCM_IV_BYTES = 12
        private const val GCM_TAG_BITS = 128
    }
}
