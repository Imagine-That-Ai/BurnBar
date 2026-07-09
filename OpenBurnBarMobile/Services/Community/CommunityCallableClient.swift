import Foundation
import FirebaseFunctions

enum CommunityCallableClient {
    private static let region = "us-central1"

    static func joinCommunity(payload: [String: Any]) async throws {
        let result = try await Functions.functions(region: region)
            .httpsCallable("joinCommunity")
            .call(payload)
        guard let dict = result.data as? [String: Any], dict["ok"] as? Bool == true else {
            throw CommunityStoreError.callableFailed("joinCommunity")
        }
    }

    static func revokeParticipation() async throws {
        let result = try await Functions.functions(region: region)
            .httpsCallable("revokeCommunityParticipation")
            .call([:])
        guard let dict = result.data as? [String: Any], dict["ok"] as? Bool == true else {
            throw CommunityStoreError.callableFailed("revokeCommunityParticipation")
        }
    }

    static func exportLookingGlassBundle() async throws -> URL {
        let result = try await Functions.functions(region: region)
            .httpsCallable("exportLookingGlassBundle")
            .call(["format": "jsonl"])
        guard let dict = result.data as? [String: Any],
              let urlString = dict["downloadURL"] as? String,
              let url = URL(string: urlString) else {
            throw CommunityStoreError.malformedResponse
        }
        return url
    }
}