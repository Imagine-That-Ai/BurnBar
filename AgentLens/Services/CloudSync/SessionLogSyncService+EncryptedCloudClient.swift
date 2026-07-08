import FirebaseFunctions
import Foundation

struct EncryptedSessionBlobUploadTicket {
    let storagePath: String
    let uploadURL: URL
}

protocol SessionLogEncryptedCloudClient: Sendable {
    func beginEncryptedSessionBlobUpload(
        documentID: String,
        bodyHash: String,
        byteCount: Int
    ) async throws -> EncryptedSessionBlobUploadTicket
    func uploadEncryptedBody(data: Data, ticket: EncryptedSessionBlobUploadTicket) async throws
    func commitEncryptedSearchIndex(
        deviceId: String,
        indexVersion: Int,
        document: [String: Any],
        chunks: [[String: Any]]
    ) async throws
    func commitEncryptedProjectMemorySnapshot(_ payload: [String: Any]) async throws
    func getEncryptedProjectMemorySnapshot(_ payload: [String: Any]) async throws -> [String: Any]
    func deleteEncryptedProjectMemorySnapshot(_ payload: [String: Any]) async throws -> [String: Any]
    func downloadEncryptedBody(storagePath: String) async throws -> Data
    /// Deletes the encrypted session body blob from Cloud Storage for a single
    /// session-log document. Used by tombstone GC after the retention window so
    /// the GCS object does not outlive the conversation it backed (B-DATA-2).
    func deleteEncryptedSessionBlob(documentID: String, storagePath: String) async throws
}

// AUDIT(@unchecked Sendable): wraps a non-Sendable Firebase `Functions` instance;
// the SDK is internally thread-safe. sendable-allowlist: firebase-sdk-handle
final class FirebaseSessionLogEncryptedCloudClient: SessionLogEncryptedCloudClient, @unchecked Sendable {
    private let injectedFunctions: Functions?
    private let urlSession: URLSession

    init(
        functions: Functions? = nil,
        urlSession: URLSession = .shared
    ) {
        self.injectedFunctions = functions
        self.urlSession = urlSession
    }

    private var functions: Functions {
        injectedFunctions ?? Functions.functions(region: "us-central1")
    }

    func beginEncryptedSessionBlobUpload(
        documentID: String,
        bodyHash: String,
        byteCount: Int
    ) async throws -> EncryptedSessionBlobUploadTicket {
        let result = try await functions.httpsCallable("beginEncryptedSessionBlobUpload").call([
            "documentID": documentID,
            "bodyHash": bodyHash,
            "encryptedByteCount": byteCount,
            "contentType": "application/octet-stream"
        ])
        guard let dict = result.data as? [String: Any],
              let storagePath = dict["storagePath"] as? String,
              let uploadURLString = dict["uploadURL"] as? String,
              let uploadURL = URL(string: uploadURLString) else {
            throw CloudSessionLogUploadError.invalidUploadTicket
        }
        return EncryptedSessionBlobUploadTicket(storagePath: storagePath, uploadURL: uploadURL)
    }

    func uploadEncryptedBody(data: Data, ticket: EncryptedSessionBlobUploadTicket) async throws {
        var request = URLRequest(url: ticket.uploadURL)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await urlSession.upload(for: request, from: data)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw CloudSessionLogUploadError.storageUploadFailed
        }
    }

    func commitEncryptedSearchIndex(
        deviceId: String,
        indexVersion: Int,
        document: [String: Any],
        chunks: [[String: Any]]
    ) async throws {
        _ = try await functions.httpsCallable("commitEncryptedSearchIndexBatch").call([
            "deviceId": deviceId,
            "indexVersion": indexVersion,
            "documents": [document],
            "chunks": chunks
        ])
    }

    func commitEncryptedProjectMemorySnapshot(_ payload: [String: Any]) async throws {
        _ = try await functions.httpsCallable("commitEncryptedProjectMemorySnapshot").call(payload as NSDictionary)
    }

    func getEncryptedProjectMemorySnapshot(_ payload: [String: Any]) async throws -> [String: Any] {
        let result = try await functions.httpsCallable("getEncryptedProjectMemorySnapshot").call(payload as NSDictionary)
        return result.data as? [String: Any] ?? [:]
    }

    func deleteEncryptedProjectMemorySnapshot(_ payload: [String: Any]) async throws -> [String: Any] {
        let result = try await functions.httpsCallable("deleteEncryptedProjectMemorySnapshot").call(payload as NSDictionary)
        return result.data as? [String: Any] ?? [:]
    }

    func downloadEncryptedBody(storagePath: String) async throws -> Data {
        let result = try await functions.httpsCallable("getEncryptedSessionBlobDownloadUrl").call([
            "storagePath": storagePath
        ])
        guard let dict = result.data as? [String: Any],
              let raw = dict["downloadURL"] as? String,
              let url = URL(string: raw) else {
            throw URLError(.badServerResponse)
        }
        let (data, response) = try await urlSession.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    func deleteEncryptedSessionBlob(documentID: String, storagePath: String) async throws {
        // The body lives behind a signed-URL / IAM boundary, so deletion is
        // server-mediated (same posture as `beginEncryptedSessionBlobUpload`).
        _ = try await functions.httpsCallable("deleteEncryptedSessionBlob").call([
            "documentID": documentID,
            "storagePath": storagePath
        ])
    }
}

enum CloudSessionLogUploadError: LocalizedError {
    case invalidUploadTicket
    case storageUploadFailed
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidUploadTicket:
            return "The encrypted session-log upload ticket was invalid."
        case .storageUploadFailed:
            return "Uploading the encrypted session log to Firebase Storage failed."
        case .encodingFailed:
            return "Encoding encrypted session-log metadata failed."
        }
    }
}
