import OpenBurnBarEngine
#if canImport(FoundationNetworking)
@preconcurrency import FoundationNetworking
#endif
import Foundation

public protocol BurnBarMembershipServing: Sendable {
    func status() async -> BurnBarMembershipStatusResponse
    func checkoutURL(_ request: BurnBarMembershipCheckoutURLRequest) async throws -> BurnBarMembershipCheckoutURLResponse
    func portalURL(_ request: BurnBarMembershipPortalURLRequest) async throws -> BurnBarMembershipPortalURLResponse
    func restore() async -> BurnBarMembershipRestoreResponse
}

protocol BurnBarMembershipCloudClient: Sendable {
    func checkoutURL(_ request: BurnBarMembershipCheckoutURLRequest) async throws -> BurnBarMembershipCheckoutURLResponse
    func portalURL(_ request: BurnBarMembershipPortalURLRequest) async throws -> BurnBarMembershipPortalURLResponse
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

    func portalURL(_ request: BurnBarMembershipPortalURLRequest) async throws -> BurnBarMembershipPortalURLResponse {
        try await cloudClient.portalURL(request)
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
    private static let requestTimeout: TimeInterval = 15
    private static let maximumResponseBytes = 64 * 1_024

    private let environment: [String: String]
    private let session: URLSession
    private let authTokenProvider: (@Sendable () -> String?)?
    private let appCheckTokenProvider: (@Sendable () -> String?)?

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession = .shared,
        authTokenProvider: (@Sendable () -> String?)? = nil,
        appCheckTokenProvider: (@Sendable () -> String?)? = nil
    ) {
        self.environment = environment
        self.session = session
        self.authTokenProvider = authTokenProvider
        self.appCheckTokenProvider = appCheckTokenProvider
    }

    func checkoutURL(_ request: BurnBarMembershipCheckoutURLRequest) async throws -> BurnBarMembershipCheckoutURLResponse {
        let endpoint = try endpointURL(
            named: "OPENBURNBAR_MEMBERSHIP_CHECKOUT_ENDPOINT",
            callableName: "createStripeBurnBarProCheckoutSession"
        )
        let token = try authToken()
        let payload = CheckoutCallablePayload(
            successUrl: try validatedOpenBurnBarLocation(request.successURL),
            cancelUrl: try validatedOpenBurnBarLocation(request.cancelURL)
        )
        let envelope = try await postJSON(
            endpoint: endpoint,
            token: token,
            appCheckToken: normalizedAppCheckToken(),
            payload: FirebaseCallableRequest(data: payload),
            as: FirebaseCallableResponse<CheckoutWireResponse>.self
        )
        guard let response = envelope.data ?? envelope.result else {
            throw BurnBarMembershipServiceError.invalidResponse("Stripe checkout callable omitted its result.")
        }
        let url = try validatedStripeExternalURL(
            response.url,
            allowedHosts: ["checkout.stripe.com", "buy.stripe.com"]
        )
        return BurnBarMembershipCheckoutURLResponse(url: url, source: response.source ?? "stripe_checkout")
    }

    func portalURL(_ request: BurnBarMembershipPortalURLRequest) async throws -> BurnBarMembershipPortalURLResponse {
        let endpoint = try endpointURL(
            named: "OPENBURNBAR_MEMBERSHIP_PORTAL_ENDPOINT",
            callableName: "createStripeBurnBarProPortalSession"
        )
        let token = try authToken()
        let appCheckToken = normalizedAppCheckToken()
        let returnURL = try validatedOpenBurnBarLocation(request.returnURL)
        let payload = PortalCallablePayload(returnUrl: returnURL)
        let envelope = try await postJSON(
            endpoint: endpoint,
            token: token,
            appCheckToken: appCheckToken,
            payload: FirebaseCallableRequest(data: payload),
            as: FirebaseCallableResponse<PortalWireResponse>.self
        )
        guard let response = envelope.data ?? envelope.result else {
            throw BurnBarMembershipServiceError.invalidResponse("Stripe billing portal callable omitted its result.")
        }
        let url = try validatedStripeExternalURL(response.url, allowedHosts: ["billing.stripe.com"])
        return BurnBarMembershipPortalURLResponse(url: url, source: "stripe_billing_portal")
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

    private func endpointURL(named name: String, callableName: String? = nil) throws -> URL {
        let configured = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = environment["OPENBURNBAR_FIREBASE_FUNCTIONS_BASE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultBase = "https://us-central1-burnbar.cloudfunctions.net"
        let resolvedBase = base?.isEmpty == false ? base ?? defaultBase : defaultBase
        let raw: String?
        if let configured, !configured.isEmpty {
            raw = configured
        } else if let callableName {
            raw = "\(resolvedBase.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/\(callableName)"
        } else {
            raw = nil
        }
        guard let raw,
              let url = URL(string: raw),
              url.scheme == "https",
              url.host?.isEmpty == false,
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443 else {
            throw BurnBarMembershipServiceError.cloudUnavailable("\(name) is not configured.")
        }
        return url
    }

    private func authToken() throws -> String {
        // When a protected token provider is wired (e.g. a daemon credential
        // store), it is the sole auth-token source. Otherwise fall back to the
        // daemon's own launch environment — the pre-existing production path.
        // That variable is stripped from every child-process environment via
        // `BurnBarCLIShellExecutor.childEnvironmentDeniedKeys`, so the daemon
        // reading its own environment does not reintroduce the child-env leak
        // this hardening removed.
        let raw: String?
        if let authTokenProvider {
            raw = authTokenProvider()
        } else {
            raw = environment["OPENBURNBAR_FIREBASE_ID_TOKEN"]
        }
        let token = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token, !token.isEmpty else {
            throw BurnBarMembershipServiceError.unauthenticated
        }
        return token
    }

    private func normalizedAppCheckToken() -> String? {
        let raw = appCheckTokenProvider?() ?? environment["OPENBURNBAR_FIREBASE_APP_CHECK_TOKEN"]
        guard let token = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty,
              token.utf8.count <= 16_384 else { return nil }
        return token
    }

    private func validatedOpenBurnBarLocation(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 2_048,
              let url = URL(string: value),
              url.scheme == "https",
              url.host == "openburnbar.com",
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443,
              ["/", "/account"].contains(url.path),
              url.query == nil,
              url.fragment == nil else {
            throw BurnBarMembershipServiceError.invalidResponse("Billing return URL is not an approved OpenBurnBar HTTPS location.")
        }
        return value
    }

    private func validatedStripeExternalURL(_ raw: String?, allowedHosts: Set<String>) throws -> String {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              raw.utf8.count <= 2_048,
              let url = URL(string: raw),
              url.scheme == "https",
              url.host.map(allowedHosts.contains) == true,
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443 else {
            throw BurnBarMembershipServiceError.invalidResponse("Stripe returned an invalid external billing URL.")
        }
        return raw
    }

    private func postJSON<Payload: Encodable, Response: Decodable>(
        endpoint: URL,
        token: String,
        appCheckToken: String? = nil,
        payload: Payload,
        as responseType: Response.Type
    ) async throws -> Response {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let appCheckToken {
            request.setValue(appCheckToken, forHTTPHeaderField: "X-Firebase-AppCheck")
        }
        request.timeoutInterval = Self.requestTimeout
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BurnBarMembershipServiceError.invalidResponse("Membership endpoint returned a non-HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw BurnBarMembershipServiceError.cloudUnavailable("Membership endpoint returned HTTP \(http.statusCode).")
        }
        guard data.count <= Self.maximumResponseBytes else {
            throw BurnBarMembershipServiceError.invalidResponse("Membership endpoint response exceeded 64 KiB.")
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

private struct CheckoutCallablePayload: Encodable, Sendable {
    let successUrl: String
    let cancelUrl: String
}

private struct PortalCallablePayload: Encodable, Sendable {
    let returnUrl: String
}

private struct PortalWireResponse: Decodable, Sendable {
    let url: String?
}

private struct FirebaseCallableRequest<Payload: Encodable & Sendable>: Encodable, Sendable {
    let data: Payload
}

private struct FirebaseCallableResponse<Payload: Decodable & Sendable>: Decodable, Sendable {
    let data: Payload?
    let result: Payload?
}

private struct RestoreWireResponse: Decodable, Sendable {
    let membership: BurnBarMembershipSnapshot?
}
