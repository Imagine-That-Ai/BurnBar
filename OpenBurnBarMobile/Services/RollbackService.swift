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
//
// Privacy: the scope JSON (which can embed an absolute file path for a
// `singleFile` rollback) and the Mac-written resolution diagnostic are sealed
// with the per-user cloud vault key before they touch Firestore
// (`sealedScope` / `sealedErrorMessage`). Snapshot index fields the Mac writes
// (`actionLabel` / `touchedFiles` / `macSnapshotPath`) are likewise sealed.
// Every reader keeps a legacy plaintext fallback so in-flight / pre-migration
// documents still render. No Cloud Function reads these collections — they are
// pure store-and-forward between the user's own devices, so a vault seal (no
// keyed hash) is the complete fix.

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
                let documents = snapshot?.documents ?? []
                // Resolve the vault key once per listener fire so sealed
                // snapshot fields can be opened; legacy plaintext docs still
                // decode when the key is nil.
                let vaultKey = try? await MobileCloudVaultKeyAccess.keyForReading(
                    uid: uid,
                    firestore: self.firestoreProvider()
                )?.keyData
                let parsed: [RollbackSnapshot] = documents.compactMap { doc in
                    Self.decodeSnapshot(
                        data: doc.data() as NSDictionary,
                        documentID: doc.documentID,
                        sessionID: sessionID,
                        vaultKey: vaultKey
                    )
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
            // `inFlight` is the legacy pre-snake_case wire value; include it so a
            // doc still carrying it isn't excluded by Firestore's exact-match `in`
            // before the tolerant `Status(wireValue:)` decoder can run. Mirrors the
            // tolerance in RollbackContracts.Status and Android RollbackService.kt
            // (`whereIn("status", listOf("pending", "in_flight", "inFlight"))`).
            .whereField("status", in: ["pending", "in_flight", "inFlight"])
        requestObservation = ref.addSnapshotListener { [weak self] snapshot, _ in
            Task { @MainActor in
                guard let self else { return }
                let documents = snapshot?.documents ?? []
                let resolvedKey = try? await MobileCloudVaultKeyAccess.keyForReading(
                    uid: uid,
                    firestore: self.firestoreProvider()
                )
                let trustedKeys: [String: Data] = if let identity = resolvedKey?.signalIdentity {
                    await MobileCloudVaultSignalPayloads.trustedSenderPublicKeys(
                        uid: uid,
                        firestore: self.firestoreProvider(),
                        localIdentity: identity
                    )
                } else { [:] }
                let parsed: [RollbackRequest] = documents.compactMap { doc in
                    let signalData = try? resolvedKey.flatMap { key in
                        try MobileCloudVaultSignalPayloads.openSignalPayloadIfPresent(
                            doc.data(),
                            uid: uid,
                            collection: "rollback_requests",
                            docId: doc.documentID,
                            signalIdentity: key.signalIdentity,
                            trustedSenderPublicKeys: trustedKeys
                        )
                    }
                    return Self.decodeRequest(
                        data: doc.data() as NSDictionary,
                        documentID: doc.documentID,
                        vaultKey: resolvedKey?.keyData,
                        signalPlaintext: signalData ?? nil
                    )
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
        let resolvedKey = try await MobileCloudVaultKeyAccess
            .keyForWriting(uid: uid, firestore: firestoreProvider())
        let ref = firestoreProvider()
            .collection("users").document(uid)
            .collection("rollback_requests").document(request.id)
        var payload = try Self.encodeRequest(request, vaultKey: resolvedKey.keyData)
        let signalState = MobileCloudVaultSignalPayloads.signalActivationState(domainID: "conversations_chat")
        if signalState != .off {
            let scopeData = try JSONEncoder().encode(request.scope)
            let privatePayload: NSDictionary = [
                "id": request.id,
                "sessionID": request.sessionID,
                "scopeJSON": String(data: scopeData, encoding: .utf8) ?? "{}",
                "requestedAt": ISO8601DateFormatter().string(from: request.requestedAt),
                "requestedBy": request.requestedBy,
                "status": request.status.rawValue,
                "schemaVersion": 1
            ]
            let plaintext = try JSONSerialization.data(withJSONObject: privatePayload, options: [.sortedKeys])
            do {
                if let envelope = try await MobileCloudVaultSignalPayloads.signalEnvelopeIfEnabled(
                    domainID: "conversations_chat",
                    uid: uid,
                    firestore: firestoreProvider(),
                    collection: "rollback_requests",
                    docId: request.id,
                    plaintext: plaintext,
                    resolvedKey: resolvedKey
                ) {
                    payload["signalEnvelope"] = envelope
                    if signalState == .required {
                        payload.removeValue(forKey: "sealedScope")
                        payload.removeValue(forKey: "sealedErrorMessage")
                        payload.removeValue(forKey: "sealedPayload")
                    }
                }
            } catch {
                if signalState == .required { throw error }
            }
        }
        try MobileCloudVaultSignalPayloads.requireEnvelopeIfRequired(
            payload: payload,
            state: signalState,
            domainID: "conversations_chat"
        )
        try await ref.setData(payload)
        return request
    }

    // MARK: - Decoding

    static func decodeSnapshot(
        data: NSDictionary,
        documentID: String,
        sessionID: String,
        vaultKey: Data?
    ) -> RollbackSnapshot? {
        guard
            let sequence = data["sequence"] as? Int,
            let takenAtString = data["takenAt"] as? String,
            let takenAt = ISO8601DateFormatter().date(from: takenAtString)
        else { return nil }
        // Open the sealed action label, falling back to legacy plaintext for
        // pre-migration documents. The label is required for the row to render.
        guard let actionLabel = openSealedString(
            data: data,
            sealedField: "sealedActionLabel",
            legacyField: "actionLabel",
            vaultKey: vaultKey
        ) else { return nil }
        // `touchedFiles` is sealed as one JSON array; legacy docs carried the
        // raw `[String]`.
        let touched = openSealedStringArray(
            data: data,
            sealedField: "sealedTouchedFiles",
            legacyField: "touchedFiles",
            vaultKey: vaultKey
        )
        let macPath = openSealedString(
            data: data,
            sealedField: "sealedMacSnapshotPath",
            legacyField: "macSnapshotPath",
            vaultKey: vaultKey
        )
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

    static func decodeRequest(
        data: NSDictionary,
        documentID: String,
        vaultKey: Data?,
        signalPlaintext: Data? = nil
    ) -> RollbackRequest? {
        var signal: NSDictionary = [:]
        if let signalPlaintext,
           let object = try? JSONSerialization.jsonObject(with: signalPlaintext),
           let dictionary = object as? NSDictionary {
            signal = dictionary
        } else if MobileCloudVaultSignalPayloads.signalSealingIsRequired(domainID: "conversations_chat") {
            return nil
        }
        let source = signal.count == 0 ? data : signal
        guard
            let sessionID = source["sessionID"] as? String,
            let scopeRaw = openSealedString(
                data: signal.count == 0 ? data : NSDictionary(dictionary: ["scopeJSON": source["scopeJSON"] as Any]),
                sealedField: "sealedScope",
                legacyField: "scopeJSON",
                vaultKey: vaultKey
            ),
            let scope = try? JSONDecoder().decode(RollbackScope.self, from: Data(scopeRaw.utf8)),
            // MUTABLE rollback state lives on the LIVE document: the Mac claim
            // path updates top-level `status`, `resolvedAt`, and
            // `sealedErrorMessage` without resealing the Signal envelope (the
            // envelope is created once at request time with `status: pending`).
            // Prefer the live fields so an `in_flight`/resolved request never
            // decodes as pending off the stale envelope; the Signal payload is
            // authoritative only for the private immutable fields and is the
            // fallback for docs the Mac has not touched yet.
            let statusRaw = (data["status"] as? String) ?? (source["status"] as? String),
            // Route through the tolerant resolver so the legacy camelCase
            // `"inFlight"` wire value (and `cancelled`) decode; a genuinely
            // unknown status still drops the row via the guard.
            let status = RollbackRequest.Status(wireValue: statusRaw)
        else { return nil }
        let requestedAt = (source["requestedAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
        let resolvedAt = ((data["resolvedAt"] as? String) ?? (source["resolvedAt"] as? String))
            .flatMap { ISO8601DateFormatter().date(from: $0) }
        let requestedBy = (source["requestedBy"] as? String) ?? "unknown"
        let errorMessage = openSealedString(
            data: data,
            sealedField: "sealedErrorMessage",
            legacyField: "errorMessage",
            vaultKey: vaultKey
        ) ?? (signal["errorMessage"] as? String)
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

    static func encodeRequest(_ request: RollbackRequest, vaultKey: Data) throws -> [String: Any] {
        let scopeData = try JSONEncoder().encode(request.scope)
        let scopeJSON = String(data: scopeData, encoding: .utf8) ?? "{}"
        // Seal the scope JSON (a `singleFile` scope embeds an absolute file
        // path) instead of writing it in clear. The phone never writes
        // `errorMessage` — that is the Mac claim path's job and it seals
        // `sealedErrorMessage` from day one.
        return [
            "id": request.id,
            "sessionID": request.sessionID,
            "sealedScope": try dictionary(CloudVaultCrypto.sealText(scopeJSON, keyData: vaultKey)),
            "requestedAt": ISO8601DateFormatter().string(from: request.requestedAt),
            "requestedBy": request.requestedBy,
            "status": request.status.rawValue,
            "schemaVersion": 1,
            "source": "ios-hermes-square"
        ]
    }

    // MARK: - Seal helpers

    /// Opens a sealed-text field, falling back to a legacy plaintext field only
    /// when the sealed field is absent. A present sealed field is authoritative:
    /// decrypt it or fail closed instead of leaking a stale plaintext sibling.
    private static func openSealedString(
        data: NSDictionary,
        sealedField: String,
        legacyField: String,
        vaultKey: Data?
    ) -> String? {
        if let envelope = sealedText(from: data[sealedField]) {
            guard let vaultKey else { return nil }
            return try? CloudVaultCrypto.openText(envelope, keyData: vaultKey)
        }
        return data[legacyField] as? String
    }

    /// Opens a sealed `[String]` (sealed as one JSON array), falling back to a
    /// legacy plaintext `[String]` field only when the sealed field is absent.
    private static func openSealedStringArray(
        data: NSDictionary,
        sealedField: String,
        legacyField: String,
        vaultKey: Data?
    ) -> [String] {
        if sealedText(from: data[sealedField]) != nil {
            guard let json = openSealedString(
                data: data,
                sealedField: sealedField,
                legacyField: "",
                vaultKey: vaultKey
            ), let decoded = try? JSONDecoder().decode([String].self, from: Data(json.utf8)) else {
                return []
            }
            return decoded
        }
        return (data[legacyField] as? [String]) ?? []
    }

    /// Encodes a `CloudVaultSealedText` envelope into a Firestore-compatible
    /// dictionary. Mirrors the adjacent sealed-text sync services.
    private static func dictionary<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else { return [:] }
        return dictionary
    }

    /// Decodes a stored sealed-text dictionary back into a `CloudVaultSealedText`.
    private static func sealedText(from value: Any?) -> CloudVaultSealedText? {
        guard let dictionary = value as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: dictionary) else {
            return nil
        }
        return try? JSONDecoder().decode(CloudVaultSealedText.self, from: data)
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
