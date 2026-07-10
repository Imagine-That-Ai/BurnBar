@testable import OpenBurnBarDaemon
#if canImport(FoundationNetworking)
@preconcurrency import FoundationNetworking
#endif
import Foundation
import XCTest

final class BurnBarLinuxAppCheckNetworkClientTests: XCTestCase {
    private let challengeEndpoint = URL(string: "https://example.com/issueLinuxAppCheckChallenge")!
    private let mintEndpoint = URL(string: "https://example.com/mintLinuxAppCheckToken")!

    func testChallengeAndMintUseExactCallableEnvelopesBearerAndNoStore() async throws {
        let recorder = AppCheckRequestRecorder()
        let challengeEndpoint = self.challengeEndpoint
        let mintEndpoint = self.mintEndpoint
        let client = EnvironmentBurnBarLinuxAppCheckCloudClient(
            challengeEndpoint: challengeEndpoint,
            mintEndpoint: mintEndpoint
        ) { request in
            await recorder.record(request)
            if request.url == challengeEndpoint {
                return (
                    Data(Self.challengeBody.utf8),
                    HTTPURLResponse(url: challengeEndpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            }
            return (
                Data(Self.mintBody.utf8),
                HTTPURLResponse(url: mintEndpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }

        let challenge = try await client.issueChallenge(binding: binding(), idToken: "firebase-id-token")
        let response = try await client.mintToken(
            attestation: .init(
                challengeId: challenge.challengeId,
                challenge: challenge.challenge,
                kind: "tpm2_ima_signed_verdict_v1",
                evidence: .object(["quote": .string("signed-quote")])
            ),
            idToken: "firebase-id-token"
        )

        XCTAssertEqual(challenge.appId, "1:123:web:linux")
        XCTAssertEqual(response.appCheckToken, "app-check-secret")
        XCTAssertEqual(response.issuedAtMillis, 1_900_000_000_000)
        XCTAssertEqual(response.expireTimeMillis, 1_900_001_800_000)
        let requests = await recorder.requests()
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer firebase-id-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        }
        let challengeRoot = try jsonObject(requests[0])
        let challengeData = try XCTUnwrap(challengeRoot["data"] as? [String: Any])
        XCTAssertEqual(challengeData["deviceId"] as? String, "device-1")
        XCTAssertEqual(challengeData["attestationKind"] as? String, "tpm2_ima_signed_verdict_v1")
        let mintRoot = try jsonObject(requests[1])
        let mintData = try XCTUnwrap(mintRoot["data"] as? [String: Any])
        let attestation = try XCTUnwrap(mintData["attestation"] as? [String: Any])
        XCTAssertEqual(attestation["challengeId"] as? String, "challenge-0123456789abcdef")
        XCTAssertEqual(attestation["kind"] as? String, "tpm2_ima_signed_verdict_v1")
        XCTAssertNil(mintRoot["appCheckToken"])
    }

    func testRedirectedOversizedMalformedAndHTTPErrorResponsesFailClosed() async throws {
        let cases: [(Data, HTTPURLResponse, BurnBarLinuxAppCheckError)] = [
            (
                Data(Self.mintBody.utf8),
                HTTPURLResponse(
                    url: URL(string: "https://redirect.example/mint")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                .invalidResponse
            ),
            (
                Data(repeating: 0x61, count: EnvironmentBurnBarLinuxAppCheckCloudClient.maximumResponseBytes + 1),
                HTTPURLResponse(url: mintEndpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                .invalidResponse
            ),
            (
                Data(#"{"result":{"ok":true}}"#.utf8),
                HTTPURLResponse(url: mintEndpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                .invalidResponse
            ),
            (
                Data(#"{"error":{"status":"UNAUTHENTICATED"}}"#.utf8),
                HTTPURLResponse(url: mintEndpoint, statusCode: 401, httpVersion: nil, headerFields: nil)!,
                .networkUnavailable
            )
        ]

        for (body, response, expectedError) in cases {
            let client = EnvironmentBurnBarLinuxAppCheckCloudClient(
                challengeEndpoint: challengeEndpoint,
                mintEndpoint: mintEndpoint
            ) { _ in (body, response) }
            do {
                _ = try await client.mintToken(
                    attestation: attestation(),
                    idToken: "id-token"
                )
                XCTFail("Invalid callable response should fail closed")
            } catch let error as BurnBarLinuxAppCheckError {
                XCTAssertEqual(error, expectedError)
            }
        }
    }

    func testEndpointOverrideRequiresStrictHTTPSAndSessionIsMemoryOnly() {
        XCTAssertEqual(
            EnvironmentBurnBarLinuxAppCheckCloudClient.validEndpoint(" https://example.com/mint "),
            URL(string: "https://example.com/mint")
        )
        XCTAssertNil(EnvironmentBurnBarLinuxAppCheckCloudClient.validEndpoint("http://example.com/mint"))
        XCTAssertNil(EnvironmentBurnBarLinuxAppCheckCloudClient.validEndpoint("https://user@example.com/mint"))
        XCTAssertNil(EnvironmentBurnBarLinuxAppCheckCloudClient.validEndpoint("https://example.com/mint#fragment"))

        let source = URLSessionConfiguration.default
        source.urlCache = URLCache(memoryCapacity: 1_024, diskCapacity: 1_024)
        source.httpShouldSetCookies = true
        let hardened = EnvironmentBurnBarLinuxAppCheckCloudClient.hardenedConfiguration(from: source)
        XCTAssertNil(hardened.urlCache)
        XCTAssertNil(hardened.httpCookieStorage)
        XCTAssertFalse(hardened.httpShouldSetCookies)
        XCTAssertNil(hardened.urlCredentialStorage)
        XCTAssertEqual(hardened.requestCachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
    }

    func testOversizedEvidenceIsRejectedBeforeTransport() async throws {
        let recorder = AppCheckRequestRecorder()
        let mintEndpoint = self.mintEndpoint
        let client = EnvironmentBurnBarLinuxAppCheckCloudClient(
            challengeEndpoint: challengeEndpoint,
            mintEndpoint: mintEndpoint
        ) { request in
            await recorder.record(request)
            return (
                Data(Self.mintBody.utf8),
                HTTPURLResponse(url: mintEndpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        let oversized = String(
            repeating: "a",
            count: EnvironmentBurnBarLinuxAppCheckCloudClient.maximumRequestBytes
        )
        do {
            _ = try await client.mintToken(
                attestation: .init(
                    challengeId: "challenge-0123456789abcdef",
                    challenge: "nonce-0123456789abcdef0123456789",
                    kind: "tpm2_ima_signed_verdict_v1",
                    evidence: .object(["quote": .string(oversized)])
                ),
                idToken: "id-token"
            )
            XCTFail("Oversized evidence must fail before transport")
        } catch let error as BurnBarLinuxAppCheckError {
            XCTAssertEqual(error, .invalidAttestation)
        }
        let requests = await recorder.requests()
        XCTAssertEqual(requests.count, 0)
    }

    func testBoundedResponseBufferRejectsChunkBeforeCrossingLimit() {
        var buffer = BurnBarLinuxAppCheckBoundedResponseBuffer(maximumBytes: 8)
        XCTAssertTrue(buffer.append(Data(repeating: 0x61, count: 5)))
        XCTAssertFalse(buffer.append(Data(repeating: 0x62, count: 4)))
        XCTAssertEqual(buffer.data, Data(repeating: 0x61, count: 5))
    }

    func testTaskCancellationStopsUnderlyingURLSessionTask() async throws {
        AppCheckSuspendedURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AppCheckSuspendedURLProtocol.self]
        let client = EnvironmentBurnBarLinuxAppCheckCloudClient(
            environment: [
                "OPENBURNBAR_LINUX_APP_CHECK_CHALLENGE_ENDPOINT": challengeEndpoint.absoluteString,
                "OPENBURNBAR_LINUX_APP_CHECK_MINT_ENDPOINT": mintEndpoint.absoluteString,
            ],
            session: URLSession(configuration: configuration)
        )
        let request = Task {
            try await client.mintToken(attestation: attestation(), idToken: "id-token")
        }
        try await waitUntil { AppCheckSuspendedURLProtocol.started }
        request.cancel()

        do {
            _ = try await request.value
            XCTFail("Cancellation must escape as CancellationError")
        } catch is CancellationError {
            // Expected.
        }
        try await waitUntil { AppCheckSuspendedURLProtocol.stopped }
    }

    private static let challengeBody = #"{"result":{"challengeId":"challenge-0123456789abcdef","challenge":"nonce-0123456789abcdef0123456789","expiresAtMillis":1900000120000,"appId":"1:123:web:linux","policyId":"openburnbar-linux-tpm2-ima-v1","protocolVersion":1}}"#
    private static let mintBody = #"{"result":{"ok":true,"appCheckToken":"app-check-secret","issuedAtMillis":1900000000000,"expireTimeMillis":1900001800000,"appId":"1:123:web:linux","trustClass":"linux_lower_trust"}}"#

    private func binding() -> BurnBarLinuxAppCheckAttestationBinding {
        .init(
            appId: "1:123:web:linux",
            deviceId: "device-1",
            appVersion: "1.0.0",
            architecture: "x86_64",
            releaseDigestSha256: String(repeating: "a", count: 64),
            policyId: "openburnbar-linux-tpm2-ima-v1",
            attestationKind: "tpm2_ima_signed_verdict_v1"
        )
    }

    private func attestation() -> BurnBarLinuxAppCheckAttestation {
        .init(
            challengeId: "challenge-0123456789abcdef",
            challenge: "nonce-0123456789abcdef0123456789",
            kind: "tpm2_ima_signed_verdict_v1",
            evidence: .object(["quote": .string("signed-quote")])
        )
    }

    private func jsonObject(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
        )
    }

    private func waitUntil(_ predicate: @escaping @Sendable () -> Bool) async throws {
        for _ in 0..<100 where predicate() == false {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(predicate())
    }
}

private actor AppCheckRequestRecorder {
    private var captured: [URLRequest] = []
    func record(_ request: URLRequest) { captured.append(request) }
    func requests() -> [URLRequest] { captured }
}

private final class AppCheckSuspendedURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var state = (started: false, stopped: false)

    static var started: Bool { lock.withLock { state.started } }
    static var stopped: Bool { lock.withLock { state.stopped } }

    static func reset() {
        lock.withLock { state = (false, false) }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        _ = request
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.state.started = true }
    }

    override func stopLoading() {
        Self.lock.withLock { Self.state.stopped = true }
    }
}
