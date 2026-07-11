import OpenBurnBarCore
#if canImport(FoundationNetworking)
@preconcurrency import FoundationNetworking
#endif
import Foundation

public protocol BurnBarMembershipServing: Sendable {
    func status() async -> BurnBarMembershipStatusResponse
    func checkoutURL(_ request: BurnBarMembershipCheckoutURLRequest) async throws -> BurnBarMembershipCheckoutURLResponse
    func restore() async -> BurnBarMembershipRestoreResponse
}

protocol BurnBarMembershipCloudClient: Sendable {
    func checkoutURL(_ request: BurnBarMembershipCheckoutURLRequest) async throws -> BurnBarMembershipCheckoutURLResponse
    func restore() async throws -> BurnBarMembershipSnapshot
}

enum BurnBarMembershipServiceError: Error, LocalizedError, Sendable {
    case unauthenticated
    case cloudUnavailable(String)
    case invalidResponse(String)

    var membershipCode: BurnBarMembershipErrorCode {
        switch self {
        case .unauthenticated:
            return .unauthenticated
        case .cloudUnavailable:
            return .cloudUnavailable
        case .invalidResponse:
            return .invalidResponse
        }
    }

    var errorDescription: String? {
        switch self {
        case .unauthenticated:
            return "membership.unauthenticated: OpenBurnBar cloud auth is unavailable; sign in before minting Stripe membership URLs."
        case .cloudUnavailable(let detail):
            return "membership.cloud_unavailable: \(detail)"
        case .invalidResponse(let detail):
            return "membership.invalid_response: \(detail)"
        }
    }

    var errorResult: BurnBarMembershipErrorResult {
        BurnBarMembershipErrorResult(
            code: membershipCode,
            message: errorDescription ?? "Membership request failed."
        )
    }
}

actor BurnBarMembershipService: BurnBarMembershipServing {
    private static let cacheEvent = "membership.entitlement_cache.updated"
    private static let defaultOfflineCacheKey = "entitlements/offline"

    private let cacheURL: URL
    private let cloudClient: any BurnBarMembershipCloudClient
    private let now: @Sendable () -> Date
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(
        cacheURL: URL = BurnBarDaemonPaths.defaultMembershipCacheURL,
        cloudClient: any BurnBarMembershipCloudClient = EnvironmentBurnBarMembershipCloudClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.cacheURL = cacheURL
        self.cloudClient = cloudClient
        self.now = now
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func status() async -> BurnBarMembershipStatusResponse {
        let snapshot = (try? readSnapshot()) ?? Self.offlineSnapshot(updatedAt: iso(now()))
        return BurnBarMembershipStatusResponse(membership: snapshot)
    }

    func checkoutURL(_ request: BurnBarMembershipCheckoutURLRequest) async throws -> BurnBarMembershipCheckoutURLResponse {
        try await cloudClient.checkoutURL(request)
    }

    func restore() async -> BurnBarMembershipRestoreResponse {
        do {
            let snapshot = try await cloudClient.restore()
            try writeSnapshot(snapshot)
            return BurnBarMembershipRestoreResponse(ok: true, membership: snapshot)
        } catch let error as BurnBarMembershipServiceError {
            return BurnBarMembershipRestoreResponse(ok: false, error: error.errorResult)
        } catch {
            return BurnBarMembershipRestoreResponse(
                ok: false,
                error: BurnBarMembershipErrorResult(
                    code: .cloudUnavailable,
                    message: "membership.cloud_unavailable: \(error.localizedDescription)"
                )
            )
        }
    }

    func replaceCachedSnapshot(_ snapshot: BurnBarMembershipSnapshot) throws {
        try writeSnapshot(snapshot)
    }

    private func readSnapshot() throws -> BurnBarMembershipSnapshot {
        let data = try Data(contentsOf: cacheURL)
        let envelope = try decoder.decode(BurnBarMembershipCacheEnvelope.self, from: data)
        return envelope.membership
    }

    private func writeSnapshot(_ snapshot: BurnBarMembershipSnapshot) throws {
        let parent = cacheURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let envelope = BurnBarMembershipCacheEnvelope(schemaVersion: 1, membership: snapshot)
        try encoder.encode(envelope).write(to: cacheURL, options: [.atomic])
    }

    static func offlineSnapshot(updatedAt: String? = nil) -> BurnBarMembershipSnapshot {
        BurnBarMembershipSnapshot(
            tier: "free",
            entitlementIds: [],
            entitlementDocs: [:],
            restoreAvailable: false,
            state: .offline,
            cacheEvent: cacheEvent,
            shellCacheEvent: cacheEvent,
            daemonCacheKey: defaultOfflineCacheKey,
            source: "local_cache",
            updatedAt: updatedAt,
            error: BurnBarMembershipErrorResult(
                code: .offline,
                message: "membership.offline: no local membership entitlement cache is available."
            )
        )
    }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private struct BurnBarMembershipCacheEnvelope: Codable, Sendable {
    let schemaVersion: Int
    let membership: BurnBarMembershipSnapshot
}

struct EnvironmentBurnBarMembershipCloudClient: BurnBarMembershipCloudClient {
    private let environment: [String: String]
    private let session: URLSession
    private let authTokenProvider: @Sendable () -> String?

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession = .shared,
        authTokenProvider: @escaping @Sendable () -> String? = { nil }
    ) {
        self.environment = environment
        self.session = session
        self.authTokenProvider = authTokenProvider
    }

    func checkoutURL(_ request: BurnBarMembershipCheckoutURLRequest) async throws -> BurnBarMembershipCheckoutURLResponse {
        let endpoint = try endpointURL(named: "OPENBURNBAR_MEMBERSHIP_CHECKOUT_ENDPOINT")
        let token = try authToken()
        let payload: [String: String] = [
            "success_url": request.successURL,
            "cancel_url": request.cancelURL,
            "mode": "subscription"
        ]
        let response = try await postJSON(endpoint: endpoint, token: token, payload: payload, as: CheckoutWireResponse.self)
        guard let url = response.url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else {
            throw BurnBarMembershipServiceError.invalidResponse("Stripe checkout response omitted url.")
        }
        return BurnBarMembershipCheckoutURLResponse(url: url, source: response.source ?? "stripe_checkout")
    }

    func restore() async throws -> BurnBarMembershipSnapshot {
        let endpoint = try endpointURL(named: "OPENBURNBAR_MEMBERSHIP_RESTORE_ENDPOINT")
        let token = try authToken()
        let response = try await postJSON(endpoint: endpoint, token: token, payload: EmptyPayload(), as: RestoreWireResponse.self)
        guard let membership = response.membership else {
            throw BurnBarMembershipServiceError.invalidResponse("Restore response omitted membership snapshot.")
        }
        return membership
    }

    private func endpointURL(named name: String) throws -> URL {
        guard let raw = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let url = URL(string: raw),
              url.scheme == "https" else {
            throw BurnBarMembershipServiceError.cloudUnavailable("\(name) is not configured.")
        }
        return url
    }

    private func authToken() throws -> String {
        let token = authTokenProvider()?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token, !token.isEmpty else {
            throw BurnBarMembershipServiceError.unauthenticated
        }
        return token
    }

    private func postJSON<Payload: Encodable, Response: Decodable>(
        endpoint: URL,
        token: String,
        payload: Payload,
        as responseType: Response.Type
    ) async throws -> Response {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BurnBarMembershipServiceError.invalidResponse("Membership endpoint returned a non-HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw BurnBarMembershipServiceError.cloudUnavailable("Membership endpoint returned HTTP \(http.statusCode).")
        }
        do {
            return try JSONDecoder().decode(responseType, from: data)
        } catch {
            throw BurnBarMembershipServiceError.invalidResponse(error.localizedDescription)
        }
    }
}

private struct EmptyPayload: Encodable, Sendable {}

private struct CheckoutWireResponse: Decodable, Sendable {
    let url: String?
    let source: String?
}

private struct RestoreWireResponse: Decodable, Sendable {
    let membership: BurnBarMembershipSnapshot?
}
