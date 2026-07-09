import Foundation
import FirebaseFunctions

struct CommunityCallableResponse: Decodable, Sendable {
    let ok: Bool?
    let downloadUrl: String?
    let signedUrl: String?
}

@MainActor
enum CommunityCallableClient {
    private static let region = "us-central1"

    static func joinCommunity(payload: [String: String]) async throws {
        let response = try await call("joinCommunity", data: payload)
        guard response.ok == true else {
            throw CommunityStoreError.callableFailed("joinCommunity")
        }
    }

    static func revokeParticipation() async throws {
        let response = try await call("revokeCommunityParticipation", data: [:])
        guard response.ok == true else {
            throw CommunityStoreError.callableFailed("revokeCommunityParticipation")
        }
    }

    static func exportLookingGlassBundle() async throws -> URL {
        let response = try await call("exportLookingGlassBundle", data: ["format": "jsonl"])
        guard let urlString = response.downloadUrl ?? response.signedUrl,
              let url = URL(string: urlString) else {
            throw CommunityStoreError.malformedResponse
        }
        return url
    }


    private static func call(_ name: String, data: [String: String]) async throws -> CommunityCallableResponse {
        let callable = Functions.functions(region: region).httpsCallable(
            name,
            requestAs: [String: String].self,
            responseAs: CommunityCallableResponse.self
        )
        return try await callable.call(data)
    }
}
