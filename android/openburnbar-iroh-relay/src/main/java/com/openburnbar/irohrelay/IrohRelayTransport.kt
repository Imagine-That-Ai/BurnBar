package com.openburnbar.irohrelay

/**
 * One iroh bidirectional stream. Every `requestId` gets its own stream; the
 * long-lived `host.register` / `host.ready` exchange uses a dedicated
 * control stream. The transport never inspects frame contents — it just
 * moves length-prefixed JSON between endpoints.
 */
interface IrohRelayStream {
    suspend fun send(frame: HermesRealtimeRelayFrame)
    /** Returns `null` on a clean stream close. */
    suspend fun receive(): HermesRealtimeRelayFrame?
    suspend fun close()
}

/** Identity of an iroh endpoint as seen by the publish/discover layer. */
data class IrohEndpointIdentity(
    /** Base32 NodeId surface form (52 chars). */
    val nodeId: String,
    /** Raw 32-byte public key, equal to the base32-decoded NodeId. */
    val rawPublicKey: ByteArray,
    val relayURL: String? = null,
    val directAddresses: List<String> = emptyList(),
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is IrohEndpointIdentity) return false
        return nodeId == other.nodeId &&
            rawPublicKey.contentEquals(other.rawPublicKey) &&
            relayURL == other.relayURL &&
            directAddresses == other.directAddresses
    }

    override fun hashCode(): Int {
        var h = nodeId.hashCode()
        h = 31 * h + rawPublicKey.contentHashCode()
        h = 31 * h + (relayURL?.hashCode() ?: 0)
        h = 31 * h + directAddresses.hashCode()
        return h
    }
}

/** Dialable address material for a remote iroh endpoint. */
data class IrohDialTarget(
    val nodeId: String,
    val relayURL: String? = null,
    val directAddresses: List<String> = emptyList(),
) {
    constructor(identity: IrohEndpointIdentity) : this(
        nodeId = identity.nodeId,
        relayURL = identity.relayURL,
        directAddresses = identity.directAddresses,
    )

    init {
        // Validation parity with the Swift initializer — drop empty
        // addresses + trim whitespace.
    }
}

/**
 * Transport-level capability. Mac calls `start()` once, then `accept()`
 * in a loop; iOS / Android call `start()` then `connect(to)` per stream.
 */
interface IrohRelayTransport {
    /** Bring up the underlying iroh endpoint. Idempotent. */
    suspend fun start(): IrohEndpointIdentity

    /** Dial a remote endpoint and open one bidirectional stream. */
    suspend fun connect(target: IrohDialTarget, timeoutMillis: Long): IrohRelayStream

    /** Wait for the next inbound bidirectional stream. */
    suspend fun accept(timeoutMillis: Long): IrohRelayStream

    /** Tear the endpoint down. Pending streams are closed. */
    suspend fun shutdown()
}
