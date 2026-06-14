package com.openburnbar.data.hermes.relay

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

private const val IROH_PAIRING_HOST_KEY_BYTES = 32

class IrohPairingHostKeyChangedException(
    val expectedFingerprint: String,
    val observedFingerprint: String,
) : RuntimeException("Iroh pairing host key changed.")

class IrohPairingHostKeyPinPersistenceException(message: String, cause: Throwable? = null) : RuntimeException(message, cause)

interface IrohPairingHostKeyPinStore {
    fun requireTrustedHostKey(uid: String, publicKey: ByteArray): ByteArray
    fun clearTrustedHostKey(uid: String)
}

/**
 * Persistent trust-on-first-use pin for the Mac's iroh pairing host key.
 *
 * **M-006 — at-rest encryption.** The pin is stored in a `MODE_PRIVATE`
 * preferences file whose values are sealed directly with an AES-256-GCM key held
 * in the Android Keystore (hardware-backed where the device offers a TEE). A
 * plaintext XML pin file was readable by anything that obtained the app's
 * private storage (rooted device, backup extraction, forensic image); encrypting
 * it raises the bar for an attacker trying to *read* or *forge* the pinned
 * host-key fingerprint, which the iroh transport treats as the root of trust for
 * the QUIC dial.
 *
 * The scoping and key-change semantics are unchanged from the previous plaintext
 * store: the fingerprint is keyed by a SHA-256 scoped uid, the first observed key
 * is pinned (and rejected on persistence failure), and any later key whose
 * fingerprint differs from the pin throws [IrohPairingHostKeyChangedException].
 *
 * Mirrors the iOS Keychain-backed `IrohHostKeyPinStore`
 * (`WhenUnlockedThisDeviceOnly`).
 */
class SharedPreferencesIrohPairingHostKeyPinStore internal constructor(
    private val persistence: IrohPairingHostKeyPinPersistence,
) : IrohPairingHostKeyPinStore {
    constructor(context: Context) : this(
        KeystoreEncryptedPinPersistence(context.applicationContext, PREFS_NAME),
    )

    @Synchronized
    override fun requireTrustedHostKey(uid: String, publicKey: ByteArray): ByteArray {
        val observedFingerprint = IrohPairingHostKeyPinning.fingerprint(publicKey)
        val key = pinPreferenceKey(uid)
        val expectedFingerprint =
            try {
                persistence.getString(key)
            } catch (err: Exception) {
                throw IrohPairingHostKeyPinPersistenceException(
                    "Unable to read iroh pairing host key pin.",
                    err,
                )
            }
        if (expectedFingerprint == null) {
            val stored =
                try {
                    persistence.putPin(
                        pinKey = key,
                        fingerprint = observedFingerprint,
                        firstSeenKey = firstSeenPreferenceKey(uid),
                        firstSeenMillis = System.currentTimeMillis(),
                    )
                } catch (err: Exception) {
                    throw IrohPairingHostKeyPinPersistenceException(
                        "Unable to persist iroh pairing host key pin.",
                        err,
                    )
                }
            if (!stored) {
                throw IrohPairingHostKeyPinPersistenceException("Unable to persist iroh pairing host key pin.")
            }
            return publicKey.copyOf()
        }
        if (expectedFingerprint != observedFingerprint) {
            throw IrohPairingHostKeyChangedException(
                expectedFingerprint = expectedFingerprint,
                observedFingerprint = observedFingerprint,
            )
        }
        return publicKey.copyOf()
    }

    @Synchronized
    override fun clearTrustedHostKey(uid: String) {
        persistence.remove(pinPreferenceKey(uid), firstSeenPreferenceKey(uid))
    }

    private fun pinPreferenceKey(uid: String): String = "host_key_pin_v1.${IrohPairingHostKeyPinning.scopedUid(uid)}"

    private fun firstSeenPreferenceKey(uid: String): String = "host_key_first_seen_v1.${IrohPairingHostKeyPinning.scopedUid(uid)}"

    companion object {
        private const val PREFS_NAME = "iroh_pairing_host_key_pins"
    }
}

/**
 * Storage seam for [SharedPreferencesIrohPairingHostKeyPinStore]. Production uses
 * [KeystoreEncryptedPinPersistence]; unit tests use an in-memory fake so the
 * pin/key-change logic is verifiable without an Android Keystore.
 */
internal interface IrohPairingHostKeyPinPersistence {
    fun getString(key: String): String?

    fun putPin(pinKey: String, fingerprint: String, firstSeenKey: String, firstSeenMillis: Long): Boolean

    fun remove(vararg keys: String)
}

/**
 * Android Keystore-backed at-rest storage for the host-key pin.
 *
 * This intentionally avoids AndroidX Security Crypto: the stable 1.1.0 APIs are
 * deprecated by AndroidX. The store uses the platform Keystore directly and
 * treats malformed or undecryptable payloads as persistence failures so a
 * corrupted/forged pin cannot silently repin a substituted host key.
 */
internal class KeystoreEncryptedPinPersistence(
    private val context: Context,
    private val prefsName: String,
) : IrohPairingHostKeyPinPersistence {
    private val prefs: SharedPreferences by lazy {
        context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
    }
    private val secretKey: SecretKey by lazy { loadOrCreateSecretKey() }

    override fun getString(key: String): String? = prefs.getString(key, null)?.let(::decrypt)

    override fun putPin(pinKey: String, fingerprint: String, firstSeenKey: String, firstSeenMillis: Long): Boolean = prefs.edit()
        .putString(pinKey, encrypt(fingerprint))
        .putString(firstSeenKey, encrypt(firstSeenMillis.toString()))
        .commit()

    override fun remove(vararg keys: String) {
        val editor = prefs.edit()
        keys.forEach { editor.remove(it) }
        editor.commit()
    }

    private fun encrypt(value: String): String {
        val cipher = Cipher.getInstance(AES_GCM_TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey)
        val iv = cipher.iv
        val ciphertext = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        return listOf(PAYLOAD_VERSION, base64(iv), base64(ciphertext)).joinToString(".")
    }

    private fun decrypt(payload: String): String {
        val parts = payload.split(".")
        require(parts.size == 3 && parts[0] == PAYLOAD_VERSION) { "Unsupported iroh host-key pin payload." }
        val iv = Base64.decode(parts[1], Base64.NO_WRAP)
        val ciphertext = Base64.decode(parts[2], Base64.NO_WRAP)
        val cipher = Cipher.getInstance(AES_GCM_TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, secretKey, GCMParameterSpec(GCM_TAG_BITS, iv))
        return String(cipher.doFinal(ciphertext), Charsets.UTF_8)
    }

    private fun loadOrCreateSecretKey(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }

        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        val spec =
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .setRandomizedEncryptionRequired(true)
                .build()
        generator.init(spec)
        return generator.generateKey()
    }

    private fun base64(bytes: ByteArray): String = Base64.encodeToString(bytes, Base64.NO_WRAP)

    private companion object {
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val AES_GCM_TRANSFORMATION = "AES/GCM/NoPadding"
        private const val GCM_TAG_BITS = 128
        private const val KEY_ALIAS = "openburnbar.iroh_pairing_host_key_pins.v1"
        private const val PAYLOAD_VERSION = "v1"
    }
}

class InMemoryIrohPairingHostKeyPinStore : IrohPairingHostKeyPinStore {
    private val pins = ConcurrentHashMap<String, String>()

    override fun requireTrustedHostKey(uid: String, publicKey: ByteArray): ByteArray {
        val observedFingerprint = IrohPairingHostKeyPinning.fingerprint(publicKey)
        val key = IrohPairingHostKeyPinning.scopedUid(uid)
        val expectedFingerprint = pins.putIfAbsent(key, observedFingerprint)
        if (expectedFingerprint != null && expectedFingerprint != observedFingerprint) {
            throw IrohPairingHostKeyChangedException(
                expectedFingerprint = expectedFingerprint,
                observedFingerprint = observedFingerprint,
            )
        }
        return publicKey.copyOf()
    }

    override fun clearTrustedHostKey(uid: String) {
        pins.remove(IrohPairingHostKeyPinning.scopedUid(uid))
    }

    fun pinnedFingerprint(uid: String): String? = pins[IrohPairingHostKeyPinning.scopedUid(uid)]
}

object IrohPairingHostKeyPinning {
    fun fingerprint(publicKey: ByteArray): String {
        require(publicKey.size == IROH_PAIRING_HOST_KEY_BYTES) { "Iroh pairing host key must be 32 bytes." }
        return base64UrlNoPadding(sha256(publicKey))
    }

    fun scopedUid(uid: String): String {
        require(uid.isNotBlank()) { "Iroh pairing host-key pin requires a non-empty uid." }
        return base64UrlNoPadding(sha256(uid.toByteArray(Charsets.UTF_8)))
    }

    private fun sha256(bytes: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(bytes)

    private fun base64UrlNoPadding(bytes: ByteArray): String = Base64.encodeToString(bytes, Base64.NO_WRAP or Base64.URL_SAFE or Base64.NO_PADDING)
}
