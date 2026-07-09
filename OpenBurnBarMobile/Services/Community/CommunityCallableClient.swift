import Foundation
import FirebaseFunctions

@MainActor
enum CommunityCallableClient {
    private static let region = "us-central1"

    static func joinCommunity(payload: [String: String]) async throws {
        let response = try await call("joinCommunity", data: payload)
        guard response.ok else {
            throw CommunityStoreError.callableFailed("joinCommunity")
        }
    }

    static func revokeParticipation() async throws {
        let response = try await call("revokeCommunityParticipation", data: [:])
        guard response.ok else {
            throw CommunityStoreError.callableFailed("revokeCommunityParticipation")
        }
    }

    static func exportLookingGlassBundle() async throws -> URL {
        let response = try await call("exportLookingGlassBundle", data: ["format": "jsonl"])
        guard let urlString = response.downloadUrl,
              let url = URL(string: urlString) else {
            throw CommunityStoreError.malformedResponse
        }
        return url
    }

    private struct CallableResponse: Sendable {
        let ok: Bool
        let downloadUrl: String?
    }

    private static func call(_ name: String, data: [String: String]) async throws -> CallableResponse {
        let callable = Functions.functions(region: region).httpsCallable(name)
        return try await withCheckedThrowingContinuation { continuation in
            callable.call(data) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let dict = result?.data as? [String: Any] else {
                    continuation.resume(throwing: CommunityStoreError.malformedResponse)
                    return
                }
                continuation.resume(returning: CallableResponse(
                    ok: dict["ok"] as? Bool == true,
                    downloadUrl: dict["downloadUrl"] as? String
                ))
            }
        }
    }
}
