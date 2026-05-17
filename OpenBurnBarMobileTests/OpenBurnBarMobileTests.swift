import XCTest
import CryptoKit
import OpenBurnBarCore
import OpenBurnBarIrohRelay
import OpenBurnBarMedia
@testable import OpenBurnBarMobile

@MainActor
final class OpenBurnBarMobileTests: XCTestCase {

    // MARK: - Shared Model Compatibility

    func testAgentProviderRoundTrip() {
        let provider = AgentProvider.minimax
        XCTAssertEqual(provider.displayName, "MiniMax")
        XCTAssertEqual(provider.persistedToken, "minimax")
        XCTAssertEqual(AgentProvider.fromPersistedToken("minimax"), .minimax)
        XCTAssertNil(AgentProvider.fromPersistedToken("unknown"))
    }

    func testTokenUsageCodable() throws {
        let usage = TokenUsage(
            provider: .claudeCode,
            sessionId: "sess-1",
            projectName: "Test",
            model: "claude-3",
            inputTokens: 100,
            outputTokens: 50,
            costUSD: 0.01,
            startTime: Date(),
            endTime: Date()
        )
        let data = try JSONEncoder().encode(usage)
        let decoded = try JSONDecoder().decode(TokenUsage.self, from: data)
        XCTAssertEqual(decoded.provider, usage.provider)
        XCTAssertEqual(decoded.totalTokens, 150)
        XCTAssertEqual(decoded.cost, 0.01)
    }

    // MARK: - Stream Session Projection

    func testActivityStoreSummarizesRawUsageRowsBySession() throws {
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        let kimiRows = (0..<40).map { index in
            makeUsage(
                provider: .kimi,
                sessionId: "kimi-flood",
                model: index < 30 ? "kimi-for-coding" : "kimi-auditor",
                inputTokens: 100 + index,
                outputTokens: 50,
                costUSD: 1,
                startTime: now.addingTimeInterval(Double(index) * 30),
                endTime: now.addingTimeInterval(Double(index) * 30 + 20)
            )
        }
        let codex = makeUsage(
            provider: .codex,
            sessionId: "codex-visible",
            model: "gpt-5.4-codex",
            inputTokens: 500,
            outputTokens: 250,
            costUSD: 2.5,
            startTime: now.addingTimeInterval(2_000),
            endTime: now.addingTimeInterval(2_200)
        )

        let summaries = ActivityStore.summarizeSessions(kimiRows + [codex])

        XCTAssertEqual(summaries.map(\.sessionId), ["codex-visible", "kimi-flood"])
        let kimi = try XCTUnwrap(summaries.first { $0.sessionId == "kimi-flood" })
        XCTAssertEqual(kimi.cost, 40, accuracy: 0.0001)
        XCTAssertEqual(kimi.inputTokens, kimiRows.reduce(0) { $0 + $1.inputTokens })
        XCTAssertEqual(kimi.outputTokens, 2_000)
        XCTAssertEqual(kimi.totalTokens, kimi.inputTokens + kimi.outputTokens)
        XCTAssertEqual(kimi.model, "kimi-for-coding")
        XCTAssertEqual(kimi.startTime, kimiRows.first?.startTime)
        XCTAssertEqual(kimi.endTime, kimiRows.last?.endTime)
    }

    func testActivityStoreDoesNotCollapseBlankSessionIds() {
        let now = Date(timeIntervalSinceReferenceDate: 20_000)
        let rows = [
            makeUsage(provider: .factory, sessionId: "", model: "factory-a", startTime: now, endTime: now),
            makeUsage(provider: .factory, sessionId: "  ", model: "factory-b", startTime: now, endTime: now)
        ]

        let summaries = ActivityStore.summarizeSessions(rows)

        XCTAssertEqual(summaries.count, 2)
    }

    func testActivityStoreSortsSummariesByLatestActivity() {
        let now = Date(timeIntervalSinceReferenceDate: 30_000)
        let older = makeUsage(
            provider: .claudeCode,
            sessionId: "older",
            model: "claude",
            startTime: now,
            endTime: now.addingTimeInterval(10)
        )
        let newer = makeUsage(
            provider: .factory,
            sessionId: "newer",
            model: "factory",
            startTime: now.addingTimeInterval(100),
            endTime: now.addingTimeInterval(120)
        )

        let summaries = ActivityStore.summarizeSessions([older, newer])

        XCTAssertEqual(summaries.map(\.sessionId), ["newer", "older"])
    }

    func testProviderQuotaBucketProgress() {
        let bucket = ProviderQuotaBucket(
            name: "Tokens",
            used: 75,
            limit: 100,
            remaining: 25,
            window: "monthly"
        )
        XCTAssertEqual(bucket.used / bucket.limit, 0.75, accuracy: 0.001)
        XCTAssertEqual((bucket.remaining / bucket.limit) * 100, 25, accuracy: 0.001)
    }

    func testUsageRollupDocCodable() throws {
        let doc = UsageRollupDoc(
            windowKey: .today,
            totals: RollupTotals(requests: 10, tokens: 1000, costUsd: 0.50),
            providerSummaries: [
                RollupProviderSummary(provider: "minimax", totalRequests: 5, totalTokens: 500)
            ],
            modelSummaries: [],
            deviceSummaries: [],
            dailyPoints: [RollupDailyPoint(date: Date(), value: 1000)],
            computedAt: Date(),
            schemaVersion: 1
        )
        let data = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(UsageRollupDoc.self, from: data)
        XCTAssertEqual(decoded.windowKey, .today)
        XCTAssertEqual(decoded.totals.tokens, 1000)
    }

    // MARK: - Computer Use Agent Watch

    func testAgentWatchOverlayCoordinatorClassifiesApprovalStreamAndResponds() async throws {
        let uid = "user-agent-watch"
        let connectionID = "relay-connection-1"
        let stream = AgentWatchFakeStream()
        let authorityPublisher = AgentWatchFakeAuthorityPublisher()
        let coordinator = AgentWatchOverlayCoordinator(
            dialer: { dialedUID, dialedConnectionID, relayPublicKey in
                XCTAssertEqual(dialedUID, uid)
                XCTAssertEqual(dialedConnectionID, connectionID)
                XCTAssertEqual(relayPublicKey, Data(repeating: 7, count: 32))
                return stream
            },
            authorityPublisher: authorityPublisher,
            initialBackoff: 0.01,
            maxBackoff: 0.01
        )
        defer {
            Task { await coordinator.stop() }
        }

        coordinator.start(
            uid: uid,
            connectionID: connectionID,
            relayPublicKey: Data(repeating: 7, count: 32)
        )

        let classifyFrame = try await waitForFrame(
            from: stream,
            matching: { $0.type == .controlClassify }
        )
        XCTAssertEqual(classifyFrame.uid, uid)
        XCTAssertEqual(classifyFrame.connectionId, connectionID)
        XCTAssertEqual(classifyFrame.control?.streamClass, MediaStreamClass.controlInput.rawValue)
        XCTAssertNotNil(classifyFrame.control?.authorityPeerNodeId)
        XCTAssertNil(classifyFrame.control?.authorityPublicKeyBase64)
        let publishedAuthorities = await authorityPublisher.published()
        XCTAssertEqual(publishedAuthorities.count, 1)
        XCTAssertEqual(publishedAuthorities.first?.uid, uid)
        XCTAssertEqual(publishedAuthorities.first?.connectionId, connectionID)
        XCTAssertEqual(publishedAuthorities.first?.peerNodeId, classifyFrame.control?.authorityPeerNodeId)

        let approval = HermesRealtimeRelayApprovalRequest(
            approvalId: "approval-1",
            runId: "run-1",
            sessionId: "session-1",
            toolKind: "mac.input.click",
            title: "Approve click",
            message: "Click Submit",
            beforeScreenshotBlake3: "abc123",
            actionSummary: "Click Submit",
            requestedAt: Date(timeIntervalSince1970: 1_000)
        )
        await stream.pushInbound(HermesRealtimeRelayFrame(
            type: .controlApprovalRequest,
            uid: uid,
            connectionId: connectionID,
            control: HermesRealtimeRelayControlPayload(
                streamClass: MediaStreamClass.controlApproval.rawValue,
                sessionId: approval.sessionId,
                approvalRequest: approval
            )
        ))

        try await waitForCondition {
            coordinator.state.pendingApproval?.approvalId == approval.approvalId
        }
        XCTAssertEqual(coordinator.state.sessionId?.rawValue, approval.sessionId)

        try await coordinator.receiver?.approve(approval)

        let responseFrame = try await waitForFrame(
            from: stream,
            matching: { $0.type == .controlApprovalResponse }
        )
        XCTAssertEqual(responseFrame.uid, uid)
        XCTAssertEqual(responseFrame.connectionId, connectionID)
        XCTAssertEqual(responseFrame.control?.streamClass, MediaStreamClass.controlApproval.rawValue)
        XCTAssertEqual(responseFrame.control?.sessionId, approval.sessionId)
        XCTAssertEqual(responseFrame.control?.approvalResponse?.approvalId, approval.approvalId)
        XCTAssertEqual(responseFrame.control?.approvalResponse?.decision, .approve)
        XCTAssertNil(coordinator.state.pendingApproval)
    }

    // MARK: - Formatting

    func testCostFormatting() {
        XCTAssertEqual(1.5.formatAsCost(), "$1.50")
        XCTAssertEqual(0.0.formatAsCost(), "$0.00")
        XCTAssertEqual(1234.5.formatAsCost(), "$1,234.50")
        XCTAssertEqual(1_500_000.0.formatAsCost(), "$1,500,000.00")
    }

    func testCostCompactFormatting() {
        XCTAssertEqual(1.5.formatAsCostCompact(), "$1.50")
        XCTAssertEqual(1234.5.formatAsCostCompact(), "$1,234.50")
    }

    func testTokenFormatting() {
        XCTAssertEqual(1500.formatAsTokens(), "1.5K")
        XCTAssertEqual(1_500_000.formatAsTokens(), "1.5M")
        XCTAssertEqual(1_500_000_000.formatAsTokens(), "1.50B")
        XCTAssertEqual(500.formatAsTokens(), "500")
        XCTAssertEqual(1234.formatAsTokens(), "1.2K")
    }

    func testTokenRawFormatting() {
        XCTAssertEqual(500.formatAsTokensRaw(), "500")
        XCTAssertEqual(1234.formatAsTokensRaw(), "1,234")
        XCTAssertEqual(1_500_000.formatAsTokensRaw(), "1,500,000")
    }

    // MARK: - Provider Connection Types

    func testProviderConnectionStatusRawValue() {
        XCTAssertEqual(ProviderConnectionStatus.connected.rawValue, "connected")
        XCTAssertEqual(ProviderConnectionStatus.error.rawValue, "error")
    }

    func testMobileDeviceIdentityPersistsGeneratedDeviceId() throws {
        let suiteName = "com.openburnbar.mobile.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removeObject(forKey: MobileDeviceIdentity.deviceIDKey)
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }

        let first = MobileDeviceIdentity.loadOrCreateDeviceId(defaults: defaults)
        let second = MobileDeviceIdentity.loadOrCreateDeviceId(defaults: defaults)

        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first, second)
        XCTAssertEqual(defaults.string(forKey: MobileDeviceIdentity.deviceIDKey), first)
    }

    // MARK: - Self-hosted Runner Delete Cleanup

    func testSelfHostedRunnerStoreDeleteRemovesURLAndSecret() throws {
        let store = SelfHostedQuotaRunnerStore()
        try store.save(accountID: "cleanup-test", runnerURL: "https://runner.example.com", accessSecret: "secret123")
        XCTAssertNotNil(SelfHostedQuotaRunnerStore.validatedRunnerURL("https://runner.example.com"))

        store.delete(accountID: "cleanup-test")
        // After deletion, reloading the URL should fail
        let defaults = UserDefaults.standard
        XCTAssertNil(defaults.string(forKey: "selfHostedQuotaRunnerURL.cleanup-test"))
    }

    // MARK: - Self-hosted Runner URL Validation

    func testValidatedRunnerURLAcceptsHTTPS() {
        XCTAssertNotNil(SelfHostedQuotaRunnerStore.validatedRunnerURL("https://runner.example.com"))
        XCTAssertNotNil(SelfHostedQuotaRunnerStore.validatedRunnerURL("  https://runner.example.com/path  "))
    }

    func testValidatedRunnerURLAcceptsLocalhost() {
        XCTAssertNotNil(SelfHostedQuotaRunnerStore.validatedRunnerURL("http://localhost:8080"))
        XCTAssertNotNil(SelfHostedQuotaRunnerStore.validatedRunnerURL("http://127.0.0.1:3000"))
    }

    func testValidatedRunnerURLRejectsInvalidSchemes() {
        XCTAssertNil(SelfHostedQuotaRunnerStore.validatedRunnerURL("ftp://runner.example.com"))
        XCTAssertNil(SelfHostedQuotaRunnerStore.validatedRunnerURL("http://192.168.1.1"))
        XCTAssertNil(SelfHostedQuotaRunnerStore.validatedRunnerURL(""))
        XCTAssertNil(SelfHostedQuotaRunnerStore.validatedRunnerURL("not-a-url"))
    }

    private func waitForFrame(
        from stream: AgentWatchFakeStream,
        matching predicate: @escaping (HermesRealtimeRelayFrame) -> Bool,
        timeout: TimeInterval = 2
    ) async throws -> HermesRealtimeRelayFrame {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let frame = await stream.sentFrames().first(where: predicate) {
                return frame
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for Agent Watch frame")
        throw NSError(domain: "AgentWatchOverlayCoordinatorTests", code: 1)
    }

    private func waitForCondition(
        timeout: TimeInterval = 2,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for Agent Watch condition")
        throw NSError(domain: "AgentWatchOverlayCoordinatorTests", code: 2)
    }

    private func makeUsage(
        provider: AgentProvider,
        sessionId: String,
        model: String,
        inputTokens: Int = 100,
        outputTokens: Int = 50,
        costUSD: Double = 1,
        startTime: Date,
        endTime: Date
    ) -> TokenUsage {
        TokenUsage(
            provider: provider,
            sessionId: sessionId,
            projectName: "Project",
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            costUSD: costUSD,
            startTime: startTime,
            endTime: endTime
        )
    }
}

private actor AgentWatchFakeStream: IrohRelayStream {
    private var inboundFrames: [HermesRealtimeRelayFrame] = []
    private var outboundFrames: [HermesRealtimeRelayFrame] = []
    private var receiveWaiter: CheckedContinuation<HermesRealtimeRelayFrame?, Error>?
    private var isClosed = false

    func send(_ frame: HermesRealtimeRelayFrame) async throws {
        outboundFrames.append(frame)
    }

    func receive() async throws -> HermesRealtimeRelayFrame? {
        if !inboundFrames.isEmpty { return inboundFrames.removeFirst() }
        if isClosed { return nil }
        return try await withCheckedThrowingContinuation { continuation in
            receiveWaiter = continuation
        }
    }

    func close() async {
        isClosed = true
        receiveWaiter?.resume(returning: nil)
        receiveWaiter = nil
    }

    func pushInbound(_ frame: HermesRealtimeRelayFrame) {
        if let receiveWaiter {
            self.receiveWaiter = nil
            receiveWaiter.resume(returning: frame)
            return
        }
        inboundFrames.append(frame)
    }

    func sentFrames() -> [HermesRealtimeRelayFrame] {
        outboundFrames
    }
}

private actor AgentWatchFakeAuthorityPublisher: PhoneControlAuthorityPublishing {
    struct Published: Equatable {
        let uid: String
        let connectionId: String
        let deviceId: String
        let peerNodeId: String
        let publicKeyData: Data
    }

    private var values: [Published] = []

    func publish(
        uid: String,
        connectionId: String,
        deviceId: String,
        peerNodeId: String,
        publicKey: Curve25519.Signing.PublicKey
    ) async throws {
        values.append(Published(
            uid: uid,
            connectionId: connectionId,
            deviceId: deviceId,
            peerNodeId: peerNodeId,
            publicKeyData: publicKey.rawRepresentation
        ))
    }

    func published() -> [Published] {
        values
    }
}
