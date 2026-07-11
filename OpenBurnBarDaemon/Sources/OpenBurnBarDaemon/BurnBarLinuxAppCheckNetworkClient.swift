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

enum BurnBarLinuxAttestationIngressClientError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidRequest
    case invalidResponse
    case networkUnavailable
    case terminalHTTPStatus(Int)
    case retryableHTTPStatus(Int)

    var isRetryable: Bool {
        switch self {
        case .networkUnavailable, .retryableHTTPStatus:
            true
        case .invalidConfiguration, .invalidRequest, .invalidResponse, .terminalHTTPStatus:
            false
        }
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
    static let productionUploadTicketEndpoint = URL(
        string: "https://us-central1-burnbar.cloudfunctions.net/issueLinuxAttestationUploadTicket"
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

    private struct UploadTicketRequest: Encodable {
        let challengeId: String
        let challenge: String
        let ticketSecretHashSha256: String
        let expectedSha256: String
        let expectedSize: Int
    }

    private struct TicketIssueResponse: Decodable {
        struct Result: Decodable {
            let ok: Bool
            let ticketId: String
            let expiresAtMillis: Int64
        }

        let result: Result
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
    private let uploadTicketEndpoint: URL
    private let challengeEndpointIsValid: Bool
    private let mintEndpointIsValid: Bool
    private let uploadTicketEndpointIsValid: Bool
    private let transport: BurnBarLinuxAppCheckTransport
    private let nowMillis: @Sendable () -> Int64

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession = .shared,
        nowMillis: @escaping @Sendable () -> Int64 = Self.currentTimeMillis
    ) {
        let challenge = Self.configuredEndpoint(
            environment["OPENBURNBAR_LINUX_APP_CHECK_CHALLENGE_ENDPOINT"],
            fallback: Self.productionChallengeEndpoint
        )
        let mint = Self.configuredEndpoint(
            environment["OPENBURNBAR_LINUX_APP_CHECK_MINT_ENDPOINT"],
            fallback: Self.productionMintEndpoint
        )
        let uploadTicket = Self.configuredEndpoint(
            environment["OPENBURNBAR_LINUX_ATTESTATION_UPLOAD_TICKET_ENDPOINT"],
            fallback: Self.productionUploadTicketEndpoint
        )
        challengeEndpoint = challenge.url
        mintEndpoint = mint.url
        uploadTicketEndpoint = uploadTicket.url
        challengeEndpointIsValid = challenge.isValid
        mintEndpointIsValid = mint.isValid
        uploadTicketEndpointIsValid = uploadTicket.isValid
        self.nowMillis = nowMillis
        let configuration = Self.hardenedConfiguration(from: session.configuration)
        transport = { request in
            let delegate = BurnBarLinuxAppCheckBoundedDataDelegate(maximumBytes: Self.maximumResponseBytes)
            return try await delegate.perform(request: request, configuration: configuration)
        }
    }

    init(
        challengeEndpoint: URL,
        mintEndpoint: URL,
        uploadTicketEndpoint: URL = Self.productionUploadTicketEndpoint,
        nowMillis: @escaping @Sendable () -> Int64 = Self.currentTimeMillis,
        transport: @escaping BurnBarLinuxAppCheckTransport
    ) {
        self.challengeEndpoint = challengeEndpoint
        self.mintEndpoint = mintEndpoint
        self.uploadTicketEndpoint = uploadTicketEndpoint
        challengeEndpointIsValid = Self.isStrictHTTPSEndpoint(challengeEndpoint)
        mintEndpointIsValid = Self.isStrictHTTPSEndpoint(mintEndpoint)
        uploadTicketEndpointIsValid = Self.isStrictHTTPSEndpoint(uploadTicketEndpoint)
        self.nowMillis = nowMillis
        self.transport = transport
    }

    func issueChallenge(
        binding: BurnBarLinuxAppCheckAttestationBinding,
        idToken: String
    ) async throws -> BurnBarLinuxAppCheckChallenge {
        guard challengeEndpointIsValid else { throw BurnBarLinuxAppCheckError.invalidResponse }
        let response: ChallengeResponse = try await post(
            endpoint: challengeEndpoint,
            payload: binding,
            idToken: idToken,
            exactResponseKeys: ["result"],
            exactResultKeys: ["challengeId", "challenge", "expiresAtMillis", "appId", "policyId", "protocolVersion"],
            responseType: ChallengeResponse.self
        )
        return response.result
    }

    func issueUploadTicket(
        challenge: BurnBarLinuxAppCheckChallenge,
        credential: BurnBarLinuxAttestationTicketCredential,
        expectedSHA256: String,
        expectedSize: Int,
        idToken: String
    ) async throws -> BurnBarLinuxAttestationTicketIssue {
        guard uploadTicketEndpointIsValid else { throw BurnBarLinuxAppCheckError.invalidResponse }
        guard Self.isLowerSHA256(expectedSHA256),
              (1...BurnBarLinuxAttestationIngressContract.maximumEvidenceBytes).contains(expectedSize) else {
            throw BurnBarLinuxAppCheckError.invalidAttestation
        }
        let response: TicketIssueResponse = try await post(
            endpoint: uploadTicketEndpoint,
            payload: UploadTicketRequest(
                challengeId: challenge.challengeId,
                challenge: challenge.challenge,
                ticketSecretHashSha256: credential.secretHashSHA256,
                expectedSha256: expectedSHA256,
                expectedSize: expectedSize
            ),
            idToken: idToken,
            exactResponseKeys: ["result"],
            exactResultKeys: ["ok", "ticketId", "expiresAtMillis"],
            responseType: TicketIssueResponse.self
        )
        guard response.result.ok,
              response.result.expiresAtMillis > nowMillis(),
              (try? credential.wireValue(ticketID: response.result.ticketId)) != nil else {
            throw BurnBarLinuxAppCheckError.invalidResponse
        }
        return .init(ticketID: response.result.ticketId, expiresAtMillis: response.result.expiresAtMillis)
    }

    func mintToken(
        attestation: BurnBarLinuxAppCheckAttestation,
        idToken: String
    ) async throws -> BurnBarLinuxAppCheckMintResponse {
        guard mintEndpointIsValid else { throw BurnBarLinuxAppCheckError.invalidResponse }
        let response: MintResponse = try await post(
            endpoint: mintEndpoint,
            payload: MintRequest(attestation: attestation),
            idToken: idToken,
            exactResponseKeys: ["result"],
            exactResultKeys: ["ok", "appCheckToken", "issuedAtMillis", "expireTimeMillis", "appId", "trustClass"],
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
        exactResponseKeys: Set<String>,
        exactResultKeys: Set<String>,
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
        guard (200..<300).contains(http.statusCode) else { throw Self.classifiedCallableHTTPError(http.statusCode) }
        do {
            try Self.requireExactJSONKeys(
                data,
                rootKeys: exactResponseKeys,
                nestedObject: "result",
                nestedKeys: exactResultKeys
            )
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw BurnBarLinuxAppCheckError.invalidResponse
        }
    }

    static func validEndpoint(_ raw: String?) -> URL? {
        guard let raw,
              raw.trimmingCharacters(in: .whitespacesAndNewlines) == raw,
              raw.isEmpty == false,
              raw.utf8.count <= 2_048,
              let url = URL(string: raw),
              isStrictHTTPSEndpoint(url) else {
            return nil
        }
        return url
    }

    private static func configuredEndpoint(_ raw: String?, fallback: URL) -> (url: URL, isValid: Bool) {
        guard raw != nil else { return (fallback, true) }
        guard let endpoint = validEndpoint(raw) else { return (fallback, false) }
        return (endpoint, true)
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

    fileprivate static func isStrictHTTPSEndpoint(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.isEmpty == false
            && url.user == nil
            && url.password == nil
            && url.query == nil
            && url.fragment == nil
    }

    fileprivate static func requireExactJSONKeys(
        _ data: Data,
        rootKeys: Set<String>,
        nestedObject: String? = nil,
        nestedKeys: Set<String>? = nil
    ) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == rootKeys else {
            throw BurnBarLinuxAppCheckError.invalidResponse
        }
        if let nestedObject, let nestedKeys {
            guard let nested = root[nestedObject] as? [String: Any], Set(nested.keys) == nestedKeys else {
                throw BurnBarLinuxAppCheckError.invalidResponse
            }
        }
    }

    fileprivate static func isLowerSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66)
        }
    }

    private static func classifiedCallableHTTPError(_ statusCode: Int) -> BurnBarLinuxAppCheckError {
        if statusCode == 408 || statusCode == 425 || statusCode == 429 || (500...599).contains(statusCode) {
            return .networkUnavailable
        }
        return .invalidResponse
    }

    private static func currentTimeMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }
}

struct EnvironmentBurnBarLinuxAttestationIngressClient: Sendable {
    static let maximumResponseBytes = 256 * 1_024
    static let maximumJSONRequestBytes = 512 * 1_024
    static let ticketHeader = "X-OpenBurnBar-Attestation-Ticket"

    private struct CreateUploadRequest: Encodable {
        let protocolVersion = BurnBarLinuxAttestationIngressContract.protocolVersion
        let attestationKind = BurnBarLinuxAttestationIngressContract.attestationKind
        let appId: String
        let deviceId: String
        let challengeId: String
        let releaseDigestSha256: String
        let expectedSha256: String
        let expectedSize: Int
    }

    private struct ReservationResponse: Decodable {
        let uploadId: String
        let expiresAtMillis: Int64
    }

    private struct ReceiptResponse: Decodable {
        let receipt: BurnBarLinuxAttestationUploadReceipt
    }

    private let baseEndpoint: URL?
    private let transport: BurnBarLinuxAppCheckTransport
    private let nowMillis: @Sendable () -> Int64

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession = .shared,
        nowMillis: @escaping @Sendable () -> Int64 = Self.currentTimeMillis
    ) {
        baseEndpoint = Self.validBaseEndpoint(environment["OPENBURNBAR_LINUX_ATTESTATION_INGRESS_ENDPOINT"])
        self.nowMillis = nowMillis
        let configuration = EnvironmentBurnBarLinuxAppCheckCloudClient.hardenedConfiguration(from: session.configuration)
        transport = { request in
            let delegate = BurnBarLinuxAppCheckBoundedDataDelegate(maximumBytes: Self.maximumResponseBytes)
            return try await delegate.perform(request: request, configuration: configuration)
        }
    }

    init(
        baseEndpoint: URL,
        nowMillis: @escaping @Sendable () -> Int64 = Self.currentTimeMillis,
        transport: @escaping BurnBarLinuxAppCheckTransport
    ) {
        self.baseEndpoint = Self.validBaseEndpoint(baseEndpoint.absoluteString)
        self.nowMillis = nowMillis
        self.transport = transport
    }

    var hasValidEndpoint: Bool { baseEndpoint != nil }

    func claimUpload(
        declaration: BurnBarLinuxAttestationUploadDeclaration,
        ticket: BurnBarLinuxAttestationTicketIssue,
        credential: BurnBarLinuxAttestationTicketCredential,
        idToken: String
    ) async throws -> BurnBarLinuxAttestationUploadReservation {
        guard let endpoint = endpoint(path: "v1/evidence-uploads") else {
            throw BurnBarLinuxAttestationIngressClientError.invalidConfiguration
        }
        guard Self.validIDToken(idToken),
              Self.validDeclaration(declaration),
              ticket.expiresAtMillis > nowMillis() else {
            throw BurnBarLinuxAttestationIngressClientError.invalidRequest
        }
        let ticketValue: String
        do {
            ticketValue = try credential.wireValue(ticketID: ticket.ticketID)
        } catch {
            throw BurnBarLinuxAttestationIngressClientError.invalidRequest
        }
        var request = Self.baseRequest(endpoint: endpoint, method: "POST", idToken: idToken, timeout: 30)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(ticketValue, forHTTPHeaderField: Self.ticketHeader)
        let body = try JSONEncoder().encode(CreateUploadRequest(
            appId: declaration.appID,
            deviceId: declaration.deviceID,
            challengeId: declaration.challengeID,
            releaseDigestSha256: declaration.releaseDigestSHA256,
            expectedSha256: declaration.expectedSHA256,
            expectedSize: declaration.expectedSize
        ))
        guard body.count <= Self.maximumJSONRequestBytes else {
            throw BurnBarLinuxAttestationIngressClientError.invalidRequest
        }
        request.httpBody = body
        let data = try await perform(request, endpoint: endpoint, expectedStatus: 201)
        do {
            try EnvironmentBurnBarLinuxAppCheckCloudClient.requireExactJSONKeys(
                data,
                rootKeys: ["uploadId", "expiresAtMillis"]
            )
            let result = try JSONDecoder().decode(ReservationResponse.self, from: data)
            guard result.expiresAtMillis > nowMillis(),
                  BurnBarLinuxAttestationTicketCredential.isCanonicalIdentifier(result.uploadId) else {
                throw BurnBarLinuxAttestationIngressClientError.invalidResponse
            }
            return .init(uploadID: result.uploadId, expiresAtMillis: result.expiresAtMillis)
        } catch let error as BurnBarLinuxAttestationIngressClientError {
            throw error
        } catch {
            throw BurnBarLinuxAttestationIngressClientError.invalidResponse
        }
    }

    func putEvidence(
        reservation: BurnBarLinuxAttestationUploadReservation,
        body: any BurnBarLinuxAttestationUploadBody,
        idToken: String
    ) async throws -> BurnBarLinuxAttestationUploadReceipt {
        guard let endpoint = endpoint(path: "v1/evidence-uploads/\(reservation.uploadID)") else {
            throw BurnBarLinuxAttestationIngressClientError.invalidConfiguration
        }
        guard BurnBarLinuxAttestationTicketCredential.isCanonicalIdentifier(reservation.uploadID),
              reservation.expiresAtMillis > nowMillis(),
              (1...BurnBarLinuxAttestationIngressContract.maximumEvidenceBytes).contains(body.byteCount),
              EnvironmentBurnBarLinuxAppCheckCloudClient.isLowerSHA256(body.sha256),
              Self.validIDToken(idToken) else {
            throw BurnBarLinuxAttestationIngressClientError.invalidRequest
        }
        var request = Self.baseRequest(endpoint: endpoint, method: "PUT", idToken: idToken, timeout: 120)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(body.byteCount), forHTTPHeaderField: "Content-Length")
        let stream = try body.makeInputStream()
        defer { stream.close() }
        var payload = Data()
        payload.reserveCapacity(body.byteCount)
        var buffer = [UInt8](repeating: 0, count: min(64 * 1024, body.byteCount))
        while payload.count < body.byteCount {
            let count = stream.read(&buffer, maxLength: min(buffer.count, body.byteCount - payload.count))
            guard count > 0 else {
                throw BurnBarLinuxAttestationIngressClientError.invalidRequest
            }
            payload.append(buffer, count: count)
        }
        request.httpBody = payload
        let data = try await perform(request, endpoint: endpoint, expectedStatus: 200)
        do {
            try EnvironmentBurnBarLinuxAppCheckCloudClient.requireExactJSONKeys(
                data,
                rootKeys: ["receipt"],
                nestedObject: "receipt",
                nestedKeys: ["uploadId", "generation", "sha256", "size"]
            )
            let receipt = try JSONDecoder().decode(ReceiptResponse.self, from: data).receipt
            guard receipt.uploadId == reservation.uploadID,
                  receipt.sha256 == body.sha256,
                  receipt.size == body.byteCount,
                  Self.validGeneration(receipt.generation) else {
                throw BurnBarLinuxAttestationIngressClientError.invalidResponse
            }
            return receipt
        } catch let error as BurnBarLinuxAttestationIngressClientError {
            throw error
        } catch {
            throw BurnBarLinuxAttestationIngressClientError.invalidResponse
        }
    }

    static func validBaseEndpoint(_ raw: String?) -> URL? {
        guard let raw,
              raw.trimmingCharacters(in: .whitespacesAndNewlines) == raw,
              raw.isEmpty == false,
              raw.utf8.count <= 2_048,
              let url = URL(string: raw),
              EnvironmentBurnBarLinuxAppCheckCloudClient.isStrictHTTPSEndpoint(url) else {
            return nil
        }
        return url
    }

    private func endpoint(path: String) -> URL? {
        guard let baseEndpoint else { return nil }
        return baseEndpoint.appendingPathComponent(path)
    }

    private func perform(_ request: URLRequest, endpoint: URL, expectedStatus: Int) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as BurnBarLinuxAttestationIngressClientError {
            throw error
        } catch {
            throw BurnBarLinuxAttestationIngressClientError.networkUnavailable
        }
        guard data.count <= Self.maximumResponseBytes,
              let http = response as? HTTPURLResponse,
              BurnBarSensitiveHTTPSession.responseMatchesExactEndpoint(http, endpoint: endpoint) else {
            throw BurnBarLinuxAttestationIngressClientError.invalidResponse
        }
        guard http.statusCode == expectedStatus else { throw Self.classifiedHTTPError(http.statusCode) }
        return data
    }

    private static func baseRequest(endpoint: URL, method: String, idToken: String, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func validDeclaration(_ value: BurnBarLinuxAttestationUploadDeclaration) -> Bool {
        !value.appID.isEmpty && value.appID.utf8.count <= 160
            && !value.deviceID.isEmpty && value.deviceID.utf8.count <= 160
            && !value.challengeID.isEmpty && value.challengeID.utf8.count <= 80
            && EnvironmentBurnBarLinuxAppCheckCloudClient.isLowerSHA256(value.releaseDigestSHA256)
            && EnvironmentBurnBarLinuxAppCheckCloudClient.isLowerSHA256(value.expectedSHA256)
            && (1...BurnBarLinuxAttestationIngressContract.maximumEvidenceBytes).contains(value.expectedSize)
    }

    private static func validIDToken(_ value: String) -> Bool {
        value.isEmpty == false && value.utf8.count <= 16_384
    }

    private static func validGeneration(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count) && value.utf8.allSatisfy {
            ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A)
                || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2E || $0 == 0x5F
                || $0 == 0x3A || $0 == 0x2D
        }
    }

    private static func classifiedHTTPError(_ statusCode: Int) -> BurnBarLinuxAttestationIngressClientError {
        if statusCode == 408 || statusCode == 425 || statusCode == 429 || (500...599).contains(statusCode) {
            return .retryableHTTPStatus(statusCode)
        }
        return .terminalHTTPStatus(statusCode)
    }

    private static func currentTimeMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }

}
