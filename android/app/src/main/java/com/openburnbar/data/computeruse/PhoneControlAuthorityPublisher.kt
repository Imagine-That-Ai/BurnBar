package com.openburnbar.data.computeruse

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import com.google.firebase.firestore.FirebaseFirestore
import com.openburnbar.irohrelay.HermesRealtimeRelayProtocol
import java.security.KeyStore
import java.security.MessageDigest
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlinx.coroutines.tasks.await

data class PhoneControlAuthorityDoc(
    val id: String,
    val connectionId: String,
    val peerNodeId: String,
    val deviceId: String,
    val publicKeyBase64: String,
    val publishedAtMillis: Long,
    val protocolVersion: Int = HermesRealtimeRelayProtocol.VERSION,
    val schemaVersion: Int = 1,
) {
    fun asMap(): Map<String, Any> = mapOf(
        "id" to id,
        "connectionId" to connectionId,
        "peerNodeId" to peerNodeId,
        "deviceId" to deviceId,
        "publicKeyBase64" to publicKeyBase64,
        "publishedAtMillis" to publishedAtMillis,
        "protocolVersion" to protocolVersion,
        "schemaVersion" to schemaVersion,
    )
}

object PhoneControlAuthorityDocumentFactory {
    fun peerNodeId(publicKey: ByteArray): String {
        require(publicKey.size == 32) { "Ed25519 public key must be 32 bytes" }
        return "android-phone-${sha256Hex(publicKey).take(24)}"
    }

    fun document(
        connectionId: String,
        deviceId: String,
        publicKey: ByteArray,
        publishedAtMillis: Long,
    ): PhoneControlAuthorityDoc {
        val peerNodeId = peerNodeId(publicKey)
        return PhoneControlAuthorityDoc(
            id = peerNodeId,
            connectionId = connectionId,
            peerNodeId = peerNodeId,
            deviceId = deviceId,
            publicKeyBase64 = Base64.getEncoder().encodeToString(publicKey),
            publishedAtMillis = publishedAtMillis,
        )
    }

    private fun sha256Hex(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256")
            .digest(bytes)
            .joinToString("") { "%02x".format(it) }
}

class PhoneControlAuthorityPublisher(
    private val firestore: FirebaseFirestore = FirebaseFirestore.getInstance(),
) {
    suspend fun publish(uid: String, authority: PhoneControlAuthorityDoc) {
        firestore.collection("users").document(uid)
            .collection("iroh_pairing").document(authority.connectionId)
            .collection("controllers").document(authority.peerNodeId)
            .set(authority.asMap())
            .await()
    }
}

class PhoneControlSigningKeyStore(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun privateKeySeed(): ByteArray {
        loadFromStore()?.let { return it }
        val fresh = PhoneControlSigner.newPrivateKeySeed()
        saveToStore(fresh)
        return fresh
    }

    fun publicKey(): ByteArray = PhoneControlSigner.publicKey(privateKeySeed())

    fun peerNodeId(): String = PhoneControlAuthorityDocumentFactory.peerNodeId(publicKey())

    fun reset() {
        prefs.edit().clear().apply()
        runCatching { keystore().deleteEntry(KEY_ALIAS) }
    }

    private fun loadFromStore(): ByteArray? {
        val wrappedB64 = prefs.getString(KEY_WRAPPED_SEED, null) ?: return null
        val ivB64 = prefs.getString(KEY_WRAP_IV, null) ?: return null
        val wrapped = runCatching { Base64.getDecoder().decode(wrappedB64) }.getOrNull() ?: return null
        val iv = runCatching { Base64.getDecoder().decode(ivB64) }.getOrNull() ?: return null
        val key = runCatching { wrappingKey() }.getOrNull() ?: return null
        return try {
            val cipher = Cipher.getInstance(AES_GCM_TRANSFORM).apply {
                init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(GCM_TAG_BITS, iv))
            }
            val plain = cipher.doFinal(wrapped)
            if (plain.size == 32) plain else null
        } catch (_: Throwable) {
            null
        }
    }

    private fun saveToStore(seed: ByteArray) {
        require(seed.size == 32) { "Ed25519 private key seed must be 32 bytes" }
        val key = wrappingKey()
        val cipher = Cipher.getInstance(AES_GCM_TRANSFORM).apply {
            init(Cipher.ENCRYPT_MODE, key)
        }
        val iv = cipher.iv
        require(iv.size == GCM_IV_BYTES) { "Unexpected AES-GCM IV length ${iv.size}" }
        val wrapped = cipher.doFinal(seed)
        prefs.edit()
            .putString(KEY_WRAPPED_SEED, Base64.getEncoder().encodeToString(wrapped))
            .putString(KEY_WRAP_IV, Base64.getEncoder().encodeToString(iv))
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
        private const val PREFS_NAME = "computer_use_phone_control_keys"
        private const val KEY_WRAPPED_SEED = "wrapped_ed25519_seed_v1"
        private const val KEY_WRAP_IV = "wrap_iv_v1"
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val KEY_ALIAS = "ai.openburnbar.computer-use-phone-control"
        private const val AES_GCM_TRANSFORM = "AES/GCM/NoPadding"
        private const val GCM_IV_BYTES = 12
        private const val GCM_TAG_BITS = 128
    }
}
