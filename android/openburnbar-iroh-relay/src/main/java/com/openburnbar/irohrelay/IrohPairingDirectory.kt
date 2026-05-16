package com.openburnbar.irohrelay

import java.util.concurrent.ConcurrentHashMap

/**
 * Storage-agnostic surface for the iroh pairing record. Production
 * implementations (Firestore-backed) live in :app.
 */
interface IrohPairingDirectory {
    /** Persists the signed pairing record. Idempotent. Android is verify-only and rarely publishes. */
    suspend fun publish(record: IrohPairingRecord, uid: String)
    /** Fetches the pairing record advertised by the Mac for this user + connection. */
    suspend fun fetch(uid: String, connectionId: String): IrohPairingRecord?
    /** Removes the pairing record. */
    suspend fun revoke(uid: String, connectionId: String)
}

class IrohPairingDirectoryException(message: String, cause: Throwable? = null) :
    RuntimeException(message, cause) {
    companion object {
        fun recordNotFound(): IrohPairingDirectoryException =
            IrohPairingDirectoryException("pairing record not found")

        fun unsupportedOnReader(): IrohPairingDirectoryException =
            IrohPairingDirectoryException("publish/revoke not supported on reader directory")
    }
}

/** In-memory directory for tests + dev fixtures. Threadsafe by construction. */
class InMemoryIrohPairingDirectory : IrohPairingDirectory {
    private val store = ConcurrentHashMap<String, IrohPairingRecord>()

    override suspend fun publish(record: IrohPairingRecord, uid: String) {
        store[key(uid, record.connectionId)] = record
    }

    override suspend fun fetch(uid: String, connectionId: String): IrohPairingRecord? =
        store[key(uid, connectionId)]

    override suspend fun revoke(uid: String, connectionId: String) {
        store.remove(key(uid, connectionId))
    }

    fun snapshot(): List<IrohPairingRecord> = store.values.toList()

    private fun key(uid: String, connectionId: String): String = "${uid}::${connectionId}"
}

/**
 * High-level pairing publisher. Android is verify-only by default — call
 * `fetchAndVerify(...)` before dialing. The publisher signs canonical
 * AAD locally — directories never see the signing key.
 */
class IrohPairingPublisher(private val directory: IrohPairingDirectory) {
    /**
     * Verify-only flow. Returns the verified dial target, or throws an
     * `IrohPairingError` (signature, expired, malformed) or
     * `IrohPairingDirectoryException` (record not found).
     */
    suspend fun fetchAndVerify(
        uid: String,
        connectionId: String,
        publicKey: ByteArray,
        nowMillis: Long = System.currentTimeMillis(),
    ): IrohDialTarget {
        val record = directory.fetch(uid, connectionId)
            ?: throw IrohPairingDirectoryException.recordNotFound()
        IrohPairingSignature.verify(record, publicKey = publicKey, nowMillis = nowMillis)
        return record.dialTarget()
    }
}
