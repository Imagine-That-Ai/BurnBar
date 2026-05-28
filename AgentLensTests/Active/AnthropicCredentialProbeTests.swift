import XCTest
@testable import OpenBurnBar

/// Coverage for the pure / deterministic surfaces of `AnthropicCredentialProbe`.
///
/// We intentionally do *not* exercise the live `probe(credential:)` path here:
/// that one hits `https://api.anthropic.com/v1/messages` and is covered by
/// the daemon-side integration test (`testGatewayProxiesAnthropicMessagesHappyPath`).
/// The fields that matter for OpenBurnBar's correctness — shape detection,
/// redaction, and status-code classification — are pure functions and are
/// what we lock down here.
final class AnthropicCredentialProbeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - detectShape

    func test_detectShape_consoleAPIKey() {
        XCTAssertEqual(AnthropicCredentialProbe.detectShape("sk-ant-api03-abc123"), .consoleAPIKey)
        XCTAssertEqual(AnthropicCredentialProbe.detectShape("sk-ant-api03-something-longer-and-base64ish"), .consoleAPIKey)
    }

    func test_detectShape_oauthBearer_default() {
        XCTAssertEqual(AnthropicCredentialProbe.detectShape("sk-ant-oat01-oauth-token"), .oauthBearer)
        XCTAssertEqual(AnthropicCredentialProbe.detectShape("eyJhbGciOiJIUzI1NiJ9.eyJ"), .oauthBearer)
        XCTAssertEqual(AnthropicCredentialProbe.detectShape("Bearer something"), .oauthBearer)
        XCTAssertEqual(AnthropicCredentialProbe.detectShape("anything-not-prefixed"), .oauthBearer)
    }

    func test_detectShape_handlesSurroundingWhitespace() {
        XCTAssertEqual(AnthropicCredentialProbe.detectShape("  sk-ant-api03-abc  \n"), .consoleAPIKey)
        XCTAssertEqual(AnthropicCredentialProbe.detectShape("\tabcd\t"), .oauthBearer)
    }

    // MARK: - redactedLabel

    func test_redactedLabel_showsOnlyTrailingFourCharacters() {
        XCTAssertEqual(AnthropicCredentialProbe.redactedLabel("sk-ant-abc123WXYZ"), "…WXYZ")
        XCTAssertEqual(AnthropicCredentialProbe.redactedLabel("0123456789"), "…6789")
    }

    func test_redactedLabel_shortCredentialBecomesEllipsisOnly() {
        XCTAssertEqual(AnthropicCredentialProbe.redactedLabel("abc"), "…")
        XCTAssertEqual(AnthropicCredentialProbe.redactedLabel(""), "…")
        XCTAssertEqual(AnthropicCredentialProbe.redactedLabel("ab"), "…")
    }

    func test_redactedLabel_neverContainsTokenSuffix() {
        // Defensive: a buggy implementation that returns the full string
        // would be caught by checking that the prefix is gone.
        let raw = "sk-ant-do_not_leak_me_ABCD"
        let label = AnthropicCredentialProbe.redactedLabel(raw)
        XCTAssertFalse(label.contains("do_not_leak_me"))
        XCTAssertTrue(label.hasSuffix("ABCD"))
    }

    // MARK: - verdict classification

    private func makeClassifier() -> AnthropicCredentialProbe {
        AnthropicCredentialProbe(clock: { Date(timeIntervalSince1970: 1_700_000_000) })
    }

    func test_classify_okOn200() {
        let probe = makeClassifier()
        XCTAssertEqual(
            probe.classify(status: 200, body: #"{"id":"msg_01"}"#),
            .ok(model: AnthropicCredentialProbe.defaultProbeModel)
        )
    }

    func test_classify_authFailedOn401() {
        let probe = makeClassifier()
        XCTAssertEqual(probe.classify(status: 401, body: #"{"error":"invalid auth"}"#), .authFailed)
    }

    func test_classify_quotaExhaustedOn402() {
        let probe = makeClassifier()
        XCTAssertEqual(probe.classify(status: 402, body: #"{"error":"out of quota"}"#), .quotaExhausted)
    }

    func test_classify_rateLimitedOn429WithoutQuotaText() {
        let probe = makeClassifier()
        XCTAssertEqual(probe.classify(status: 429, body: #"{"error":"rate limited"}"#), .rateLimited)
    }

    func test_classify_quotaExhaustedOn429WithQuotaText() {
        let probe = makeClassifier()
        XCTAssertEqual(probe.classify(status: 429, body: #"{"error":"quota exhausted for the month"}"#), .quotaExhausted)
    }

    func test_classify_modelUnavailableOn404() {
        let probe = makeClassifier()
        let verdict = probe.classify(status: 404, body: #"{"error":"model not found"}"#)
        if case .modelUnavailable = verdict { } else {
            XCTFail("expected .modelUnavailable, got \(verdict)")
        }
    }

    func test_classify_unexpectedOn500() {
        let probe = makeClassifier()
        let verdict = probe.classify(status: 500, body: "internal server error")
        if case .unexpected(let status, _) = verdict {
            XCTAssertEqual(status, 500)
        } else {
            XCTFail("expected .unexpected, got \(verdict)")
        }
    }

    func test_classify_truncatesLongBodyMessages() {
        let probe = makeClassifier()
        let longBody = String(repeating: "X", count: 1024)
        let verdict = probe.classify(status: 503, body: longBody)
        if case .unexpected(_, let message) = verdict {
            XCTAssertLessThanOrEqual(message.count, 200)
            XCTAssertTrue(message.hasSuffix("…"))
        } else {
            XCTFail("expected .unexpected, got \(verdict)")
        }
    }

    // MARK: - probe header dispatch

    func test_probe_sendsConsoleAPIKeyHeader_forSkAntAPIKeyPrefix() throws {
        let probe = AnthropicCredentialProbe()
        let built = try probe.buildProbeRequest(credential: "sk-ant-api03-recorded")
        XCTAssertEqual(built.request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-api03-recorded")
        XCTAssertNil(built.request.value(forHTTPHeaderField: "Authorization"))
    }

    func test_probe_sendsBearerHeader_forOAuthCredential() throws {
        let probe = AnthropicCredentialProbe()
        let built = try probe.buildProbeRequest(credential: "sk-ant-oat01-oauth-bearer-token")
        XCTAssertEqual(
            built.request.value(forHTTPHeaderField: "Authorization"),
            "Bearer sk-ant-oat01-oauth-bearer-token"
        )
        XCTAssertNil(built.request.value(forHTTPHeaderField: "x-api-key"))
    }

    func test_probe_alwaysPinsAnthropicVersionHeader() throws {
        let probe = AnthropicCredentialProbe()
        let built = try probe.buildProbeRequest(credential: "sk-ant-api03-test")
        XCTAssertEqual(
            built.request.value(forHTTPHeaderField: "anthropic-version"),
            AnthropicCredentialProbe.defaultAnthropicVersion
        )
    }

    // MARK: - helpers

    private func makeMockedProbe(
        status: Int,
        body: String,
        recorder: RequestRecorder? = nil
    ) -> AnthropicCredentialProbe {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.registerResponder { request in
            recorder?.record(request)
            let http = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (http, Data(body.utf8))
        }
        let session = URLSession(configuration: configuration)
        return AnthropicCredentialProbe(
            session: session,
            baseURL: URL(string: "https://api.anthropic.test/v1")!,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }
}

// MARK: - Test doubles

private final class RequestRecorder: @unchecked Sendable {
    private var requests: [URLRequest] = []
    private let lock = NSLock()

    func record(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
    }

    var last: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return requests.last
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var responder: ((URLRequest) -> (HTTPURLResponse, Data))?

    static func registerResponder(_ responder: @escaping (URLRequest) -> (HTTPURLResponse, Data)) {
        lock.lock()
        self.responder = responder
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        responder = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.caseInsensitiveCompare("api.anthropic.test") == .orderedSame
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let responder = Self.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotLoadFromNetwork))
            return
        }
        let (response, data) = responder(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
