import FirebaseAuth
import FirebaseFirestore
import FirebaseFunctions
import Foundation
import OpenBurnBarCore
import OpenBurnBarFirestoreModels

enum CommunityServiceError: LocalizedError {
    case notSignedIn
    case malformedResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Sign in to use Community."
        case .malformedResponse: return "Community service returned an unexpected response."
        case .server(let message): return message
        }
    }
}

/// Community windows match `functions/src/community/aggregation.ts`.
enum CommunityLeaderboardWindow: String, CaseIterable, Identifiable, Sendable {
    case today
    case sevenDays = "7d"
    case thirtyDays = "30d"
    case ninetyDays = "90d"
    case allTime = "all_time"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .today: return "Today"
        case .sevenDays: return "7 days"
        case .thirtyDays: return "30 days"
        case .ninetyDays: return "90 days"
        case .allTime: return "All time"
        }
    }
}

@MainActor
final class CommunityService: ObservableObject {
    private let firestore: CloudSyncFirestoreGateway
    private let functions: Functions
    private let uidProvider: () -> String?

    @Published private(set) var remoteConsent: FirestoreCommunityConsentDoc?
    @Published private(set) var profile: FirestoreCommunityProfileDoc?
    @Published private(set) var lastError: String?

    init(
        firestore: CloudSyncFirestoreGateway = CloudSyncFirestoreLiveGateway(),
        functions: Functions = Functions.functions(region: "us-central1"),
        uidProvider: @escaping () -> String? = { Auth.auth().currentUser?.uid }
    ) {
        self.firestore = firestore
        self.functions = functions
        self.uidProvider = uidProvider
    }

    func refreshOwnerDocs() async {
        guard let uid = uidProvider() else {
            remoteConsent = nil
            profile = nil
            return
        }
        do {
            let community = firestore.collection("users").document(uid).collection("community")
            async let consentData = community.document("consent").getData()
            async let profileData = community.document("profile").getData()
            let (consent, prof) = try await (consentData, profileData)
            remoteConsent = try decode(FirestoreCommunityConsentDoc.self, from: consent)
            profile = try decode(FirestoreCommunityProfileDoc.self, from: prof)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func fetchLeaderboard(
        window: CommunityLeaderboardWindow,
        tier: FirestoreGeographyTier,
        geoKey: String
    ) async throws -> FirestoreCommunityLeaderboardDoc {
        let docID = "\(window.rawValue)_\(tier.rawValue)_\(geoKey)"
        let data = try await firestore.collection("community_leaderboards").document(docID).getData()
        return try decode(FirestoreCommunityLeaderboardDoc.self, from: data)
    }

    @discardableResult
    func joinCommunity(payload: [String: Any]) async throws -> String {
        let result = try await call("joinCommunity", payload)
        guard let dict = result.data as? [String: Any],
              let anonId = dict["anonId"] as? String else {
            throw CommunityServiceError.malformedResponse
        }
        await refreshOwnerDocs()
        return anonId
    }

    func updateProfile(_ payload: [String: Any]) async throws {
        _ = try await call("updateCommunityProfile", payload)
        await refreshOwnerDocs()
    }

    func revokeParticipation() async throws {
        _ = try await call("revokeCommunityParticipation", [:] as [String: Any])
        remoteConsent = nil
        profile = nil
        await refreshOwnerDocs()
    }

    func exportLookingGlassBundle(format: String = "jsonl") async throws -> URL {
        let result = try await call("exportLookingGlassBundle", ["format": format])
        guard let dict = result.data as? [String: Any],
              let urlString = dict["downloadUrl"] as? String,
              let url = URL(string: urlString) else {
            throw CommunityServiceError.malformedResponse
        }
        return url
    }

    private func call(_ name: String, _ payload: [String: Any]) async throws -> HTTPSCallableResult {
        guard uidProvider() != nil else { throw CommunityServiceError.notSignedIn }
        do {
            return try await functions.httpsCallable(name).call(payload)
        } catch {
            throw CommunityServiceError.server(error.localizedDescription)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: [String: Any]?) throws -> T {
        guard let data else { throw CommunityServiceError.malformedResponse }
        let sanitized = Self.sanitizeForJSON(data)
        guard JSONSerialization.isValidJSONObject(sanitized) else {
            throw CommunityServiceError.malformedResponse
        }
        do {
            let json = try JSONSerialization.data(withJSONObject: sanitized)
            return try JSONDecoder().decode(type, from: json)
        } catch {
            throw CommunityServiceError.malformedResponse
        }
    }

    private static func sanitizeForJSON(_ value: Any) -> Any {
        switch value {
        case let timestamp as Timestamp:
            return iso8601String(from: timestamp.dateValue())
        case let date as Date:
            return iso8601String(from: date)
        case let dict as [String: Any]:
            return dict.reduce(into: [String: Any]()) { result, entry in
                result[entry.key] = sanitizeForJSON(entry.value)
            }
        case let array as [Any]:
            return array.map(sanitizeForJSON)
        case is NSNull:
            return NSNull()
        default:
            return value
        }
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
