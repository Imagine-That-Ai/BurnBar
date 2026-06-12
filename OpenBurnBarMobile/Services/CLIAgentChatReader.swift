@preconcurrency import Foundation
import FirebaseAppCheck
@preconcurrency import FirebaseAuth
import FirebaseCore
@preconcurrency import FirebaseFirestore
import OpenBurnBarCore
import OSLog

// MARK: - CLI Agent Chat Reader
//
// Mobile-side reader for the CLI agent transcripts the macOS app mirrors
// into Firestore via `CLIAgentSessionMirror`. Surfaces Codex / Claude
// Code / OpenClaw sessions inside the iOS Assistants tab so the user can
// pick up where their Mac left off — tool pills included.
//
// Symmetric with `MobileAssistantChatReader` on the Mac side: read-only,
// snapshot-driven, idempotent refreshes. Listens to auth changes so the
// thread list clears on sign-out.

@MainActor
protocol CLIAgentChatRemoteSource: AnyObject {
    func fetchAll() async throws -> [CLIAgentSessionRecord]
    func fetch(agent: CLIAgentRuntime) async throws -> [CLIAgentSessionRecord]
    var isAvailable: Bool { get }
}

@MainActor
@Observable
final class CLIAgentChatReader {
    static let shared = CLIAgentChatReader()

    private(set) var sessions: [CLIAgentSessionRecord] = []
    private(set) var isLoading: Bool = false
    private(set) var lastError: String?
    private(set) var lastRefreshedAt: Date?

    private let remote: CLIAgentChatRemoteSource
    private let logger = Logger(subsystem: "com.openburnbar.mobile", category: "CLIAgentChatReader")
    @ObservationIgnored private nonisolated(unsafe) var authListenerHandle: AuthStateDidChangeListenerHandle?
    @ObservationIgnored private nonisolated(unsafe) var sessionsListener: ListenerRegistration?

    init(
        remote: CLIAgentChatRemoteSource = CLIAgentChatFirestoreSource(),
        observeAuthChanges: Bool? = nil
    ) {
        self.remote = remote
        if observeAuthChanges ?? (remote is CLIAgentChatFirestoreSource) {
            attachAuthListener()
        }
    }

    deinit {
        if let handle = authListenerHandle {
            Auth.auth().removeStateDidChangeListener(handle)
        }
        sessionsListener?.remove()
    }

    /// Filtered list per CLI runtime, sorted newest-first.
    func sessions(for agent: CLIAgentRuntime) -> [CLIAgentSessionRecord] {
        sessions
            .filter { $0.agent == agent }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Newest snapshot for a single session id (used by the transcript
    /// view to pick up live edits from the Mac without refetching the
    /// full list).
    func session(id: String) -> CLIAgentSessionRecord? {
        sessions.first { $0.id == id }
    }

    /// Pull a fresh snapshot from Firestore. Safe to call repeatedly;
    /// in-flight calls coalesce on `isLoading`.
    func refresh() async {
        guard !isLoading else { return }
        guard remote.isAvailable else { return }
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        do {
            sessions = try await remote.fetchAll()
            lastRefreshedAt = Date()
        } catch {
            lastError = error.localizedDescription
            logger.warning("CLI agent fetch failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func attachAuthListener() {
        guard FirebaseApp.app() != nil else { return }
        authListenerHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                if user == nil {
                    self?.sessionsListener?.remove()
                    self?.sessionsListener = nil
                    self?.sessions = []
                    self?.lastRefreshedAt = nil
                } else {
                    self?.startListening(uid: user?.uid)
                    await self?.refresh()
                }
            }
        }
    }

    private func startListening(uid: String?) {
        guard let uid, FirebaseApp.app() != nil else { return }
        sessionsListener?.remove()
        sessionsListener = Firestore.firestore()
            .collection("users").document(uid)
            .collection("cli_sessions")
            .order(by: "updatedAt", descending: true)
            .limit(to: 200)
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor in
                    if let error {
                        self?.lastError = error.localizedDescription
                        self?.logger.warning("CLI agent listener failed: \(String(describing: error), privacy: .public)")
                        return
                    }
                    // `uid` is already a non-optional String here (unwrapped by the
                    // `guard let uid` above), so it can be used directly.
                    let key: MobileCloudVaultResolvedKey?
                    do {
                        key = try await MobileCloudVaultKeyAccess.keyForReading(uid: uid)
                    } catch {
                        self?.logger.warning("CLI agent vault key read failed: \(String(describing: error), privacy: .public)")
                        key = nil
                    }
                    self?.sessions = snapshot?.documents.compactMap { document in
                        CLIAgentChatFirestoreSource.decodeDocument(
                            documentID: document.documentID,
	                            data: document.data(),
	                            vaultKey: key?.keyData
	                        )
	                    } ?? []
                    self?.lastRefreshedAt = Date()
                    self?.lastError = nil
                }
            }
    }

    func updateSessionMetadata(
        id: String,
        customTitle: String? = nil,
        labelColorHex: String? = nil,
        isPinned: Bool? = nil,
        priorityOrder: Int? = nil
    ) async throws {
        guard FirebaseApp.app() != nil else { return }
        guard let uid = Auth.auth().currentUser?.uid else { return }

        let db = Firestore.firestore()
        let docRef = db
            .collection("users").document(uid)
            .collection("cli_sessions").document(id)

        // `customTitle` is private user text and only legally exists inside the
        // sealed record (`CLIAgentSessionCodec.encodeSealed` JSON), never as a
        // top-level field — `validCliSessionMirror` (firestore.rules) rejects a
        // top-level `customTitle`. Mirror the already-correct
        // `MobileChatHistoryStore` / Android `AssistantChatHistoryStore`
        // pattern: re-seal the WHOLE record with the new `customTitle` baked in.
        //
        // `labelColorHex` / `isPinned` / `priorityOrder` are allowed top-level
        // by the rules, so they stay as a plain `merge:true` write and never
        // require re-sealing the transcript.
        if customTitle != nil {
            let key = try await MobileCloudVaultKeyAccess.keyForReading(uid: uid)
            let snapshot = try await docRef.getDocument()
            guard let data = snapshot.data(),
                  let record = CLIAgentChatFirestoreSource.decodeDocument(
                    documentID: id,
                    data: data,
                    vaultKey: key?.keyData
                  ) else {
                // No existing record to re-seal (or vault key unavailable for a
                // sealed doc). Skip the title change rather than leak plaintext.
                logger.warning("CLI session rename skipped: missing record or vault key for \(id, privacy: .public)")
                return
            }

            guard let key else {
                logger.warning("CLI session rename skipped: vault key unavailable for \(id, privacy: .public)")
                return
            }

            let updated = Self.applyMetadata(
                to: record,
                customTitle: customTitle,
                labelColorHex: labelColorHex,
                isPinned: isPinned,
                priorityOrder: priorityOrder
            )
            var sealed = try CLIAgentSessionCodec.encodeSealed(
                updated,
                vaultKey: key.keyData,
                vaultKeyID: key.vaultKeyID
            )
            // `merge:true` keeps untouched fields, so explicitly delete any
            // legacy plaintext `customTitle` (and the legacy plaintext `title`/
            // `preview`/`messages`) a pre-seal writer or older client may have
            // left behind — otherwise the rename would leave a plaintext copy.
            for legacyField in ["customTitle", "title", "preview", "messages"] where sealed[legacyField] == nil {
                sealed[legacyField] = FieldValue.delete()
            }
            try await docRef.setData(sealed, merge: true)
            return
        }

        // No title change: only the non-private top-level metadata changed.
        // A targeted `merge:true` write keeps the sealed transcript untouched.
        var payload: [String: Any] = [:]
        if let labelColorHex {
            payload["labelColorHex"] = labelColorHex == "#NONE#" ? FieldValue.delete() : labelColorHex
        }
        if let isPinned {
            payload["isPinned"] = isPinned
        }
        if let priorityOrder {
            payload["priorityOrder"] = priorityOrder
        }

        if !payload.isEmpty {
            try await docRef.setData(payload, merge: true)
        }
    }

    /// Apply rename / metadata edits onto an in-memory record so the whole
    /// record can be re-sealed. An empty `customTitle` clears the override
    /// (preserving the old "delete to reset" gesture); non-private metadata is
    /// updated in place when supplied.
    static func applyMetadata(
        to record: CLIAgentSessionRecord,
        customTitle: String?,
        labelColorHex: String?,
        isPinned: Bool?,
        priorityOrder: Int?
    ) -> CLIAgentSessionRecord {
        var updated = record
        if let customTitle {
            updated.customTitle = customTitle.isEmpty ? nil : customTitle
        }
        if let labelColorHex {
            updated.labelColorHex = labelColorHex == "#NONE#" ? nil : labelColorHex
        }
        if let isPinned {
            updated.isPinned = isPinned
        }
        if let priorityOrder {
            updated.priorityOrder = priorityOrder
        }
        return updated
    }
}

// MARK: - Firestore implementation

@MainActor
final class CLIAgentChatFirestoreSource: CLIAgentChatRemoteSource {
    private let firestoreProvider: () -> Firestore

    init(firestoreProvider: @escaping () -> Firestore = { Firestore.firestore() }) {
        self.firestoreProvider = firestoreProvider
    }

    var isAvailable: Bool {
        FirebaseApp.app() != nil && Auth.auth().currentUser != nil
    }

    func fetchAll() async throws -> [CLIAgentSessionRecord] {
        try await fetch(filter: nil)
    }

    func fetch(agent: CLIAgentRuntime) async throws -> [CLIAgentSessionRecord] {
        try await fetch(filter: agent)
    }

    private func fetch(filter: CLIAgentRuntime?) async throws -> [CLIAgentSessionRecord] {
        guard FirebaseApp.app() != nil else {
            throw NSError(domain: "CLIAgentChat", code: 1, userInfo: [NSLocalizedDescriptionKey: "Firebase unavailable"])
        }
        guard let uid = Auth.auth().currentUser?.uid else {
            throw NSError(domain: "CLIAgentChat", code: 2, userInfo: [NSLocalizedDescriptionKey: "Not signed in"])
        }
        var query: Query = firestoreProvider()
            .collection("users").document(uid).collection("cli_sessions")
            .order(by: "updatedAt", descending: true)
            .limit(to: 200)
        if let filter {
            query = query.whereField("agent", isEqualTo: filter.rawValue)
        }
	        let snapshot = try await query.getDocuments()
	        let key = try await MobileCloudVaultKeyAccess.keyForReading(uid: uid)
	        return snapshot.documents.compactMap { document in
	            Self.decodeDocument(
	                documentID: document.documentID,
	                data: document.data(),
	                vaultKey: key?.keyData
	            )
	        }
	    }

	    static func decodeDocument(documentID: String, data: [String: Any], vaultKey: Data?) -> CLIAgentSessionRecord? {
	        if data["contentSealed"] as? Bool == true || data["sealedPayload"] != nil {
	            guard let vaultKey else { return nil }
	            return CLIAgentSessionCodec.decodeSealed(documentID: documentID, data: data, vaultKey: vaultKey)
	        }
	        return CLIAgentSessionCodec.decode(
	            documentID: documentID,
	            data: data,
	            timestampDecoder: Self.firestoreTimestampDecoder
	        )
	    }

    /// Firestore returns `Timestamp` (not Foundation `Date`). The codec
    /// stays SDK-free; we plug an SDK-aware decoder here.
    static let firestoreTimestampDecoder: (Any?) -> Date? = { raw in
        if let value = raw as? Timestamp { return value.dateValue() }
        if let value = raw as? Date { return value }
        if let value = raw as? Double { return Date(timeIntervalSince1970: value) }
        if let value = raw as? Int { return Date(timeIntervalSince1970: TimeInterval(value)) }
        return nil
    }
}
