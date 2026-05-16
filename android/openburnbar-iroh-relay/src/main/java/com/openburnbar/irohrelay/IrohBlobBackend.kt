package com.openburnbar.irohrelay

/**
 * Backend contract for the iroh-blobs side of Mercury media. Parallel to
 * `IrohEndpointBackend` but pinned to `iroh_blobs::ALPN`. Two endpoints
 * per device — chat keeps its single-ALPN router; blobs get their own —
 * matches the Swift Mercury Phase 1 architecture.
 */
interface IrohBlobBackend {
    /**
     * Spin up the blob endpoint with a 32-byte secret + on-disk store
     * directory. Returns the iroh node identity. `relayURL` null → n0
     * public relays; non-null → pin the relay.
     */
    suspend fun bootstrap(
        secret: ByteArray,
        storeDirectoryPath: String,
        relayURL: String?,
    ): IrohEndpointIdentity

    /**
     * Hash + ingest a local file into the blob store. Returns the base32
     * `BlobTicket` text the receiver dials with.
     */
    suspend fun publishBlob(localPath: String): String

    /**
     * Dial the ticket's source node, download the blob, write it to
     * `destination`. Resume across reconnects is handled internally.
     */
    suspend fun fetchBlob(ticketText: String, destination: String): BlobTransferStats

    /** Returns the cached identity. Throws if `bootstrap` has not been called. */
    suspend fun identity(): IrohEndpointIdentity

    /** Tear down the router + endpoint + store + runtime. Idempotent. */
    suspend fun shutdown()
}

/** Per-transfer statistics returned from `fetchBlob`. */
data class BlobTransferStats(
    val bytesTotal: Long,
    val blake3Hash: String,
    val durationMillis: Long,
    val didResume: Boolean,
)

sealed class IrohBlobBackendError(message: String) : RuntimeException(message) {
    object NotInitialized : IrohBlobBackendError("blob backend not initialized")
    object InvalidSecretKey : IrohBlobBackendError("invalid blob secret key")
    data class InvalidTicket(val detail: String) : IrohBlobBackendError("invalid blob ticket: $detail")
    data class PublishFailed(val detail: String) : IrohBlobBackendError("publish failed: $detail")
    data class FetchFailed(val detail: String) : IrohBlobBackendError("fetch failed: $detail")
    data class StoreUnavailable(val detail: String) : IrohBlobBackendError("store unavailable: $detail")
    data class RuntimeFailed(val detail: String) : IrohBlobBackendError("runtime failed: $detail")
}
