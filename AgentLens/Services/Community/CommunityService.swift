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

struct CommunityJoinRequest: Encodable, Sendable {
    let l1Analytics: String
    let l2Rankings: String
    let l2World: String
    let l2Country: String
    let l2Region: String
    let l2City: String
    let locationConsent: String
    let l3LookingGlass: String
    let timezone: String
    let locale: String
    let handle: String?
    let countryCode: String?
    let regionKey: String?
    let cityKey: String?
}

struct CommunityProfileUpdateRequest: Encodable, Sendable {
    let handle: String?
    let timezone: String
    let locale: String
}

private struct CommunityEmptyRequest: Encodable {}

private struct CommunityOKResponse: Decodable {
    let ok: Bool?
}

private struct CommunityJoinResponse: Decodable {
    let anonId: String
}

private struct CommunityExportResponse: Decodable {
    let downloadUrl: String?
    let signedUrl: String?
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
            async let consentData = getOptionalDocumentData(community.document("consent"))
            async let profileData = getOptionalDocumentData(community.document("profile"))
            let (consent, prof) = try await (consentData, profileData)
            remoteConsent = try decodeOptional(FirestoreCommunityConsentDoc.self, from: consent)
            profile = try decodeOptional(FirestoreCommunityProfileDoc.self, from: prof)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func getOptionalDocumentData(_ document: CloudSyncDocumentGateway) async throws -> NSDictionary? {
        do {
            return try await document.getData() as NSDictionary
        } catch let error as NSError
            where error.domain == FirestoreErrorDomain && error.code == FirestoreErrorCode.notFound.rawValue {
            return nil
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
    func joinCommunity(payload: CommunityJoinRequest) async throws -> String {
        let response = try await call("joinCommunity", payload, response: CommunityJoinResponse.self)
        await refreshOwnerDocs()
        return response.anonId
    }

    func updateProfile(_ payload: CommunityProfileUpdateRequest) async throws {
        let response: CommunityOKResponse = try await call("updateCommunityProfile", payload)
        guard response.ok == true else {
            throw CommunityServiceError.malformedResponse
        }
        await refreshOwnerDocs()
    }

    func revokeParticipation() async throws {
        let response: CommunityOKResponse = try await call("revokeCommunityParticipation", CommunityEmptyRequest())
        guard response.ok == true else {
            throw CommunityServiceError.malformedResponse
        }
        remoteConsent = nil
        profile = nil
        await refreshOwnerDocs()
    }

    func exportLookingGlassBundle(format: String = "jsonl") async throws -> URL {
        let response = try await call(
            "exportLookingGlassBundle",
            CommunityExportRequest(format: format),
            response: CommunityExportResponse.self
        )
        guard let urlString = response.downloadUrl ?? response.signedUrl,
              let url = URL(string: urlString) else {
            throw CommunityServiceError.malformedResponse
        }
        return url
    }

    private struct CommunityExportRequest: Encodable {
        let format: String
    }

    private func call<Request: Encodable, Response: Decodable>(
        _ name: String,
        _ payload: Request,
        response: Response.Type = Response.self
    ) async throws -> Response {
        guard uidProvider() != nil else { throw CommunityServiceError.notSignedIn }
        do {
            let payloadObject = try Self.encodeJSONObject(payload)
            let result = try await functions.httpsCallable(name).call(payloadObject)
            return try Self.decodeResponse(response, from: result.data)
        } catch {
            throw CommunityServiceError.server(error.localizedDescription)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Any?) throws -> T {
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

    private func decodeOptional<T: Decodable>(_ type: T.Type, from data: Any?) throws -> T? {
        guard let data, !(data is NSNull) else { return nil }
        return try decode(type, from: data)
    }

    private static func encodeJSONObject<Request: Encodable>(_ request: Request) throws -> NSDictionary {
        let data = try JSONEncoder().encode(request)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? NSDictionary else {
            throw CommunityServiceError.malformedResponse
        }
        return dictionary
    }

    private static func decodeResponse<Response: Decodable>(_ type: Response.Type, from raw: Any?) throws -> Response {
        guard let raw else { throw CommunityServiceError.malformedResponse }
        let sanitized = sanitizeForJSON(raw)
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
        case let dict as NSDictionary:
            let sanitized = NSMutableDictionary(capacity: dict.count)
            for (key, value) in dict {
                guard let key = key as? String else { continue }
                sanitized[key] = sanitizeForJSON(value)
            }
            return sanitized
        case let array as NSArray:
            return array.map(sanitizeForJSON) as NSArray
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
