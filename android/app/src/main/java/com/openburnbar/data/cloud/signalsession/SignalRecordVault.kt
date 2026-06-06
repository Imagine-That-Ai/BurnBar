package com.openburnbar.data.cloud.signalsession

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
