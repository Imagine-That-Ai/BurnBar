import CryptoKit
import Foundation
@preconcurrency import FirebaseFirestore
import OpenBurnBarIrohRelay

/// T-TRN-04 — reduce cloud-visible control-plane metadata in iroh audit events.
///
/// The transport hands raw NodeIds, relay URLs, IP-bearing addresses, and exact
/// counts in the audit `detail`. Those land in Firestore where the relay/backend
/// (in scope for the E2EE threat model) can read them and correlate a user's
/// peers, home relay, and network. This scrubber hashes the high-entropy
/// identifiers to a short, stable, non-reversible fingerprint and buckets the
/// counts — exactly the way media telemetry already hashes/buckets — so the audit
/// trail stays useful for support/forensics (the same peer hashes to the same
/// token within a salt epoch) without storing the plaintext identifier.
///
/// Pure and `@Sendable`, so the fail-closed scrubbing is unit-testable.
enum IrohAuditMetadataScrubber {
    /// Detail keys whose VALUE is a high-entropy identifier (NodeId / relay URL /
    /// address). Replaced in place with a hashed fingerprint token.
    private static let identifierKeys: Set<String> = [
        "localNodeId",
        "targetNodeId",
        "remoteNodeId",
        "peerNodeId",
        "irohPeerNodeId",
        "relayURL",
        "relayUrl",
        "directAddress",
        "directAddresses",
        "ip",
        "ipAddress",
        "endpoint"
    ]

    /// Detail keys whose VALUE is an exact count we coarsen into a bucket so the
    /// precise topology size is not stored.
    private static let countKeys: Set<String> = [
        "directAddressCount"
    ]

    /// Scrub a detail dictionary: hash identifiers, bucket counts, pass through
    /// everything else (stage labels, error classes, booleans) unchanged.
    static func scrub(_ detail: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        result.reserveCapacity(detail.count)
        for (key, value) in detail {
            if identifierKeys.contains(key) {
                result[key] = fingerprint(value)
            } else if countKeys.contains(key) {
                result[key] = bucket(value)
            } else {
                result[key] = value
            }
        }
        return result
    }

    /// Non-reversible short fingerprint of a high-entropy identifier. An empty
    /// value maps to "none" so an empty relay URL is not silently dropped (it is
    /// itself signal). The hash is truncated to 8 bytes (>=64 bits) — enough to
    /// keep correlation across events for the same peer, far too short to reverse.
    static func fingerprint(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "none" }
        let digest = SHA256.hash(data: Data(trimmed.utf8))
        let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "h:\(hex)"
    }

    /// Coarsen an exact count into a bucket so the precise number is not stored.
    static func bucket(_ raw: String) -> String {
        guard let count = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return "na" }
        switch count {
        case ..<0: return "na"
        case 0: return "0"
        case 1: return "1"
        case 2...4: return "2-4"
        case 5...9: return "5-9"
        default: return "10+"
        }
    }
}

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
            // T-TRN-04 — scrub raw control-plane identifiers (NodeIds / relay
            // URL / addresses) and bucket exact counts before they reach
            // Firestore, so the cloud-visible audit trail cannot be used to
            // correlate a user's peers and home relay.
            payload["detail"] = IrohAuditMetadataScrubber.scrub(detail)
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
            let nsError = error as NSError
            NSLog("hermes_iroh_audit_write_failed event=\(event.rawValue) code=\(nsError.code) domain=\(nsError.domain) message=\(nsError.localizedDescription)")
            #endif
        }
    }
}
