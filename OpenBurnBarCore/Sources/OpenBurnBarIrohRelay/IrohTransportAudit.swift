import Foundation

/// Shared audit contract for iroh transport telemetry. App targets provide
/// their own Firestore-backed implementation so the SwiftPM relay package
/// does not need a Firebase dependency.
public protocol IrohTransportAuditLogging: Sendable {
    func record(
        event: IrohTransportAuditEvent,
        uid: String,
        connectionId: String,
        transport: IrohTransportSelection?,
        rttMillis: Int?,
        detail: [String: String]
    ) async
}

public enum IrohTransportAuditEvent: String, Sendable, Equatable {
    case streamOpened = "iroh_stream_opened"
    case streamClosed = "iroh_stream_closed"
    case streamFailed = "iroh_stream_failed"
    case pairingPublished = "iroh_pairing_published"
    case pairingVerified = "iroh_pairing_verified"
    case pairingRejected = "iroh_pairing_rejected"
    case fallbackToWss = "iroh_fallback_to_wss"
}

public enum IrohTransportSelection: String, Sendable, Equatable {
    case irohDirect = "iroh-direct"
    case irohRelay = "iroh-relay"
    case wss = "wss"
    case firestore = "firestore"
}
