#if canImport(AppKit) && !DISTRIBUTION_MAS
import CryptoKit
import XCTest
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import OpenBurnBarIrohRelay
import OpenBurnBarMedia
@testable import OpenBurnBar

final class PhoneControlReceiverTests: XCTestCase {
    @MainActor
    func testChaosSoftCapUpdateDoesNotShrinkActiveSessionActionCap() async throws {
        let browserCapture = BrowserActionCapture()
        let coordinator = ComputerUseSessionCoordinator(
            configuration: ComputerUseSessionCoordinator.Configuration(
                userId: "uid-soft-cap",
                macHostNodeId: "mac-soft-cap",
                entitlement: ComputerUseEntitlementSnapshot(
                    isActive: true,
                    productId: "hosted_computer_use_sync",
                    allowsBrowser: true
                ),
                quotaUsage: ComputerUseQuotaUsage(dayKey: "2026-05-18"),
                auditBaseDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("computer-use-soft-cap-\(UUID().uuidString)", isDirectory: true),
                macAppVersion: "test"
            ),
            browserDispatcher: { action in
                await browserCapture.record(action)
                return .object(["ok": .bool(true)])
            },
            approvalPresenter: { request, _ in
                HermesRealtimeRelayApprovalResponse(
                    approvalId: request.approvalId,
                    decision: .approve,
                    respondedBy: "mac",
                    respondedAt: Date()
                )
            }
        )
        let started = try await coordinator.startSession(
            request: ComputerUseSessionStartRequest(
                mode: ComputerUseMode.browser.rawValue,
                trustMode: ComputerUseTrustMode.trusted.rawValue,
                clientID: BurnBarClientID(rawValue: "client-soft-cap"),
                actionCap: ComputerUseBudgetEnvelope.initialNormal.activeActionsPerRun
            )
        )
        coordinator.updateBudgetEnvelope(.softCapEnvelope(
            projectedMonthEndUSD: 1_500,
            monthToDateUSD: 800,
            updatedAt: Date()
        ))

        for index in 0..<26 {
            let response = await coordinator.invoke(BurnBarToolInvocation(
                callID: "soft-cap-\(index)",
                runID: BurnBarRunID(rawValue: "run-soft-cap"),
                tool: .browserClick,
                arguments: .object(["selector": .string("#safe")]),
                requestedBy: BurnBarClientID(rawValue: "agent"),
                requestedAt: Date()
            ))
            XCTAssertEqual(response.status, .executed, "action \(index)")
            XCTAssertEqual(response.sessionId, started.sessionId)
        }

        let browserActions = await browserCapture.actions()
        XCTAssertEqual(browserActions.count, 26)
        XCTAssertEqual(coordinator.state?.actionsExecuted, 26)
        XCTAssertNil(coordinator.state?.endReason)
    }

    @MainActor
    func testChaosHardCapUpdateImmediatelyEndsActiveSessionAndAuditsHardCap() async throws {
        let auditDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("computer-use-hard-cap-\(UUID().uuidString)", isDirectory: true)
        let coordinator = ComputerUseSessionCoordinator(
            configuration: ComputerUseSessionCoordinator.Configuration(
                userId: "uid-hard-cap",
                macHostNodeId: "mac-hard-cap",
                entitlement: ComputerUseEntitlementSnapshot(
                    isActive: true,
                    productId: "hosted_computer_use_sync",
                    allowsBrowser: true
                ),
                quotaUsage: ComputerUseQuotaUsage(dayKey: "2026-05-18"),
                auditBaseDirectory: auditDirectory,
                macAppVersion: "test"
            ),
            browserDispatcher: { _ in .object(["ok": .bool(true)]) },
            approvalPresenter: { request, _ in
                HermesRealtimeRelayApprovalResponse(
                    approvalId: request.approvalId,
                    decision: .approve,
                    respondedBy: "mac",
                    respondedAt: Date()
                )
            }
        )
        let started = try await coordinator.startSession(
            request: ComputerUseSessionStartRequest(
                mode: ComputerUseMode.browser.rawValue,
                trustMode: ComputerUseTrustMode.trusted.rawValue,
                clientID: BurnBarClientID(rawValue: "client-hard-cap")
            )
        )

        coordinator.updateBudgetEnvelope(.hardCapEnvelope(
            projectedMonthEndUSD: 2_500,
            monthToDateUSD: 2_100,
            updatedAt: Date()
        ))

        XCTAssertEqual(coordinator.state?.endReason, .budgetHardCap)
        XCTAssertEqual(coordinator.lastDeniedReason, .hardCap)
        XCTAssertEqual(coordinator.actionTimeline.last?.status, .panicHalted)
        XCTAssertEqual(coordinator.actionTimeline.last?.actionKind, "budget.hard_cap")

        let response = await coordinator.invoke(BurnBarToolInvocation(
            callID: "hard-cap-after-halt",
            runID: BurnBarRunID(rawValue: "run-hard-cap"),
            tool: .browserClick,
            arguments: .object(["selector": .string("#blocked")]),
            requestedBy: BurnBarClientID(rawValue: "agent"),
            requestedAt: Date()
        ))
        XCTAssertEqual(response.status, .error)
        XCTAssertEqual(response.denyReason, "no_active_session")

        let chainURL = auditDirectory
            .appendingPathComponent(started.sessionId, isDirectory: true)
            .appendingPathComponent("chain.jsonl")
        let chainText = try String(contentsOf: chainURL, encoding: .utf8)
        let entries = try chainText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                try ComputerUseAuditHasher.canonicalJSONDecoder.decode(
                    ComputerUseAuditEntry.self,
                    from: Data(line.utf8)
                )
            }
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.approvedBy, .panic)
        XCTAssertEqual(entries.first?.denyReason, ComputerUseDenyReason.hardCap.rawValue)
    }

    @MainActor
    func testPhoneApprovalResponseCompletesPendingBrowserActionAndAuditsPhoneApproval() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let peerNodeId = "ios-phone-approval"
        let provider = StaticPhoneControlAuthorityProvider(
            expectedUID: "uid-approval",
            expectedConnectionID: "conn-approval",
            expectedPeerNodeID: peerNodeId,
            publicKey: privateKey.publicKey
        )
        let replyCapture = ControlFrameCapture()
        let browserCapture = BrowserActionCapture()
        let deferredPresenter = DeferredApprovalPresenter()
        let auditDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("computer-use-cross-device-approval-\(UUID().uuidString)", isDirectory: true)

        let coordinator = ComputerUseSessionCoordinator(
            configuration: ComputerUseSessionCoordinator.Configuration(
                userId: "uid-approval",
                macHostNodeId: "mac-approval",
                entitlement: ComputerUseEntitlementSnapshot(
                    isActive: true,
                    productId: "hosted_computer_use_sync",
                    allowsBrowser: true,
                    allowsPhoneControl: true
                ),
                quotaUsage: ComputerUseQuotaUsage(dayKey: "2026-05-18"),
                auditBaseDirectory: auditDirectory,
                macAppVersion: "test"
            ),
            browserDispatcher: { action in
                await browserCapture.record(action)
                return .object(["ok": .bool(true), "kind": .string(action.kind.rawValue)])
            },
            authorityProvider: provider,
            approvalPresenter: { request, _ in
                await deferredPresenter.waitForFallbackResponse(request)
            }
        )
        let started = try await coordinator.startSession(
            request: ComputerUseSessionStartRequest(
                mode: ComputerUseMode.browser.rawValue,
                trustMode: ComputerUseTrustMode.manual.rawValue,
                clientID: BurnBarClientID(rawValue: "client-approval")
            )
        )

        let dispatcher = coordinator.controlDispatcher
        await dispatcher(
            HermesRealtimeRelayFrame(
                type: .controlClassify,
                uid: "uid-approval",
                connectionId: "conn-approval",
                control: HermesRealtimeRelayControlPayload(
                    streamClass: MediaStreamClass.controlApproval.rawValue,
                    sessionId: started.sessionId,
                    authorityPeerNodeId: peerNodeId
                )
            ),
            { frame in await replyCapture.record(frame) }
        )

        let invocation = BurnBarToolInvocation(
            callID: "call-phone-approval",
            runID: BurnBarRunID(rawValue: "run-phone-approval"),
            tool: .browserGoto,
            arguments: .object(["url": .string("https://example.com")]),
            requestedBy: BurnBarClientID(rawValue: "agent"),
            requestedAt: Date()
        )
        let invokeTask = Task { @MainActor in
            await coordinator.invoke(invocation)
        }

        let approvalRequestFrame = try await replyCapture.firstFrame { frame in
            frame.type == .controlApprovalRequest
        }
        let approvalRequest = try XCTUnwrap(approvalRequestFrame.control?.approvalRequest)
        XCTAssertEqual(approvalRequest.sessionId, started.sessionId)
        XCTAssertEqual(approvalRequest.toolKind, BurnBarToolKind.browserGoto.rawValue)
        XCTAssertEqual(coordinator.pendingApproval?.approvalId, approvalRequest.approvalId)

        await dispatcher(
            HermesRealtimeRelayFrame(
                type: .controlApprovalResponse,
                uid: "uid-approval",
                connectionId: "conn-approval",
                control: HermesRealtimeRelayControlPayload(
                    streamClass: MediaStreamClass.controlApproval.rawValue,
                    sessionId: started.sessionId,
                    approvalResponse: HermesRealtimeRelayApprovalResponse(
                        approvalId: approvalRequest.approvalId,
                        decision: .approve,
                        respondedBy: "phone",
                        respondedAt: Date()
                    )
                )
            ),
            { frame in await replyCapture.record(frame) }
        )

        let response = await invokeTask.value
        await deferredPresenter.releaseFallbackResponse()
        XCTAssertEqual(response.status, ComputerUseInvokeResponse.Status.executed)
        XCTAssertEqual(response.approvalId, approvalRequest.approvalId)
        XCTAssertNil(coordinator.pendingApproval)

        let browserActions = await browserCapture.actions()
        XCTAssertEqual(browserActions.count, 1)
        XCTAssertEqual(browserActions.first?.kind, .goto)
        XCTAssertEqual(browserActions.first?.url, "https://example.com")

        let chainURL = auditDirectory
            .appendingPathComponent(started.sessionId, isDirectory: true)
            .appendingPathComponent("chain.jsonl")
        let chainText = try String(contentsOf: chainURL, encoding: .utf8)
        let entries = try chainText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                try ComputerUseAuditHasher.canonicalJSONDecoder.decode(
                    ComputerUseAuditEntry.self,
                    from: Data(line.utf8)
                )
            }
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.approvedBy, .phone)
        XCTAssertEqual(entries.first?.approvalId, approvalRequest.approvalId)
    }

    @MainActor
    func testIrohRequestHandlerRoutesControlStreamIntoCoordinator() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let peerNodeId = "ios-phone-stream"
        let provider = StaticPhoneControlAuthorityProvider(
            expectedUID: "uid-stream",
            expectedConnectionID: "conn-stream",
            expectedPeerNodeID: peerNodeId,
            publicKey: privateKey.publicKey
        )
        let coordinator = ComputerUseSessionCoordinator(
            configuration: ComputerUseSessionCoordinator.Configuration(
                userId: "uid-stream",
                macHostNodeId: "mac-stream",
                entitlement: ComputerUseEntitlementSnapshot(
                    isActive: true,
                    productId: "hosted_computer_use_sync",
                    allowsSystem: true,
                    allowsPhoneControl: true
                ),
                quotaUsage: ComputerUseQuotaUsage(dayKey: "2026-05-17"),
                auditBaseDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("computer-use-handler-stream-\(UUID().uuidString)", isDirectory: true),
                macAppVersion: "test"
            ),
            authorityProvider: provider,
            displayBoundsProvider: {
                [MacInputCore.DisplayBounds(originX: 0, originY: 0, width: 1_000, height: 500)]
            },
            approvalPresenter: { request, _ in
                HermesRealtimeRelayApprovalResponse(
                    approvalId: request.approvalId,
                    decision: .approve,
                    respondedBy: "test",
                    respondedAt: Date()
                )
            }
        )
        let started = try await coordinator.startSession(
            request: ComputerUseSessionStartRequest(
                mode: ComputerUseMode.system.rawValue,
                trustMode: ComputerUseTrustMode.manual.rawValue,
                clientID: BurnBarClientID(rawValue: "client-stream")
            )
        )
        let classify = HermesRealtimeRelayFrame(
            type: .controlClassify,
            uid: "uid-stream",
            connectionId: "conn-stream",
            control: HermesRealtimeRelayControlPayload(
                streamClass: MediaStreamClass.controlInput.rawValue,
                sessionId: started.sessionId,
                authorityPeerNodeId: peerNodeId
            )
        )
        let placeholder = emptyAuthority()
        var intent = HermesRealtimeRelayInputIntent(kind: .panic, authority: placeholder)
        let signed = try ComputerUsePhoneControlSigner().sign(
            intent: intent,
            peerNodeId: peerNodeId,
            counter: 1,
            timestamp: Date(),
            privateKey: privateKey
        )
        intent.authority = envelope(from: signed)
        let signedInput = HermesRealtimeRelayFrame(
            type: .controlInputIntent,
            uid: "uid-stream",
            connectionId: "conn-stream",
            control: HermesRealtimeRelayControlPayload(
                streamClass: MediaStreamClass.controlInput.rawValue,
                sessionId: started.sessionId,
                inputIntent: intent
            )
        )
        let stream = PhoneControlRecordingIrohStream(inbound: [classify, signedInput])
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PhoneControlReceiverTests.\(UUID().uuidString)"))
        let handler = IrohRelayRequestHandler(
            relayKeyStore: HermesRelayKeyStore(),
            urlSession: .shared,
            settingsManager: SettingsManager(defaults: defaults, flushDelayNanoseconds: 0),
            controlDispatcher: coordinator.controlDispatcher
        )

        try await handler.serve(stream: stream, uid: "uid-stream", connectionID: "conn-stream")

        let sentFrames = await stream.sentFrames()
        let fetchCount = await provider.fetchCount
        XCTAssertTrue(sentFrames.isEmpty)
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(coordinator.state?.endReason, .panicPhoneGesture)
        XCTAssertEqual(coordinator.actionTimeline.last?.status, .panicHalted)
    }

    @MainActor
    func testCoordinatorClassifyRegistersAuthorityAndSignedPanicHaltsSession() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let peerNodeId = "android-phone-loopback"
        let provider = StaticPhoneControlAuthorityProvider(
            expectedUID: "uid-loopback",
            expectedConnectionID: "conn-loopback",
            expectedPeerNodeID: peerNodeId,
            publicKey: privateKey.publicKey
        )
        let replies = PhoneControlReceiverCapture()
        let coordinator = ComputerUseSessionCoordinator(
            configuration: ComputerUseSessionCoordinator.Configuration(
                userId: "uid-loopback",
                macHostNodeId: "mac-loopback",
                entitlement: ComputerUseEntitlementSnapshot(
                    isActive: true,
                    productId: "hosted_computer_use_sync",
                    allowsSystem: true,
                    allowsPhoneControl: true
                ),
                quotaUsage: ComputerUseQuotaUsage(dayKey: "2026-05-17"),
                auditBaseDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("computer-use-coordinator-loopback-\(UUID().uuidString)", isDirectory: true),
                macAppVersion: "test"
            ),
            authorityProvider: provider,
            displayBoundsProvider: {
                [MacInputCore.DisplayBounds(originX: 0, originY: 0, width: 1_000, height: 500)]
            },
            approvalPresenter: { request, _ in
                HermesRealtimeRelayApprovalResponse(
                    approvalId: request.approvalId,
                    decision: .approve,
                    respondedBy: "test",
                    respondedAt: Date()
                )
            }
        )
        let started = try await coordinator.startSession(
            request: ComputerUseSessionStartRequest(
                mode: ComputerUseMode.system.rawValue,
                trustMode: ComputerUseTrustMode.manual.rawValue,
                clientID: BurnBarClientID(rawValue: "client-loopback")
            )
        )

        let dispatcher = coordinator.controlDispatcher
        await dispatcher(
            HermesRealtimeRelayFrame(
                type: .controlClassify,
                uid: "uid-loopback",
                connectionId: "conn-loopback",
                control: HermesRealtimeRelayControlPayload(
                    streamClass: MediaStreamClass.controlInput.rawValue,
                    sessionId: started.sessionId,
                    authorityPeerNodeId: peerNodeId
                )
            ),
            { frame in await replies.recordDenied(frame) }
        )

        let placeholder = emptyAuthority()
        var intent = HermesRealtimeRelayInputIntent(kind: .panic, authority: placeholder)
        let signed = try ComputerUsePhoneControlSigner().sign(
            intent: intent,
            peerNodeId: peerNodeId,
            counter: 1,
            timestamp: Date(),
            privateKey: privateKey
        )
        intent.authority = envelope(from: signed)
        await dispatcher(
            HermesRealtimeRelayFrame(
                type: .controlInputIntent,
                uid: "uid-loopback",
                connectionId: "conn-loopback",
                control: HermesRealtimeRelayControlPayload(
                    streamClass: MediaStreamClass.controlInput.rawValue,
                    sessionId: started.sessionId,
                    inputIntent: intent
                )
            ),
            { frame in await replies.recordDenied(frame) }
        )

        let fetchCount = await provider.fetchCount
        let deniedFrames = await replies.deniedFrames()
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(coordinator.state?.endReason, .panicPhoneGesture)
        XCTAssertEqual(coordinator.actionTimeline.last?.status, .panicHalted)
        XCTAssertTrue(deniedFrames.isEmpty)
    }

    func testSignedScrollIntentDispatchesMacScrollAction() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let signer = ComputerUsePhoneControlSigner()
        let placeholder = emptyAuthority()
        var intent = HermesRealtimeRelayInputIntent(
            kind: .scroll,
            normalizedX: 0.40,
            normalizedY: 0.50,
            normalizedX2: 0.40,
            normalizedY2: 0.20,
            authority: placeholder
        )
        let signed = try signer.sign(
            intent: intent,
            peerNodeId: "phone-peer",
            counter: 1,
            timestamp: Date(),
            privateKey: privateKey
        )
        intent.authority = envelope(from: signed)

        let validator = PhoneControlAuthorityValidator()
        validator.registerPeer(nodeId: "phone-peer", publicKey: privateKey.publicKey)
        let capture = PhoneControlReceiverCapture()
        let receiver = PhoneControlReceiver(
            sessionId: ComputerUseSessionID("session-phone"),
            validator: validator,
            displayBoundsProvider: {
                [MacInputCore.DisplayBounds(originX: 0, originY: 0, width: 1_000, height: 500)]
            },
            dispatchHandler: { action, sessionId, _ in
                await capture.record(action: action, sessionId: sessionId)
            },
            denyFrameSink: { frame in
                await capture.recordDenied(frame)
            }
        )

        await receiver.ingest(frame(intent))

        let dispatched = try await capture.firstAction()
        XCTAssertEqual(dispatched.sessionId, ComputerUseSessionID("session-phone"))
        guard case let .macInput(action) = dispatched.action else {
            return XCTFail("expected macInput action")
        }
        XCTAssertEqual(action.kind, .scroll)
        XCTAssertEqual(action.displayX, 400)
        XCTAssertEqual(action.displayY, 250)
        XCTAssertEqual(action.dragEndX, 400)
        XCTAssertEqual(action.dragEndY, 100)
        let deniedFrames = await capture.deniedFrames()
        XCTAssertTrue(deniedFrames.isEmpty)
    }

    func testMalformedScrollCoordinatesEmitDeniedFrame() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let signer = ComputerUsePhoneControlSigner()
        let placeholder = emptyAuthority()
        var intent = HermesRealtimeRelayInputIntent(
            kind: .scroll,
            normalizedX: 1.20,
            normalizedY: 0.50,
            normalizedX2: 0.40,
            normalizedY2: 0.20,
            authority: placeholder
        )
        let signed = try signer.sign(
            intent: intent,
            peerNodeId: "phone-peer",
            counter: 1,
            timestamp: Date(),
            privateKey: privateKey
        )
        intent.authority = envelope(from: signed)

        let validator = PhoneControlAuthorityValidator()
        validator.registerPeer(nodeId: "phone-peer", publicKey: privateKey.publicKey)
        let capture = PhoneControlReceiverCapture()
        let receiver = PhoneControlReceiver(
            sessionId: ComputerUseSessionID("session-phone"),
            validator: validator,
            displayBoundsProvider: {
                [MacInputCore.DisplayBounds(originX: 0, originY: 0, width: 1_000, height: 500)]
            },
            dispatchHandler: { action, sessionId, _ in
                await capture.record(action: action, sessionId: sessionId)
            },
            denyFrameSink: { frame in
                await capture.recordDenied(frame)
            }
        )

        await receiver.ingest(frame(intent))

        let actions = await capture.actions()
        XCTAssertTrue(actions.isEmpty)
        let deniedFrames = await capture.deniedFrames()
        let denied = try XCTUnwrap(deniedFrames.first)
        XCTAssertEqual(denied.type, .controlDenied)
        XCTAssertEqual(denied.control?.denied?.reason, .unknown)
        XCTAssertEqual(denied.control?.denied?.detail, "malformed_coordinates")
    }

    func testReplayChaosRejectsOneThousandDuplicateIntentEnvelopes() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let signer = ComputerUsePhoneControlSigner()
        let placeholder = emptyAuthority()
        var intent = HermesRealtimeRelayInputIntent(
            kind: .tap,
            normalizedX: 0.25,
            normalizedY: 0.40,
            authority: placeholder
        )
        let signed = try signer.sign(
            intent: intent,
            peerNodeId: "phone-peer-chaos",
            counter: 42,
            timestamp: Date(),
            privateKey: privateKey
        )
        intent.authority = envelope(from: signed)

        let validator = PhoneControlAuthorityValidator()
        validator.registerPeer(nodeId: "phone-peer-chaos", publicKey: privateKey.publicKey)
        let capture = PhoneControlReceiverCapture()
        let receiver = PhoneControlReceiver(
            sessionId: ComputerUseSessionID("session-phone-chaos"),
            validator: validator,
            displayBoundsProvider: {
                [MacInputCore.DisplayBounds(originX: 0, originY: 0, width: 1_000, height: 500)]
            },
            dispatchHandler: { action, sessionId, _ in
                await capture.record(action: action, sessionId: sessionId)
            },
            denyFrameSink: { frame in
                await capture.recordDenied(frame)
            }
        )

        let frame = frame(intent)
        await receiver.ingest(frame)
        for _ in 0..<1_000 {
            await receiver.ingest(frame)
        }

        let actions = await capture.actions()
        XCTAssertEqual(actions.count, 1)
        guard case let .macInput(action) = actions.first?.action else {
            return XCTFail("expected first intent to dispatch as macInput")
        }
        XCTAssertEqual(action.kind, .click)
        XCTAssertEqual(action.displayX, 250)
        XCTAssertEqual(action.displayY, 200)

        let deniedFrames = await capture.deniedFrames()
        XCTAssertEqual(deniedFrames.count, 1_000)
        XCTAssertTrue(deniedFrames.allSatisfy { $0.control?.denied?.reason == .counterReplay })
    }

    private func frame(_ intent: HermesRealtimeRelayInputIntent) -> HermesRealtimeRelayFrame {
        HermesRealtimeRelayFrame(
            type: .controlInputIntent,
            uid: "uid-phone",
            connectionId: "relay-phone",
            control: HermesRealtimeRelayControlPayload(
                streamClass: MediaStreamClass.controlInput.rawValue,
                inputIntent: intent
            )
        )
    }

    private func emptyAuthority() -> HermesRealtimeRelayAuthorityEnvelope {
        HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: "",
            counter: 0,
            timestamp: Date(timeIntervalSince1970: 0),
            intentHashBlake3: "",
            signatureEd25519: ""
        )
    }

    private func envelope(
        from signed: ComputerUsePhoneControlSigner.SignedAuthority
    ) -> HermesRealtimeRelayAuthorityEnvelope {
        HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: signed.peerNodeId,
            counter: signed.counter,
            timestamp: signed.timestamp,
            intentHashBlake3: signed.intentHashHex,
            signatureEd25519: signed.signatureBase64
        )
    }
}

final class MacComputerUseDenyRegionsTests: XCTestCase {
    func testDenyRegionMatrixCoversSensitiveMacSurfaces() {
        let classifier = MacComputerUseDenyRegions()
        let cases: [(String, MacComputerUseDenyRegions.Element, ComputerUseAccessibilityDenyReason)] = [
            (
                "secure text field",
                .init(role: "AXTextField", subrole: "AXSecureTextField", title: "Password"),
                .secureTextField
            ),
            (
                "Keychain Access bundle",
                .init(role: "AXWindow", title: "Keychain Access", bundleId: "com.apple.keychainaccess"),
                .keychainPrompt
            ),
            (
                "SecurityAgent bundle",
                .init(role: "AXWindow", title: "Authenticate", bundleId: "com.apple.SecurityAgent"),
                .keychainPrompt
            ),
            (
                "SecurityAgentHelper bundle",
                .init(role: "AXWindow", title: "Authenticate", bundleId: "com.apple.SecurityAgentHelper"),
                .keychainPrompt
            ),
            (
                "loginwindow bundle",
                .init(role: "AXWindow", title: "Login", bundleId: "com.apple.loginwindow"),
                .keychainPrompt
            ),
            (
                "FileVault recovery bundle",
                .init(role: "AXWindow", title: "Recovery", bundleId: "com.apple.FileVaultRecoveryUtility"),
                .keychainPrompt
            ),
            (
                "authenticate dialog",
                .init(role: "AXDialog", title: "Authenticate to make changes"),
                .systemAuthSheet
            ),
            (
                "authorization sheet",
                .init(role: "AXSheet", label: "Authorize OpenBurnBar"),
                .systemAuthSheet
            ),
            (
                "password sheet",
                .init(role: "AXSheet", label: "Enter login password"),
                .systemAuthSheet
            ),
            (
                "privacy dialog",
                .init(role: "AXDialog", title: "Privacy & Security"),
                .systemAuthSheet
            ),
            (
                "passcode dialog",
                .init(role: "AXDialog", label: "Enter passcode"),
                .systemAuthSheet
            ),
            (
                "keychain sheet by role description",
                .init(roleDescription: "authentication sheet", title: "Keychain wants to sign"),
                .systemAuthSheet
            )
        ]

        for (label, element, expected) in cases {
            XCTAssertEqual(classifier.denyReason(for: element), expected, label)
        }
    }

    func testDenyRegionMatrixAllowsBenignElements() {
        let classifier = MacComputerUseDenyRegions()
        let benign: [MacComputerUseDenyRegions.Element] = [
            .init(role: "AXTextField", subrole: nil, title: "Search"),
            .init(role: "AXDialog", title: "About OpenBurnBar", bundleId: "com.openburnbar.app"),
            .init(role: "AXWindow", title: "Calculator", bundleId: "com.apple.calculator")
        ]

        for element in benign {
            XCTAssertNil(classifier.denyReason(for: element))
        }
    }
}

private actor PhoneControlReceiverCapture {
    struct DispatchedAction: Sendable {
        let action: ComputerUseAction
        let sessionId: ComputerUseSessionID
    }

    private var recordedActions: [DispatchedAction] = []
    private var recordedDeniedFrames: [HermesRealtimeRelayFrame] = []

    func record(action: ComputerUseAction, sessionId: ComputerUseSessionID) {
        recordedActions.append(DispatchedAction(action: action, sessionId: sessionId))
    }

    func recordDenied(_ frame: HermesRealtimeRelayFrame) {
        recordedDeniedFrames.append(frame)
    }

    func actions() -> [DispatchedAction] {
        recordedActions
    }

    func firstAction() throws -> DispatchedAction {
        guard let action = recordedActions.first else {
            throw NSError(domain: "PhoneControlReceiverCapture", code: 1)
        }
        return action
    }

    func deniedFrames() -> [HermesRealtimeRelayFrame] {
        recordedDeniedFrames
    }
}

private actor ControlFrameCapture {
    private var recordedFrames: [HermesRealtimeRelayFrame] = []

    func record(_ frame: HermesRealtimeRelayFrame) {
        recordedFrames.append(frame)
    }

    func firstFrame(
        timeoutNanoseconds: UInt64 = 5_000_000_000,
        matching predicate: @Sendable (HermesRealtimeRelayFrame) -> Bool
    ) async throws -> HermesRealtimeRelayFrame {
        let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))
        while ContinuousClock.now < deadline {
            if let frame = recordedFrames.first(where: predicate) {
                return frame
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(domain: "ControlFrameCapture", code: 1)
    }
}

private actor BrowserActionCapture {
    private var recordedActions: [BrowserAction] = []

    func record(_ action: BrowserAction) {
        recordedActions.append(action)
    }

    func actions() -> [BrowserAction] {
        recordedActions
    }
}

private actor DeferredApprovalPresenter {
    private var continuation: CheckedContinuation<HermesRealtimeRelayApprovalResponse, Never>?

    func waitForFallbackResponse(
        _ request: HermesRealtimeRelayApprovalRequest
    ) async -> HermesRealtimeRelayApprovalResponse {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func releaseFallbackResponse() {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: HermesRealtimeRelayApprovalResponse(
            approvalId: "fallback-after-phone-response",
            decision: .reject,
            respondedBy: "mac",
            respondedAt: Date()
        ))
    }
}

private final class PhoneControlRecordingIrohStream: IrohRelayStream, @unchecked Sendable {
    private let lock = NSLock()
    private var inboundFrames: [HermesRealtimeRelayFrame]
    private var outboundFrames: [HermesRealtimeRelayFrame] = []
    private var isClosed = false

    init(inbound: [HermesRealtimeRelayFrame]) {
        self.inboundFrames = inbound
    }

    func send(_ frame: HermesRealtimeRelayFrame) async throws {
        lock.withLock {
            outboundFrames.append(frame)
        }
    }

    func receive() async throws -> HermesRealtimeRelayFrame? {
        lock.withLock {
            guard !isClosed, !inboundFrames.isEmpty else { return nil }
            return inboundFrames.removeFirst()
        }
    }

    func close() async {
        lock.withLock {
            isClosed = true
        }
    }

    func sentFrames() async -> [HermesRealtimeRelayFrame] {
        lock.withLock { outboundFrames }
    }
}

private actor StaticPhoneControlAuthorityProvider: PhoneControlAuthorityPublicKeyProviding {
    private let expectedUID: String
    private let expectedConnectionID: String
    private let expectedPeerNodeID: String
    private let publicKey: Curve25519.Signing.PublicKey
    private(set) var fetchCount = 0

    init(
        expectedUID: String,
        expectedConnectionID: String,
        expectedPeerNodeID: String,
        publicKey: Curve25519.Signing.PublicKey
    ) {
        self.expectedUID = expectedUID
        self.expectedConnectionID = expectedConnectionID
        self.expectedPeerNodeID = expectedPeerNodeID
        self.publicKey = publicKey
    }

    func fetchPublicKey(
        uid: String,
        connectionId: String,
        peerNodeId: String
    ) async throws -> Curve25519.Signing.PublicKey {
        fetchCount += 1
        XCTAssertEqual(uid, expectedUID)
        XCTAssertEqual(connectionId, expectedConnectionID)
        XCTAssertEqual(peerNodeId, expectedPeerNodeID)
        return publicKey
    }
}
#endif
