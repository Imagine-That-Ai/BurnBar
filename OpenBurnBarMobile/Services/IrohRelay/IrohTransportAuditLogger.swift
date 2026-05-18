import Foundation
@preconcurrency import FirebaseFirestore
import OpenBurnBarIrohRelay

/// Append-only audit logger for iroh transport events. Mirrors the
/// `IrohTransportAuditEventDoc` schema in `functions/src/types.ts`.
/// Writes to `/users/{uid}/iroh_audit_events/{eventId}`. Read-only from the
/// client side (rules deny update + delete).
final class FirestoreIrohAuditLogger: IrohTransportAuditLogging, @unchecked Sendable {
    static let shared = FirestoreIrohAuditLogger()

    private let firestoreProvider: @Sendable () -> Firestore
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let auditTTLSeconds: TimeInterval

    init(
        firestoreProvider: @escaping @Sendable () -> Firestore = { Firestore.firestore() },
        auditTTLSeconds: TimeInterval = 30 * 24 * 60 * 60
    ) {
        self.firestoreProvider = firestoreProvider
        self.auditTTLSeconds = auditTTLSeconds
    }

    func record(
        event: IrohTransportAuditEvent,
        uid: String,
        connectionId: String,
        transport: IrohTransportSelection?,
        rttMillis: Int?,
        detail: [String: String]
    ) async {
        let eventId = UUID().uuidString
        let now = Date()
        let expireAt = now.addingTimeInterval(auditTTLSeconds)
        var payload: [String: Any] = [
            "id": eventId,
            "connectionId": connectionId,
            "eventType": event.rawValue,
            "observedAt": isoFormatter.string(from: now),
            "schemaVersion": 1,
            "expireAt": Timestamp(date: expireAt)
        ]
        if let transport {
            payload["transport"] = transport.rawValue
        }
        if let rttMillis {
            payload["rttMillis"] = rttMillis
        }
        if !detail.isEmpty {
            payload["detail"] = detail
        }

        do {
            try await firestoreProvider()
                .collection("users")
                .document(uid)
                .collection("iroh_audit_events")
                .document(eventId)
                .setData(payload, merge: false)
        } catch {
            #if DEBUG
            NSLog("hermes_iroh_audit_write_failed: \(error.localizedDescription)")
            #endif
        }
    }
}
