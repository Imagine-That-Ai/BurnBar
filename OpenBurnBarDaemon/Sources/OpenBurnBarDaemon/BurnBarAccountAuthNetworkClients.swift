import OpenBurnBarLinuxSecurity
#if canImport(FoundationNetworking)
@preconcurrency import FoundationNetworking
#endif
import Foundation

final class BurnBarNoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static func redirectedRequest(
        for _: HTTPURLResponse,
        proposedRequest _: URLRequest
    ) -> URLRequest? {
        nil
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        _ = session
        _ = task
        completionHandler(Self.redirectedRequest(for: response, proposedRequest: request))
    }
}

enum BurnBarSensitiveHTTPSession {
    static func wrapping(_ session: URLSession) -> URLSession {
        URLSession(
            configuration: session.configuration,
            delegate: BurnBarNoRedirectSessionDelegate(),
            delegateQueue: nil
        )
    }

    static func responseMatchesExactEndpoint(_ response: URLResponse, endpoint: URL) -> Bool {
        response.url?.absoluteString == endpoint.absoluteString
    }
}

struct EnvironmentBurnBarDeviceAuthCloudClient: BurnBarDeviceAuthCloudClient {
    static let productionStartURL = URL(
        string: "https://us-central1-burnbar.cloudfunctions.net/startCliLink"
    )!
    static let productionPollURL = URL(
        string: "https://us-central1-burnbar.cloudfunctions.net/pollCliLink"
    )!

    private let startURL: URL
    private let pollURL: URL
    private let session: URLSession

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession = .shared
    ) {
        startURL = Self.httpsURL(
            environment["OPENBURNBAR_DEVICE_AUTH_START_ENDPOINT"]
        ) ?? Self.productionStartURL
        pollURL = Self.httpsURL(
            environment["OPENBURNBAR_DEVICE_AUTH_POLL_ENDPOINT"]
        ) ?? Self.productionPollURL
        self.session = BurnBarSensitiveHTTPSession.wrapping(session)
    }

    func start(_ request: BurnBarDeviceAuthStartRequest) async throws -> BurnBarDeviceAuthStartResponse {
        let wire: StartWireResponse = try await postJSON(
            endpoint: startURL,
            payload: request,
            as: StartWireResponse.self
        )
        guard let deviceCode = wire.deviceCode.normalized(maxLength: 256),
              let userCode = wire.userCode.normalized(maxLength: 64),
              let rawURL = (wire.verificationUriComplete ?? wire.verificationURL)?.normalized(maxLength: 2_048),
              let verificationURL = URL(string: rawURL),
              Self.isValidVerificationURL(verificationURL, expectedUserCode: userCode),
              (1...60).contains(wire.interval),
              (60...3_600).contains(wire.expiresIn) else {
            throw BurnBarAccountAuthError.invalidResponse
        }
        return BurnBarDeviceAuthStartResponse(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURL: verificationURL,
            pollIntervalSeconds: wire.interval,
            expiresInSeconds: wire.expiresIn
        )
    }

    func poll(deviceCode: String, deviceSecret: String) async throws -> BurnBarDeviceAuthPollResponse {
        let wire: PollWireResponse = try await postJSON(
            endpoint: pollURL,
            payload: PollWireRequest(deviceCode: deviceCode, deviceSecret: deviceSecret),
            as: PollWireResponse.self
        )
        guard let status = BurnBarDeviceAuthPollStatus(rawValue: wire.status) else {
            throw BurnBarAccountAuthError.invalidResponse
        }
        if status == .approved, wire.credentialEnvelope == nil {
            throw BurnBarAccountAuthError.invalidResponse
        }
        return BurnBarDeviceAuthPollResponse(
            status: status,
            credentialEnvelope: wire.credentialEnvelope
        )
    }

    func cancel(deviceCode: String, deviceSecret: String) async throws {
        let response: CancelWireResponse = try await postJSON(
            endpoint: pollURL,
            payload: CancelWireRequest(
                deviceCode: deviceCode,
                deviceSecret: deviceSecret,
                action: "cancel"
            ),
            as: CancelWireResponse.self
        )
        guard response.status == "cancelled" || response.status == "expired" else {
            throw BurnBarAccountAuthError.invalidResponse
        }
    }

    private func postJSON<Payload: Encodable, Response: Decodable>(
        endpoint: URL,
        payload: Payload,
        as responseType: Response.Type
    ) async throws -> Response {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = try JSONEncoder().encode(payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BurnBarAccountAuthError.networkUnavailable
        }
        guard data.count <= 64 * 1_024,
              let http = response as? HTTPURLResponse,
              BurnBarSensitiveHTTPSession.responseMatchesExactEndpoint(http, endpoint: endpoint) else {
            throw BurnBarAccountAuthError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw BurnBarAccountAuthError.networkUnavailable
        }
        do {
            return try JSONDecoder().decode(responseType, from: data)
        } catch {
            throw BurnBarAccountAuthError.invalidResponse
        }
    }

    static func isValidVerificationURL(_ url: URL, expectedUserCode: String? = nil) -> Bool {
        guard url.scheme == "https",
              url.host?.lowercased() == "burnbar.ai",
              url.port == nil,
              url.user == nil,
              url.password == nil,
              url.path == "/link",
              url.fragment == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        let items = components.queryItems ?? []
        guard items.count == 2,
              Set(items.map(\.name)) == Set(["code", "flow"]) else {
            return false
        }
        let flowItems = items.filter { $0.name == "flow" }
        let codeItems = items.filter { $0.name == "code" }
        guard flowItems.count == 1,
              flowItems[0].value == "desktop_auth",
              codeItems.count == 1,
              let code = codeItems[0].value?.normalized(maxLength: 64) else {
            return false
        }
        return expectedUserCode == nil || code == expectedUserCode
    }

    private static func httpsURL(_ raw: String?) -> URL? {
        guard let raw = raw?.normalized(maxLength: 2_048),
              let url = URL(string: raw),
              url.scheme == "https",
              url.host?.isEmpty == false else { return nil }
        return url
    }
}

struct EnvironmentBurnBarFirebaseIdentityClient: BurnBarFirebaseIdentityClient {
    private let identityBaseURL: URL
    private let secureTokenBaseURL: URL
    private let session: URLSession
    private let now: @Sendable () -> Date

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        identityBaseURL = Self.httpsBaseURL(
            environment["OPENBURNBAR_FIREBASE_IDENTITY_BASE_URL"]
        ) ?? URL(string: "https://identitytoolkit.googleapis.com/v1")!
        secureTokenBaseURL = Self.httpsBaseURL(
            environment["OPENBURNBAR_FIREBASE_SECURE_TOKEN_BASE_URL"]
        ) ?? URL(string: "https://securetoken.googleapis.com/v1")!
        self.session = BurnBarSensitiveHTTPSession.wrapping(session)
        self.now = now
    }

    func signIn(customToken: String, apiKey: String) async throws -> BurnBarFirebaseTokenSet {
        let endpoint = try keyedEndpoint(
            baseURL: identityBaseURL,
            path: "accounts:signInWithCustomToken",
            apiKey: apiKey
        )
        let wire: SignInWireResponse = try await postJSON(
            endpoint: endpoint,
            payload: SignInWireRequest(token: customToken, returnSecureToken: true),
            reauthenticationOnClientError: true,
            as: SignInWireResponse.self
        )
        return try tokenSet(
            idToken: wire.idToken,
            refreshToken: wire.refreshToken,
            expiresIn: wire.expiresIn,
            localID: wire.localId,
            email: wire.email,
            displayName: wire.displayName,
            photoURL: wire.photoUrl
        )
    }

    func refresh(refreshToken: String, apiKey: String) async throws -> BurnBarFirebaseTokenSet {
        let endpoint = try keyedEndpoint(
            baseURL: secureTokenBaseURL,
            path: "token",
            apiKey: apiKey
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = formEncoded([
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken)
        ])
        let wire: RefreshWireResponse = try await send(
            request,
            reauthenticationOnClientError: true,
            as: RefreshWireResponse.self
        )
        return try tokenSet(
            idToken: wire.idToken,
            refreshToken: wire.refreshToken,
            expiresIn: wire.expiresIn,
            localID: wire.userId,
            email: nil,
            displayName: nil,
            photoURL: nil
        )
    }

    func profile(idToken: String, apiKey: String) async throws -> BurnBarFirebaseProfile {
        let endpoint = try keyedEndpoint(
            baseURL: identityBaseURL,
            path: "accounts:lookup",
            apiKey: apiKey
        )
        let wire: LookupWireResponse = try await postJSON(
            endpoint: endpoint,
            payload: LookupWireRequest(idToken: idToken),
            reauthenticationOnClientError: true,
            as: LookupWireResponse.self
        )
        guard let user = wire.users?.first,
              let uid = user.localId.normalized(maxLength: 256) else {
            throw BurnBarAccountAuthError.invalidResponse
        }
        return BurnBarFirebaseProfile(
            uid: uid,
            email: user.email?.normalized(maxLength: 512),
            displayName: user.displayName?.normalized(maxLength: 512),
            photoURL: Self.safePhotoURL(user.photoUrl)
        )
    }

    private func tokenSet(
        idToken: String?,
        refreshToken: String?,
        expiresIn: String?,
        localID: String?,
        email: String?,
        displayName: String?,
        photoURL: String?
    ) throws -> BurnBarFirebaseTokenSet {
        guard let idToken = idToken?.normalized(maxLength: 16_384),
              let refreshToken = refreshToken?.normalized(maxLength: 16_384),
              let rawLifetime = expiresIn.flatMap(Int.init),
              (60...86_400).contains(rawLifetime) else {
            throw BurnBarAccountAuthError.invalidResponse
        }
        return BurnBarFirebaseTokenSet(
            idToken: idToken,
            refreshToken: refreshToken,
            expiresAt: now().addingTimeInterval(TimeInterval(rawLifetime)),
            localID: localID?.normalized(maxLength: 256),
            email: email?.normalized(maxLength: 512),
            displayName: displayName?.normalized(maxLength: 512),
            photoURL: Self.safePhotoURL(photoURL)
        )
    }

    private func keyedEndpoint(baseURL: URL, path: String, apiKey: String) throws -> URL {
        guard let apiKey = apiKey.normalized(maxLength: 512) else {
            throw BurnBarAccountAuthError.reauthenticationRequired
        }
        let endpoint = baseURL.appendingPathComponent(path)
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw BurnBarAccountAuthError.invalidResponse
        }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else { throw BurnBarAccountAuthError.invalidResponse }
        return url
    }

    private func postJSON<Payload: Encodable, Response: Decodable>(
        endpoint: URL,
        payload: Payload,
        reauthenticationOnClientError: Bool,
        as responseType: Response.Type
    ) async throws -> Response {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = try JSONEncoder().encode(payload)
        return try await send(
            request,
            reauthenticationOnClientError: reauthenticationOnClientError,
            as: responseType
        )
    }

    private func send<Response: Decodable>(
        _ request: URLRequest,
        reauthenticationOnClientError: Bool,
        as responseType: Response.Type
    ) async throws -> Response {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BurnBarAccountAuthError.networkUnavailable
        }
        guard data.count <= 64 * 1_024,
              let http = response as? HTTPURLResponse,
              BurnBarSensitiveHTTPSession.responseMatchesExactEndpoint(http, endpoint: request.url!) else {
            throw BurnBarAccountAuthError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if reauthenticationOnClientError, http.statusCode == 400 || http.statusCode == 401 {
                throw BurnBarAccountAuthError.reauthenticationRequired
            }
            throw BurnBarAccountAuthError.networkUnavailable
        }
        do {
            return try JSONDecoder().decode(responseType, from: data)
        } catch {
            throw BurnBarAccountAuthError.invalidResponse
        }
    }

    private func formEncoded(_ fields: [(String, String)]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let parts: [String] = fields.map { name, value in
            let encodedName = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(encodedName)=\(encodedValue)"
        }
        let body: String = parts.joined(separator: "&")
        return Data(body.utf8)
    }

    private static func httpsBaseURL(_ raw: String?) -> URL? {
        guard let raw = raw?.normalized(maxLength: 2_048),
              let url = URL(string: raw),
              url.scheme == "https",
              url.host?.isEmpty == false else { return nil }
        return url
    }

    private static func safePhotoURL(_ raw: String?) -> String? {
        guard let raw = raw?.normalized(maxLength: 2_048),
              let url = URL(string: raw),
              url.scheme == "https",
              url.host?.isEmpty == false else { return nil }
        return url.absoluteString
    }
}

private struct PollWireRequest: Encodable, Sendable {
    let deviceCode: String
    let deviceSecret: String
}

private struct CancelWireRequest: Encodable, Sendable {
    let deviceCode: String
    let deviceSecret: String
    let action: String
}

private struct CancelWireResponse: Decodable, Sendable {
    let status: String
}

private struct StartWireResponse: Decodable, Sendable {
    let deviceCode: String
    let userCode: String
    let verificationUriComplete: String?
    let verificationURL: String?
    let interval: Int
    let expiresIn: Int
}

private struct PollWireResponse: Decodable, Sendable {
    let status: String
    let credentialEnvelope: LinuxDesktopAuthCredentialEnvelope?
}

private struct SignInWireRequest: Encodable, Sendable {
    let token: String
    let returnSecureToken: Bool
}

private struct SignInWireResponse: Decodable, Sendable {
    let idToken: String?
    let refreshToken: String?
    let expiresIn: String?
    let localId: String?
    let email: String?
    let displayName: String?
    let photoUrl: String?
}

private struct RefreshWireResponse: Decodable, Sendable {
    let idToken: String?
    let refreshToken: String?
    let expiresIn: String?
    let userId: String?

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case userId = "user_id"
    }
}

private struct LookupWireRequest: Encodable, Sendable {
    let idToken: String
}

private struct LookupWireResponse: Decodable, Sendable {
    struct User: Decodable, Sendable {
        let localId: String
        let email: String?
        let displayName: String?
        let photoUrl: String?
    }

    let users: [User]?
}

private extension String {
    func normalized(maxLength: Int) -> String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty == false, value.utf8.count <= maxLength else { return nil }
        return value
    }
}
