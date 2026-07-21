#if os(Linux)
import Foundation
import OpenBurnBarEngine
#if canImport(FoundationNetworking)
@preconcurrency import FoundationNetworking
#endif

enum LinuxCloudAuthHTTPError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidConfiguration
    case invalidRequest
    case requestTooLarge
    case responseTooLarge
    case transportFailure
    case rejected(stage: String, status: Int, reason: String?)
    case malformedResponse(stage: String)

    var description: String {
        switch self {
        case .invalidConfiguration: "Cloud authentication is not configured."
        case .invalidRequest: "Cloud authentication request was invalid."
        case .requestTooLarge: "Cloud authentication request exceeded its size limit."
        case .responseTooLarge: "Cloud authentication response exceeded its size limit."
        case .transportFailure: "Cloud authentication transport failed."
        case let .rejected(stage, status, _): "Cloud authentication stage \(stage) was rejected (HTTP \(status))."
        case let .malformedResponse(stage): "Cloud authentication stage \(stage) returned an invalid response."
        }
    }
}

struct LinuxFirebaseSession: Sendable, Equatable {
    let uid: String
    let idToken: String
    let refreshToken: String
    let expiresAt: Date
}

struct LinuxGoogleOAuthToken: Sendable, Equatable {
    let idToken: String
}

struct LinuxAppCheckChallenge: Sendable, Equatable {
    let challengeID: String
    let canonicalPayload: Data
    let issuedAtMillis: Int64
    let expiresAtMillis: Int64
}

struct LinuxAppCheckMint: Sendable, Equatable {
    let token: String
    let expiresAt: Date
}

typealias LinuxCloudAuthHTTPTransport = @Sendable (URLRequest, Int) async throws -> (Data, HTTPURLResponse)

struct LinuxCloudAuthHTTPClient: Sendable {
    static let maximumRequestBytes = 32 * 1_024
    static let maximumResponseBytes = 64 * 1_024
    /// Account exports contain bounded domain snapshots and sealed references,
    /// so they need a larger ceiling than authentication responses. The
    /// daemon still rejects unbounded responses before they reach the shell.
    static let maximumDataControlResponseBytes = 8 * 1_024 * 1_024

    private let transport: LinuxCloudAuthHTTPTransport
    private let allowedHosts: Set<String>
    private let now: @Sendable () -> Date

    init(
        allowedHosts: Set<String>,
        transport: @escaping LinuxCloudAuthHTTPTransport = Self.productionTransport,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.allowedHosts = Set(allowedHosts.map { $0.lowercased() })
        self.transport = transport
        self.now = now
    }

    func exchangeGoogleAuthorizationCode(
        endpoint: URL,
        clientID: String,
        clientSecret: String?,
        code: String,
        verifier: String,
        redirectURI: String
    ) async throws -> LinuxGoogleOAuthToken {
        var fields = [
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI
        ]
        if let clientSecret, clientSecret.isEmpty == false { fields["client_secret"] = clientSecret }
        let response: GoogleTokenResponse = try await postForm(
            endpoint,
            fields: fields,
            stage: "google_token"
        )
        guard let idToken = response.idToken?.boundedToken else {
            throw LinuxCloudAuthHTTPError.malformedResponse(stage: "google_token")
        }
        return LinuxGoogleOAuthToken(idToken: idToken)
    }

    func signInToFirebase(
        endpoint: URL,
        apiKey: String,
        googleIDToken: String,
        requestURI: String
    ) async throws -> LinuxFirebaseSession {
        let url = try endpointWithAPIKey(endpoint, apiKey: apiKey)
        let postBody = formBody([
            "id_token": googleIDToken,
            "providerId": "google.com"
        ])
        let response: FirebaseSignInResponse = try await postJSON(
            url,
            value: FirebaseSignInRequest(
                requestUri: requestURI,
                postBody: String(decoding: postBody, as: UTF8.self),
                returnIdpCredential: false,
                returnSecureToken: true
            ),
            stage: "firebase_sign_in"
        )
        return try firebaseSession(
            uid: response.localId,
            idToken: response.idToken,
            refreshToken: response.refreshToken,
            expiresIn: response.expiresIn,
            stage: "firebase_sign_in"
        )
    }

    func refreshFirebaseSession(
        endpoint: URL,
        apiKey: String,
        refreshToken: String
    ) async throws -> LinuxFirebaseSession {
        let response: FirebaseRefreshResponse = try await postForm(
            try endpointWithAPIKey(endpoint, apiKey: apiKey),
            fields: [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken
            ],
            stage: "firebase_refresh"
        )
        return try firebaseSession(
            uid: response.userId,
            idToken: response.idToken,
            refreshToken: response.refreshToken,
            expiresIn: response.expiresIn,
            stage: "firebase_refresh"
        )
    }

    func registerLinuxDevice(
        functionsBaseURL: URL,
        idToken: String,
        deviceID: String,
        deviceName: String,
        appID: String,
        publicKeyBase64: String,
        issuedAtMillis: Int64,
        signatureBase64: String
    ) async throws {
        let response: MutationResponse = try await call(
            baseURL: functionsBaseURL,
            name: "registerLinuxAppCheckDevice",
            payload: RegisterDeviceRequest(
                deviceId: deviceID,
                deviceName: deviceName,
                appId: appID,
                publicKeyBase64: publicKeyBase64,
                issuedAtMillis: issuedAtMillis,
                signatureBase64: signatureBase64
            ),
            idToken: idToken,
            appCheckToken: nil,
            stage: "register_linux_device"
        )
        guard response.ok else { throw LinuxCloudAuthHTTPError.malformedResponse(stage: "register_linux_device") }
    }

    func issueLinuxChallenge(
        functionsBaseURL: URL,
        idToken: String,
        deviceID: String,
        appID: String
    ) async throws -> LinuxAppCheckChallenge {
        let response: ChallengeResponse = try await call(
            baseURL: functionsBaseURL,
            name: "issueLinuxAppCheckChallenge",
            payload: ChallengeRequest(deviceId: deviceID, appId: appID),
            idToken: idToken,
            appCheckToken: nil,
            stage: "issue_linux_challenge"
        )
        guard response.ok,
              response.signatureAlgorithm == "ed25519",
              let payload = Data(base64Encoded: response.canonicalPayloadBase64),
              payload.isEmpty == false,
              payload.count <= 4 * 1_024,
              response.challengeId.isBoundedIdentifier,
              response.issuedAtMillis > 0,
              response.expiresAtMillis > response.issuedAtMillis else {
            throw LinuxCloudAuthHTTPError.malformedResponse(stage: "issue_linux_challenge")
        }
        return LinuxAppCheckChallenge(
            challengeID: response.challengeId,
            canonicalPayload: payload,
            issuedAtMillis: response.issuedAtMillis,
            expiresAtMillis: response.expiresAtMillis
        )
    }

    func mintLinuxAppCheck(
        functionsBaseURL: URL,
        idToken: String,
        deviceID: String,
        appID: String,
        challengeID: String,
        signatureBase64: String
    ) async throws -> LinuxAppCheckMint {
        let response: MintResponse = try await call(
            baseURL: functionsBaseURL,
            name: "mintLinuxAppCheckToken",
            payload: MintRequest(
                attestation: .init(
                    kind: "device-key-v1",
                    deviceId: deviceID,
                    appId: appID,
                    challengeId: challengeID,
                    signatureBase64: signatureBase64
                )
            ),
            idToken: idToken,
            appCheckToken: nil,
            stage: "mint_linux_app_check"
        )
        guard response.ok,
              response.appId == appID,
              response.trustClass == "linux_lower_trust",
              let token = response.appCheckToken.boundedToken,
              response.ttlMillis >= 60_000,
              response.ttlMillis <= 1_800_000 else {
            throw LinuxCloudAuthHTTPError.malformedResponse(stage: "mint_linux_app_check")
        }
        return LinuxAppCheckMint(
            token: token,
            expiresAt: now().addingTimeInterval(Double(response.ttlMillis) / 1_000)
        )
    }

    func bindAppCheck(
        functionsBaseURL: URL,
        idToken: String,
        appCheckToken: String
    ) async throws {
        let response: MutationResponse = try await call(
            baseURL: functionsBaseURL,
            name: "bindAppCheckAttestation",
            payload: EmptyRequest(),
            idToken: idToken,
            appCheckToken: appCheckToken,
            stage: "bind_app_check"
        )
        guard response.ok else { throw LinuxCloudAuthHTTPError.malformedResponse(stage: "bind_app_check") }
    }

    /// List Linux App Check devices through the native trusted-device callable.
    /// The caller must provide credentials belonging to the trusted native
    /// manager (not the lower-trust Linux installation). Public-key bytes and
    /// server bookkeeping are validated here and discarded before the redacted
    /// daemon contract is returned.
    func listLinuxTrustedDevices(
        functionsBaseURL: URL,
        credentials: LinuxCloudTrustedDeviceManagerCredentials
    ) async throws -> [BurnBarLinuxTrustedDevice] {
        try validateTrustedDeviceCredentials(credentials, stage: "list_linux_devices")
        let response: TrustedDeviceListResponse = try await trustedDeviceCall(
            baseURL: functionsBaseURL,
            name: "listLinuxAppCheckDevices",
            payload: TrustedDeviceListRequest(approverDeviceId: credentials.approverDeviceID),
            credentials: credentials,
            stage: "list_linux_devices"
        )
        guard response.ok, response.devices.count <= 100 else {
            throw LinuxCloudAuthHTTPError.malformedResponse(stage: "list_linux_devices")
        }
        return try response.devices.map { try $0.redacted() }
    }

    /// Approve a pending Linux App Check device. Nonce and action proof are
    /// supplied by the trusted companion-device flow and forwarded unchanged;
    /// Linux never signs or synthesizes either value locally.
    func approveLinuxTrustedDevice(
        functionsBaseURL: URL,
        credentials: LinuxCloudTrustedDeviceManagerCredentials,
        deviceID: String,
        authorization: LinuxCloudTrustedDeviceMutationAuthorization
    ) async throws -> LinuxTrustedDeviceMutation {
        try await mutateLinuxTrustedDevice(
            functionsBaseURL: functionsBaseURL,
            credentials: credentials,
            deviceID: deviceID,
            authorization: authorization,
            approve: true
        )
    }

    /// Revoke an approved or pending Linux App Check device. This is the same
    /// high-risk boundary as approval and therefore requires a fresh,
    /// nonce-bound companion proof on every request.
    func revokeLinuxTrustedDevice(
        functionsBaseURL: URL,
        credentials: LinuxCloudTrustedDeviceManagerCredentials,
        deviceID: String,
        authorization: LinuxCloudTrustedDeviceMutationAuthorization
    ) async throws -> LinuxTrustedDeviceMutation {
        try await mutateLinuxTrustedDevice(
            functionsBaseURL: functionsBaseURL,
            credentials: credentials,
            deviceID: deviceID,
            authorization: authorization,
            approve: false
        )
    }

    private func mutateLinuxTrustedDevice(
        functionsBaseURL: URL,
        credentials: LinuxCloudTrustedDeviceManagerCredentials,
        deviceID: String,
        authorization: LinuxCloudTrustedDeviceMutationAuthorization,
        approve: Bool
    ) async throws -> LinuxTrustedDeviceMutation {
        let stage = approve ? "approve_linux_device" : "revoke_linux_device"
        try validateTrustedDeviceCredentials(credentials, stage: stage)
        guard Self.isBoundedTrustedDeviceID(deviceID),
              Self.isValidMutationAuthorization(authorization, now: now()) else {
            throw LinuxCloudAuthHTTPError.invalidRequest
        }
        let response: TrustedDeviceMutationResponse = try await trustedDeviceCall(
            baseURL: functionsBaseURL,
            name: approve ? "approveLinuxAppCheckDevice" : "revokeLinuxAppCheckDevice",
            payload: TrustedDeviceMutationRequest(
                actionProof: authorization.actionProof,
                approverDeviceId: credentials.approverDeviceID,
                deviceId: deviceID,
                nonce: authorization.nonce
            ),
            credentials: credentials,
            stage: stage
        )
        let expectedState: BurnBarLinuxTrustedDeviceTrustState = approve ? .trusted : .revoked
        guard response.ok,
              response.deviceId == deviceID,
              response.trustState == (approve ? "approved" : "revoked") else {
            throw LinuxCloudAuthHTTPError.malformedResponse(stage: stage)
        }
        return try LinuxTrustedDeviceMutation(
            deviceID: response.deviceId,
            trustState: expectedState,
            alreadyInState: response.alreadyInState
        )
    }

    private func trustedDeviceCall<Payload: Encodable, Result: Decodable>(
        baseURL: URL,
        name: String,
        payload: Payload,
        credentials: LinuxCloudTrustedDeviceManagerCredentials,
        stage: String
    ) async throws -> Result {
        try await call(
            baseURL: baseURL,
            name: name,
            payload: payload,
            idToken: credentials.idToken,
            appCheckToken: credentials.appCheckToken,
            stage: stage
        )
    }

    private func validateTrustedDeviceCredentials(
        _ credentials: LinuxCloudTrustedDeviceManagerCredentials,
        stage: String
    ) throws {
        try validateFreshBearer(credentials.idToken, stage: stage)
        guard credentials.appCheckToken.boundedToken != nil,
              Self.isBoundedTrustedDeviceID(credentials.approverDeviceID) else {
            throw LinuxCloudAuthHTTPError.invalidRequest
        }
    }

    private static func isValidMutationAuthorization(
        _ authorization: LinuxCloudTrustedDeviceMutationAuthorization,
        now: Date
    ) -> Bool {
        guard isBoundedNonce(authorization.nonce),
              authorization.actionProof.version == 1,
              authorization.actionProof.algorithm == "signal-identity-xeddsa-v1",
              isBoundedTrustedDeviceID(authorization.actionProof.deviceSignalIdentityKeyId),
              isBoundedTrustedDeviceID(authorization.actionProof.deviceSignalIdentityPublicKeyFingerprint),
              authorization.actionProof.issuedAtMillis > 0,
              let signature = Data(base64Encoded: authorization.actionProof.signature),
              (64...256).contains(signature.count) else {
            return false
        }
        let issuedAt = Date(timeIntervalSince1970: Double(authorization.actionProof.issuedAtMillis) / 1_000)
        return abs(now.timeIntervalSince(issuedAt)) <= 5 * 60
    }

    private static func isBoundedNonce(_ value: String) -> Bool {
        value.utf8.count >= 16
            && value.utf8.count <= 256
            && value.trimmingCharacters(in: .whitespacesAndNewlines) == value
            && value.unicodeScalars.allSatisfy { CharacterSet.controlCharacters.contains($0) == false }
    }

    private static func isBoundedTrustedDeviceID(_ value: String) -> Bool {
        value.isBoundedIdentifier && value.utf8.count <= 160
    }

    /// Call the canonical cloud export callable using an already-authorized
    /// trusted-device proof. Linux never constructs or stores this proof; it is
    /// supplied by the trusted-device step-up lane and is forwarded unchanged.
    func exportUserData(
        functionsBaseURL: URL,
        idToken: String,
        appCheckToken: String,
        request: LinuxCloudDataExportRequest
    ) async throws -> Data {
        try validateFreshBearer(idToken, stage: "data_export")
        guard appCheckToken.boundedToken != nil else {
            throw LinuxCloudAuthHTTPError.invalidRequest
        }
        guard Self.validDataDomainSelection(request.domains) else {
            throw LinuxCloudAuthHTTPError.invalidRequest
        }
        let data = try await postJSONData(
            functionsBaseURL.appendingPathComponent("exportUserData", isDirectory: false),
            value: CallableRequest(data: request),
            headers: [
                "Authorization": "Bearer \(idToken)",
                "X-Firebase-AppCheck": appCheckToken
            ],
            stage: "data_export",
            maximumResponseBytes: Self.maximumDataControlResponseBytes
        )
        guard let payload = Self.callablePayload(from: data),
              Self.validDataExportEnvelope(payload) else {
            throw LinuxCloudAuthHTTPError.malformedResponse(stage: "data_export")
        }
        return payload
    }

    /// Request authoritative account erasure. The exact confirmation token is
    /// required locally before any irreversible callable is sent. The server
    /// still remains authoritative: it additionally requires a fresh nonce and
    /// trusted-device action proof, and may return a retry-required failure.
    func deleteUserCloudData(
        functionsBaseURL: URL,
        idToken: String,
        appCheckToken: String,
        request: LinuxCloudDataDeletionRequest
    ) async throws -> LinuxCloudDataDeletionResponse {
        try validateFreshBearer(idToken, stage: "account_delete")
        guard appCheckToken.boundedToken != nil,
              request.confirmation == LinuxCloudDataDeletionRequest.confirmationToken else {
            throw LinuxCloudAuthHTTPError.invalidRequest
        }
        let response: LinuxCloudDataDeletionResponse = try await call(
            baseURL: functionsBaseURL,
            name: "deleteUserCloudData",
            payload: request,
            idToken: idToken,
            appCheckToken: appCheckToken,
            stage: "account_delete"
        )
        guard response.success, response.cloudDataDeleted else {
            throw LinuxCloudAuthHTTPError.malformedResponse(stage: "account_delete")
        }
        return response
    }

    private func firebaseSession(
        uid: String?,
        idToken: String?,
        refreshToken: String?,
        expiresIn: String?,
        stage: String
    ) throws -> LinuxFirebaseSession {
        guard let uid, uid.isBoundedIdentifier,
              let idToken = idToken?.boundedToken,
              let refreshToken = refreshToken?.boundedToken,
              let expiresIn,
              let seconds = Int64(expiresIn),
              (60...86_400).contains(seconds) else {
            throw LinuxCloudAuthHTTPError.malformedResponse(stage: stage)
        }
        return LinuxFirebaseSession(
            uid: uid,
            idToken: idToken,
            refreshToken: refreshToken,
            expiresAt: now().addingTimeInterval(TimeInterval(seconds))
        )
    }

    private func call<Payload: Encodable, Result: Decodable>(
        baseURL: URL,
        name: String,
        payload: Payload,
        idToken: String,
        appCheckToken: String?,
        stage: String
    ) async throws -> Result {
        guard name.isBoundedIdentifier else { throw LinuxCloudAuthHTTPError.invalidRequest }
        let endpoint = baseURL.appendingPathComponent(name, isDirectory: false)
        var headers = ["Authorization": "Bearer \(idToken)"]
        if let appCheckToken { headers["X-Firebase-AppCheck"] = appCheckToken }
        let response: CallableResponse<Result> = try await postJSON(
            endpoint,
            value: CallableRequest(data: payload),
            headers: headers,
            stage: stage
        )
        return response.value
    }

    private func postJSON<Value: Encodable, Result: Decodable>(
        _ url: URL,
        value: Value,
        headers: [String: String] = [:],
        stage: String
    ) async throws -> Result {
        let data: Data
        do { data = try JSONEncoder().encode(value) } catch { throw LinuxCloudAuthHTTPError.invalidRequest }
        return try await post(
            url,
            body: data,
            contentType: "application/json",
            headers: headers,
            stage: stage
        )
    }

    private func postJSONData<Value: Encodable>(
        _ url: URL,
        value: Value,
        headers: [String: String] = [:],
        stage: String,
        maximumResponseBytes: Int = Self.maximumResponseBytes
    ) async throws -> Data {
        let data: Data
        do { data = try JSONEncoder().encode(value) } catch { throw LinuxCloudAuthHTTPError.invalidRequest }
        return try await postRaw(
            url,
            body: data,
            contentType: "application/json",
            headers: headers,
            stage: stage,
            maximumResponseBytes: maximumResponseBytes
        )
    }

    private func postForm<Result: Decodable>(
        _ url: URL,
        fields: [String: String],
        stage: String
    ) async throws -> Result {
        try await post(
            url,
            body: formBody(fields),
            contentType: "application/x-www-form-urlencoded",
            headers: [:],
            stage: stage
        )
    }

    private func post<Result: Decodable>(
        _ url: URL,
        body: Data,
        contentType: String,
        headers: [String: String],
        stage: String
    ) async throws -> Result {
        let data = try await postRaw(
            url,
            body: body,
            contentType: contentType,
            headers: headers,
            stage: stage
        )
        do {
            return try JSONDecoder().decode(Result.self, from: data)
        } catch {
            throw LinuxCloudAuthHTTPError.malformedResponse(stage: stage)
        }
    }

    private func postRaw(
        _ url: URL,
        body: Data,
        contentType: String,
        headers: [String: String],
        stage: String,
        maximumResponseBytes: Int = Self.maximumResponseBytes
    ) async throws -> Data {
        guard isAllowedEndpoint(url), body.count <= Self.maximumRequestBytes else {
            throw body.count > Self.maximumRequestBytes
                ? LinuxCloudAuthHTTPError.requestTooLarge
                : LinuxCloudAuthHTTPError.invalidConfiguration
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport(request, maximumResponseBytes)
        } catch let error as LinuxCloudAuthHTTPError {
            throw error
        } catch {
            throw LinuxCloudAuthHTTPError.transportFailure
        }
        guard data.count <= maximumResponseBytes else { throw LinuxCloudAuthHTTPError.responseTooLarge }
        guard (200..<300).contains(response.statusCode) else {
            let reason = try? JSONDecoder().decode(CallableErrorResponse.self, from: data)
                .error.details?.reason
            throw LinuxCloudAuthHTTPError.rejected(
                stage: stage,
                status: response.statusCode,
                reason: reason.flatMap { $0.isBoundedIdentifier ? $0 : nil }
            )
        }
        return data
    }

    private func validateFreshBearer(_ token: String, stage: String) throws {
        guard token.boundedToken != nil else { throw LinuxCloudAuthHTTPError.invalidRequest }
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        // Test transports use opaque fixture tokens. Production Firebase ID
        // tokens are JWTs, for which an expired `exp` is always rejected.
        guard segments.count == 3 else { return }
        var payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload.append(String(repeating: "=", count: (4 - payload.count % 4) % 4))
        guard let payloadData = Data(base64Encoded: payload), payloadData.count <= 16 * 1_024,
              let object = try? JSONSerialization.jsonObject(with: payloadData),
              let claims = object as? [String: Any],
              let expiry = claims["exp"] as? NSNumber,
              expiry.doubleValue > now().timeIntervalSince1970 else {
            throw LinuxCloudAuthHTTPError.rejected(stage: stage, status: 401, reason: "expired_token")
        }
    }

    private static func validDataExportEnvelope(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              dictionary["ok"] as? Bool == true,
              dictionary["schemaVersion"] as? Int == 2,
              let generatedAt = dictionary["generatedAt"] as? String,
              generatedAt.isEmpty == false,
              let domains = dictionary["domains"] as? [[String: Any]],
              domains.count <= 24 else { return false }
        return domains.allSatisfy { domain in
            guard let id = domain["id"] as? String, id.isEmpty == false,
                  let tier = domain["encryptionTier"] as? String,
                  ["server_readable", "zero_access", "end_to_end"].contains(tier) else { return false }
            if let redacted = domain["redactedFields"] as? [Any], redacted.count > 256 { return false }
            if let refs = domain["sealedRefs"] as? [[String: Any]], refs.count > 2_000 { return false }
            return true
        }
    }

    /// Mirror the server's bounded domain selector before sending a request.
    /// Unknown IDs remain a server concern because the canonical registry is
    /// owned by the functions package; this guard only prevents malformed or
    /// oversized input from crossing the Linux network boundary.
    private static func validDataDomainSelection(_ domains: [String]?) -> Bool {
        guard let domains else { return true }
        guard domains.count <= 24 else { return false }
        return domains.allSatisfy { domain in
            let trimmed = domain.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed == domain
                && trimmed.isEmpty == false
                && domain.utf8.count <= 64
                && domain.unicodeScalars.allSatisfy { CharacterSet.controlCharacters.contains($0) == false }
        }
    }

    private static func callablePayload(from data: Data) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return nil }
        for key in ["result", "data"] {
            guard let value = dictionary[key], JSONSerialization.isValidJSONObject(value) else { continue }
            return try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        }
        return nil
    }

    private func endpointWithAPIKey(_ endpoint: URL, apiKey: String) throws -> URL {
        guard apiKey.isEmpty == false, apiKey.utf8.count <= 512,
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw LinuxCloudAuthHTTPError.invalidConfiguration
        }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else { throw LinuxCloudAuthHTTPError.invalidConfiguration }
        return url
    }

    private func formBody(_ fields: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((components.percentEncodedQuery ?? "").utf8)
    }

    private func isAllowedEndpoint(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              allowedHosts.contains(host),
              components.user == nil,
              components.password == nil,
              components.fragment == nil else { return false }
        return components.port == nil || components.port == 443
    }

    static func productionTransport(_ request: URLRequest, maximumBytes: Int) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return try await LinuxCloudAuthBoundedDataDelegate(
            configuration: configuration,
            maximumBytes: maximumBytes
        ).perform(request)
    }
}

// AUDIT(@unchecked Sendable): URLSession retains this NSObject delegate; mutable
// response/continuation/session state is guarded by `lock`.
// sendable-allowlist: nslock-protected-storage
final class LinuxCloudAuthBoundedDataDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let configuration: URLSessionConfiguration
    private let maximumBytes: Int
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var response: HTTPURLResponse?
    private var data = Data()
    private var completed = false
    private var session: URLSession?

    init(configuration: URLSessionConfiguration, maximumBytes: Int) {
        self.configuration = configuration
        self.maximumBytes = maximumBytes
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let shouldStart = lock.withLock { () -> Bool in
                    guard completed == false else { return false }
                    self.continuation = continuation
                    self.session = session
                    return true
                }
                guard shouldStart else {
                    session.invalidateAndCancel()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                session.dataTask(with: request).resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            finish(.failure(LinuxCloudAuthHTTPError.transportFailure))
            completionHandler(.cancel)
            return
        }
        if let declared = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init),
           declared > maximumBytes {
            finish(.failure(LinuxCloudAuthHTTPError.responseTooLarge))
            completionHandler(.cancel)
            return
        }
        lock.withLock { self.response = http }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive incoming: Data) {
        let overflow = lock.withLock { () -> Bool in
            guard data.count <= maximumBytes - incoming.count else { return true }
            data.append(incoming)
            return false
        }
        if overflow {
            dataTask.cancel()
            finish(.failure(LinuxCloudAuthHTTPError.responseTooLarge))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
            return
        }
        let result: Result<(Data, HTTPURLResponse), Error> = lock.withLock {
            guard let response else { return .failure(LinuxCloudAuthHTTPError.transportFailure) }
            return .success((data, response))
        }
        finish(result)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    private func finish(_ result: Result<(Data, HTTPURLResponse), Error>) {
        let values: (CheckedContinuation<(Data, HTTPURLResponse), Error>?, URLSession?) = lock.withLock {
            guard completed == false else { return (nil, nil) }
            completed = true
            let continuation = self.continuation
            self.continuation = nil
            let session = self.session
            self.session = nil
            return (continuation, session)
        }
        values.1?.invalidateAndCancel()
        values.0?.resume(with: result)
    }

    private func cancel() {
        finish(.failure(CancellationError()))
    }
}

/// Trusted-device step-up material returned by the approval lane. Linux treats
/// this as opaque signed data and never generates a local substitute.
public struct LinuxCloudTrustedDeviceActionProof: Codable, Equatable, Sendable {
    public let version: Int
    public let algorithm: String
    public let deviceSignalIdentityKeyId: String
    public let deviceSignalIdentityPublicKeyFingerprint: String
    public let issuedAtMillis: Int64
    public let signature: String

    public init(
        version: Int = 1,
        algorithm: String = "signal-identity-xeddsa-v1",
        deviceSignalIdentityKeyId: String,
        deviceSignalIdentityPublicKeyFingerprint: String,
        issuedAtMillis: Int64,
        signature: String
    ) {
        self.version = version
        self.algorithm = algorithm
        self.deviceSignalIdentityKeyId = deviceSignalIdentityKeyId
        self.deviceSignalIdentityPublicKeyFingerprint = deviceSignalIdentityPublicKeyFingerprint
        self.issuedAtMillis = issuedAtMillis
        self.signature = signature
    }
}

public struct LinuxCloudDataExportRequest: Codable, Equatable, Sendable {
    public let domains: [String]?
    public let nonce: String
    public let trustedDeviceId: String
    public let actionProof: LinuxCloudTrustedDeviceActionProof

    public init(
        domains: [String]? = nil,
        nonce: String,
        trustedDeviceId: String,
        actionProof: LinuxCloudTrustedDeviceActionProof
    ) {
        self.domains = domains
        self.nonce = nonce
        self.trustedDeviceId = trustedDeviceId
        self.actionProof = actionProof
    }
}

public struct LinuxCloudDataDeletionRequest: Codable, Equatable, Sendable {
    public static let confirmationToken = "DELETE MY ACCOUNT"

    public let confirmation: String
    public let nonce: String
    public let trustedDeviceId: String
    public let actionProof: LinuxCloudTrustedDeviceActionProof

    public init(
        confirmation: String,
        nonce: String,
        trustedDeviceId: String,
        actionProof: LinuxCloudTrustedDeviceActionProof
    ) {
        self.confirmation = confirmation
        self.nonce = nonce
        self.trustedDeviceId = trustedDeviceId
        self.actionProof = actionProof
    }
}

public struct LinuxCloudDataDeletionResponse: Codable, Equatable, Sendable {
    public let success: Bool
    public let cloudDataDeleted: Bool
    public let retryRequired: Bool
    public let deletedDocuments: Int
    public let destroyedSecrets: Int
    public let failedSecretDestroys: Int
    public let deletedStoragePrefixes: Int
    public let failedStorageDeletes: Int
    public let deletedAuthUser: Bool
    public let authUserAlreadyMissing: Bool

    public init(
        success: Bool,
        cloudDataDeleted: Bool,
        retryRequired: Bool,
        deletedDocuments: Int = 0,
        destroyedSecrets: Int = 0,
        failedSecretDestroys: Int = 0,
        deletedStoragePrefixes: Int = 0,
        failedStorageDeletes: Int = 0,
        deletedAuthUser: Bool = false,
        authUserAlreadyMissing: Bool = false
    ) {
        self.success = success
        self.cloudDataDeleted = cloudDataDeleted
        self.retryRequired = retryRequired
        self.deletedDocuments = deletedDocuments
        self.destroyedSecrets = destroyedSecrets
        self.failedSecretDestroys = failedSecretDestroys
        self.deletedStoragePrefixes = deletedStoragePrefixes
        self.failedStorageDeletes = failedStorageDeletes
        self.deletedAuthUser = deletedAuthUser
        self.authUserAlreadyMissing = authUserAlreadyMissing
    }
}

/// Credentials owned by the trusted native companion that manages Linux
/// App Check devices. A lower-trust Linux session must never substitute its
/// own App Check token for this manager credential.
public struct LinuxCloudTrustedDeviceManagerCredentials: Sendable, Equatable {
    public let idToken: String
    public let appCheckToken: String
    public let approverDeviceID: String

    public init(
        idToken: String,
        appCheckToken: String,
        approverDeviceID: String
    ) throws {
        guard approverDeviceID.isBoundedIdentifier,
              approverDeviceID.utf8.count <= 160 else {
            throw LinuxTrustedDeviceManagementError.invalidDeviceID
        }
        guard idToken.boundedToken != nil, appCheckToken.boundedToken != nil else {
            throw LinuxTrustedDeviceManagementError.rejected
        }
        self.idToken = idToken
        self.appCheckToken = appCheckToken
        self.approverDeviceID = approverDeviceID
    }
}

/// Fresh action material minted by the trusted companion. The adapter treats
/// this as opaque data and forwards it only to the matching callable.
public struct LinuxCloudTrustedDeviceMutationAuthorization: Sendable, Equatable {
    public let nonce: String
    public let actionProof: LinuxCloudTrustedDeviceActionProof

    public init(
        nonce: String,
        actionProof: LinuxCloudTrustedDeviceActionProof
    ) throws {
        guard nonce.utf8.count >= 16,
              nonce.utf8.count <= 256,
              nonce.trimmingCharacters(in: .whitespacesAndNewlines) == nonce,
              nonce.unicodeScalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) == false }) else {
            throw LinuxTrustedDeviceManagementError.rejected
        }
        self.nonce = nonce
        self.actionProof = actionProof
    }
}

public typealias LinuxCloudTrustedDeviceCredentialsProvider =
    @Sendable () async throws -> LinuxCloudTrustedDeviceManagerCredentials

public typealias LinuxCloudTrustedDeviceAuthProvider =
    @Sendable (_ actionKind: String, _ subjectDeviceID: String) async throws
    -> LinuxCloudTrustedDeviceMutationAuthorization

/// Production composition for the daemon trusted-device surface. The
/// providers are intentionally injected: a future Iroh/mobile bridge owns the
/// companion credentials and proof minting, while this adapter owns endpoint
/// allowlisting, bounded transport, callable envelopes, and response mapping.
public struct LinuxCloudTrustedDeviceHTTPAdapter: LinuxTrustedDeviceManaging, Sendable {
    private let functionsBaseURL: URL
    private let credentials: LinuxCloudTrustedDeviceCredentialsProvider
    private let authorizeMutation: LinuxCloudTrustedDeviceAuthProvider
    private let client: LinuxCloudAuthHTTPClient

    public init(
        functionsBaseURL: URL,
        credentials: @escaping LinuxCloudTrustedDeviceCredentialsProvider,
        authorizeMutation: @escaping LinuxCloudTrustedDeviceAuthProvider
    ) {
        self.init(
            functionsBaseURL: functionsBaseURL,
            credentials: credentials,
            authorizeMutation: authorizeMutation,
            client: LinuxCloudAuthHTTPClient(
                allowedHosts: Set([functionsBaseURL.host].compactMap { $0 })
            )
        )
    }

    init(
        functionsBaseURL: URL,
        credentials: @escaping LinuxCloudTrustedDeviceCredentialsProvider,
        authorizeMutation: @escaping LinuxCloudTrustedDeviceAuthProvider,
        allowedHosts: Set<String>,
        transport: @escaping LinuxCloudAuthHTTPTransport,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.init(
            functionsBaseURL: functionsBaseURL,
            credentials: credentials,
            authorizeMutation: authorizeMutation,
            client: LinuxCloudAuthHTTPClient(
                allowedHosts: allowedHosts,
                transport: transport,
                now: now
            )
        )
    }

    private init(
        functionsBaseURL: URL,
        credentials: @escaping LinuxCloudTrustedDeviceCredentialsProvider,
        authorizeMutation: @escaping LinuxCloudTrustedDeviceAuthProvider,
        client: LinuxCloudAuthHTTPClient
    ) {
        self.functionsBaseURL = functionsBaseURL
        self.credentials = credentials
        self.authorizeMutation = authorizeMutation
        self.client = client
    }

    public func listTrustedDevices() async throws -> [BurnBarLinuxTrustedDevice] {
        do {
            let devices = try await client.listLinuxTrustedDevices(
                functionsBaseURL: functionsBaseURL,
                credentials: credentials()
            )
            var seen = Set<String>()
            guard devices.allSatisfy({ seen.insert($0.deviceID).inserted }) else {
                throw LinuxTrustedDeviceManagementError.malformedResponse
            }
            return devices
        } catch {
            throw Self.map(error)
        }
    }

    public func approveTrustedDevice(deviceID: String) async throws -> LinuxTrustedDeviceMutation {
        try await mutate(deviceID: deviceID, approve: true)
    }

    public func revokeTrustedDevice(deviceID: String) async throws -> LinuxTrustedDeviceMutation {
        try await mutate(deviceID: deviceID, approve: false)
    }

    private func mutate(deviceID: String, approve: Bool) async throws -> LinuxTrustedDeviceMutation {
        do {
            guard Self.isBoundedDeviceID(deviceID) else {
                throw LinuxTrustedDeviceManagementError.invalidDeviceID
            }
            let managerCredentials = try await credentials()
            let actionKind = approve
                ? "linux_app_check_device_approve"
                : "linux_app_check_device_revoke"
            let authorization = try await authorizeMutation(actionKind, deviceID)
            if approve {
                return try await client.approveLinuxTrustedDevice(
                    functionsBaseURL: functionsBaseURL,
                    credentials: managerCredentials,
                    deviceID: deviceID,
                    authorization: authorization
                )
            }
            return try await client.revokeLinuxTrustedDevice(
                functionsBaseURL: functionsBaseURL,
                credentials: managerCredentials,
                deviceID: deviceID,
                authorization: authorization
            )
        } catch {
            throw Self.map(error)
        }
    }

    private static func map(_ error: Error) -> LinuxTrustedDeviceManagementError {
        if let error = error as? LinuxTrustedDeviceManagementError { return error }
        guard let error = error as? LinuxCloudAuthHTTPError else {
            return error is CancellationError ? .transportFailure : .transportFailure
        }
        switch error {
        case .invalidConfiguration:
            return .unavailable
        case .invalidRequest:
            return .rejected
        case .requestTooLarge, .responseTooLarge, .malformedResponse:
            return .malformedResponse
        case .transportFailure:
            return .transportFailure
        case let .rejected(_, status, _):
            return [401, 403].contains(status) ? .unauthorized : .rejected
        }
    }

    private static func isBoundedDeviceID(_ value: String) -> Bool {
        value.isEmpty == false
            && value.utf8.count <= 160
            && value.contains("\n") == false
            && value.contains("\r") == false
            && value.allSatisfy { $0.isLetter || $0.isNumber || "._:+-/=".contains($0) }
    }
}

private struct GoogleTokenResponse: Decodable { let idToken: String?; enum CodingKeys: String, CodingKey { case idToken = "id_token" } }
private struct FirebaseSignInRequest: Encodable { let requestUri: String; let postBody: String; let returnIdpCredential: Bool; let returnSecureToken: Bool }
private struct FirebaseSignInResponse: Decodable { let localId: String?; let idToken: String?; let refreshToken: String?; let expiresIn: String? }
private struct FirebaseRefreshResponse: Decodable {
    let userId: String?; let idToken: String?; let refreshToken: String?; let expiresIn: String?
    enum CodingKeys: String, CodingKey { case userId = "user_id"; case idToken = "id_token"; case refreshToken = "refresh_token"; case expiresIn = "expires_in" }
}
private struct CallableRequest<Payload: Encodable>: Encodable { let data: Payload }
private struct CallableResponse<Result: Decodable>: Decodable {
    let value: Result
    enum CodingKeys: String, CodingKey { case result, data }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try container.decodeIfPresent(Result.self, forKey: .result)
            ?? container.decode(Result.self, forKey: .data)
    }
}
private struct CallableErrorResponse: Decodable {
    struct Payload: Decodable {
        struct Details: Decodable { let reason: String? }
        let details: Details?
    }
    let error: Payload
}
private struct EmptyRequest: Encodable {}
private struct MutationResponse: Decodable { let ok: Bool }
private struct RegisterDeviceRequest: Encodable { let deviceId: String; let deviceName: String; let appId: String; let publicKeyBase64: String; let issuedAtMillis: Int64; let signatureBase64: String }
private struct ChallengeRequest: Encodable { let deviceId: String; let appId: String }
private struct ChallengeResponse: Decodable { let ok: Bool; let challengeId: String; let canonicalPayloadBase64: String; let signatureAlgorithm: String; let issuedAtMillis: Int64; let expiresAtMillis: Int64 }
private struct MintRequest: Encodable {
    struct Attestation: Encodable { let kind: String; let deviceId: String; let appId: String; let challengeId: String; let signatureBase64: String }
    let attestation: Attestation
}
private struct MintResponse: Decodable { let ok: Bool; let appCheckToken: String; let ttlMillis: Int64; let appId: String; let trustClass: String }

private struct TrustedDeviceListRequest: Encodable { let approverDeviceId: String }
private struct TrustedDeviceListResponse: Decodable {
    let ok: Bool
    let devices: [TrustedDeviceRecord]
}
private struct TrustedDeviceMutationRequest: Encodable {
    let actionProof: LinuxCloudTrustedDeviceActionProof
    let approverDeviceId: String
    let deviceId: String
    let nonce: String
}
private struct TrustedDeviceMutationResponse: Decodable {
    let ok: Bool
    let deviceId: String
    let trustState: String
    let alreadyInState: Bool
}
private struct TrustedDeviceRecord: Decodable {
    let deviceId: String
    let deviceName: String
    let platform: String
    let publicKeyBase64: String
    let safetyFingerprint: String
    let trustState: String
    let createdAtMillis: Int64
    let approvedAtMillis: Int64?
    let revokedAtMillis: Int64?
    let approvedByDeviceId: String?
    let revokedByDeviceId: String?

    func redacted() throws -> BurnBarLinuxTrustedDevice {
        guard deviceId.isBoundedIdentifier,
              deviceId.utf8.count <= 160,
              deviceName.isEmpty == false,
              deviceName.utf8.count <= 256,
              deviceName.contains("\n") == false,
              deviceName.contains("\r") == false,
              platform == "Linux",
              let publicKey = Data(base64Encoded: publicKeyBase64),
              publicKey.count == 32,
              publicKey.base64EncodedString() == publicKeyBase64,
              safetyFingerprint.isEmpty == false,
              safetyFingerprint.utf8.count <= 256,
              safetyFingerprint.contains("\n") == false,
              safetyFingerprint.contains("\r") == false,
              createdAtMillis > 0,
              ["pending", "approved", "revoked"].contains(trustState),
              approvedAtMillis.map({ $0 > 0 }) ?? true,
              revokedAtMillis.map({ $0 > 0 }) ?? true,
              approvedByDeviceId.map({ $0.isBoundedIdentifier && $0.utf8.count <= 160 }) ?? true,
              revokedByDeviceId.map({ $0.isBoundedIdentifier && $0.utf8.count <= 160 }) ?? true else {
            throw LinuxCloudAuthHTTPError.malformedResponse(stage: "list_linux_devices")
        }
        guard let mappedTrustState = BurnBarLinuxTrustedDeviceTrustState(
            rawValue: trustState == "approved" ? "trusted" : trustState
        ) else {
            throw LinuxCloudAuthHTTPError.malformedResponse(stage: "list_linux_devices")
        }
        return BurnBarLinuxTrustedDevice(
            deviceID: deviceId,
            displayName: deviceName,
            platform: platform,
            trustState: mappedTrustState,
            isCurrentDevice: false,
            safetyFingerprint: safetyFingerprint
        )
    }
}

private extension String {
    var boundedToken: String? { isEmpty == false && utf8.count <= 16_384 && contains("\n") == false && contains("\r") == false ? self : nil }
    var isBoundedIdentifier: Bool { isEmpty == false && utf8.count <= 256 && allSatisfy { $0.isLetter || $0.isNumber || "._:+-/=".contains($0) } }
}
#endif
