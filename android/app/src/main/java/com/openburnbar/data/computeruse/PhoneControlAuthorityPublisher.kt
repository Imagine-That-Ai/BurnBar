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

data class PhoneControlAuthorityDoc(
    val id: String,
    val connectionId: String,
    val peerNodeId: String,
    val deviceId: String,
    val publicKeyBase64: String,
    val publishedAtMillis: Long,
    val protocolVersion: Int = HermesRealtimeRelayProtocol.VERSION,
    val schemaVersion: Int = 1,
    /**
     * F2 — signing key custody class (`PhoneControlSigningKeyKind` wire
     * value). `null` for the legacy Ed25519 key so legacy publishes stay
     * byte-identical (the server treats absence as `ed25519`); `"se-p256"`
     * for a StrongBox/TEE P-256 key published as 65-byte X9.63.
     */
    val keyKind: String? = null,
) {
    fun asMap(): Map<String, Any> = buildMap {
        put("id", id)
        put("connectionId", connectionId)
        put("peerNodeId", peerNodeId)
        put("deviceId", deviceId)
        put("publicKeyBase64", publicKeyBase64)
        put("publishedAtMillis", publishedAtMillis)
        put("protocolVersion", protocolVersion)
        put("schemaVersion", schemaVersion)
        keyKind?.let { put("keyKind", it) }
    }
}

object PhoneControlAuthorityDocumentFactory {
    private const val VAL_24 = 24
    private const val VAL_32 = 32
    fun peerNodeId(publicKey: ByteArray): String {
        require(publicKey.size == VAL_32) { "Ed25519 public key must be 32 bytes" }
        return "android-phone-${sha256Hex(publicKey).take(VAL_24)}"
    }

    /**
     * F2 — canonical Android peerNodeId for a key-kind-aware identity. Must
     * stay byte-identical to `PhoneControlPeerNodeIdDerivation` (Swift) and
     * `requireDerivedPhoneControlPeerNodeId` (server):
     *
     * - Ed25519: `android-phone-<sha256hex(rawKey)[0..<24]>` (legacy)
     * - SE-P256: `android-se-<sha256hex(x963Key)[0..<24]>`
     */
    fun peerNodeId(identity: PhoneControlSigningIdentity): String = when (identity.kind) {
        PhoneControlSigningKeyKind.ED25519 -> peerNodeId(identity.publicKeyRepresentation)
        PhoneControlSigningKeyKind.SECURE_ENCLAVE_P256 ->
            "android-se-${sha256Hex(identity.publicKeyRepresentation).take(VAL_24)}"
    }

    fun document(connectionId: String, deviceId: String, publicKey: ByteArray, publishedAtMillis: Long): PhoneControlAuthorityDoc {
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

    /**
     * F2 — key-kind-aware twin of `document(...)`. Legacy Ed25519 identities
     * produce the exact pre-F2 document (no `keyKind`); SE-P256 identities
     * publish the 65-byte X9.63 key, the `android-se-` peerNodeId, and the
     * `"se-p256"` discriminator the server persists as `signingKeyKind`.
     */
    fun document(
        connectionId: String,
        deviceId: String,
        identity: PhoneControlSigningIdentity,
        publishedAtMillis: Long,
    ): PhoneControlAuthorityDoc {
        val peerNodeId = peerNodeId(identity)
        return PhoneControlAuthorityDoc(
            id = peerNodeId,
            connectionId = connectionId,
            peerNodeId = peerNodeId,
            deviceId = deviceId,
            publicKeyBase64 = Base64.getEncoder().encodeToString(identity.publicKeyRepresentation),
            publishedAtMillis = publishedAtMillis,
            keyKind = identity.wireKeyKind,
        )
    }

    private fun sha256Hex(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256")
        .digest(bytes)
        .joinToString("") { "%02x".format(it) }
}

class PhoneControlAuthorityPublisher(
    private val firestore: FirebaseFirestore = FirebaseFirestore.getInstance(),
    private val securityCallables: ComputerUseSecurityCallableClient = ComputerUseSecurityCallableClient(),
) {
    suspend fun publish(uid: String, authority: PhoneControlAuthorityDoc) {
        securityCallables.publishPhoneControlAuthority(authority)
    }

    suspend fun publishAgentGrantAuthority(uid: String, sourceDeviceId: String, authority: PhoneControlAuthorityDoc) {
        securityCallables.publishAgentGrantAuthority(
            deviceId = sourceDeviceId,
            peerNodeId = authority.peerNodeId,
            publicKeyBase64 = authority.publicKeyBase64,
            keyKind = authority.keyKind,
        )
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

    fun peerNodeId(): String = peerNodeId(signingIdentity())

    fun peerNodeId(identity: PhoneControlSigningIdentity): String = PhoneControlAuthorityDocumentFactory.peerNodeId(identity)

    /**
     * F2 — the key-kind-aware signing identity, gated by the
     * `computer_use_phone_control_secure_enclave_key` Remote Config flag.
     * Mirrors the iOS `PhoneControlSigningKeyStore.signingIdentity()`.
     */
    fun signingIdentity(): PhoneControlSigningIdentity =
        signingIdentity(secureEnclaveEnabled = PhoneControlSecureEnclaveKeyPolicy.secureEnclaveKeyEnabled())

    /**
     * Resolution order (identical to iOS):
     *  1. An already-minted StrongBox/TEE key always wins (its peerNodeId is
     *     the published controller identity — never silently downgrade).
     *  2. With the gate on and the keystore available, mint a biometry-gated
     *     hardware P-256 key (StrongBox preferred, TEE fallback).
     *  3. Otherwise the legacy software Ed25519 key (wire-identical to pre-F2).
     */
    fun signingIdentity(secureEnclaveEnabled: Boolean): PhoneControlSigningIdentity {
        PhoneControlSecureEnclaveKeystore.loadIdentity()?.let { return it }
        if (secureEnclaveEnabled) {
            PhoneControlSecureEnclaveKeystore.mintIdentity()?.let { return it }
        }
        return PhoneControlSigningIdentity.Ed25519(privateKeySeed())
    }

    fun reset() {
        prefs.edit().clear().apply()
        runCatching { keystore().deleteEntry(KEY_ALIAS) }
        PhoneControlSecureEnclaveKeystore.deleteKey()
    }

    private fun loadFromStore(): ByteArray? {
        val wrappedB64 = prefs.getString(KEY_WRAPPED_SEED, null)
        val ivB64 = prefs.getString(KEY_WRAP_IV, null)
        val wrapped = wrappedB64?.let { runCatching { Base64.getDecoder().decode(it) }.getOrNull() }
        val iv = ivB64?.let { runCatching { Base64.getDecoder().decode(it) }.getOrNull() }
        val key = runCatching { wrappingKey() }.getOrNull()
        if (wrapped == null || iv == null || key == null) return null
        return try {
            val cipher =
                Cipher.getInstance(AES_GCM_TRANSFORM).apply {
                    init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(GCM_TAG_BITS, iv))
                }
            val plain = cipher.doFinal(wrapped)
            plain.takeIf { it.size == VAL_32 }
        } catch (_: Throwable) {
            null
        }
    }

    private fun saveToStore(seed: ByteArray) {
        require(seed.size == VAL_32) { "Ed25519 private key seed must be 32 bytes" }
        val key = wrappingKey()
        val cipher =
            Cipher.getInstance(AES_GCM_TRANSFORM).apply {
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
        private const val VAL_32 = 32
        private const val VAL_256 = 256
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
