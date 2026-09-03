import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

/// Memory-purpose requests on the loopback gateway: the embeddings route,
/// scoped tokens, the policy gate, OpenRouter's no-retention flag, the
/// upstream model name, and the egress log.
final class BurnBarHTTPGatewayServerMemoryEgressTests: XCTestCase {
    private let staticToken = "static-gateway-token"

    override func setUp() {
        super.setUp()
        GatewayUpstreamURLProtocol.reset()
    }

    override func tearDown() {
        GatewayUpstreamURLProtocol.reset()
        super.tearDown()
    }

    private struct Fixture {
        let harness: GatewayHarness
        let enforcer: BurnBarMemoryEgressEnforcer
        let logURL: URL
    }

    private func makeFixture(
        proActive: Bool = true,
        policy: BurnBarMemoryEgressPolicy = BurnBarMemoryEgressPolicy(enabled: true, consentedProviderIDs: ["openrouter"], requireNoRetention: true, dailyCapUSD: 2),
        spentTodayUSD: Double = 0
    ) async throws -> Fixture {
        let session = GatewayHarness.makeUpstreamSession()
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-egress-gateway-\(UUID().uuidString).jsonl", isDirectory: false)
        var enforcerSlot: BurnBarMemoryEgressEnforcer?
        let harness = try GatewayHarness(
            authToken: staticToken,
            providerExecutor: BurnBarOpenAICompatibleProviderExecutor(session: session),
            memoryEgress: { configStore, _ in
                let enforcer = BurnBarMemoryEgressEnforcer(
                    configStore: configStore,
                    membership: FakeMembershipService(active: proActive, now: Date()),
                    tokenStore: BurnBarGatewayScopedTokenStore(),
                    log: BurnBarMemoryEgressLogStore(fileURL: logURL),
                    spentTodayUSD: { _ in spentTodayUSD },
                    now: Date.init
                )
                enforcerSlot = enforcer
                return enforcer
            }
        )
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "openrouter",
                isEnabled: true,
                baseURL: "https://gateway-upstream.test/openrouter/v1",
                preferredModelIDs: ["openrouter-anthropic-claude-opus-5", "openrouter-openai-text-embedding-3-small"],
                preferredCredentialSlotID: "primary"
            )
        )
        _ = try await harness.configStore.upsertCredentialSlot(providerID: "openrouter", slotID: "primary", label: "Primary", apiKey: "openrouter-key")
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "vercel-ai-gateway",
                isEnabled: true,
                baseURL: "https://gateway-upstream.test/vercel/v1",
                preferredModelIDs: ["vercel-anthropic-claude-opus-5"],
                preferredCredentialSlotID: "primary"
            )
        )
        _ = try await harness.configStore.upsertCredentialSlot(providerID: "vercel-ai-gateway", slotID: "primary", label: "Primary", apiKey: "vercel-key")
        var snapshot = try await harness.configStore.snapshot()
        snapshot.memoryEgress = policy
        _ = try await harness.configStore.replaceSnapshot(snapshot)
        try await harness.start()
        addTeardownBlock { await harness.stop() }
        return Fixture(harness: harness, enforcer: try XCTUnwrap(enforcerSlot), logURL: logURL)
    }

    /// The harness runs with a zero catalog cache, so every request first
    /// probes each candidate provider's live `/v1/models`. Answer those probes
    /// with the vendor-namespaced ids the aggregators advertise.
    private func enqueueProviderCatalogs() {
        let rows = ["anthropic/claude-opus-5", "anthropic/claude-haiku-4-5", "openai/gpt-5.5", "openai/text-embedding-3-small"]
            .map { #"{"id":"\#($0)","object":"model"}"# }
            .joined(separator: ",")
        for path in ["/openrouter/v1/models", "/vercel/v1/models"] {
            GatewayUpstreamURLProtocol.enqueue(status: 200, body: #"{"object":"list","data":[\#(rows)]}"#, path: path)
            GatewayUpstreamURLProtocol.enqueue(status: 200, body: #"{"object":"list","data":[\#(rows)]}"#, path: path)
        }
    }

    private func send(
        port: Int,
        path: String,
        token: String,
        purpose: String?,
        body: String
    ) async throws -> (Int, [String: Any]) {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let purpose {
            request.setValue(purpose, forHTTPHeaderField: "X-OpenBurnBar-Purpose")
        }
        request.httpBody = Data(body.utf8)
        enqueueProviderCatalogs()
        var lastError: Error?
        for _ in 0..<10 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let http = try XCTUnwrap(response as? HTTPURLResponse)
                let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                return (http.statusCode, object)
            } catch {
                lastError = error
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        throw lastError ?? URLError(.cannotConnectToHost)
    }

    private func mintedToken(_ fixture: Fixture, purposes: Set<String> = Set(BurnBarMemoryEgressPolicy.purposes)) async -> String {
        await fixture.enforcer.tokenStore.mint(purposes: purposes).token
    }

    private func errorCode(_ object: [String: Any]) -> String? {
        (object["error"] as? [String: Any])?["code"] as? String
    }

    private func logEntries(_ fixture: Fixture) async throws -> [BurnBarMemoryEgressEntry] {
        try await BurnBarMemoryEgressLogStore(fileURL: fixture.logURL).entries()
    }

    func test_embeddingsRouteProxiesWithTheStaticTokenAndRecordsUsage() async throws {
        let fixture = try await makeFixture()
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: #"{"object":"list","data":[{"object":"embedding","index":0,"embedding":[0.1,0.2]}],"model":"openai/text-embedding-3-small","usage":{"prompt_tokens":7,"total_tokens":7}}"#
        )
        let (status, object) = try await send(
            port: fixture.harness.port,
            path: "/v1/embeddings",
            token: staticToken,
            purpose: nil,
            body: #"{"model":"openrouter/openai/text-embedding-3-small","input":["hello"]}"#
        )
        XCTAssertEqual(status, 200)
        XCTAssertEqual(((object["data"] as? [[String: Any]])?.first?["embedding"] as? [Double])?.count, 2)
        let upstream = try XCTUnwrap(GatewayUpstreamURLProtocol.recordedRequests().last { $0.path.hasSuffix("/embeddings") })
        XCTAssertTrue(upstream.path.hasSuffix("/openrouter/v1/embeddings"), upstream.path)
        XCTAssertEqual(upstream.authorization, "Bearer openrouter-key")
        let upstreamBody = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(upstream.body.utf8)) as? [String: Any])
        XCTAssertEqual(upstreamBody["model"] as? String, "openai/text-embedding-3-small", "the vendor-namespaced alias goes upstream, never the unique catalog id")
        XCTAssertEqual((upstreamBody["provider"] as? [String: Any])?["data_collection"] as? String, "deny")
        let spent = try await fixture.harness.usageRecorder.sumCost(since: Date().addingTimeInterval(-3_600)) { _ in true }
        XCTAssertGreaterThan(spent, 0)
    }

    func test_memoryPurposeWithScopedTokenIsAllowedAndLogged() async throws {
        let fixture = try await makeFixture()
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: #"{"id":"chatcmpl-1","object":"chat.completion","model":"anthropic/claude-opus-5","choices":[{"index":0,"message":{"role":"assistant","content":"{\"facts\":[]}"},"finish_reason":"stop"}],"usage":{"prompt_tokens":12,"completion_tokens":4,"total_tokens":16}}"#
        )
        let token = await mintedToken(fixture)
        let (status, _) = try await send(
            port: fixture.harness.port,
            path: "/v1/chat/completions",
            token: token,
            purpose: "memory-extract",
            body: #"{"model":"openrouter/anthropic/claude-opus-5","messages":[{"role":"user","content":"hi"}]}"#
        )
        XCTAssertEqual(status, 200)
        let upstream = try XCTUnwrap(GatewayUpstreamURLProtocol.recordedRequests().last { $0.path.hasSuffix("/chat/completions") })
        let upstreamBody = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(upstream.body.utf8)) as? [String: Any])
        XCTAssertEqual(upstreamBody["model"] as? String, "anthropic/claude-opus-5")
        XCTAssertEqual((upstreamBody["provider"] as? [String: Any])?["data_collection"] as? String, "deny")
        let entries = try await logEntries(fixture)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].outcome, "allowed")
        XCTAssertEqual(entries[0].purpose, "memory-extract")
        XCTAssertEqual(entries[0].providerID, "openrouter")
        XCTAssertGreaterThan(entries[0].responseBytes, 0)
        let memoryProSpend = try await fixture.harness.usageRecorder.sumCost(since: Date().addingTimeInterval(-3_600)) {
            $0.executionSourceID == BurnBarMemoryEgressEnforcer.executionSource.id
        }
        XCTAssertGreaterThan(memoryProSpend, 0)
    }

    func test_memoryPurposeRequestsNeverShortCircuitToFusion() async throws {
        let fixture = try await makeFixture()
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: #"{"id":"chatcmpl-2","object":"chat.completion","model":"anthropic/claude-opus-5","choices":[{"index":0,"message":{"role":"assistant","content":"ok"}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}"#
        )
        let token = await mintedToken(fixture)
        let (status, _) = try await send(
            port: fixture.harness.port,
            path: "/v1/chat/completions",
            token: token,
            purpose: "memory-extract",
            body: #"{"model":"openrouter/anthropic/claude-opus-5","plugins":[{"id":"fusion"}],"messages":[{"role":"user","content":"hi"}]}"#
        )
        XCTAssertEqual(status, 200)
        let entries = try await BurnBarMemoryEgressLogStore(fileURL: fixture.logURL).entries()
        XCTAssertEqual(entries.last?.outcome, "allowed", "the enforcer saw the request; fusion never ran it")
        XCTAssertEqual(entries.last?.purpose, "memory-extract")
    }

    func test_upstreamFailuresAreRecordedInTheEgressChain() async throws {
        let fixture = try await makeFixture()
        GatewayUpstreamURLProtocol.enqueue(status: 500, body: #"{"error":{"message":"boom"}}"#)
        let token = await mintedToken(fixture)
        let (status, _) = try await send(
            port: fixture.harness.port,
            path: "/v1/chat/completions",
            token: token,
            purpose: "memory-extract",
            body: #"{"model":"openrouter/anthropic/claude-opus-5","messages":[{"role":"user","content":"hi"}]}"#
        )
        XCTAssertNotEqual(status, 200)
        let entries = try await BurnBarMemoryEgressLogStore(fileURL: fixture.logURL).entries()
        let failed = try XCTUnwrap(entries.first { $0.outcome == "failed" }, "a request that left the Mac and failed is still chained")
        XCTAssertEqual(failed.purpose, "memory-extract")
        XCTAssertEqual(failed.providerID, "openrouter")
        XCTAssertTrue((failed.code ?? "").hasPrefix("UPSTREAM"), failed.code ?? "nil")
        let store = BurnBarMemoryEgressLogStore(fileURL: fixture.logURL)
        let verification = try await store.verify()
        XCTAssertTrue(verification.ok, "chain broken at \(String(describing: verification.brokenAtSeq))")
    }

    func test_policyDenialsReturn403WithTheCodeAndAreLogged() async throws {
        let stale = try await makeFixture(proActive: false)
        let token = await mintedToken(stale)
        let body = #"{"model":"openrouter/anthropic/claude-opus-5","messages":[{"role":"user","content":"hi"}]}"#
        var (status, object) = try await send(port: stale.harness.port, path: "/v1/chat/completions", token: token, purpose: "memory-judge", body: body)
        XCTAssertEqual(status, 403)
        XCTAssertEqual(errorCode(object), "PRO_REQUIRED")
        XCTAssertTrue(GatewayUpstreamURLProtocol.recordedRequests().allSatisfy { $0.path.hasSuffix("/models") }, "a denied request never reaches the provider")
        var entries = try await logEntries(stale)
        XCTAssertEqual(entries.last?.code, "PRO_REQUIRED")
        XCTAssertEqual(entries.last?.outcome, "denied")

        let unconsented = try await makeFixture(policy: BurnBarMemoryEgressPolicy(enabled: true, consentedProviderIDs: ["openrouter"], requireNoRetention: true))
        (status, object) = try await send(port: unconsented.harness.port, path: "/v1/chat/completions", token: await mintedToken(unconsented), purpose: "memory-answer",
                                          body: #"{"model":"vercel-ai-gateway/anthropic/claude-opus-5","messages":[{"role":"user","content":"hi"}]}"#)
        XCTAssertEqual(status, 403)
        XCTAssertEqual(errorCode(object), "PROVIDER_NOT_CONSENTED")

        let retention = try await makeFixture(policy: BurnBarMemoryEgressPolicy(enabled: true, consentedProviderIDs: ["openrouter", "vercel-ai-gateway"], requireNoRetention: true))
        (status, object) = try await send(port: retention.harness.port, path: "/v1/chat/completions", token: await mintedToken(retention), purpose: "memory-answer",
                                          body: #"{"model":"vercel-ai-gateway/anthropic/claude-opus-5","messages":[{"role":"user","content":"hi"}]}"#)
        XCTAssertEqual(status, 403)
        XCTAssertEqual(errorCode(object), "EGRESS_BLOCKED_RETENTION")

        let broke = try await makeFixture(spentTodayUSD: 3)
        (status, object) = try await send(port: broke.harness.port, path: "/v1/chat/completions", token: await mintedToken(broke), purpose: "memory-rerank", body: body)
        XCTAssertEqual(status, 403)
        XCTAssertEqual(errorCode(object), "BUDGET_EXCEEDED")
        entries = try await logEntries(broke)
        XCTAssertEqual(entries.count, 1)
    }

    func test_scopedTokensAreRejectedOutsideMemoryPurposesAndPaths() async throws {
        let fixture = try await makeFixture()
        let token = await mintedToken(fixture)
        let body = #"{"model":"openrouter/anthropic/claude-opus-5","messages":[{"role":"user","content":"hi"}]}"#
        let (noPurpose, _) = try await send(port: fixture.harness.port, path: "/v1/chat/completions", token: token, purpose: nil, body: body)
        XCTAssertEqual(noPurpose, 401)
        let (wrongPath, _) = try await send(port: fixture.harness.port, path: "/v1/responses", token: token, purpose: "memory-extract", body: body)
        XCTAssertEqual(wrongPath, 401)
        let expired = await fixture.enforcer.tokenStore.mint(purposes: ["models"]).token
        let (wrongScope, _) = try await send(port: fixture.harness.port, path: "/v1/chat/completions", token: expired, purpose: "memory-extract", body: body)
        XCTAssertEqual(wrongScope, 401)
        XCTAssertTrue(GatewayUpstreamURLProtocol.recordedRequests().allSatisfy { $0.path.hasSuffix("/models") })
    }

    func test_buffered403UsesTheForbiddenStatusText() async throws {
        let fixture = try await makeFixture(proActive: false)
        let token = await mintedToken(fixture)
        let body = #"{"model":"openrouter/anthropic/claude-opus-5","messages":[{"role":"user","content":"hi"}]}"#
        let head = "POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer \(token)\r\nX-OpenBurnBar-Purpose: memory-extract\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        let (status, headers, _) = try sendRaw(port: fixture.harness.port, request: head + body)
        XCTAssertEqual(status, "HTTP/1.1 403 Forbidden")
        XCTAssertEqual(headers["content-type"], "application/json")
    }

    private func sendRaw(port: Int, request: String) throws -> (status: String, headers: [String: String], body: String) {
        enqueueProviderCatalogs()
        let socket = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { throw URLError(.cannotConnectToHost) }
        var receiveTimeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))
        _ = request.withCString { Darwin.send(socket, $0, strlen($0), 0) }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var received = Data()
        while true {
            let count = recv(socket, &buffer, buffer.count, 0)
            if count <= 0 { break }
            received.append(buffer, count: count)
        }
        let text = String(decoding: received, as: UTF8.self)
        let parts = text.components(separatedBy: "\r\n\r\n")
        let headLines = parts.first?.components(separatedBy: "\r\n") ?? []
        var headers: [String: String] = [:]
        for line in headLines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2 { headers[pair[0].lowercased()] = pair[1] }
        }
        return (headLines.first ?? "", headers, parts.dropFirst().joined(separator: "\r\n\r\n"))
    }
}
