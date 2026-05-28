import XCTest
import CryptoKit
import OpenBurnBarComputerUseCore
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
        XCTAssertEqual(AgentProvider.fromPersistedToken("claude-code"), .claudeCode)
        XCTAssertEqual(AgentProvider.fromPersistedToken("Claude Code"), .claudeCode)
        XCTAssertEqual(AgentProvider.fromPersistedToken("open-code"), .openCode)
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

    func testRemoteUnlockCredentialStoreKeyPrefersStableRecipientKey() {
        let state = makeRemoteUnlockState(credentialRecipientKeyId: " recipient-key-1 ")

        let key = RemoteUnlockCredentialStoreKey.make(
            state: state,
            phoneControlConnectionID: "control-route-older",
            mirrorConnectionID: "mirror-route-newer",
            mirrorRequestID: "request-1"
        )

        XCTAssertEqual(key, "recipient-key-1")
    }

    func testRemoteUnlockCredentialStoreKeyFallsBackToConnectionIdentifiers() {
        XCTAssertEqual(
            RemoteUnlockCredentialStoreKey.make(
                state: nil,
                phoneControlConnectionID: " control-route ",
                mirrorConnectionID: "mirror-route",
                mirrorRequestID: "request-1"
            ),
            "control-route"
        )
        XCTAssertEqual(
            RemoteUnlockCredentialStoreKey.make(
                state: nil,
                phoneControlConnectionID: " ",
                mirrorConnectionID: " mirror-route ",
                mirrorRequestID: "request-1"
            ),
            "mirror-route"
        )
        XCTAssertEqual(
            RemoteUnlockCredentialStoreKey.make(
                state: nil,
                phoneControlConnectionID: nil,
                mirrorConnectionID: " ",
                mirrorRequestID: " request-1 "
            ),
            "request-1"
        )
    }

    func testMercuryReceiverInstallIsRetainedByRelayTransport() {
        let transport = HermesIrohRelayTransport(
            directory: InMemoryIrohPairingDirectory(),
            pairingPublicKeyProvider: MobileFakeIrohPairingPublicKeyProvider(),
            auditLogger: MobileNoopIrohTransportAuditLogger(),
            transportFactory: { _ in MobileNoopIrohRelayTransport() }
        )

        do {
            let receiver = iOSFileTransferService(
                service: MediaFileTransferService(
                    backend: MobileFakeIrohBlobBackend(),
                    configuration: MediaFileTransferService.Configuration(
                        storeDirectoryURL: FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString, isDirectory: true),
                        inboxDirectoryURL: FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString, isDirectory: true),
                        secretKeyProvider: { Data(repeating: 0x7, count: 32) }
                    )
                ),
                settingsProvider: { true }
            )
            transport.installMediaControlStream(into: receiver)
        }

        XCTAssertTrue(transport.isMediaControlReceiverInstalledForTesting)
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
            signingKeyStore: AgentWatchFakeSigningKeyStore(),
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

    func testAgentWatchLoopbackReflectsTenActionLogEntriesWithinTwoHundredMillisecondsEach() async throws {
        let uid = "user-agent-watch-loopback"
        let connectionID = "relay-connection-loopback"
        let sessionID = "session-loopback"
        let stream = AgentWatchFakeStream()
        let coordinator = AgentWatchOverlayCoordinator(
            dialer: { _, _, _ in stream },
            signingKeyStore: AgentWatchFakeSigningKeyStore(),
            authorityPublisher: AgentWatchFakeAuthorityPublisher(),
            initialBackoff: 0.01,
            maxBackoff: 0.01
        )
        defer {
            Task { await coordinator.stop() }
        }

        coordinator.start(
            uid: uid,
            connectionID: connectionID,
            relayPublicKey: Data(repeating: 8, count: 32)
        )
        _ = try await waitForFrame(from: stream) { $0.type == .controlClassify }

        await stream.pushInbound(HermesRealtimeRelayFrame(
            type: .controlClassify,
            uid: uid,
            connectionId: connectionID,
            control: HermesRealtimeRelayControlPayload(
                streamClass: MediaStreamClass.controlActionLog.rawValue,
                sessionId: sessionID
            )
        ))
        try await waitForCondition {
            coordinator.state.sessionId?.rawValue == sessionID
        }

        var perEntryLatencies: [TimeInterval] = []
        for index in 0..<10 {
            let sentAt = Date()
            await stream.pushInbound(actionLogFrame(
                uid: uid,
                connectionID: connectionID,
                sessionID: sessionID,
                index: index
            ))
            try await waitForCondition(timeout: 0.2) {
                coordinator.state.actionTimeline.contains { $0.entryIndex == index }
            }
            perEntryLatencies.append(Date().timeIntervalSince(sentAt))
        }

        XCTAssertEqual(coordinator.state.actionTimeline.map(\.entryIndex), Array(0..<10))
        XCTAssertEqual(coordinator.state.actionTimeline.map(\.summary), (0..<10).map { "Fake agent action \($0)" })
        XCTAssertEqual(coordinator.state.actionsExecuted, 10)
        XCTAssertTrue(
            perEntryLatencies.allSatisfy { $0 <= 0.2 },
            "Expected every action-log frame to reach the phone timeline within 200 ms, got \(perEntryLatencies)"
        )
    }

    func testAgentWatchReceiverSendsSignedTapAndScrollIntents() async throws {
        let uid = "user-agent-watch-input"
        let connectionID = "relay-connection-input"
        let stream = AgentWatchFakeStream()
        let coordinator = AgentWatchOverlayCoordinator(
            dialer: { _, _, _ in stream },
            signingKeyStore: AgentWatchFakeSigningKeyStore(),
            authorityPublisher: AgentWatchFakeAuthorityPublisher(),
            initialBackoff: 0.01,
            maxBackoff: 0.01
        )
        defer {
            Task { await coordinator.stop() }
        }

        coordinator.start(
            uid: uid,
            connectionID: connectionID,
            relayPublicKey: Data(repeating: 9, count: 32)
        )
        _ = try await waitForFrame(from: stream) { $0.type == .controlClassify }

        try await coordinator.receiver?.tap(normalizedX: 0.25, normalizedY: 0.75, mouseButton: 1)
        let tapFrame = try await waitForFrame(from: stream) {
            $0.type == .controlInputIntent &&
            $0.control?.inputIntent?.kind == .tap
        }
        let tapIntent = try XCTUnwrap(tapFrame.control?.inputIntent)
        XCTAssertEqual(try XCTUnwrap(tapIntent.normalizedX), 0.25, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(tapIntent.normalizedY), 0.75, accuracy: 0.0001)
        XCTAssertEqual(tapIntent.mouseButton, 1)
        XCTAssertFalse(tapIntent.authority.peerNodeId.isEmpty)
        XCTAssertFalse(tapIntent.authority.signatureEd25519.isEmpty)

        try await coordinator.receiver?.scrollDrag(
            startNormalizedX: 0.40,
            startNormalizedY: 0.45,
            endNormalizedX: 0.40,
            endNormalizedY: 0.20
        )
        let scrollFrame = try await waitForFrame(from: stream) {
            $0.type == .controlInputIntent &&
            $0.control?.inputIntent?.kind == .scroll
        }
        let scrollIntent = try XCTUnwrap(scrollFrame.control?.inputIntent)
        XCTAssertEqual(try XCTUnwrap(scrollIntent.normalizedX), 0.40, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(scrollIntent.normalizedY), 0.45, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(scrollIntent.normalizedX2), 0.40, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(scrollIntent.normalizedY2), 0.20, accuracy: 0.0001)
        XCTAssertEqual(scrollIntent.authority.counter, tapIntent.authority.counter + 1)
        XCTAssertFalse(scrollIntent.authority.signatureEd25519.isEmpty)

        try await coordinator.receiver?.type("hello from iphone")
        let typeFrame = try await waitForFrame(from: stream) {
            $0.type == .controlInputIntent &&
            $0.control?.inputIntent?.kind == .type
        }
        let typeIntent = try XCTUnwrap(typeFrame.control?.inputIntent)
        XCTAssertEqual(typeIntent.text, "hello from iphone")
        XCTAssertEqual(typeIntent.authority.counter, scrollIntent.authority.counter + 1)
        XCTAssertFalse(typeIntent.authority.signatureEd25519.isEmpty)

        try await coordinator.receiver?.pointerClick(mouseButton: 1)
        let pointerClickFrame = try await waitForFrame(from: stream) {
            $0.type == .controlInputIntent &&
            $0.control?.inputIntent?.kind == .pointerClick
        }
        let pointerClickIntent = try XCTUnwrap(pointerClickFrame.control?.inputIntent)
        XCTAssertEqual(pointerClickIntent.mouseButton, 1)
        XCTAssertEqual(pointerClickIntent.authority.counter, typeIntent.authority.counter + 1)
        XCTAssertFalse(pointerClickIntent.authority.signatureEd25519.isEmpty)
    }

    func testPhoneControlSenderSerializesConcurrentInputIntentsBeforeWritingFrames() async throws {
        let suiteName = "PhoneControlSenderSerializes-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let key = Curve25519SigningKey(privateKey: Curve25519.Signing.PrivateKey())
        let firstFrameGate = MobileAsyncGate()
        let recorder = PhoneControlFrameOrderRecorder()
        let sender = PhoneControlSender(
            peerNodeId: "ios-phone-glass-trackpad-test",
            uid: "user-glass-trackpad-test",
            connectionId: "relay-glass-trackpad-test",
            signingKeyProvider: { key },
            userDefaults: defaults,
            frameSink: { frame in
                guard let counter = frame.control?.inputIntent?.authority.counter else {
                    return
                }
                await recorder.recordStarted(counter)
                if counter == 1 {
                    await firstFrameGate.wait()
                }
                await recorder.recordFinished(counter)
            }
        )
        let placeholder = HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: "",
            counter: 0,
            timestamp: Date(timeIntervalSince1970: 0),
            intentHashBlake3: "",
            signatureEd25519: ""
        )
        let intent = HermesRealtimeRelayInputIntent(
            kind: .pointerMove,
            normalizedX2: 12,
            normalizedY2: -7,
            authority: placeholder
        )

        let firstSend = Task { try await sender.send(intent: intent) }
        await recorder.waitForStarted(counter: 1)

        let secondSend = Task { try await sender.send(intent: intent) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let finishedBeforeGateOpen = await recorder.finishedCounters()
        XCTAssertEqual(
            finishedBeforeGateOpen,
            [],
            "A later Glass Trackpad intent must not pass a stalled earlier counter."
        )

        await firstFrameGate.open()
        let firstAuthority = try await firstSend.value
        let secondAuthority = try await secondSend.value

        XCTAssertEqual(firstAuthority.counter, 1)
        XCTAssertEqual(secondAuthority.counter, 2)
        let finishedAfterGateOpen = await recorder.finishedCounters()
        XCTAssertEqual(finishedAfterGateOpen, [1, 2])
    }

    func testPhoneControlSenderCancelsQueuedIntentBeforeItWritesAFrame() async throws {
        let suiteName = "PhoneControlSenderCancellation-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let key = Curve25519SigningKey(privateKey: Curve25519.Signing.PrivateKey())
        let firstFrameGate = MobileAsyncGate()
        let recorder = PhoneControlFrameOrderRecorder()
        let sender = PhoneControlSender(
            peerNodeId: "ios-phone-cancelled-trackpad-test",
            uid: "user-cancelled-trackpad-test",
            connectionId: "relay-cancelled-trackpad-test",
            signingKeyProvider: { key },
            userDefaults: defaults,
            frameSink: { frame in
                guard let counter = frame.control?.inputIntent?.authority.counter else {
                    return
                }
                await recorder.recordStarted(counter)
                if counter == 1 {
                    await firstFrameGate.wait()
                }
                await recorder.recordFinished(counter)
            }
        )
        let placeholder = HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: "",
            counter: 0,
            timestamp: Date(timeIntervalSince1970: 0),
            intentHashBlake3: "",
            signatureEd25519: ""
        )
        let intent = HermesRealtimeRelayInputIntent(
            kind: .pointerMove,
            normalizedX2: 8,
            normalizedY2: 3,
            authority: placeholder
        )

        let firstSend = Task { try await sender.send(intent: intent) }
        await recorder.waitForStarted(counter: 1)

        let secondSend = Task { try await sender.send(intent: intent) }
        secondSend.cancel()

        await firstFrameGate.open()
        _ = try await firstSend.value

        do {
            _ = try await secondSend.value
            XCTFail("Expected the queued Glass Trackpad intent to honor caller cancellation.")
        } catch is CancellationError {
            // Expected.
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        let startedCounters = await recorder.startedCounterValues()
        XCTAssertEqual(startedCounters, [1])
        XCTAssertEqual(defaults.object(forKey: "openburnbar.phoneControl.counter.ios-phone-cancelled-trackpad-test") as? Int, 1)
    }

    func testPhoneControlCounterAllocationIsProcessWideAcrossConcurrentCallers() async throws {
        let suiteName = "PhoneControlCounterGlobal-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let peerNodeId = "ios-phone-global-counter-test"
        let count = 200
        let counters = await withTaskGroup(of: UInt64.self, returning: [UInt64].self) { group in
            for _ in 0..<count {
                group.addTask {
                    PhoneControlSender.nextCounter(peerNodeId: peerNodeId, userDefaults: defaults)
                }
            }
            var collected: [UInt64] = []
            for await counter in group {
                collected.append(counter)
            }
            return collected
        }

        XCTAssertEqual(Set(counters).count, count)
        XCTAssertEqual(counters.sorted(), Array(UInt64(1)...UInt64(count)))
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
        let suiteName = "OpenBurnBarMobileTests.selfHosted.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let secrets = MobileFakeSelfHostedQuotaRunnerSecrets()
        let store = SelfHostedQuotaRunnerStore(defaults: defaults, secrets: secrets)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        try store.save(accountID: "cleanup-test", runnerURL: "https://runner.example.com", accessSecret: "secret123")
        XCTAssertNotNil(SelfHostedQuotaRunnerStore.validatedRunnerURL("https://runner.example.com"))
        XCTAssertEqual(secrets.savedByAccount["cleanup-test"], "secret123")

        store.delete(accountID: "cleanup-test")
        XCTAssertNil(defaults.string(forKey: "selfHostedQuotaRunnerURL.cleanup-test"))
        XCTAssertNil(secrets.savedByAccount["cleanup-test"])
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

    private func actionLogFrame(
        uid: String,
        connectionID: String,
        sessionID: String,
        index: Int
    ) -> HermesRealtimeRelayFrame {
        HermesRealtimeRelayFrame(
            type: .controlActionLogEntry,
            uid: uid,
            connectionId: connectionID,
            control: HermesRealtimeRelayControlPayload(
                streamClass: MediaStreamClass.controlActionLog.rawValue,
                sessionId: sessionID,
                actionLogEntry: HermesRealtimeRelayActionLogEntry(
                    entryIndex: index,
                    gopOrdinal: UInt32(index),
                    timestamp: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)),
                    actionKind: "browser.click",
                    summary: "Fake agent action \(index)",
                    status: .completed,
                    screenshotHashBlake3: "shot-\(index)",
                    parentEntryBlake3: "head-\(index)"
                )
            )
        )
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

    private func makeRemoteUnlockState(
        credentialRecipientKeyId: String?
    ) -> HermesRealtimeRelayRemoteUnlockState {
        HermesRealtimeRelayRemoteUnlockState(
            sessionId: "unlock-session-1",
            lockState: .loginWindow,
            backend: .appleScreenSharingLoopback,
            capabilities: HermesRealtimeRelayRemoteUnlockCapabilities(
                enabled: true,
                certificationStatus: .certified,
                activeBackend: .appleScreenSharingLoopback,
                supportedBackends: [.appleScreenSharingLoopback],
                supportedLockStates: [.loginWindow],
                allowsCredentialPaste: true,
                allowsSavedCredentialUnlock: true,
                credentialRecipientKeyId: credentialRecipientKeyId,
                credentialRecipientPublicKeyBase64: "recipient-public-key",
                credentialEnvelopeAlgorithm: RemoteUnlockPolicy.credentialEnvelopeAlgorithm
            ),
            observedAt: Date(timeIntervalSinceReferenceDate: 1_000)
        )
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

final class ScreenShareControlInputPolicyTests: XCTestCase {
    func testSingleControlTapUsesPrimaryClick() {
        XCTAssertEqual(ScreenShareControlInputPolicy.controlClickMouseButton(heldDuration: 0.08), 0)
    }

    func testLongControlPressUsesSecondaryClick() {
        XCTAssertEqual(
            ScreenShareControlInputPolicy.controlClickMouseButton(
                heldDuration: ScreenShareControlInputPolicy.rightClickHoldDuration
            ),
            1
        )
    }

    func testTrackpadTapClicksImmediatelyButDragDoesNot() {
        XCTAssertEqual(
            ScreenShareControlInputPolicy.trackpadClickMouseButton(
                heldDuration: 0.06,
                travelDistance: ScreenShareControlInputPolicy.trackpadTapTravelLimit - 0.1
            ),
            0
        )
        XCTAssertNil(
            ScreenShareControlInputPolicy.trackpadClickMouseButton(
                heldDuration: 0.06,
                travelDistance: ScreenShareControlInputPolicy.trackpadTapTravelLimit
            )
        )
    }

    func testCursorStartsCenteredAndClampsInsideVideoBounds() {
        let bounds = CGRect(x: 100, y: 50, width: 300, height: 200)

        XCTAssertEqual(
            ScreenShareControlInputPolicy.initialCursorPoint(in: bounds),
            CGPoint(x: 250, y: 150)
        )

        XCTAssertEqual(
            ScreenShareControlInputPolicy.movedCursorPoint(
                current: nil,
                delta: CGSize(width: -1_000, height: 1_000),
                bounds: bounds
            ),
            CGPoint(x: 100, y: 250)
        )
    }
}

final class ScreenShareViewerStatsMeterTests: XCTestCase {
    func testRecordsInboundBitrateOverRollingWindow() {
        var meter = ScreenShareViewerStatsMeter(minimumSampleInterval: 0.5)
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        let first = meter.recordFrame(
            byteCount: 500_000,
            now: start,
            codec: "HEVC",
            resolution: "1920x1080"
        )
        XCTAssertEqual(first.bitsPerSecond, 0, "bitrate should wait for enough elapsed sample time")
        XCTAssertEqual(first.codec, "HEVC")
        XCTAssertEqual(first.resolution, "1920x1080")

        let second = meter.recordFrame(
            byteCount: 500_000,
            now: start.addingTimeInterval(1),
            codec: "HEVC",
            resolution: "1920x1080"
        )

        XCTAssertEqual(second.bitsPerSecond, 8_000_000)
        XCTAssertEqual(second.codec, "HEVC")
        XCTAssertEqual(second.resolution, "1920x1080")
    }

    func testRoundTripMillisIsClampedAndPreservesFrameStats() {
        var meter = ScreenShareViewerStatsMeter(minimumSampleInterval: 0.5)
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        _ = meter.recordFrame(byteCount: 250_000, now: start, codec: "H.264", resolution: "1280x720")
        _ = meter.recordFrame(byteCount: 250_000, now: start.addingTimeInterval(0.5), codec: "H.264", resolution: "1280x720")

        let clamped = meter.updateRoundTripMillis(-12)
        XCTAssertEqual(clamped.roundTripMillis, 0)
        XCTAssertEqual(clamped.bitsPerSecond, 8_000_000)

        let updated = meter.updateRoundTripMillis(37)
        XCTAssertEqual(updated.roundTripMillis, 37)
        XCTAssertEqual(updated.codec, "H.264")
        XCTAssertEqual(updated.resolution, "1280x720")
    }
}

final class ScreenShareViewportStateTests: XCTestCase {
    func testMagnificationClampsScaleToSupportedRange() {
        var viewport = ScreenShareViewportState()

        viewport.applyMagnification(10, in: CGSize(width: 390, height: 844))
        XCTAssertEqual(viewport.scale, ScreenShareViewportState.maximumScale)

        viewport.applyMagnification(0.01, in: CGSize(width: 390, height: 844))
        XCTAssertEqual(viewport.scale, ScreenShareViewportState.minimumScale)
        XCTAssertEqual(viewport.offset, .zero)
    }

    func testPanningIsClampedToScaledContentBounds() {
        var viewport = ScreenShareViewportState(scale: 2)

        viewport.applyTranslation(CGSize(width: 1_000, height: -1_000), in: CGSize(width: 400, height: 800))

        XCTAssertEqual(viewport.offset.width, 200)
        XCTAssertEqual(viewport.offset.height, -400)
    }

    func testPanningAtDefaultScaleAlwaysRecenters() {
        var viewport = ScreenShareViewportState()

        viewport.applyTranslation(CGSize(width: 100, height: 100), in: CGSize(width: 400, height: 800))

        XCTAssertEqual(viewport.scale, 1)
        XCTAssertEqual(viewport.offset, .zero)
    }

    func testPreviewDoesNotMutateCommittedViewport() {
        let viewport = ScreenShareViewportState(scale: 2, offset: CGSize(width: 20, height: -40))

        let preview = viewport.preview(
            magnification: 1.5,
            translation: CGSize(width: 10, height: 10),
            in: CGSize(width: 400, height: 800)
        )

        XCTAssertEqual(viewport.scale, 2)
        XCTAssertEqual(viewport.offset, CGSize(width: 20, height: -40))
        XCTAssertEqual(preview.scale, 3)
        XCTAssertEqual(preview.offset, CGSize(width: 30, height: -30))
    }

    func testReclampPreservesZoomAcrossRotationButConstrainsOffset() {
        var viewport = ScreenShareViewportState(scale: 3, offset: CGSize(width: 600, height: 600))

        viewport.reclamp(in: CGSize(width: 844, height: 390))

        XCTAssertEqual(viewport.scale, 3)
        XCTAssertEqual(viewport.offset.width, 600)
        XCTAssertEqual(viewport.offset.height, 390)
    }

    func testQuickZoomTogglesBetweenFitAndZoomed() {
        var viewport = ScreenShareViewportState()

        viewport.toggleQuickZoom(in: CGSize(width: 400, height: 800))
        XCTAssertEqual(viewport.scale, ScreenShareViewportState.quickZoomScale)
        XCTAssertEqual(viewport.offset, .zero)

        viewport.toggleQuickZoom(in: CGSize(width: 400, height: 800))
        XCTAssertEqual(viewport.scale, ScreenShareViewportState.minimumScale)
        XCTAssertEqual(viewport.offset, .zero)
    }

    func testNormalizedTapMappingAtDefaultScale() {
        let viewport = ScreenShareViewportState()

        let point = viewport.normalizedPoint(
            for: CGPoint(x: 100, y: 600),
            in: CGSize(width: 400, height: 800)
        )

        XCTAssertEqual(point.x, 0.25, accuracy: 0.0001)
        XCTAssertEqual(point.y, 0.75, accuracy: 0.0001)
    }

    func testNormalizedTapMappingCompensatesForZoomAndPan() {
        let viewport = ScreenShareViewportState(scale: 2, offset: CGSize(width: 40, height: -80))

        let point = viewport.normalizedPoint(
            for: CGPoint(x: 240, y: 320),
            in: CGSize(width: 400, height: 800)
        )

        XCTAssertEqual(point.x, 0.50, accuracy: 0.0001)
        XCTAssertEqual(point.y, 0.50, accuracy: 0.0001)
    }

    func testNormalizedTapMappingUsesLetterboxedVideoRect() {
        let viewport = ScreenShareViewportState()
        let container = CGSize(width: 2048, height: 944)
        let contentWidth = container.height * 1.6
        let contentRect = CGRect(
            x: (container.width - contentWidth) / 2,
            y: 0,
            width: contentWidth,
            height: container.height
        )

        let point = viewport.normalizedPoint(
            for: CGPoint(x: contentRect.minX + contentRect.width * 0.25, y: contentRect.height * 0.75),
            in: container,
            contentRect: contentRect
        )
        let leftLetterboxPoint = viewport.normalizedPoint(
            for: CGPoint(x: 20, y: container.height / 2),
            in: container,
            contentRect: contentRect
        )

        XCTAssertEqual(point.x, 0.25, accuracy: 0.0001)
        XCTAssertEqual(point.y, 0.75, accuracy: 0.0001)
        XCTAssertEqual(leftLetterboxPoint.x, 0, accuracy: 0.0001)
        XCTAssertEqual(leftLetterboxPoint.y, 0.5, accuracy: 0.0001)
    }

    func testNormalizedTapMappingCombinesLetterboxZoomAndPan() {
        let viewport = ScreenShareViewportState(scale: 2, offset: CGSize(width: 50, height: -50))
        let container = CGSize(width: 1_000, height: 500)
        let contentRect = CGRect(x: 100, y: 0, width: 800, height: 500)

        let point = viewport.normalizedPoint(
            for: CGPoint(x: 550, y: 200),
            in: container,
            contentRect: contentRect
        )

        XCTAssertEqual(point.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(point.y, 0.5, accuracy: 0.0001)
    }

    func testNormalizedTapMappingClampsEdgesAfterRotation() {
        var viewport = ScreenShareViewportState(scale: 3, offset: CGSize(width: 900, height: -900))
        viewport.reclamp(in: CGSize(width: 844, height: 390))

        let point = viewport.normalizedPoint(
            for: CGPoint(x: 844, y: 0),
            in: CGSize(width: 844, height: 390)
        )

        XCTAssertGreaterThanOrEqual(point.x, 0)
        XCTAssertLessThanOrEqual(point.x, 1)
        XCTAssertGreaterThanOrEqual(point.y, 0)
        XCTAssertLessThanOrEqual(point.y, 1)
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

private actor MobileAsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else {
            return
        }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor PhoneControlFrameOrderRecorder {
    private var startedCounters: Set<UInt64> = []
    private var finished: [UInt64] = []
    private var startedWaiters: [UInt64: [CheckedContinuation<Void, Never>]] = [:]

    func recordStarted(_ counter: UInt64) {
        startedCounters.insert(counter)
        let pending = startedWaiters.removeValue(forKey: counter) ?? []
        pending.forEach { $0.resume() }
    }

    func waitForStarted(counter: UInt64) async {
        if startedCounters.contains(counter) {
            return
        }
        await withCheckedContinuation { continuation in
            startedWaiters[counter, default: []].append(continuation)
        }
    }

    func recordFinished(_ counter: UInt64) {
        finished.append(counter)
    }

    func finishedCounters() -> [UInt64] {
        finished
    }

    func startedCounterValues() -> [UInt64] {
        startedCounters.sorted()
    }
}

private final class AgentWatchFakeSigningKeyStore: PhoneControlSigningKeyProviding {
    private let key = Curve25519SigningKey(privateKey: Curve25519.Signing.PrivateKey())

    func signingKey() throws -> Curve25519SigningKey {
        key
    }

    func peerNodeId(for key: Curve25519SigningKey) -> String {
        "ios-phone-test-\(key.privateKey.publicKey.rawRepresentation.prefix(4).map { String(format: "%02x", $0) }.joined())"
    }
}

private struct MobileFakeIrohPairingPublicKeyProvider: IrohPairingPublicKeyProviding {
    func fetchPublicKey(uid: String) async throws -> Data {
        Data(repeating: 0x1, count: 32)
    }
}

private struct MobileNoopIrohTransportAuditLogger: IrohTransportAuditLogging {
    func record(
        event: IrohTransportAuditEvent,
        uid: String,
        connectionId: String,
        transport: IrohTransportSelection?,
        rttMillis: Int?,
        detail: [String: String]
    ) async {}
}

private final class MobileNoopIrohRelayTransport: IrohRelayTransport, @unchecked Sendable {
    func start() async throws -> IrohEndpointIdentity {
        IrohEndpointIdentity(
            nodeId: "noop-node",
            rawPublicKey: Data(repeating: 0x2, count: 32)
        )
    }

    func connect(to target: IrohDialTarget, timeout: TimeInterval) async throws -> any IrohRelayStream {
        throw IrohBackendError.connectFailed("noop")
    }

    func accept(timeout: TimeInterval) async throws -> any IrohRelayStream {
        throw IrohBackendError.acceptFailed("noop")
    }

    func shutdown() async {}
}

private final class MobileFakeIrohBlobBackend: IrohBlobBackend, @unchecked Sendable {
    func bootstrap(
        secret: Data,
        storeDirectoryPath: String,
        relayURL: String?
    ) async throws -> IrohEndpointIdentity {
        IrohEndpointIdentity(
            nodeId: "blob-node",
            rawPublicKey: Data(repeating: 0x3, count: 32),
            relayURL: relayURL
        )
    }

    func publishBlob(localPath: String) async throws -> String {
        "blob-ticket"
    }

    func fetchBlob(ticketText: String, destination: String) async throws -> BlobTransferStats {
        BlobTransferStats(bytesTotal: 0, blake3Hash: "0", durationMillis: 0, didResume: false)
    }

    func identity() async throws -> IrohEndpointIdentity {
        IrohEndpointIdentity(
            nodeId: "blob-node",
            rawPublicKey: Data(repeating: 0x3, count: 32)
        )
    }

    func shutdown() async {}
}

@MainActor
private final class MobileFakeSelfHostedQuotaRunnerSecrets: SelfHostedQuotaRunnerSecretStoring {
    var savedByAccount: [String: String] = [:]

    func save(_ value: String, accountID: String) throws {
        savedByAccount[accountID] = value
    }

    func load(accountID: String) throws -> String? {
        savedByAccount[accountID]
    }

    func delete(accountID: String) throws {
        savedByAccount.removeValue(forKey: accountID)
    }
}
