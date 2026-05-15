import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation
import Observation
import OpenBurnBarCore

// MARK: - Rollback Service (Hermes Square §6.10)
//
// Listens to `users/{uid}/cli_sessions/{sessionID}/snapshots` for the
// per-session snapshot index the Mac publishes. Submits a `RollbackRequest`
// to `users/{uid}/rollback_requests/{requestID}` which the Mac claims and
// applies.

@MainActor
@Observable
final class RollbackService {
    static let shared = RollbackService()

    private(set) var snapshotsBySession: [String: [RollbackSnapshot]] = [:]
    private(set) var pendingRequests: [RollbackRequest] = []
    private(set) var inlineError: String?

    private var snapshotObservations: [String: ListenerRegistration] = [:]
    private var requestObservation: ListenerRegistration?

    private let firestoreProvider: () -> Firestore

    init(firestoreProvider: @escaping () -> Firestore = { Firestore.firestore() }) {
        self.firestoreProvider = firestoreProvider
    }

    func startObservingSession(_ sessionID: String) {
        guard FirebaseApp.app() != nil, snapshotObservations[sessionID] == nil else { return }
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let ref = firestoreProvider()
            .collection("users").document(uid)
            .collection("cli_sessions").document(sessionID)
            .collection("snapshots")
            .order(by: "sequence")
        let reg = ref.addSnapshotListener { [weak self] snapshot, _ in
            Task { @MainActor in
                guard let self else { return }
                let parsed: [RollbackSnapshot] = (snapshot?.documents ?? []).compactMap { doc in
                    Self.decodeSnapshot(data: doc.data(), documentID: doc.documentID, sessionID: sessionID)
                }
                self.snapshotsBySession[sessionID] = parsed
            }
        }
        snapshotObservations[sessionID] = reg
    }

    func stopObservingSession(_ sessionID: String) {
        snapshotObservations[sessionID]?.remove()
        snapshotObservations.removeValue(forKey: sessionID)
    }

    func startObservingRequests() {
        guard FirebaseApp.app() != nil, requestObservation == nil else { return }
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let ref = firestoreProvider()
            .collection("users").document(uid)
            .collection("rollback_requests")
            .whereField("status", in: ["pending", "in_flight"])
        requestObservation = ref.addSnapshotListener { [weak self] snapshot, _ in
            Task { @MainActor in
                guard let self else { return }
                let parsed: [RollbackRequest] = (snapshot?.documents ?? []).compactMap { doc in
                    Self.decodeRequest(data: doc.data(), documentID: doc.documentID)
                }
                self.pendingRequests = parsed
            }
        }
    }

    /// Submit a rollback request. Mac claims and applies; the phone watches
    /// `pendingRequests` for status transitions.
    @discardableResult
    func submit(sessionID: String, scope: RollbackScope, requestedBy: String) async throws -> RollbackRequest {
        guard FirebaseApp.app() != nil else { throw RollbackError.firebaseUnavailable }
        guard let uid = Auth.auth().currentUser?.uid else { throw RollbackError.notSignedIn }
        let request = RollbackRequest(sessionID: sessionID, scope: scope, requestedBy: requestedBy)
        let ref = firestoreProvider()
            .collection("users").document(uid)
            .collection("rollback_requests").document(request.id)
        try await ref.setData(Self.encodeRequest(request))
        return request
    }

    // MARK: - Decoding

    private static func decodeSnapshot(data: [String: Any], documentID: String, sessionID: String) -> RollbackSnapshot? {
        guard
            let sequence = data["sequence"] as? Int,
            let takenAtString = data["takenAt"] as? String,
            let takenAt = ISO8601DateFormatter().date(from: takenAtString),
            let actionLabel = data["actionLabel"] as? String
        else { return nil }
        let touched = (data["touchedFiles"] as? [String]) ?? []
        let macPath = data["macSnapshotPath"] as? String
        let restoredAt = (data["restoredAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return RollbackSnapshot(
            id: (data["id"] as? String) ?? documentID,
            sessionID: sessionID,
            sequence: sequence,
            takenAt: takenAt,
            actionLabel: actionLabel,
            touchedFiles: touched,
            macSnapshotPath: macPath,
            restoredAt: restoredAt
        )
    }

    private static func decodeRequest(data: [String: Any], documentID: String) -> RollbackRequest? {
        guard
            let sessionID = data["sessionID"] as? String,
            let scopeRaw = data["scopeJSON"] as? String,
            let scope = try? JSONDecoder().decode(RollbackScope.self, from: Data(scopeRaw.utf8)),
            let statusRaw = data["status"] as? String,
            let status = RollbackRequest.Status(rawValue: statusRaw)
        else { return nil }
        let requestedAt = (data["requestedAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
        let resolvedAt = (data["resolvedAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        let requestedBy = (data["requestedBy"] as? String) ?? "unknown"
        let errorMessage = data["errorMessage"] as? String
        return RollbackRequest(
            id: documentID,
            sessionID: sessionID,
            scope: scope,
            requestedAt: requestedAt,
            requestedBy: requestedBy,
            status: status,
            resolvedAt: resolvedAt,
            errorMessage: errorMessage
        )
    }

    private static func encodeRequest(_ request: RollbackRequest) throws -> [String: Any] {
        let scopeData = try JSONEncoder().encode(request.scope)
        return [
            "id": request.id,
            "sessionID": request.sessionID,
            "scopeJSON": String(data: scopeData, encoding: .utf8) ?? "{}",
            "requestedAt": ISO8601DateFormatter().string(from: request.requestedAt),
            "requestedBy": request.requestedBy,
            "status": request.status.rawValue,
            "schemaVersion": 1,
            "source": "ios-hermes-square"
        ]
    }

    enum RollbackError: LocalizedError {
        case firebaseUnavailable
        case notSignedIn

        var errorDescription: String? {
            switch self {
            case .firebaseUnavailable: return "Firebase is not configured."
            case .notSignedIn:         return "Sign in to submit rollback requests."
            }
        }
    }
}
