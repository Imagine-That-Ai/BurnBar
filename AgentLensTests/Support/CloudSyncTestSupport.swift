import Foundation
import FirebaseAuth
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

@MainActor
final class FakeSessionLogEncryptedCloudClient: SessionLogEncryptedCloudClient {
    private(set) var uploadRequests: [(documentID: String, bodyHash: String, byteCount: Int)] = []
    private(set) var uploadedBodies: [(data: Data, ticket: EncryptedSessionBlobUploadTicket)] = []
    private(set) var searchIndexCommits: [(deviceId: String, indexVersion: Int, document: [String: Any], chunks: [[String: Any]])] = []
    var downloadableBodies: [String: Data] = [:]
    var onBeginUpload: (() async -> Void)?

    func beginEncryptedSessionBlobUpload(
        documentID: String,
        bodyHash: String,
        byteCount: Int
    ) async throws -> EncryptedSessionBlobUploadTicket {
        if let onBeginUpload {
            await onBeginUpload()
        }
        uploadRequests.append((documentID: documentID, bodyHash: bodyHash, byteCount: byteCount))
        return EncryptedSessionBlobUploadTicket(
            storagePath: "session-logs/\(documentID).json",
            uploadURL: URL(string: "https://upload.invalid/\(documentID)")!
        )
    }

    func uploadEncryptedBody(data: Data, ticket: EncryptedSessionBlobUploadTicket) async throws {
        uploadedBodies.append((data, ticket))
        downloadableBodies[ticket.storagePath] = data
    }

    func commitEncryptedSearchIndex(
        deviceId: String,
        indexVersion: Int,
        document: [String: Any],
        chunks: [[String: Any]]
    ) async throws {
        searchIndexCommits.append((deviceId, indexVersion, document, chunks))
    }

    /// Every payload passed to `commitEncryptedProjectMemorySnapshot`, in order,
    /// so tests can assert the opaque `docID` is sent and the plaintext
    /// `projectSlug`/`projectDisplayName` are absent (privacy-leak remediation).
    private(set) var projectMemoryCommits: [[String: Any]] = []
    /// Stored snapshots keyed by the doc identifier the commit wrote under
    /// (`docID` when present). `getEncryptedProjectMemorySnapshot` resolves by the
    /// requested `docID` first, then falls back to the legacy `projectSlug` so the
    /// reader's migration fallback path is exercisable.
    var projectMemorySnapshotsByKey: [String: [String: Any]] = [:]

    func commitEncryptedProjectMemorySnapshot(_ payload: [String: Any]) async throws {
        projectMemoryCommits.append(payload)
        let key = (payload["docID"] as? String) ?? (payload["projectSlug"] as? String)
        if let key {
            var stored = payload
            stored.removeValue(forKey: "legacyDocID")
            projectMemorySnapshotsByKey[key] = stored
        }
        // Mirror the server's client-side migration: dropping the legacy
        // plaintext-slug doc once the sealed, opaque-keyed copy exists.
        if let legacyKey = payload["legacyDocID"] as? String {
            projectMemorySnapshotsByKey.removeValue(forKey: legacyKey)
        }
    }

    func getEncryptedProjectMemorySnapshot(_ payload: [String: Any]) async throws -> [String: Any] {
        let key = (payload["docID"] as? String) ?? (payload["projectSlug"] as? String)
        guard let key, let snapshot = projectMemorySnapshotsByKey[key] else {
            return ["snapshot": NSNull()]
        }
        return ["snapshot": snapshot]
    }

    func downloadEncryptedBody(storagePath: String) async throws -> Data {
        guard let data = downloadableBodies[storagePath] else {
            throw URLError(.fileDoesNotExist)
        }
        return data
    }

    private(set) var deletedBodies: [(documentID: String, storagePath: String)] = []

    func deleteEncryptedSessionBlob(documentID: String, storagePath: String) async throws {
        deletedBodies.append((documentID: documentID, storagePath: storagePath))
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
