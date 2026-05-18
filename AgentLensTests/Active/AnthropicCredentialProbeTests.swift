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

    // MARK: - verdict classification (via private probe path)

    /// 200-class responses should land on `.ok(model:)` regardless of body
    /// (the probe model name is the source of truth).
    func test_classify_okOn200() async {
        let probe = makeMockedProbe(status: 200, body: #"{"id":"msg_01"}"#)
        let result = await probe.probe(credential: "sk-ant-api03-fake")
        XCTAssertEqual(result.verdict, .ok(model: AnthropicCredentialProbe.defaultProbeModel))
        XCTAssertTrue(result.isHealthy)
        XCTAssertEqual(result.shape, .consoleAPIKey)
    }

    func test_classify_authFailedOn401() async {
        let probe = makeMockedProbe(status: 401, body: #"{"error":"invalid auth"}"#)
        let result = await probe.probe(credential: "sk-ant-api03-bad")
        XCTAssertEqual(result.verdict, .authFailed)
        XCTAssertFalse(result.isHealthy)
    }

    func test_classify_quotaExhaustedOn402() async {
        let probe = makeMockedProbe(status: 402, body: #"{"error":"out of quota"}"#)
        let result = await probe.probe(credential: "sk-ant-api03-fake")
        XCTAssertEqual(result.verdict, .quotaExhausted)
    }

    func test_classify_rateLimitedOn429WithoutQuotaText() async {
        let probe = makeMockedProbe(status: 429, body: #"{"error":"rate limited"}"#)
        let result = await probe.probe(credential: "sk-ant-api03-fake")
        XCTAssertEqual(result.verdict, .rateLimited)
    }

    func test_classify_quotaExhaustedOn429WithQuotaText() async {
        let probe = makeMockedProbe(status: 429, body: #"{"error":"quota exhausted for the month"}"#)
        let result = await probe.probe(credential: "sk-ant-api03-fake")
        XCTAssertEqual(result.verdict, .quotaExhausted)
    }

    func test_classify_modelUnavailableOn404() async {
        let probe = makeMockedProbe(status: 404, body: #"{"error":"model not found"}"#)
        let result = await probe.probe(credential: "sk-ant-api03-fake")
        if case .modelUnavailable = result.verdict { } else {
            XCTFail("expected .modelUnavailable, got \(result.verdict)")
        }
    }

    func test_classify_unexpectedOn500() async {
        let probe = makeMockedProbe(status: 500, body: "internal server error")
        let result = await probe.probe(credential: "sk-ant-api03-fake")
        if case .unexpected(let status, _) = result.verdict {
            XCTAssertEqual(status, 500)
        } else {
            XCTFail("expected .unexpected, got \(result.verdict)")
        }
    }

    func test_classify_truncatesLongBodyMessages() async {
        let longBody = String(repeating: "X", count: 1024)
        let probe = makeMockedProbe(status: 503, body: longBody)
        let result = await probe.probe(credential: "sk-ant-api03-fake")
        if case .unexpected(_, let message) = result.verdict {
            XCTAssertLessThanOrEqual(message.count, 200)
            XCTAssertTrue(message.hasSuffix("…"))
        } else {
            XCTFail("expected .unexpected, got \(result.verdict)")
        }
    }

    // MARK: - probe header dispatch

    func test_probe_sendsConsoleAPIKeyHeader_forSkAntAPIKeyPrefix() async throws {
        let recorder = RequestRecorder()
        let probe = makeMockedProbe(status: 200, body: "{}", recorder: recorder)
        _ = await probe.probe(credential: "sk-ant-api03-recorded")
        let recorded = recorder.last
        XCTAssertNotNil(recorded)
        XCTAssertEqual(recorded?.value(forHTTPHeaderField: "x-api-key"), "sk-ant-api03-recorded")
        XCTAssertNil(recorded?.value(forHTTPHeaderField: "Authorization"))
    }

    func test_probe_sendsBearerHeader_forOAuthCredential() async throws {
        let recorder = RequestRecorder()
        let probe = makeMockedProbe(status: 200, body: "{}", recorder: recorder)
        _ = await probe.probe(credential: "sk-ant-oat01-oauth-bearer-token")
        let recorded = recorder.last
        XCTAssertEqual(recorded?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-ant-oat01-oauth-bearer-token")
        XCTAssertNil(recorded?.value(forHTTPHeaderField: "x-api-key"))
    }

    func test_probe_alwaysPinsAnthropicVersionHeader() async {
        let recorder = RequestRecorder()
        let probe = makeMockedProbe(status: 200, body: "{}", recorder: recorder)
        _ = await probe.probe(credential: "sk-ant-api03-test")
        let recorded = recorder.last
        XCTAssertEqual(
            recorded?.value(forHTTPHeaderField: "anthropic-version"),
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
        MockURLProtocol.responder = { request in
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
    nonisolated(unsafe) static var responder: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let responder = Self.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotLoadFromNetwork))
            return
        }
        // URLSession strips the body before handing us a request, so reach
        // through `urlRequest` for the body when we need to inspect it. The
        // tests only inspect headers, which are preserved.
        let (response, data) = responder(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
