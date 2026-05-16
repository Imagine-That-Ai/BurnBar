package com.openburnbar.data.hermes.relay

import com.openburnbar.irohrelay.IrohRelayTransportError
import com.openburnbar.irohrelay.IrohTransportAuditEvent
import com.openburnbar.irohrelay.IrohTransportAuditLogging
import com.openburnbar.irohrelay.IrohTransportSelection
import com.openburnbar.irohrelay.NoopIrohTransportAuditLogging

/**
 * Cascading relay that prefers iroh and falls back to Firestore on
 * timeout / dial failure. Matches the iOS `HermesCompositeRelayTransport`
 * behavior:
 *
 *   1. If the kill switch is set (`hermes_iroh_transport_enabled`
 *      remote-config flag returns false), skip iroh entirely.
 *   2. Otherwise attempt iroh; on `TimedOut` / `StreamRejected` /
 *      `EndpointNotReady` / `Shutdown`, audit a fallback event and
 *      delegate to the Firestore client. Decode errors and unknown
 *      throwables propagate (they almost certainly indicate a server
 *      bug we want to surface, not a transport drop).
 */
class HermesCompositeRelayTransport(
    private val iroh: HermesRelayTransporting,
    private val firestoreFallback: HermesRelayTransporting,
    private val featureFlag: () -> Boolean = { true },
    private val auditLogger: IrohTransportAuditLogging = NoopIrohTransportAuditLogging,
) : HermesRelayTransporting {
    override suspend fun sendUnary(payload: HermesRelayPayload, timeoutMillis: Long): String {
        if (!featureFlag()) {
            return firestoreFallback.sendUnary(payload, timeoutMillis)
        }
        return try {
            iroh.sendUnary(payload, timeoutMillis)
        } catch (err: IrohRelayTransportError) {
            auditFallback(payload, err)
            firestoreFallback.sendUnary(payload, timeoutMillis)
        }
    }

    override suspend fun sendStreaming(
        payload: HermesRelayPayload,
        timeoutMillis: Long,
        onSseEvent: suspend (String) -> Unit,
    ) {
        if (!featureFlag()) {
            return firestoreFallback.sendStreaming(payload, timeoutMillis, onSseEvent)
        }
        try {
            iroh.sendStreaming(payload, timeoutMillis, onSseEvent)
        } catch (err: IrohRelayTransportError) {
            auditFallback(payload, err)
            firestoreFallback.sendStreaming(payload, timeoutMillis, onSseEvent)
        }
    }

    private suspend fun auditFallback(payload: HermesRelayPayload, err: IrohRelayTransportError) {
        auditLogger.record(
            event = IrohTransportAuditEvent.FALLBACK_TO_WSS,
            uid = "", // composite doesn't know uid — leave blank; the inner transport already recorded the SREAM_FAILED for full attribution.
            connectionId = payload.connectionID,
            transport = IrohTransportSelection.FIRESTORE,
            rttMillis = null,
            detail = mapOf(
                "reason" to (err.message ?: err.javaClass.simpleName).take(256),
            ),
        )
    }
}

/**
 * Thin shim around the Firestore-polling `HermesRelayClient` so the
 * cascade composes against a single interface. Production wiring builds
 * it from a real `HermesRelayClient`; tests substitute fakes.
 */
class FirestoreRelayShim(
    private val client: HermesRelayClient,
    private val descriptorProvider: suspend (connectionId: String) -> HermesRelayConnectionDescriptor,
) : HermesRelayTransporting {
    override suspend fun sendUnary(payload: HermesRelayPayload, timeoutMillis: Long): String {
        val descriptor = descriptorProvider(payload.connectionID)
        return client.sendUnary(
            connection = descriptor,
            operation = payload.operation,
            method = payload.method,
            path = payload.path,
            body = payload.body ?: ByteArray(0),
            sessionId = payload.sessionID,
        )
    }

    override suspend fun sendStreaming(
        payload: HermesRelayPayload,
        timeoutMillis: Long,
        onSseEvent: suspend (String) -> Unit,
    ) {
        val descriptor = descriptorProvider(payload.connectionID)
        client.sendStreaming(
            connection = descriptor,
            operation = payload.operation,
            method = payload.method,
            path = payload.path,
            body = payload.body ?: ByteArray(0),
            sessionId = payload.sessionID,
            onChunk = { _, text -> onSseEvent(text) },
        )
    }
}
