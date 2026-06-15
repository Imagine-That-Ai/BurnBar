package com.openburnbar.data.hermes.relay

import android.content.Context
import android.content.SharedPreferences
import android.util.Base64
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap

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
 * **M-006 — at-rest encryption.** The pin is stored in an
 * [EncryptedSharedPreferences] store whose key/value entries are sealed with
 * an AES-256 master key held in the Android Keystore (hardware-backed where the
 * device offers a TEE/StrongBox). A plaintext `MODE_PRIVATE` XML pin file was
 * readable by anything that obtained the app's private storage (rooted device,
 * backup extraction, forensic image); encrypting it raises the bar for an
 * attacker trying to *read* or *forge* the pinned host-key fingerprint, which
 * the iroh transport treats as the root of trust for the QUIC dial.
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
        EncryptedSharedPreferencesPinPersistence(context.applicationContext, PREFS_NAME),
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
 * [EncryptedSharedPreferencesPinPersistence]; unit tests use an in-memory fake so
 * the pin/key-change logic is verifiable without an Android Keystore.
 */
internal interface IrohPairingHostKeyPinPersistence {
    fun getString(key: String): String?

    fun putPin(pinKey: String, fingerprint: String, firstSeenKey: String, firstSeenMillis: Long): Boolean

    fun remove(vararg keys: String)
}

/**
 * Android Keystore-backed at-rest storage for the host-key pin. Entries are
 * sealed by [EncryptedSharedPreferences] under an AES-256-GCM [MasterKey]. If the
 * encrypted store cannot be opened (corrupted keyset / Keystore migration), the
 * backing file + keyset are dropped once and recreated so a poisoned/corrupt
 * store can never masquerade as a valid pin — the caller then re-pins on first
 * use, which the directory verification still guards.
 */
internal class EncryptedSharedPreferencesPinPersistence(
    private val context: Context,
    private val prefsName: String,
) : IrohPairingHostKeyPinPersistence {
    private val prefs: SharedPreferences by lazy { openEncryptedPrefs() }

    override fun getString(key: String): String? = prefs.getString(key, null)

    override fun putPin(pinKey: String, fingerprint: String, firstSeenKey: String, firstSeenMillis: Long): Boolean = prefs.edit()
        .putString(pinKey, fingerprint)
        .putLong(firstSeenKey, firstSeenMillis)
        .commit()

    override fun remove(vararg keys: String) {
        val editor = prefs.edit()
        keys.forEach { editor.remove(it) }
        editor.commit()
    }

    private fun openEncryptedPrefs(): SharedPreferences {
        val masterKey =
            MasterKey.Builder(context)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()
        return try {
            createEncryptedPrefs(masterKey)
        } catch (_: Exception) {
            // A corrupt keyset or a Keystore migration can make the existing
            // encrypted store unreadable. Drop it once and recreate so we never
            // silently fall back to an unencrypted/forged pin file; the next
            // first-use pin re-establishes trust.
            context.deleteSharedPreferences(prefsName)
            createEncryptedPrefs(masterKey)
        }
    }

    private fun createEncryptedPrefs(masterKey: MasterKey): SharedPreferences = EncryptedSharedPreferences.create(
        context,
        prefsName,
        masterKey,
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
    )
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
