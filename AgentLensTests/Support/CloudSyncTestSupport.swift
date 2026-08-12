import Foundation
import FirebaseAuth
import OpenBurnBarCore
@testable import OpenBurnBar

// MARK: - FakeAccountManager

@MainActor
final class FakeAccountManager: AccountManaging {
    var isSignedIn = false
    var isCloudSyncEnabled = true
    var isFirebaseAvailable = true
    var deviceId = "test-device-1"
    var currentUser: User? = nil
    var currentUID: String? = nil

    static func makeSignedIn(uid: String = "test-uid-1") -> FakeAccountManager {
        let manager = FakeAccountManager()
        manager.isSignedIn = true
        manager.isFirebaseAvailable = true
        manager.isCloudSyncEnabled = true
        manager.currentUID = uid
        return manager
    }
}

// MARK: - Session Log Test Doubles

final class FakeSessionLogEncryptedCloudClient: SessionLogEncryptedCloudClient {
    /// Firebase callable payloads use `[String: Any]`, which is not statically
    /// `Sendable`. This test-only state never exposes a mutable reference across
    /// threads: every read returns a value copy and every mutation is serialized
    /// by `Locked`.
    private struct State: @unchecked Sendable {
        var uploadRequests: [(documentID: String, bodyHash: String, byteCount: Int)] = []
        var uploadedBodies: [(data: Data, ticket: EncryptedSessionBlobUploadTicket)] = []
        var searchIndexCommits: [
            (deviceId: String, indexVersion: Int, document: [String: Any], chunks: [[String: Any]])
        ] = []
        var downloadableBodies: [String: Data] = [:]
        var onBeginUpload: (@Sendable () async -> Void)?
        var projectMemoryCommits: [[String: Any]] = []
        var projectMemorySnapshotsByKey: [String: [String: Any]] = [:]
        var projectMemoryDeletes: [[String: Any]] = []
        var deletedBodies: [(documentID: String, storagePath: String)] = []
    }

    private let state = Locked(State())

    var uploadRequests: [(documentID: String, bodyHash: String, byteCount: Int)] {
        state.read().uploadRequests
    }

    var uploadedBodies: [(data: Data, ticket: EncryptedSessionBlobUploadTicket)] {
        state.read().uploadedBodies
    }

    var searchIndexCommits: [
        (deviceId: String, indexVersion: Int, document: [String: Any], chunks: [[String: Any]])
    ] {
        state.read().searchIndexCommits
    }

    var downloadableBodies: [String: Data] {
        get { state.read().downloadableBodies }
        set { state.withLock { $0.downloadableBodies = newValue } }
    }

    var onBeginUpload: (@Sendable () async -> Void)? {
        get { state.read().onBeginUpload }
        set { state.withLock { $0.onBeginUpload = newValue } }
    }

    var projectMemoryCommits: [[String: Any]] {
        state.read().projectMemoryCommits
    }

    var projectMemoryDeletes: [[String: Any]] {
        state.read().projectMemoryDeletes
    }

    var deletedBodies: [(documentID: String, storagePath: String)] {
        state.read().deletedBodies
    }

    func beginEncryptedSessionBlobUpload(
        documentID: String,
        bodyHash: String,
        byteCount: Int
    ) async throws -> EncryptedSessionBlobUploadTicket {
        if let onBeginUpload = state.read().onBeginUpload {
            await onBeginUpload()
        }
        state.withLock {
            $0.uploadRequests.append(
                (documentID: documentID, bodyHash: bodyHash, byteCount: byteCount)
            )
        }
        return EncryptedSessionBlobUploadTicket(
            storagePath: "session-logs/\(documentID).json",
            uploadURL: URL(string: "https://upload.invalid/\(documentID)")!
        )
    }

    func uploadEncryptedBody(data: Data, ticket: EncryptedSessionBlobUploadTicket) async throws {
        state.withLock {
            $0.uploadedBodies.append((data, ticket))
            $0.downloadableBodies[ticket.storagePath] = data
        }
    }

    func commitEncryptedSearchIndex(
        deviceId: String,
        indexVersion: Int,
        document: [String: Any],
        chunks: [[String: Any]]
    ) async throws {
        state.withLock {
            $0.searchIndexCommits.append((deviceId, indexVersion, document, chunks))
        }
    }

    /// Every payload passed to `commitEncryptedProjectMemorySnapshot`, in order,
    /// so tests can assert the opaque `docID` is sent and the plaintext
    /// `projectSlug`/`projectDisplayName` are absent (privacy-leak remediation).
    /// Stored snapshots keyed by the doc identifier the commit wrote under
    /// (`docID` when present). `getEncryptedProjectMemorySnapshot` resolves by the
    /// requested `docID` first, then falls back to the legacy `projectSlug` so the
    /// reader's migration fallback path is exercisable.

    func commitEncryptedProjectMemorySnapshot(_ payload: [String: Any]) async throws {
        let key = (payload["docID"] as? String) ?? (payload["projectSlug"] as? String)
        state.withLock { state in
            state.projectMemoryCommits.append(payload)
            if let key {
                var stored = payload
                stored.removeValue(forKey: "legacyDocID")
                state.projectMemorySnapshotsByKey[key] = stored
            }
            // Mirror the server's client-side migration: dropping the legacy
            // plaintext-slug doc once the sealed, opaque-keyed copy exists.
            if let legacyKey = payload["legacyDocID"] as? String {
                state.projectMemorySnapshotsByKey.removeValue(forKey: legacyKey)
            }
        }
    }

    func getEncryptedProjectMemorySnapshot(_ payload: [String: Any]) async throws -> [String: Any] {
        let key = (payload["docID"] as? String) ?? (payload["projectSlug"] as? String)
        return state.withLock { state in
            guard let key, let snapshot = state.projectMemorySnapshotsByKey[key] else {
                return ["snapshot": NSNull()]
            }
            return ["snapshot": snapshot]
        }
    }

    func deleteEncryptedProjectMemorySnapshot(_ payload: [String: Any]) async throws -> [String: Any] {
        let key = (payload["docID"] as? String) ?? (payload["projectSlug"] as? String)
        let existed = state.withLock { state in
            state.projectMemoryDeletes.append(payload)
            return key.flatMap { state.projectMemorySnapshotsByKey.removeValue(forKey: $0) } != nil
        }
        return [
            "ok": true,
            "docID": key ?? "",
            "existed": existed,
            "deletedAt": ISO8601DateFormatter().string(from: Date()),
            "receiptHash": String(repeating: "a", count: 64)
        ]
    }

    func downloadEncryptedBody(storagePath: String) async throws -> Data {
        guard let data = state.withLock({ $0.downloadableBodies[storagePath] }) else {
            throw URLError(.fileDoesNotExist)
        }
        return data
    }

    func deleteEncryptedSessionBlob(documentID: String, storagePath: String) async throws {
        state.withLock {
            $0.deletedBodies.append((documentID: documentID, storagePath: storagePath))
        }
    }
}

struct StaticSessionLogVaultKeyStore: SessionLogVaultKeyProviding {
    let keyData: Data

    init(keyData: Data = Data(repeating: 0x43, count: 32)) {
        self.keyData = keyData
    }

    func loadKey(uid: String) throws -> Data? {
        keyData
    }

    func getOrCreateKey(uid: String) throws -> Data {
        keyData
    }
}

@MainActor
struct NoopSessionLogVaultKeyPublisher: SessionLogVaultKeyPublishing {
    func publishCloudVaultKey(uid: String, vaultKey: Data, context: CloudSyncContext) async throws {}
}
