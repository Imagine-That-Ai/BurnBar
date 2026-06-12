package com.openburnbar.data.hermes.relay

import com.openburnbar.irohrelay.IrohRelayTransportError
import com.openburnbar.irohrelay.IrohTransportAuditEvent
import com.openburnbar.irohrelay.IrohTransportAuditLogging
import com.openburnbar.irohrelay.IrohTransportSelection
import com.openburnbar.irohrelay.NoopIrohTransportAuditLogging

/** Cap on the error-reason text recorded in the fallback audit detail. */
private const val AUDIT_FALLBACK_REASON_MAX_CHARS = 256

/**
 * Cascading relay that prefers iroh and can fall back to Firestore on
 * timeout / dial failure. Matches the Android relay contract:
 *
 *   1. If the kill switch is set (`hermes_iroh_transport_enabled`
 *      remote-config flag returns false), skip iroh entirely.
 *   2. Otherwise attempt iroh. Unary control-plane calls fall back to
 *      Firestore. Streaming `/v1/chat/completions` surfaces direct iroh
 *      stream failures instead of silently rerouting the selected model
 *      through a different relay path, but stale/invalid iroh pairing
 *      metadata falls back to the same selected Mac's Firestore relay.
 *      Streaming `/v1/cli-agent/chat` also falls back to Firestore because
 *      it still targets the same selected Mac executor.
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

    override suspend fun sendStreaming(payload: HermesRelayPayload, timeoutMillis: Long, onSseEvent: suspend (String) -> Unit) {
        if (!featureFlag()) {
            return firestoreFallback.sendStreaming(payload, timeoutMillis, onSseEvent)
        }
        try {
            iroh.sendStreaming(payload, timeoutMillis, onSseEvent)
        } catch (err: IrohRelayTransportError) {
            auditFallback(payload, err)
            if (shouldFallbackStreaming(payload, err)) {
                return firestoreFallback.sendStreaming(payload, timeoutMillis, onSseEvent)
            }
            throw HermesRelayException(
                "Iroh direct Hermes relay failed before the selected Mac harness completed: " +
                    "${err.message ?: err.javaClass.simpleName}. No Firestore fallback was attempted, " +
                    "so the selected model is not silently rerouted.",
                err,
            )
        }
    }

    private fun shouldFallbackStreaming(payload: HermesRelayPayload, err: IrohRelayTransportError): Boolean =
        payload.operation == HermesRelayOperationName.CLI_AGENT_CHAT ||
            err is IrohRelayTransportError.PairingRejected

    private suspend fun auditFallback(payload: HermesRelayPayload, err: IrohRelayTransportError) {
        auditLogger.record(
            event = IrohTransportAuditEvent.FALLBACK_TO_FIRESTORE,
            uid = "", // composite doesn't know uid; the inner transport already recorded STREAM_FAILED for full attribution.
            connectionId = payload.connectionID,
            transport = IrohTransportSelection.FIRESTORE,
            rttMillis = null,
            detail =
            mapOf(
                "reason" to (err.message ?: err.javaClass.simpleName).take(AUDIT_FALLBACK_REASON_MAX_CHARS),
                "target" to "firestore",
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
            timeoutMillis = timeoutMillis,
        )
    }

    override suspend fun sendStreaming(payload: HermesRelayPayload, timeoutMillis: Long, onSseEvent: suspend (String) -> Unit) {
        val descriptor = descriptorProvider(payload.connectionID)
        client.sendStreaming(
            connection = descriptor,
            operation = payload.operation,
            method = payload.method,
            path = payload.path,
            body = payload.body ?: ByteArray(0),
            sessionId = payload.sessionID,
            timeoutMillis = timeoutMillis,
            onChunk = { _, text -> onSseEvent(text) },
        )
    }
}
