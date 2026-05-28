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
    private(set) var uploadedBodies: [(data: Data, ticket: EncryptedSessionBlobUploadTicket)] = []
    private(set) var searchIndexCommits: [(deviceId: String, indexVersion: Int, document: [String: Any], chunks: [[String: Any]])] = []

    func beginEncryptedSessionBlobUpload(
        documentID: String,
        bodyHash: String,
        byteCount: Int
    ) async throws -> EncryptedSessionBlobUploadTicket {
        EncryptedSessionBlobUploadTicket(
            storagePath: "session-logs/\(documentID).json",
            uploadURL: URL(string: "https://upload.invalid/\(documentID)")!
        )
    }

    func uploadEncryptedBody(data: Data, ticket: EncryptedSessionBlobUploadTicket) async throws {
        uploadedBodies.append((data, ticket))
    }

    func commitEncryptedSearchIndex(
        deviceId: String,
        indexVersion: Int,
        document: [String: Any],
        chunks: [[String: Any]]
    ) async throws {
        searchIndexCommits.append((deviceId, indexVersion, document, chunks))
    }

    func commitEncryptedProjectMemorySnapshot(_ payload: [String: Any]) async throws {}

    func getEncryptedProjectMemorySnapshot(_ payload: [String: Any]) async throws -> [String: Any] {
        [:]
    }
}
