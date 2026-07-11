#if canImport(FoundationNetworking)
@preconcurrency import FoundationNetworking
#endif
import Foundation

typealias BurnBarLinuxAppCheckTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

struct BurnBarLinuxAppCheckBoundedResponseBuffer {
    let maximumBytes: Int
    private(set) var data = Data()

    mutating func append(_ chunk: Data) -> Bool {
        guard chunk.count <= maximumBytes, data.count <= maximumBytes - chunk.count else { return false }
        data.append(chunk)
        return true
    }
}

private final class BurnBarLinuxAppCheckBoundedDataDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maximumBytes: Int
    private let taskLock = NSLock()
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var session: URLSession?
    private var activeTask: URLSessionDataTask?
    private var cancellationRequested = false
    private var response: URLResponse?
    private var body: BurnBarLinuxAppCheckBoundedResponseBuffer
    private var terminalError: Error?

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
        body = BurnBarLinuxAppCheckBoundedResponseBuffer(maximumBytes: maximumBytes)
    }

    func perform(request: URLRequest, configuration: URLSessionConfiguration) async throws -> (Data, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.dataTask(with: request)
                let shouldCancel = taskLock.withLock {
                    activeTask = task
                    return cancellationRequested
                }
                task.resume()
                if shouldCancel { task.cancel() }
            }
        } onCancel: {
            let task = self.taskLock.withLock {
                self.cancellationRequested = true
                return self.activeTask
            }
            task?.cancel()
        }
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
        _ = response
        _ = request
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        _ = session
        _ = dataTask
        self.response = response
        let declaredLength = response.expectedContentLength
        if declaredLength > Int64(maximumBytes) {
            terminalError = BurnBarLinuxAppCheckError.invalidResponse
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        _ = session
        guard terminalError == nil else { return }
        guard body.append(data) else {
            terminalError = BurnBarLinuxAppCheckError.invalidResponse
            dataTask.cancel()
            return
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        _ = task
        let wasCancelled = taskLock.withLock {
            activeTask = nil
            return cancellationRequested
        }
        defer {
            continuation = nil
            self.session = nil
            session.finishTasksAndInvalidate()
        }
        if wasCancelled {
            continuation?.resume(throwing: CancellationError())
        } else if let terminalError {
            continuation?.resume(throwing: terminalError)
        } else if let error {
            continuation?.resume(throwing: error)
        } else if let response {
            continuation?.resume(returning: (body.data, response))
        } else {
            continuation?.resume(throwing: BurnBarLinuxAppCheckError.invalidResponse)
        }
    }
}

struct EnvironmentBurnBarLinuxAppCheckCloudClient: BurnBarLinuxAppCheckCloudClient {
    static let productionChallengeEndpoint = URL(
        string: "https://us-central1-burnbar.cloudfunctions.net/issueLinuxAppCheckChallenge"
    )!
    static let productionMintEndpoint = URL(
        string: "https://us-central1-burnbar.cloudfunctions.net/mintLinuxAppCheckToken"
    )!
    static let maximumRequestBytes = 640 * 1_024
    static let maximumResponseBytes = 256 * 1_024

    private struct CallableRequest<Payload: Encodable>: Encodable {
        let data: Payload
    }

    private struct ChallengeResponse: Decodable {
        let result: BurnBarLinuxAppCheckChallenge
    }

    private struct MintRequest: Encodable {
        let attestation: BurnBarLinuxAppCheckAttestation
    }

    private struct MintResponse: Decodable {
            struct Result: Decodable {
                let ok: Bool
                let appCheckToken: String
                let issuedAtMillis: Int64
                let expireTimeMillis: Int64
            let appId: String
            let trustClass: String
        }

        let result: Result
    }

    private let challengeEndpoint: URL
    private let mintEndpoint: URL
    private let transport: BurnBarLinuxAppCheckTransport

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession = .shared
    ) {
        challengeEndpoint = Self.validEndpoint(environment["OPENBURNBAR_LINUX_APP_CHECK_CHALLENGE_ENDPOINT"])
            ?? Self.productionChallengeEndpoint
        mintEndpoint = Self.validEndpoint(environment["OPENBURNBAR_LINUX_APP_CHECK_MINT_ENDPOINT"])
            ?? Self.productionMintEndpoint
        let configuration = Self.hardenedConfiguration(from: session.configuration)
        transport = { request in
            let delegate = BurnBarLinuxAppCheckBoundedDataDelegate(maximumBytes: Self.maximumResponseBytes)
            return try await delegate.perform(request: request, configuration: configuration)
        }
    }

    init(
        challengeEndpoint: URL,
        mintEndpoint: URL,
        transport: @escaping BurnBarLinuxAppCheckTransport
    ) {
        self.challengeEndpoint = challengeEndpoint
        self.mintEndpoint = mintEndpoint
        self.transport = transport
    }

    func issueChallenge(
        binding: BurnBarLinuxAppCheckAttestationBinding,
        idToken: String
    ) async throws -> BurnBarLinuxAppCheckChallenge {
        let response: ChallengeResponse = try await post(
            endpoint: challengeEndpoint,
            payload: binding,
            idToken: idToken,
            responseType: ChallengeResponse.self
        )
        return response.result
    }

    func mintToken(
        attestation: BurnBarLinuxAppCheckAttestation,
        idToken: String
    ) async throws -> BurnBarLinuxAppCheckMintResponse {
        let response: MintResponse = try await post(
            endpoint: mintEndpoint,
            payload: MintRequest(attestation: attestation),
            idToken: idToken,
            responseType: MintResponse.self
        )
        guard response.result.ok else { throw BurnBarLinuxAppCheckError.invalidResponse }
        return .init(
            appCheckToken: response.result.appCheckToken,
            issuedAtMillis: response.result.issuedAtMillis,
            expireTimeMillis: response.result.expireTimeMillis,
            appID: response.result.appId,
            trustClass: response.result.trustClass
        )
    }

    private func post<Payload: Encodable, Response: Decodable>(
        endpoint: URL,
        payload: Payload,
        idToken: String,
        responseType _: Response.Type
    ) async throws -> Response {
        guard Self.isStrictHTTPSEndpoint(endpoint),
              idToken.isEmpty == false,
              idToken.utf8.count <= 16_384 else {
            throw BurnBarLinuxAppCheckError.invalidResponse
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        let requestBody = try JSONEncoder().encode(CallableRequest(data: payload))
        guard requestBody.count <= Self.maximumRequestBytes else {
            throw BurnBarLinuxAppCheckError.invalidAttestation
        }
        request.httpBody = requestBody

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as BurnBarLinuxAppCheckError {
            throw error
        } catch {
            throw BurnBarLinuxAppCheckError.networkUnavailable
        }
        guard data.count <= Self.maximumResponseBytes,
              let http = response as? HTTPURLResponse,
              BurnBarSensitiveHTTPSession.responseMatchesExactEndpoint(http, endpoint: endpoint) else {
            throw BurnBarLinuxAppCheckError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw BurnBarLinuxAppCheckError.networkUnavailable
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw BurnBarLinuxAppCheckError.invalidResponse
        }
    }

    static func validEndpoint(_ raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.isEmpty == false,
              raw.utf8.count <= 2_048,
              let url = URL(string: raw),
              isStrictHTTPSEndpoint(url) else {
            return nil
        }
        return url
    }

    static func hardenedConfiguration(from source: URLSessionConfiguration) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = source.protocolClasses
        configuration.connectionProxyDictionary = source.connectionProxyDictionary
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return configuration
    }

    private static func isStrictHTTPSEndpoint(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.isEmpty == false
            && url.user == nil
            && url.password == nil
            && url.fragment == nil
    }
}
