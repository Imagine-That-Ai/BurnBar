#if os(Linux)
import Foundation
import Glibc
import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

/// Memory-purpose requests on the Linux loopback gateway: scoped tokens, the
/// policy gate, the egress log, and the no-enforcer refusal. Mirrors the
/// Darwin `BurnBarHTTPGatewayServerMemoryEgressTests` so the two gateways
/// cannot drift on Memory Pro egress again (regression from PR #2501, which
/// wired the enforcer on Darwin only and broke the Linux build).
final class OpenBurnBarHTTPGatewayServerLinuxMemoryEgressTests: XCTestCase {
    private let staticToken = "static-gateway-token"
    private let chatBody = #"{"model":"glm-5-turbo","messages":[{"role":"user","content":"hi"}]}"#

    private struct Fixture {
        let harness: LinuxGatewayHarness
        let upstream: LinuxMockOpenAIStreamServer
        let enforcer: BurnBarMemoryEgressEnforcer?
        let logURL: URL
    }

    private func makeFixture(
        proActive: Bool = true,
        policy: BurnBarMemoryEgressPolicy = BurnBarMemoryEgressPolicy(
            enabled: true,
            consentedProviderIDs: ["zai"],
            requireNoRetention: false,
            dailyCapUSD: 2
        ),
        spentTodayUSD: Double = 0,
        upstreamResponse: LinuxMockOpenAIStreamServer.Response = .openAIChatJSON,
        withEnforcer: Bool = true
    ) async throws -> Fixture {
        let upstream = LinuxMockOpenAIStreamServer(response: upstreamResponse)
        try upstream.start()

        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("linux-memory-egress-\(UUID().uuidString).jsonl", isDirectory: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: logURL) }
        var enforcerSlot: BurnBarMemoryEgressEnforcer?
        let harness = try LinuxGatewayHarness(
            authToken: staticToken,
            memoryEgress: withEnforcer ? { configStore, _ in
                let enforcer = BurnBarMemoryEgressEnforcer(
                    configStore: configStore,
                    membership: LinuxFakeMembershipService(active: proActive, now: Date()),
                    tokenStore: BurnBarGatewayScopedTokenStore(),
                    log: BurnBarMemoryEgressLogStore(fileURL: logURL),
                    spentTodayUSD: { _ in spentTodayUSD },
                    now: { Date() }
                )
                enforcerSlot = enforcer
                return enforcer
            } : nil
        )
        addTeardownBlock { await harness.stop() }
        try await harness.configureZAIProvider(baseURL: "http://127.0.0.1:\(upstream.port)/v1")
        var snapshot = try await harness.configStore.snapshot()
        snapshot.memoryEgress = policy
        _ = try await harness.configStore.replaceSnapshot(snapshot)
        try await harness.start()
        // Registered last so it runs first: teardown blocks are LIFO, and the
        // mock's blocking `accept` holds a cooperative-pool worker until the
        // socket is shut down. Releasing it before the other async teardown
        // blocks keeps XCTest's teardown sequence from starving.
        addTeardownBlock { upstream.stop() }
        return Fixture(harness: harness, upstream: upstream, enforcer: enforcerSlot, logURL: logURL)
    }

    private func send(
        _ fixture: Fixture,
        path: String = "/v1/chat/completions",
        token: String,
        purpose: String?,
        body: String? = nil
    ) async throws -> (status: Int, headers: [String: String], object: [String: Any]) {
        var headers = ["Authorization": "Bearer \(token)"]
        if let purpose {
            headers["X-OpenBurnBar-Purpose"] = purpose
        }
        let response = try await LinuxHTTPClient.post(
            port: fixture.harness.port,
            path: path,
            body: body ?? chatBody,
            headers: headers
        )
        let object = (try? JSONSerialization.jsonObject(with: Data(response.body.utf8)) as? [String: Any]) ?? [:]
        return (response.statusCode, response.headers, object)
    }

    private func mintedToken(_ fixture: Fixture, purposes: Set<String> = Set(BurnBarMemoryEgressPolicy.purposes)) async throws -> String {
        let enforcer = try XCTUnwrap(fixture.enforcer)
        return await enforcer.tokenStore.mint(purposes: purposes).token
    }

    private func errorCode(_ object: [String: Any]) -> String? {
        (object["error"] as? [String: Any])?["code"] as? String
    }

    private func logEntries(_ fixture: Fixture) async throws -> [BurnBarMemoryEgressEntry] {
        try await BurnBarMemoryEgressLogStore(fileURL: fixture.logURL).entries()
    }

    func testMemoryPurposeWithScopedTokenIsAllowedAndLogged() async throws {
        let fixture = try await makeFixture()
        let token = try await mintedToken(fixture)
        let (status, headers, object) = try await send(fixture, token: token, purpose: "memory-extract")
        XCTAssertEqual(status, 200, "\(object)")
        XCTAssertEqual(headers["content-type"], "application/json")
        XCTAssertEqual(object["id"] as? String, "chatcmpl-linux-json")

        let upstream = try XCTUnwrap(fixture.upstream.recordedRequests.first)
        XCTAssertEqual(upstream.path, "/v1/chat/completions")
        XCTAssertEqual(upstream.authorization, "Bearer primary-key")

        let entries = try await logEntries(fixture)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.outcome, "allowed")
        XCTAssertEqual(entries.first?.purpose, "memory-extract")
        XCTAssertEqual(entries.first?.providerID, "zai")
        XCTAssertEqual(entries.first?.modelID, "glm-5-turbo")
        XCTAssertGreaterThan(entries.first?.requestBytes ?? 0, 0)
        XCTAssertGreaterThan(entries.first?.responseBytes ?? 0, 0)

        // Spend lands on the Memory Pro execution source so the daily cap reads it.
        let usage = try await fixture.harness.usageRecorder.recentUsage(limit: 1)
        let event = try XCTUnwrap(usage.first)
        XCTAssertEqual(event.executionSourceID, BurnBarMemoryEgressEnforcer.executionSource.id)
        XCTAssertEqual(event.providerID, "zai")
    }

    func testMemoryPurposeRequestsAreNeverStreamed() async throws {
        let fixture = try await makeFixture()
        let token = try await mintedToken(fixture)
        let streamingBody = #"{"model":"glm-5-turbo","stream":true,"messages":[{"role":"user","content":"hi"}]}"#
        let (status, headers, object) = try await send(fixture, token: token, purpose: "memory-judge", body: streamingBody)
        XCTAssertEqual(status, 200, "\(object)")
        XCTAssertEqual(headers["content-type"], "application/json", "memory-purpose traffic is buffered so the egress chain can size the response")
        XCTAssertNotEqual(headers["content-type"], "text/event-stream")
        let entries = try await logEntries(fixture)
        XCTAssertEqual(entries.last?.outcome, "allowed")
        XCTAssertGreaterThan(entries.last?.responseBytes ?? 0, 0)
    }

    func testStaticTokenMayCarryAMemoryPurpose() async throws {
        let fixture = try await makeFixture()
        let (status, _, object) = try await send(fixture, token: staticToken, purpose: "memory-answer")
        XCTAssertEqual(status, 200, "\(object)")
        let entries = try await logEntries(fixture)
        XCTAssertEqual(entries.last?.purpose, "memory-answer")
        XCTAssertEqual(entries.last?.outcome, "allowed")
    }

    func testUpstreamFailuresAreRecordedInTheEgressChain() async throws {
        let fixture = try await makeFixture(upstreamResponse: .openAIChatUpstream500)
        let token = try await mintedToken(fixture)
        let (status, _, _) = try await send(fixture, token: token, purpose: "memory-extract")
        XCTAssertNotEqual(status, 200)
        XCTAssertEqual(fixture.upstream.recordedRequests.count, 1)

        let entries = try await logEntries(fixture)
        let failed = try XCTUnwrap(entries.first { $0.outcome == "failed" }, "a request that left the machine and failed is still chained")
        XCTAssertEqual(failed.purpose, "memory-extract")
        XCTAssertEqual(failed.providerID, "zai")
        XCTAssertEqual(failed.code, "UPSTREAM_500")
        XCTAssertEqual(failed.responseBytes, 0)
        let verification = try await BurnBarMemoryEgressLogStore(fileURL: fixture.logURL).verify()
        XCTAssertTrue(verification.ok, "chain broken at \(String(describing: verification.brokenAtSeq))")
    }

    // One gateway per test: the Linux accept loops block a cooperative-pool
    // thread each, so stacking several fixtures in one process starves it.

    private func assertDenied(
        _ fixture: Fixture,
        purpose: String,
        code expectedCode: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let (status, _, object) = try await send(fixture, token: try await mintedToken(fixture), purpose: purpose)
        XCTAssertEqual(status, 403, "\(object)", file: file, line: line)
        XCTAssertEqual(errorCode(object), expectedCode, file: file, line: line)
        XCTAssertEqual((object["error"] as? [String: Any])?["type"] as? String, "memory_egress_denied", file: file, line: line)
        XCTAssertTrue(fixture.upstream.recordedRequests.isEmpty, "a denied request never reaches the provider", file: file, line: line)
        let entries = try await logEntries(fixture)
        XCTAssertEqual(entries.count, 1, file: file, line: line)
        XCTAssertEqual(entries.last?.outcome, "denied", file: file, line: line)
        XCTAssertEqual(entries.last?.code, expectedCode, file: file, line: line)
        XCTAssertEqual(entries.last?.purpose, purpose, file: file, line: line)
    }

    func testStaleMembershipIsDeniedWithProRequired() async throws {
        let fixture = try await makeFixture(proActive: false)
        try await assertDenied(fixture, purpose: "memory-judge", code: "PRO_REQUIRED")
    }

    func testDisabledPolicyIsDeniedWithCloudConsentRequired() async throws {
        let fixture = try await makeFixture(policy: BurnBarMemoryEgressPolicy(enabled: false, consentedProviderIDs: ["zai"], requireNoRetention: false))
        try await assertDenied(fixture, purpose: "memory-answer", code: "CLOUD_CONSENT_REQUIRED")
    }

    func testUnconsentedProviderIsDenied() async throws {
        let fixture = try await makeFixture(policy: BurnBarMemoryEgressPolicy(enabled: true, consentedProviderIDs: ["openrouter"], requireNoRetention: false))
        try await assertDenied(fixture, purpose: "memory-answer", code: "PROVIDER_NOT_CONSENTED")
    }

    func testRetentionRequirementBlocksProvidersWithoutANoRetentionPromise() async throws {
        let fixture = try await makeFixture(policy: BurnBarMemoryEgressPolicy(enabled: true, consentedProviderIDs: ["zai"], requireNoRetention: true))
        try await assertDenied(fixture, purpose: "memory-answer", code: "EGRESS_BLOCKED_RETENTION")
    }

    func testSpentDailyCapIsDeniedWithBudgetExceeded() async throws {
        let fixture = try await makeFixture(spentTodayUSD: 3)
        try await assertDenied(fixture, purpose: "memory-rerank", code: "BUDGET_EXCEEDED")
    }

    func testScopedTokensAreRejectedOutsideMemoryPurposesAndPaths() async throws {
        let fixture = try await makeFixture()
        let token = try await mintedToken(fixture)

        let (noPurpose, _, _) = try await send(fixture, token: token, purpose: nil)
        XCTAssertEqual(noPurpose, 401, "a scoped token is not the static gateway token")

        let (wrongPath, _, _) = try await send(fixture, path: "/v1/responses", token: token, purpose: "memory-extract")
        XCTAssertEqual(wrongPath, 401, "memory purposes may only use the two proxy paths")

        let (staticWrongPath, _, _) = try await send(fixture, path: "/v1/messages", token: staticToken, purpose: "memory-extract")
        XCTAssertEqual(staticWrongPath, 401, "the path rule applies to the static token as well")

        let wrongScope = try await mintedToken(fixture, purposes: ["models"])
        let (scoped, _, _) = try await send(fixture, token: wrongScope, purpose: "memory-extract")
        XCTAssertEqual(scoped, 401)

        let (unknownPurpose, _, _) = try await send(fixture, token: token, purpose: "memory-anything")
        XCTAssertEqual(unknownPurpose, 401, "an unknown purpose header falls back to static-token auth")

        XCTAssertTrue(fixture.upstream.recordedRequests.isEmpty)
        let entries = try await logEntries(fixture)
        XCTAssertTrue(entries.isEmpty, "auth refusals happen before the policy gate and are not chained")
    }

    func testMissingEnforcerRefusesMemoryPurposeInsteadOfProxying() async throws {
        let fixture = try await makeFixture(withEnforcer: false)
        let (status, headers, object) = try await send(fixture, token: staticToken, purpose: "memory-extract")
        XCTAssertEqual(status, 403)
        XCTAssertEqual(headers["content-type"], "application/json")
        XCTAssertEqual(errorCode(object), "CLOUD_CONSENT_REQUIRED")
        XCTAssertTrue(fixture.upstream.recordedRequests.isEmpty, "no enforcer means nothing leaves the machine")

        // Ordinary traffic with the static token still proxies.
        let (plain, _, plainObject) = try await send(fixture, token: staticToken, purpose: nil)
        XCTAssertEqual(plain, 200, "\(plainObject)")
        XCTAssertEqual(fixture.upstream.recordedRequests.count, 1)
    }

    func testForbiddenStatusLineUsesTheForbiddenReasonPhrase() async throws {
        let fixture = try await makeFixture(proActive: false)
        let token = try await mintedToken(fixture)
        let head = "POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1:\(fixture.harness.port)\r\nAuthorization: Bearer \(token)\r\nX-OpenBurnBar-Purpose: memory-extract\r\nContent-Type: application/json\r\nContent-Length: \(chatBody.utf8.count)\r\nConnection: close\r\n\r\n"
        let response = try await LinuxHTTPClient.raw(port: fixture.harness.port, request: head + chatBody)
        XCTAssertTrue(response.rawText.hasPrefix("HTTP/1.1 403 Forbidden"), response.rawText)
        XCTAssertEqual(response.headers["content-type"], "application/json")
    }
}

/// Test double for the membership service; the Linux gateway test target
/// cannot see the Darwin package tests' `FakeMembershipService`.
struct LinuxFakeMembershipService: BurnBarMembershipServing {
    let active: Bool
    let now: Date

    func status() async -> BurnBarMembershipStatusResponse {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return BurnBarMembershipStatusResponse(membership: BurnBarMembershipSnapshot(
            tier: active ? "pro" : "free",
            entitlementIds: active ? ["burnbar_pro"] : [],
            restoreAvailable: true,
            state: active ? .active : .offline,
            daemonCacheKey: "entitlements/test",
            source: "local_cache",
            updatedAt: formatter.string(from: now)
        ))
    }

    func checkoutURL(_ request: BurnBarMembershipCheckoutURLRequest) async throws -> BurnBarMembershipCheckoutURLResponse {
        throw BurnBarMembershipServiceError.unauthenticated
    }

    func portalURL(_ request: BurnBarMembershipPortalURLRequest) async throws -> BurnBarMembershipPortalURLResponse {
        throw BurnBarMembershipServiceError.unauthenticated
    }

    func restore() async -> BurnBarMembershipRestoreResponse {
        BurnBarMembershipRestoreResponse(ok: false, error: BurnBarMembershipErrorResult(code: .offline, message: "test"))
    }
}
#endif
