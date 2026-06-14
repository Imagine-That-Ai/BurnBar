package com.openburnbar.data.cloud.signalsession

import android.content.Context
import com.openburnbar.data.cloud.AndroidLocalSecretBox
import com.openburnbar.data.cloud.CloudVaultCryptoSupport
import java.util.concurrent.ConcurrentHashMap

/**
 * Minimal persistence boundary for [AndroidSignalProtocolStore]. Production backs this with
 * `AndroidLocalSecretBox`-sealed SharedPreferences (device-local, AES-256-GCM via the Android
 * KeyStore); JVM unit tests use [InMemorySignalRecordVault] so the libsignal Double Ratchet
 * round-trip runs with NO device/emulator. The store keeps the ratchet state device-local —
 * it is never written to Firestore (mirrors `SESSION_STATE_STORAGE = "device-local-only"`).
 */
interface SignalRecordVault {
    fun read(account: String): ByteArray?
    fun write(account: String, data: ByteArray)
    fun delete(account: String)
    fun accounts(prefix: String): List<String>
}

class AndroidEncryptedSignalRecordVault(
    context: Context,
    name: String = "openburnbar_signal_protocol_store",
) : SignalRecordVault {
    private val prefs = context.applicationContext.getSharedPreferences(name, Context.MODE_PRIVATE)

    override fun read(account: String): ByteArray? {
        val sealed = prefs.getString(storageKey(account), null) ?: return null
        return AndroidLocalSecretBox.decrypt(CloudVaultCryptoSupport.decodeBase64(sealed))
    }

    override fun write(account: String, data: ByteArray) {
        val sealed = AndroidLocalSecretBox.encrypt(data.copyOf())
        prefs.edit()
            .putString(storageKey(account), CloudVaultCryptoSupport.encodeBase64(sealed))
            .apply()
    }

    override fun delete(account: String) {
        prefs.edit().remove(storageKey(account)).apply()
    }

    override fun accounts(prefix: String): List<String> = prefs.all.keys
        .asSequence()
        .filter { it.startsWith(KEY_PREFIX) }
        .map { it.removePrefix(KEY_PREFIX) }
        .filter { it.startsWith(prefix) }
        .toList()

    private fun storageKey(account: String): String {
        require(!account.contains("\u0000")) { "account contains forbidden NUL" }
        return KEY_PREFIX + account
    }

    private companion object {
        const val KEY_PREFIX = "signal_record:"
    }
}

/** In-memory, hermetic vault for JVM tests (no AndroidKeyStore / SharedPreferences). */
class InMemorySignalRecordVault : SignalRecordVault {
    private val map = ConcurrentHashMap<String, ByteArray>()

    override fun read(account: String): ByteArray? = map[account]?.copyOf()

    override fun write(account: String, data: ByteArray) {
        map[account] = data.copyOf()
    }

    override fun delete(account: String) {
        map.remove(account)
    }

    override fun accounts(prefix: String): List<String> = map.keys.filter { it.startsWith(prefix) }
}
