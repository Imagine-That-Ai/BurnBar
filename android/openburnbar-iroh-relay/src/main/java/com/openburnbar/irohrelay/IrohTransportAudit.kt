package com.openburnbar.irohrelay

/**
 * Shared audit contract for iroh transport telemetry. Mirrors the Swift
 * `IrohTransportAuditLogging` protocol. App targets provide their own
 * Firestore-backed implementation so this module does not pull Firebase
 * into the relay library.
 */
interface IrohTransportAuditLogging {
    suspend fun record(
        event: IrohTransportAuditEvent,
        uid: String,
        connectionId: String,
        transport: IrohTransportSelection?,
        rttMillis: Int?,
        detail: Map<String, String>,
    )
}

enum class IrohTransportAuditEvent(val raw: String) {
    STREAM_OPENED("iroh_stream_opened"),
    STREAM_CLOSED("iroh_stream_closed"),
    STREAM_FAILED("iroh_stream_failed"),
    PAIRING_PUBLISHED("iroh_pairing_published"),
    PAIRING_VERIFIED("iroh_pairing_verified"),
    PAIRING_REJECTED("iroh_pairing_rejected"),
    FALLBACK_TO_WSS("iroh_fallback_to_wss"),
}

enum class IrohTransportSelection(val raw: String) {
    IROH_DIRECT("iroh-direct"),
    IROH_RELAY("iroh-relay"),
    WSS("wss"),
    FIRESTORE("firestore"),
}

/** No-op audit logger for unit tests and the loopback path. */
object NoopIrohTransportAuditLogging : IrohTransportAuditLogging {
    override suspend fun record(
        event: IrohTransportAuditEvent,
        uid: String,
        connectionId: String,
        transport: IrohTransportSelection?,
        rttMillis: Int?,
        detail: Map<String, String>,
    ) = Unit
}
