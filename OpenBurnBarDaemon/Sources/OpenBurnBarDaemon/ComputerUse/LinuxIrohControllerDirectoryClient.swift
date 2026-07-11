#if os(Linux)
import Foundation
#if canImport(FoundationNetworking)
@preconcurrency import FoundationNetworking
#endif
import OpenBurnBarIrohRelay

struct LinuxIrohControllerRoute: Sendable, Equatable {
    let uid: String
    let connectionID: String
    let sourceDeviceID: String
    let transportNodeID: String
    let authorityPeerNodeID: String
    let generation: Int64
    let registeredAt: Date
    let expiresAt: Date
    let accountGeneration: UInt64
}

protocol LinuxIrohControllerDirectoryServing: Sendable {
    func publishHostPublicKey(_ keypair: IrohPairingKeypair) async throws
    func publishHostRecord(_ record: IrohPairingRecord) async throws
    func resolveActiveRoute(connectionID: String) async throws -> LinuxIrohControllerRoute?
    func revokeHostRecord(connectionID: String) async throws
}

enum LinuxIrohControllerDirectoryError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidRequest
    case invalidResponse
    case requestTooLarge
    case responseTooLarge
    case transportFailure
    case rejected(status: Int)
    case routeMismatch
}

typealias LinuxIrohCallableTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
struct LinuxIrohControllerDirectoryClient: LinuxIrohControllerDirectoryServing {
    static let defaultBaseURL = URL(string: "https://us-central1-burnbar.cloudfunctions.net")!
    static let maximumRequestBytes = 32 * 1_024
    static let maximumResponseBytes = 64 * 1_024

    private let baseURL: URL
    private let credentials: LinuxIrohControllerCredentialProvider
    private let transport: LinuxIrohCallableTransport
    private let now: @Sendable () -> Date

    init(
        baseURL: URL = defaultBaseURL,
        credentials: @escaping LinuxIrohControllerCredentialProvider,
        transport: @escaping LinuxIrohCallableTransport = { request in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.urlCache = nil
            configuration.httpShouldSetCookies = false
            return try await URLSession(configuration: configuration).data(for: request)
        },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.baseURL = baseURL
        self.credentials = credentials
        self.transport = transport
        self.now = now
    }

    func publishHostPublicKey(_ keypair: IrohPairingKeypair) async throws {
        let context = try await credentials()
        let nonce = try await issueNonce(context: context)
        let result: MutationResult = try await call(
            name: "publishIrohPairingPublicKey",
            payload: PublishPublicKeyRequest(
                deviceId: context.deviceID,
                roleId: "host",
                publicKeyBase64: keypair.publicKeyBase64,
                nonce: nonce
            ),
            context: context
        )
        guard result.ok, result.roleId == "host" else {
            throw LinuxIrohControllerDirectoryError.invalidResponse
        }
    }

    func publishHostRecord(_ record: IrohPairingRecord) async throws {
        let context = try await credentials()
        guard record.uid == context.uid else {
            throw LinuxIrohControllerDirectoryError.invalidRequest
        }
        let nonce = try await issueNonce(context: context)
        let result: MutationResult = try await call(
            name: "publishIrohPairingRecord",
            payload: PublishRecordRequest(
                deviceId: context.deviceID,
                connectionId: record.connectionId,
                nodeId: record.nodeId,
                relayURL: record.relayURL,
                directAddresses: record.directAddresses,
                publishedAtMillis: record.publishedAtMillis,
                protocolVersion: record.protocolVersion,
                signature: record.signature,
                nonce: nonce
            ),
            context: context
        )
        guard result.ok, result.connectionId == record.connectionId else {
            throw LinuxIrohControllerDirectoryError.invalidResponse
        }
    }

    func resolveActiveRoute(connectionID: String) async throws -> LinuxIrohControllerRoute? {
        let context = try await credentials()
        let result: ResolveRoutesResult = try await call(
            name: "resolveActiveIrohControllerRoutes",
            payload: ResolveRoutesRequest(connectionId: connectionID),
            context: context
        )
        let postResolutionContext = try await credentials()
        let localResolvedAt = now()
        let localResolvedAtMillis = Int64(localResolvedAt.timeIntervalSince1970 * 1_000)
        guard result.uid == context.uid,
              postResolutionContext.uid == context.uid,
              postResolutionContext.sessionGeneration == context.sessionGeneration,
              postResolutionContext.deviceID == context.deviceID,
              result.connectionId == connectionID,
              result.routes.count <= 1,
              result.resolvedAtMillis > 0,
              abs(result.resolvedAtMillis - localResolvedAtMillis) <= 30_000 else {
            throw LinuxIrohControllerDirectoryError.routeMismatch
        }
        guard let route = result.routes.first else { return nil }
        let remainingLeaseMillis = route.expiresAtMillis - result.resolvedAtMillis
        guard
              route.connectionId == connectionID,
              route.generation > 0,
              route.registeredAtMillis > 0,
              route.registeredAtMillis <= result.resolvedAtMillis,
              remainingLeaseMillis > 0,
              remainingLeaseMillis <= 15 * 60 * 1_000,
              Self.isIdentifier(route.sourceDeviceId),
              Self.isIdentifier(route.authorityPeerNodeId),
              Self.isTransportNodeID(route.transportNodeId) else {
            throw LinuxIrohControllerDirectoryError.routeMismatch
        }
        return LinuxIrohControllerRoute(
            uid: context.uid,
            connectionID: connectionID,
            sourceDeviceID: route.sourceDeviceId,
            transportNodeID: route.transportNodeId.lowercased(),
            authorityPeerNodeID: route.authorityPeerNodeId,
            generation: route.generation,
            registeredAt: Date(timeIntervalSince1970: Double(route.registeredAtMillis) / 1_000),
            expiresAt: Date(timeIntervalSince1970: Double(route.expiresAtMillis) / 1_000),
            accountGeneration: context.sessionGeneration
        )
    }

    func revokeHostRecord(connectionID: String) async throws {
        let context = try await credentials()
        let nonce = try await issueNonce(context: context)
        let result: MutationResult = try await call(
            name: "revokeIrohPairingRecord",
            payload: RevokeRecordRequest(
                deviceId: context.deviceID,
                connectionId: connectionID,
                nonce: nonce
            ),
            context: context
        )
        guard result.ok, result.connectionId == connectionID else {
            throw LinuxIrohControllerDirectoryError.invalidResponse
        }
    }

    private func issueNonce(context: LinuxIrohControllerCredentialContext) async throws -> String {
        let result: NonceResult = try await call(
            name: "issueHighRiskActionNonce",
            payload: EmptyRequest(),
            context: context
        )
        guard Self.isIdentifier(result.nonce) else {
            throw LinuxIrohControllerDirectoryError.invalidResponse
        }
        return result.nonce
    }

    private func call<Payload: Encodable, Result: Decodable>(
        name: String,
        payload: Payload,
        context: LinuxIrohControllerCredentialContext
    ) async throws -> Result {
        guard Self.isStrictHTTPSEndpoint(baseURL),
              Self.isIdentifier(name),
              context.idToken.utf8.count <= 16_384,
              context.appCheckToken.utf8.count <= 16_384 else {
            throw LinuxIrohControllerDirectoryError.invalidConfiguration
        }
        let endpoint = baseURL.appendingPathComponent(name, isDirectory: false)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(context.idToken)", forHTTPHeaderField: "Authorization")
        request.setValue(context.appCheckToken, forHTTPHeaderField: "X-Firebase-AppCheck")
        let body = try JSONEncoder().encode(CallableRequest(data: payload))
        guard body.count <= Self.maximumRequestBytes else {
            throw LinuxIrohControllerDirectoryError.requestTooLarge
        }
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch {
            throw LinuxIrohControllerDirectoryError.transportFailure
        }
        guard data.count <= Self.maximumResponseBytes else {
            throw LinuxIrohControllerDirectoryError.responseTooLarge
        }
        guard let http = response as? HTTPURLResponse else {
            throw LinuxIrohControllerDirectoryError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LinuxIrohControllerDirectoryError.rejected(status: http.statusCode)
        }
        do {
            return try JSONDecoder().decode(CallableResponse<Result>.self, from: data).value
        } catch {
            throw LinuxIrohControllerDirectoryError.invalidResponse
        }
    }

    private static func isIdentifier(_ value: String) -> Bool {
        value.isEmpty == false
            && value.utf8.count <= 160
            && value.allSatisfy { $0.isLetter || $0.isNumber || "._:+-/=".contains($0) }
    }

    private static func isStrictHTTPSEndpoint(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme?.lowercased() == "https"
            && components.host?.isEmpty == false
            && components.user == nil
            && components.password == nil
            && components.query == nil
            && components.fragment == nil
    }

    private static func isTransportNodeID(_ value: String) -> Bool {
        let normalized = value.lowercased()
        return normalized.utf8.count == 64
            && normalized.allSatisfy { "0123456789abcdef".contains($0) }
    }
}

private struct CallableRequest<Payload: Encodable>: Encodable {
    let data: Payload
}

private struct CallableResponse<Result: Decodable>: Decodable {
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

private struct EmptyRequest: Encodable {}
private struct NonceResult: Decodable { let nonce: String }
private struct MutationResult: Decodable {
    let ok: Bool
    let roleId: String?
    let connectionId: String?
}
private struct PublishPublicKeyRequest: Encodable {
    let deviceId: String
    let roleId: String
    let publicKeyBase64: String
    let nonce: String
}
private struct PublishRecordRequest: Encodable {
    let deviceId: String
    let connectionId: String
    let nodeId: String
    let relayURL: String?
    let directAddresses: [String]
    let publishedAtMillis: Int64
    let protocolVersion: Int
    let signature: String
    let nonce: String
}
private struct ResolveRoutesRequest: Encodable { let connectionId: String }
private struct RevokeRecordRequest: Encodable {
    let deviceId: String
    let connectionId: String
    let nonce: String
}
private struct ResolveRoutesResult: Decodable {
    let uid: String
    let connectionId: String
    let resolvedAtMillis: Int64
    let routes: [Route]

    struct Route: Decodable {
        let connectionId: String
        let sourceDeviceId: String
        let transportNodeId: String
        let authorityPeerNodeId: String
        let generation: Int64
        let registeredAtMillis: Int64
        let expiresAtMillis: Int64
    }
}
#endif
