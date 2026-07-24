import Foundation
#if canImport(FoundationNetworking)
@preconcurrency import FoundationNetworking
#endif

public struct FirebaseLinuxCloudReplicaCredentials: Sendable, Equatable {
    public let idToken: String
    public let appCheckToken: String

    public init(idToken: String, appCheckToken: String) {
        self.idToken = idToken
        self.appCheckToken = appCheckToken
    }
}

public typealias FirebaseLinuxCloudReplicaCredentialProvider = @Sendable () async throws
    -> FirebaseLinuxCloudReplicaCredentials
public typealias FirebaseLinuxCloudReplicaTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

/// Firebase callable gateway for encrypted Linux cloud replicas. Authentication
/// and App Check material are resolved inside the daemon for every request.
public struct FirebaseLinuxCloudReplicaGateway: LinuxCloudReplicaEngine.Gateway {
    public static let defaultBaseURL = URL(string: "https://us-central1-burnbar.cloudfunctions.net") ?? URL(fileURLWithPath: "/")
    public static let maximumRequestBytes = 8 * 1_024 * 1_024
    public static let maximumResponseBytes = 8 * 1_024 * 1_024
    public static let pullLimit = 500

    public enum GatewayError: Error, Equatable, Sendable {
        case invalidConfiguration
        case invalidRequest
        case invalidResponse
        case requestTooLarge
        case responseTooLarge
        case transportFailure
        case rejected(status: Int)
    }

    private let baseURL: URL
    private let allowedHosts: Set<String>
    private let credentials: FirebaseLinuxCloudReplicaCredentialProvider
    private let transport: FirebaseLinuxCloudReplicaTransport

    public init(
        baseURL: URL = defaultBaseURL,
        allowedHosts: Set<String> = ["us-central1-burnbar.cloudfunctions.net"],
        credentials: @escaping FirebaseLinuxCloudReplicaCredentialProvider,
        transport: @escaping FirebaseLinuxCloudReplicaTransport = { request in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.urlCache = nil
            configuration.httpShouldSetCookies = false
            return try await URLSession(configuration: configuration).data(for: request)
        }
    ) {
        self.baseURL = baseURL
        self.allowedHosts = allowedHosts
        self.credentials = credentials
        self.transport = transport
    }

    public func push(
        uid: String,
        mutations: [LinuxCloudReplicaEngine.OutboundMutation]
    ) async throws -> LinuxCloudReplicaEngine.PushResult {
        guard !mutations.isEmpty, mutations.count <= 200 else { throw GatewayError.invalidRequest }
        let result: LinuxCloudReplicaEngine.PushResult = try await call(
            name: "pushLinuxCloudReplicas",
            payload: FirebaseCloudReplicaPushRequest(mutations: mutations)
        )
        let expectedIDs = Set(mutations.map(\.mutationID))
        guard result.acknowledgedMutationIDs.count == expectedIDs.count,
              Set(result.acknowledgedMutationIDs) == expectedIDs,
              result.authoritativeReplicas.count <= mutations.count else {
            throw GatewayError.invalidResponse
        }
        return result
    }

    public func pull(
        uid: String,
        domains: Set<LinuxCloudReplicaEngine.Domain>,
        after cursor: String?
    ) async throws -> LinuxCloudReplicaEngine.PullPage {
        guard !domains.isEmpty,
              domains.isSubset(of: LinuxCloudReplicaEngine.Domain.supported),
              cursor?.utf8.count ?? 0 <= 256 else {
            throw GatewayError.invalidRequest
        }
        let result: LinuxCloudReplicaEngine.PullPage = try await call(
            name: "pullLinuxCloudReplicas",
            payload: FirebaseCloudReplicaPullRequest(
                domains: domains.map(\.rawValue).sorted(),
                cursor: cursor,
                limit: Self.pullLimit
            )
        )
        guard result.replicas.count <= Self.pullLimit,
              result.nextCursor?.utf8.count ?? 0 <= 256,
              result.replicas.allSatisfy({ domains.contains($0.domain) }) else {
            throw GatewayError.invalidResponse
        }
        return result
    }

    private func call<Payload: Encodable, Result: Decodable>(
        name: String,
        payload: Payload
    ) async throws -> Result {
        guard Self.isStrictHTTPSBaseURL(baseURL, allowedHosts: allowedHosts) else {
            throw GatewayError.invalidConfiguration
        }
        let credential = try await credentials()
        guard !credential.idToken.isEmpty,
              credential.idToken.utf8.count <= 16_384,
              !credential.appCheckToken.isEmpty,
              credential.appCheckToken.utf8.count <= 16_384 else {
            throw GatewayError.invalidConfiguration
        }

        var request = URLRequest(url: baseURL.appendingPathComponent(name, isDirectory: false))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(credential.idToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credential.appCheckToken, forHTTPHeaderField: "X-Firebase-AppCheck")
        let body = try JSONEncoder().encode(FirebaseCloudReplicaCallableRequest(data: payload))
        guard body.count <= Self.maximumRequestBytes else { throw GatewayError.requestTooLarge }
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch {
            throw GatewayError.transportFailure
        }
        guard data.count <= Self.maximumResponseBytes else { throw GatewayError.responseTooLarge }
        guard let http = response as? HTTPURLResponse else { throw GatewayError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw GatewayError.rejected(status: http.statusCode) }
        guard let decoded = try? JSONDecoder().decode(
            FirebaseCloudReplicaCallableResponse<Result>.self,
            from: data
        ) else {
            throw GatewayError.invalidResponse
        }
        return decoded.value
    }

    private static func isStrictHTTPSBaseURL(_ url: URL, allowedHosts: Set<String>) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        let host = components.host?.lowercased()
        return components.scheme?.lowercased() == "https"
            && host.map(allowedHosts.contains) == true
            && components.user == nil
            && components.password == nil
            && (components.port == nil || components.port == 443)
            && (components.path.isEmpty || components.path == "/")
            && components.query == nil
            && components.fragment == nil
    }
}

private struct FirebaseCloudReplicaPushRequest: Encodable {
    let mutations: [LinuxCloudReplicaEngine.OutboundMutation]
}

private struct FirebaseCloudReplicaPullRequest: Encodable {
    let domains: [String]
    let cursor: String?
    let limit: Int
}

private struct FirebaseCloudReplicaCallableRequest<Payload: Encodable>: Encodable {
    let data: Payload
}

private struct FirebaseCloudReplicaCallableResponse<Result: Decodable>: Decodable {
    let value: Result

    private enum CodingKeys: String, CodingKey { case result, data }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let result = try container.decodeIfPresent(Result.self, forKey: .result) {
            value = result
        } else {
            value = try container.decode(Result.self, forKey: .data)
        }
    }
}
