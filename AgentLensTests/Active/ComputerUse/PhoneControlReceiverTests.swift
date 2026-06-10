#if canImport(AppKit) && !DISTRIBUTION_MAS
import CryptoKit
import Foundation
import XCTest
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import OpenBurnBarIrohRelay
import OpenBurnBarMedia
@testable import OpenBurnBar

final class PhoneControlReceiverTests: XCTestCase {
    func testKeyboardPhoneActionsRetargetCapturedTerminalWindow() {
        XCTAssertTrue(ComputerUseSessionCoordinator.shouldRetargetPhoneKeyboardAction(
            .macInput(MacInputAction(kind: .type, text: "hello"))
        ))
        XCTAssertTrue(ComputerUseSessionCoordinator.shouldRetargetPhoneKeyboardAction(
            .macInput(MacInputAction(kind: .shortcut, key: "Return"))
        ))
        XCTAssertTrue(ComputerUseSessionCoordinator.shouldRetargetPhoneKeyboardAction(
            .macInput(MacInputAction(kind: .key, key: "Tab"))
        ))
    }

    func testPointerPhoneActionsDoNotStealFocusBackToTerminal() {
        XCTAssertFalse(ComputerUseSessionCoordinator.shouldRetargetPhoneKeyboardAction(
            .macInput(MacInputAction(kind: .click, displayX: 100, displayY: 120))
        ))
        XCTAssertFalse(ComputerUseSessionCoordinator.shouldRetargetPhoneKeyboardAction(
            .macInput(MacInputAction(kind: .scroll, displayX: 100, displayY: 120, dragEndX: 100, dragEndY: 60))
        ))
        XCTAssertFalse(ComputerUseSessionCoordinator.shouldRetargetPhoneKeyboardAction(
            .phoneIntent(PhoneControlIntent(kind: .panic))
        ))
    }

    @MainActor
    func testMobileLocalAuthProofDoesNotBypassMacApprovalForHighRiskGrants() {
        let now = Date(timeIntervalSince1970: 1_000)
        let threadID = "thread-\(UUID().uuidString)"
        let request = AgentCapabilityGrantRequest(
            requestID: "grant-\(UUID().uuidString)",
            runtimeID: .codex,
            threadID: threadID,
            preset: .workspace,
            deliveryMode: .live,
            requestedAt: now,
            expiresAt: now.addingTimeInterval(300),
            sourceDeviceID: "iphone-1",
            clientIntentID: "intent-\(UUID().uuidString)",
            localAuthenticationSatisfied: true,
            localAuthProof: HermesRealtimeRelayAgentGrantLocalAuthProof(
                proofId: "proof-\(UUID().uuidString)",
                deviceId: "iphone-1",
                signedIntentHash: String(repeating: "a", count: 64),
                authenticatedAt: now,
                expiresAt: now.addingTimeInterval(60),
                signatureEd25519: "signature"
            )
        )

        let receipt = AgentCapabilityGrantStore.shared.apply(request, now: now)

        XCTAssertEqual(receipt.status, .denied)
        XCTAssertEqual(receipt.denialReason, .macApprovalRequired)
        XCTAssertNil(AgentCapabilityGrantStore.shared.activeGrant(runtimeID: .codex, threadID: threadID, now: now))
    }

    @MainActor
    func testMacApprovedHighRiskGrantAppliesAfterLocalAuthProof() {
        let now = Date(timeIntervalSince1970: 2_000)
        let threadID = "thread-\(UUID().uuidString)"
        let request = AgentCapabilityGrantRequest(
            requestID: "grant-\(UUID().uuidString)",
            runtimeID: .codex,
            threadID: threadID,
            preset: .workspace,
            deliveryMode: .live,
            requestedAt: now,
            expiresAt: now.addingTimeInterval(300),
            sourceDeviceID: "iphone-1",
            clientIntentID: "intent-\(UUID().uuidString)",
            localAuthenticationSatisfied: true,
            localAuthProof: HermesRealtimeRelayAgentGrantLocalAuthProof(
                proofId: "proof-\(UUID().uuidString)",
                deviceId: "iphone-1",
                signedIntentHash: String(repeating: "b", count: 64),
                authenticatedAt: now,
                expiresAt: now.addingTimeInterval(60),
                signatureEd25519: "signature"
            )
        )

        let receipt = AgentCapabilityGrantStore.shared.apply(request, now: now, macApprovalSatisfied: true)

        XCTAssertEqual(receipt.status, .applied)
        let activeGrant = AgentCapabilityGrantStore.shared.activeGrant(runtimeID: .codex, threadID: threadID, now: now)
        XCTAssertEqual(activeGrant?.capabilities, AgentPermissionPreset.workspace.capabilities)
    }

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
                actionCap: ComputerUseBudgetEnvelope.initialNormal.activeActionsPerRun,
                clientID: BurnBarClientID(rawValue: "client-soft-cap")
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
        XCTAssertEqual(response.status, ComputerUseInvokeResponse.Status.error)
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
            phoneValidator: confirmedPhoneValidator(
                uid: "uid-approval",
                peerNodeId: peerNodeId,
                publicKey: privateKey.publicKey
            ),
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
                connectionId: "conn-attacker",
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
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(coordinator.pendingApproval?.approvalId, approvalRequest.approvalId)
        let actionsBeforeMatchedApproval = await browserCapture.actions()
        XCTAssertEqual(actionsBeforeMatchedApproval.count, 0)

        await dispatcher(
            HermesRealtimeRelayFrame(
                type: .controlApprovalResponse,
                uid: "uid-approval",
                connectionId: "conn-approval",
                control: HermesRealtimeRelayControlPayload(
                    streamClass: MediaStreamClass.controlApproval.rawValue,
                    sessionId: started.sessionId,
                    approvalResponse: try signedApprovalResponse(
                        approvalRequest: approvalRequest,
                        privateKey: privateKey,
                        peerNodeId: peerNodeId,
                        counter: 1
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
        // Blocker 1 (audit-before-action): an executed action now writes a
        // reservation row (carrying the audit-reserved sentinel) BEFORE dispatch
        // and a completion row after — two rows total.
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first?.approvedBy, .phone)
        XCTAssertEqual(entries.first?.approvalId, approvalRequest.approvalId)
        XCTAssertEqual(entries.first?.denyReason, "audit_reserved_pending")
        XCTAssertEqual(entries.last?.approvedBy, .phone)
        XCTAssertEqual(entries.last?.approvalId, approvalRequest.approvalId)
        XCTAssertNil(entries.last?.denyReason)
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
            phoneValidator: confirmedPhoneValidator(
                uid: "uid-stream",
                peerNodeId: peerNodeId,
                publicKey: privateKey.publicKey
            ),
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
            phoneValidator: confirmedPhoneValidator(
                uid: "uid-loopback",
                peerNodeId: peerNodeId,
                publicKey: privateKey.publicKey
            ),
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
        XCTAssertTrue(deniedFrames.isEmpty)
    }

    @MainActor
    func testAgentContextTargetReceiverIngestion() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let peerNodeId = "android-phone-copilot"
        let validator = isolatedPhoneControlAuthorityValidator()
        validator.registerPeer(nodeId: peerNodeId, publicKey: privateKey.publicKey)

        let target = HermesRealtimeRelayAgentContextTarget(
            requestId: UUID().uuidString,
            sessionId: "test-session",
            runtime: "hermes",
            threadId: "test-thread",
            displayId: "main",
            normalizedX: 0.5,
            normalizedY: 0.5,
            normalizedRect: nil,
            instruction: "Click this button",
            focusContext: nil,
            clientIntentId: UUID().uuidString,
            requestedAt: Date(),
            authority: emptyAuthority()
        )

        let signed = try ComputerUsePhoneControlSigner().sign(
            target: target,
            peerNodeId: peerNodeId,
            counter: 1,
            timestamp: Date(),
            privateKey: privateKey
        )

        var signedTarget = target
        signedTarget.authority = envelope(from: signed)

        let frame = HermesRealtimeRelayFrame(
            type: .controlAgentContextTarget,
            uid: "uid-copilot",
            connectionId: "conn-copilot",
            control: HermesRealtimeRelayControlPayload(
                streamClass: MediaStreamClass.controlInput.rawValue,
                agentContextTarget: signedTarget
            )
        )

        var replyReceived: HermesRealtimeRelayFrame?
        let receiver = AgentContextTargetReceiver(
            sessionId: ComputerUseSessionID(rawValue: "test-session"),
            validator: validator,
            chatControllerProvider: { nil },
            displayBoundsProvider: {
                [MacInputCore.DisplayBounds(originX: 0, originY: 0, width: 1_000, height: 1_000)]
            },
            replyFrameSink: { frame in
                replyReceived = frame
            },
            auditLoggerProvider: { nil }
        )
        await receiver.ingest(frame)

        XCTAssertNotNil(replyReceived)
        XCTAssertEqual(replyReceived?.type, .controlDenied)
        XCTAssertEqual(replyReceived?.control?.denied?.reason, .agentUnavailable)
    }

    @MainActor
    func testPhoneControlGateDenialEmitsControlDeniedFrame() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let peerNodeId = "ios-phone-denied"
        let provider = StaticPhoneControlAuthorityProvider(
            expectedUID: "uid-denied",
            expectedConnectionID: "conn-denied",
            expectedPeerNodeID: peerNodeId,
            publicKey: privateKey.publicKey
        )
        let replies = ControlFrameCapture()
        let coordinator = ComputerUseSessionCoordinator(
            configuration: ComputerUseSessionCoordinator.Configuration(
                userId: "uid-denied",
                macHostNodeId: "mac-denied",
                entitlement: ComputerUseEntitlementSnapshot(
                    isActive: true,
                    productId: "hosted_computer_use_sync",
                    allowsSystem: true,
                    allowsPhoneControl: true
                ),
                quotaUsage: ComputerUseQuotaUsage(dayKey: "2026-05-23"),
                auditBaseDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("computer-use-phone-denied-\(UUID().uuidString)", isDirectory: true),
                macAppVersion: "test"
            ),
            authorityProvider: provider,
            phoneValidator: confirmedPhoneValidator(
                uid: "uid-denied",
                peerNodeId: peerNodeId,
                publicKey: privateKey.publicKey
            ),
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
                clientID: BurnBarClientID(rawValue: "client-denied")
            )
        )

        let dispatcher = coordinator.controlDispatcher
        await dispatcher(
            HermesRealtimeRelayFrame(
                type: .controlClassify,
                uid: "uid-denied",
                connectionId: "conn-denied",
                control: HermesRealtimeRelayControlPayload(
                    streamClass: MediaStreamClass.controlInput.rawValue,
                    sessionId: started.sessionId,
                    authorityPeerNodeId: peerNodeId
                )
            ),
            { frame in await replies.record(frame) }
        )
        coordinator.updateEntitlement(ComputerUseEntitlementSnapshot(
            isActive: false,
            productId: "hosted_computer_use_sync",
            allowsSystem: true,
            allowsPhoneControl: true
        ))

        XCTAssertEqual(coordinator.state?.endReason, .entitlementLost)
        XCTAssertNotNil(coordinator.state?.endedAt)

        let response = await coordinator.invoke(BurnBarToolInvocation(
            callID: "entitlement-after-end",
            runID: BurnBarRunID(rawValue: "run-entitlement-ended"),
            tool: .macInputClick,
            arguments: .object(["displayX": .number(10), "displayY": .number(10)]),
            requestedBy: BurnBarClientID(rawValue: "agent"),
            requestedAt: Date()
        ))
        XCTAssertEqual(response.status, ComputerUseInvokeResponse.Status.error)
        XCTAssertEqual(response.denyReason, "no_active_session")
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

        let validator = isolatedPhoneControlAuthorityValidator()
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

        let validator = isolatedPhoneControlAuthorityValidator()
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

    func testSignedTypeIntentDispatchesMacTypeAction() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let signer = ComputerUsePhoneControlSigner()
        let placeholder = emptyAuthority()
        var intent = HermesRealtimeRelayInputIntent(
            kind: .type,
            text: "hello from iphone",
            authority: placeholder
        )
        let signed = try signer.sign(
            intent: intent,
            peerNodeId: "phone-peer-type",
            counter: 1,
            timestamp: Date(),
            privateKey: privateKey
        )
        intent.authority = envelope(from: signed)

        let validator = isolatedPhoneControlAuthorityValidator()
        validator.registerPeer(nodeId: "phone-peer-type", publicKey: privateKey.publicKey)
        let capture = PhoneControlReceiverCapture()
        let receiver = PhoneControlReceiver(
            sessionId: ComputerUseSessionID("session-phone-type"),
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
        XCTAssertEqual(dispatched.sessionId, ComputerUseSessionID("session-phone-type"))
        guard case let .macInput(action) = dispatched.action else {
            return XCTFail("expected macInput action")
        }
        XCTAssertEqual(action.kind, .type)
        XCTAssertEqual(action.text, "hello from iphone")
        let deniedFrames = await capture.deniedFrames()
        XCTAssertTrue(deniedFrames.isEmpty)
    }

    func testSignedPointerMoveIntentDispatchesMacPointerMoveDelta() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let signer = ComputerUsePhoneControlSigner()
        let placeholder = emptyAuthority()
        var intent = HermesRealtimeRelayInputIntent(
            kind: .pointerMove,
            normalizedX2: 17.4,
            normalizedY2: -8.6,
            authority: placeholder
        )
        let signed = try signer.sign(
            intent: intent,
            peerNodeId: "phone-peer-pointer",
            counter: 1,
            timestamp: Date(),
            privateKey: privateKey
        )
        intent.authority = envelope(from: signed)

        let validator = isolatedPhoneControlAuthorityValidator()
        validator.registerPeer(nodeId: "phone-peer-pointer", publicKey: privateKey.publicKey)
        let capture = PhoneControlReceiverCapture()
        let receiver = PhoneControlReceiver(
            sessionId: ComputerUseSessionID("session-phone-pointer"),
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
        XCTAssertEqual(dispatched.sessionId, ComputerUseSessionID("session-phone-pointer"))
        guard case let .macInput(action) = dispatched.action else {
            return XCTFail("expected macInput action")
        }
        XCTAssertEqual(action.kind, .pointerMove)
        XCTAssertEqual(action.deltaX, 17)
        XCTAssertEqual(action.deltaY, -9)
        let deniedFrames = await capture.deniedFrames()
        XCTAssertTrue(deniedFrames.isEmpty)
    }

    func testReplayChaosRejectsOneThousandDuplicateIntentEnvelopes() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let signer = ComputerUsePhoneControlSigner()
        let placeholder = emptyAuthority()
        var intent = HermesRealtimeRelayInputIntent(
            kind: .tap,
            normalizedX: 0.25,
            normalizedY: 0.40,
            mouseButton: 1,
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

        let validator = isolatedPhoneControlAuthorityValidator()
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
        XCTAssertEqual(action.mouseButton, 1)

        let deniedFrames = await capture.deniedFrames()
        XCTAssertEqual(deniedFrames.count, 1_000)
        XCTAssertTrue(deniedFrames.allSatisfy { $0.control?.denied?.reason == .counterReplay })
    }

    func testDuplicateClientIntentIdWithFreshCounterDispatchesOnlyOnce() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let signer = ComputerUsePhoneControlSigner()
        let placeholder = emptyAuthority()
        let clientIntentId = "tap-once-\(UUID().uuidString)"
        var firstIntent = HermesRealtimeRelayInputIntent(
            kind: .tap,
            normalizedX: 0.25,
            normalizedY: 0.40,
            clientIntentId: clientIntentId,
            authority: placeholder
        )
        let firstSigned = try signer.sign(
            intent: firstIntent,
            peerNodeId: "phone-peer-idempotent",
            counter: 1,
            timestamp: Date(),
            privateKey: privateKey
        )
        firstIntent.authority = envelope(from: firstSigned)

        var secondIntent = HermesRealtimeRelayInputIntent(
            kind: .tap,
            normalizedX: 0.25,
            normalizedY: 0.40,
            clientIntentId: clientIntentId,
            authority: placeholder
        )
        let secondSigned = try signer.sign(
            intent: secondIntent,
            peerNodeId: "phone-peer-idempotent",
            counter: 2,
            timestamp: Date(),
            privateKey: privateKey
        )
        secondIntent.authority = envelope(from: secondSigned)

        let validator = isolatedPhoneControlAuthorityValidator()
        validator.registerPeer(nodeId: "phone-peer-idempotent", publicKey: privateKey.publicKey)
        let capture = PhoneControlReceiverCapture()
        let receiver = PhoneControlReceiver(
            sessionId: ComputerUseSessionID("session-phone-idempotent"),
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

        await receiver.ingest(frame(firstIntent))
        await receiver.ingest(frame(secondIntent))

        let actions = await capture.actions()
        XCTAssertEqual(actions.count, 1)
        guard case let .macInput(action) = actions.first?.action else {
            return XCTFail("expected first intent to dispatch as macInput")
        }
        XCTAssertEqual(action.kind, .click)
        XCTAssertEqual(action.displayX, 250)
        XCTAssertEqual(action.displayY, 200)

        let deniedFrames = await capture.deniedFrames()
        XCTAssertEqual(deniedFrames.count, 1)
        XCTAssertEqual(deniedFrames.first?.control?.denied?.reason, .counterReplay)
        XCTAssertEqual(deniedFrames.first?.control?.denied?.detail, "duplicate_client_intent")
    }

    @MainActor
    func testSignedClipboardPasteWritesMacPasteboardDispatchesPasteAndAuditsWithoutContent() async throws {
        let secret = "phone clipboard secret \(UUID().uuidString)"
        let privateKey = Curve25519.Signing.PrivateKey()
        let peerNodeId = "ios-phone-clipboard-paste"
        let provider = StaticPhoneControlAuthorityProvider(
            expectedUID: "uid-clipboard-paste",
            expectedConnectionID: "conn-clipboard-paste",
            expectedPeerNodeID: peerNodeId,
            publicKey: privateKey.publicKey
        )
        let pasteboard = FakeRemoteClipboardPasteboard()
        let input = FakeRemoteClipboardInputController()
        let inspector = FakeRemoteClipboardInspector()
        let replies = ControlFrameCapture()
        let auditDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("computer-use-clipboard-paste-\(UUID().uuidString)", isDirectory: true)
        let coordinator = ComputerUseSessionCoordinator(
            configuration: ComputerUseSessionCoordinator.Configuration(
                userId: "uid-clipboard-paste",
                macHostNodeId: "mac-clipboard",
                entitlement: ComputerUseEntitlementSnapshot(
                    isActive: true,
                    productId: "hosted_computer_use_sync",
                    allowsSystem: true,
                    allowsPhoneControl: true
                ),
                quotaUsage: ComputerUseQuotaUsage(dayKey: "2026-05-25"),
                auditBaseDirectory: auditDirectory,
                macAppVersion: "test",
                clipboardConsentGranted: true
            ),
            remoteClipboardController: RemoteClipboardController(
                pasteboard: pasteboard,
                inputController: input,
                inspector: inspector
            ),
            authorityProvider: provider,
            phoneValidator: confirmedPhoneValidator(
                uid: "uid-clipboard-paste",
                peerNodeId: peerNodeId,
                publicKey: privateKey.publicKey
            ),
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
                phoneViewerNodeId: peerNodeId,
                clientID: BurnBarClientID(rawValue: "client-clipboard-paste")
            )
        )
        let dispatcher = coordinator.controlDispatcher
        await dispatcher(clipboardClassify(uid: "uid-clipboard-paste", connectionId: "conn-clipboard-paste", sessionId: started.sessionId, peerNodeId: peerNodeId)) {
            frame in await replies.record(frame)
        }

        let request = try signedClipboardRequest(
            action: .pasteToMac,
            text: secret,
            privateKey: privateKey,
            peerNodeId: peerNodeId,
            counter: 1
        )
        await dispatcher(clipboardFrame(request, uid: "uid-clipboard-paste", connectionId: "conn-clipboard-paste", sessionId: started.sessionId)) {
            frame in await replies.record(frame)
        }

        let responseFrame = try await replies.firstFrame { $0.type == .controlClipboardResponse }
        let response = try XCTUnwrap(responseFrame.control?.clipboardResponse)
        XCTAssertEqual(response.status, .accepted)
        XCTAssertEqual(response.action, .pasteToMac)
        XCTAssertNil(response.text)
        XCTAssertEqual(pasteboard.storedText, secret)
        XCTAssertEqual(input.pasteShortcutCount, 1)
        XCTAssertEqual(coordinator.actionTimeline.last?.actionKind, "clipboard.paste_to_mac")
        XCTAssertEqual(coordinator.actionTimeline.last?.status, .completed)

        let chainText = try auditChainText(baseDirectory: auditDirectory, sessionId: started.sessionId)
        XCTAssertFalse(chainText.contains(secret))
        XCTAssertTrue(chainText.contains("clipboard.paste_to_mac"))
    }

    @MainActor
    func testSignedClipboardGrabReturnsMacTextWithoutPasting() async throws {
        let macClipboard = "mac clipboard text \(UUID().uuidString)"
        let privateKey = Curve25519.Signing.PrivateKey()
        let peerNodeId = "ios-phone-clipboard-grab"
        let provider = StaticPhoneControlAuthorityProvider(
            expectedUID: "uid-clipboard-grab",
            expectedConnectionID: "conn-clipboard-grab",
            expectedPeerNodeID: peerNodeId,
            publicKey: privateKey.publicKey
        )
        let pasteboard = FakeRemoteClipboardPasteboard(storedText: macClipboard)
        let input = FakeRemoteClipboardInputController()
        let inspector = FakeRemoteClipboardInspector()
        let replies = ControlFrameCapture()
        let auditDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("computer-use-clipboard-grab-\(UUID().uuidString)", isDirectory: true)
        let coordinator = ComputerUseSessionCoordinator(
            configuration: ComputerUseSessionCoordinator.Configuration(
                userId: "uid-clipboard-grab",
                macHostNodeId: "mac-clipboard",
                entitlement: ComputerUseEntitlementSnapshot(
                    isActive: true,
                    productId: "hosted_computer_use_sync",
                    allowsSystem: true,
                    allowsPhoneControl: true
                ),
                quotaUsage: ComputerUseQuotaUsage(dayKey: "2026-05-25"),
                auditBaseDirectory: auditDirectory,
                macAppVersion: "test",
                clipboardConsentGranted: true
            ),
            remoteClipboardController: RemoteClipboardController(
                pasteboard: pasteboard,
                inputController: input,
                inspector: inspector
            ),
            authorityProvider: provider,
            phoneValidator: confirmedPhoneValidator(
                uid: "uid-clipboard-grab",
                peerNodeId: peerNodeId,
                publicKey: privateKey.publicKey
            ),
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
                phoneViewerNodeId: peerNodeId,
                clientID: BurnBarClientID(rawValue: "client-clipboard-grab")
            )
        )
        let dispatcher = coordinator.controlDispatcher
        await dispatcher(clipboardClassify(uid: "uid-clipboard-grab", connectionId: "conn-clipboard-grab", sessionId: started.sessionId, peerNodeId: peerNodeId)) {
            frame in await replies.record(frame)
        }

        let request = try signedClipboardRequest(
            action: .grabFromMac,
            text: nil,
            privateKey: privateKey,
            peerNodeId: peerNodeId,
            counter: 1
        )
        await dispatcher(clipboardFrame(request, uid: "uid-clipboard-grab", connectionId: "conn-clipboard-grab", sessionId: started.sessionId)) {
            frame in await replies.record(frame)
        }

        let responseFrame = try await replies.firstFrame { $0.type == .controlClipboardResponse }
        let response = try XCTUnwrap(responseFrame.control?.clipboardResponse)
        XCTAssertEqual(response.status, .accepted)
        XCTAssertEqual(response.action, .grabFromMac)
        XCTAssertEqual(response.text, macClipboard)
        XCTAssertEqual(response.contentType, "text/plain")
        XCTAssertEqual(input.pasteShortcutCount, 0)
        XCTAssertEqual(coordinator.actionTimeline.last?.actionKind, "clipboard.grab_from_mac")

        let chainText = try auditChainText(baseDirectory: auditDirectory, sessionId: started.sessionId)
        XCTAssertFalse(chainText.contains(macClipboard))
        XCTAssertTrue(chainText.contains("clipboard.grab_from_mac"))
    }

    @MainActor
    func testClipboardDeniedWithoutDedicatedConsentEvenWhenInputAllowed() async throws {
        // Consent is split from allowsSystem: with a valid signed paste and
        // full remote-control entitlement but `clipboardConsentGranted` OFF,
        // the clipboard request must fail closed (`clipboard_consent_required`)
        // and never touch the pasteboard.
        let secret = "phone clipboard secret \(UUID().uuidString)"
        let privateKey = Curve25519.Signing.PrivateKey()
        let peerNodeId = "ios-phone-clipboard-noconsent"
        let provider = StaticPhoneControlAuthorityProvider(
            expectedUID: "uid-clipboard-noconsent",
            expectedConnectionID: "conn-clipboard-noconsent",
            expectedPeerNodeID: peerNodeId,
            publicKey: privateKey.publicKey
        )
        let pasteboard = FakeRemoteClipboardPasteboard(storedText: "before")
        let input = FakeRemoteClipboardInputController()
        let inspector = FakeRemoteClipboardInspector()
        let replies = ControlFrameCapture()
        let auditDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("computer-use-clipboard-noconsent-\(UUID().uuidString)", isDirectory: true)
        let coordinator = ComputerUseSessionCoordinator(
            configuration: ComputerUseSessionCoordinator.Configuration(
                userId: "uid-clipboard-noconsent",
                macHostNodeId: "mac-clipboard",
                entitlement: ComputerUseEntitlementSnapshot(
                    isActive: true,
                    productId: "hosted_computer_use_sync",
                    allowsSystem: true,
                    allowsPhoneControl: true
                ),
                quotaUsage: ComputerUseQuotaUsage(dayKey: "2026-05-25"),
                auditBaseDirectory: auditDirectory,
                macAppVersion: "test"
                // clipboardConsentGranted intentionally omitted -> defaults OFF.
            ),
            remoteClipboardController: RemoteClipboardController(
                pasteboard: pasteboard,
                inputController: input,
                inspector: inspector
            ),
            authorityProvider: provider,
            phoneValidator: confirmedPhoneValidator(
                uid: "uid-clipboard-noconsent",
                peerNodeId: peerNodeId,
                publicKey: privateKey.publicKey
            ),
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
                phoneViewerNodeId: peerNodeId,
                clientID: BurnBarClientID(rawValue: "client-clipboard-noconsent")
            )
        )
        let dispatcher = coordinator.controlDispatcher
        await dispatcher(clipboardClassify(uid: "uid-clipboard-noconsent", connectionId: "conn-clipboard-noconsent", sessionId: started.sessionId, peerNodeId: peerNodeId)) {
            frame in await replies.record(frame)
        }

        let request = try signedClipboardRequest(
            action: .pasteToMac,
            text: secret,
            privateKey: privateKey,
            peerNodeId: peerNodeId,
            counter: 1
        )
        await dispatcher(clipboardFrame(request, uid: "uid-clipboard-noconsent", connectionId: "conn-clipboard-noconsent", sessionId: started.sessionId)) {
            frame in await replies.record(frame)
        }

        let responseFrame = try await replies.firstFrame { $0.type == .controlClipboardResponse }
        let response = try XCTUnwrap(responseFrame.control?.clipboardResponse)
        XCTAssertEqual(response.status, .denied)
        XCTAssertEqual(response.detail, ComputerUseDenyReason.clipboardConsentRequired.rawValue)
        XCTAssertEqual(pasteboard.storedText, "before")
        XCTAssertEqual(input.pasteShortcutCount, 0)
        XCTAssertEqual(coordinator.lastDeniedReason, .clipboardConsentRequired)
        XCTAssertEqual(coordinator.actionTimeline.last?.status, .rejected)
    }

    @MainActor
    func testStrictAttestationDeniesClipboardBeforePasteboardOrInputMutation() async throws {
        let previousStrictSetting = SettingsManager.shared.computerUsePhoneControlAttestationRequired
        SettingsManager.shared.computerUsePhoneControlAttestationRequired = true
        defer { SettingsManager.shared.computerUsePhoneControlAttestationRequired = previousStrictSetting }

        let privateKey = Curve25519.Signing.PrivateKey()
        let peerNodeId = "ios-phone-clipboard-attestation"
        let provider = StaticPhoneControlAuthorityProvider(
            expectedUID: "uid-clipboard-attestation",
            expectedConnectionID: "conn-clipboard-attestation",
            expectedPeerNodeID: peerNodeId,
            publicKey: privateKey.publicKey
        )
        let pasteboard = FakeRemoteClipboardPasteboard(storedText: "before")
        let input = FakeRemoteClipboardInputController()
        let inspector = FakeRemoteClipboardInspector()
        let replies = ControlFrameCapture()
        let coordinator = ComputerUseSessionCoordinator(
            configuration: ComputerUseSessionCoordinator.Configuration(
                userId: "uid-clipboard-attestation",
                macHostNodeId: "mac-clipboard",
                entitlement: ComputerUseEntitlementSnapshot(
                    isActive: true,
                    productId: "hosted_computer_use_sync",
                    allowsSystem: true,
                    allowsPhoneControl: true
                ),
                quotaUsage: ComputerUseQuotaUsage(dayKey: "2026-05-25"),
                auditBaseDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("computer-use-clipboard-attestation-\(UUID().uuidString)", isDirectory: true),
                macAppVersion: "test",
                clipboardConsentGranted: true
            ),
            remoteClipboardController: RemoteClipboardController(
                pasteboard: pasteboard,
                inputController: input,
                inspector: inspector
            ),
            authorityProvider: provider,
            phoneValidator: confirmedPhoneValidator(
                uid: "uid-clipboard-attestation",
                peerNodeId: peerNodeId,
                publicKey: privateKey.publicKey
            ),
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
                phoneViewerNodeId: peerNodeId,
                clientID: BurnBarClientID(rawValue: "client-clipboard-attestation")
            )
        )
        let dispatcher = coordinator.controlDispatcher
        await dispatcher(clipboardClassify(uid: "uid-clipboard-attestation", connectionId: "conn-clipboard-attestation", sessionId: started.sessionId, peerNodeId: peerNodeId)) {
            frame in await replies.record(frame)
        }

        let request = try signedClipboardRequest(
            action: .pasteToMac,
            text: "blocked by attestation",
            privateKey: privateKey,
            peerNodeId: peerNodeId,
            counter: 1
        )
        await dispatcher(clipboardFrame(request, uid: "uid-clipboard-attestation", connectionId: "conn-clipboard-attestation", sessionId: started.sessionId)) {
            frame in await replies.record(frame)
        }

        let responseFrame = try await replies.firstFrame { $0.type == .controlClipboardResponse }
        let response = try XCTUnwrap(responseFrame.control?.clipboardResponse)
        XCTAssertEqual(response.status, .denied)
        XCTAssertEqual(response.detail, "mac_attestation_unbound")
        XCTAssertEqual(pasteboard.storedText, "before")
        XCTAssertEqual(input.pasteShortcutCount, 0)
        XCTAssertEqual(coordinator.lastDeniedReason, .signatureFailure)
        XCTAssertEqual(coordinator.actionTimeline.last?.status, .rejected)
    }

    @MainActor
    func testClipboardPasteDeniedInSecureFocusBeforePasteboardOrInputMutation() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let peerNodeId = "ios-phone-clipboard-denied"
        let provider = StaticPhoneControlAuthorityProvider(
            expectedUID: "uid-clipboard-denied",
            expectedConnectionID: "conn-clipboard-denied",
            expectedPeerNodeID: peerNodeId,
            publicKey: privateKey.publicKey
        )
        let pasteboard = FakeRemoteClipboardPasteboard(storedText: "before")
        let input = FakeRemoteClipboardInputController()
        let inspector = FakeRemoteClipboardInspector(denyReason: .secureTextField)
        let replies = ControlFrameCapture()
        let auditDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("computer-use-clipboard-denied-\(UUID().uuidString)", isDirectory: true)
        let coordinator = ComputerUseSessionCoordinator(
            configuration: ComputerUseSessionCoordinator.Configuration(
                userId: "uid-clipboard-denied",
                macHostNodeId: "mac-clipboard",
                entitlement: ComputerUseEntitlementSnapshot(
                    isActive: true,
                    productId: "hosted_computer_use_sync",
                    allowsSystem: true,
                    allowsPhoneControl: true
                ),
                quotaUsage: ComputerUseQuotaUsage(dayKey: "2026-05-25"),
                auditBaseDirectory: auditDirectory,
                macAppVersion: "test",
                clipboardConsentGranted: true
            ),
            remoteClipboardController: RemoteClipboardController(
                pasteboard: pasteboard,
                inputController: input,
                inspector: inspector
            ),
            authorityProvider: provider,
            phoneValidator: confirmedPhoneValidator(
                uid: "uid-clipboard-replay",
                peerNodeId: peerNodeId,
                publicKey: privateKey.publicKey
            ),
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
                phoneViewerNodeId: peerNodeId,
                clientID: BurnBarClientID(rawValue: "client-clipboard-denied")
            )
        )
        let dispatcher = coordinator.controlDispatcher
        await dispatcher(clipboardClassify(uid: "uid-clipboard-denied", connectionId: "conn-clipboard-denied", sessionId: started.sessionId, peerNodeId: peerNodeId)) {
            frame in await replies.record(frame)
        }

        let request = try signedClipboardRequest(
            action: .pasteToMac,
            text: "blocked clipboard",
            privateKey: privateKey,
            peerNodeId: peerNodeId,
            counter: 1
        )
        await dispatcher(clipboardFrame(request, uid: "uid-clipboard-denied", connectionId: "conn-clipboard-denied", sessionId: started.sessionId)) {
            frame in await replies.record(frame)
        }

        let responseFrame = try await replies.firstFrame { $0.type == .controlClipboardResponse }
        let response = try XCTUnwrap(responseFrame.control?.clipboardResponse)
        XCTAssertEqual(response.status, .denied)
        XCTAssertEqual(response.detail, ComputerUseDenyReason.denyRegion.rawValue)
        XCTAssertEqual(pasteboard.storedText, "before")
        XCTAssertEqual(input.pasteShortcutCount, 0)
        XCTAssertEqual(coordinator.lastDeniedReason, .denyRegion)
        XCTAssertEqual(coordinator.actionTimeline.last?.status, .rejected)
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

    private func clipboardFrame(
        _ request: HermesRealtimeRelayClipboardRequest,
        uid: String,
        connectionId: String,
        sessionId: String
    ) -> HermesRealtimeRelayFrame {
        HermesRealtimeRelayFrame(
            type: .controlClipboardRequest,
            uid: uid,
            connectionId: connectionId,
            requestId: request.requestId,
            control: HermesRealtimeRelayControlPayload(
                streamClass: "control.clipboard",
                sessionId: sessionId,
                clipboardRequest: request
            )
        )
    }

    private func clipboardClassify(
        uid: String,
        connectionId: String,
        sessionId: String,
        peerNodeId: String
    ) -> HermesRealtimeRelayFrame {
        HermesRealtimeRelayFrame(
            type: .controlClassify,
            uid: uid,
            connectionId: connectionId,
            control: HermesRealtimeRelayControlPayload(
                streamClass: MediaStreamClass.controlInput.rawValue,
                sessionId: sessionId,
                authorityPeerNodeId: peerNodeId
            )
        )
    }

    private func signedClipboardRequest(
        action: HermesRealtimeRelayClipboardAction,
        text: String?,
        privateKey: Curve25519.Signing.PrivateKey,
        peerNodeId: String,
        counter: UInt64
    ) throws -> HermesRealtimeRelayClipboardRequest {
        var request = HermesRealtimeRelayClipboardRequest(
            requestId: UUID().uuidString,
            action: action,
            contentType: "text/plain",
            text: text,
            maxBytes: 65_536,
            clientIntentId: UUID().uuidString,
            authority: emptyAuthority()
        )
        let signed = try ComputerUsePhoneControlSigner().sign(
            clipboardRequest: request,
            peerNodeId: peerNodeId,
            counter: counter,
            timestamp: Date(),
            privateKey: privateKey
        )
        request.authority = envelope(from: signed)
        return request
    }

    private func signedApprovalResponse(
        approvalRequest: HermesRealtimeRelayApprovalRequest,
        privateKey: Curve25519.Signing.PrivateKey,
        peerNodeId: String,
        counter: UInt64
    ) throws -> HermesRealtimeRelayApprovalResponse {
        let requestHash = try ComputerUsePhoneControlSigner()
            .canonicalApprovalRequestHashHex(request: approvalRequest)
        var response = HermesRealtimeRelayApprovalResponse(
            approvalId: approvalRequest.approvalId,
            decision: .approve,
            respondedBy: "phone",
            respondedAt: Date(),
            requestHashBlake3: requestHash
        )
        let signed = try ComputerUsePhoneControlSigner().sign(
            approvalResponse: response,
            peerNodeId: peerNodeId,
            counter: counter,
            timestamp: Date(),
            privateKey: privateKey
        )
        response.authority = envelope(from: signed)
        return response
    }

    private func auditChainText(baseDirectory: URL, sessionId: String) throws -> String {
        let chainURL = baseDirectory
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("chain.jsonl")
        return try String(contentsOf: chainURL, encoding: .utf8)
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
        from signed: ComputerUsePhoneControlSigner.SignedAuthority,
        attestationHashBlake3: String? = nil
    ) -> HermesRealtimeRelayAuthorityEnvelope {
        HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: signed.peerNodeId,
            counter: signed.counter,
            timestamp: signed.timestamp,
            intentHashBlake3: signed.intentHashHex,
            signatureEd25519: signed.signatureBase64,
            attestationHashBlake3: attestationHashBlake3
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

private final class FakeRemoteClipboardPasteboard: RemoteClipboardPasteboard, @unchecked Sendable {
    var storedText: String?

    init(storedText: String? = nil) {
        self.storedText = storedText
    }

    func readString() -> String? {
        storedText
    }

    func writeString(_ text: String) throws {
        storedText = text
    }
}

private final class FakeRemoteClipboardInputController: RemoteClipboardInputControlling, @unchecked Sendable {
    var accessibilityTrusted = true
    var pasteShortcutCount = 0

    func isAccessibilityTrusted() -> Bool {
        accessibilityTrusted
    }

    @discardableResult
    func pasteShortcut() throws -> Double {
        pasteShortcutCount += 1
        return 0
    }
}

private final class FakeRemoteClipboardInspector: RemoteClipboardContextInspecting, @unchecked Sendable {
    var scopeContext: ComputerUseScopeContext
    var denyReason: ComputerUseAccessibilityDenyReason?

    init(
        scopeContext: ComputerUseScopeContext = ComputerUseScopeContext(
            url: nil,
            bundleId: "com.apple.TextEdit",
            windowTitle: "Notes"
        ),
        denyReason: ComputerUseAccessibilityDenyReason? = nil
    ) {
        self.scopeContext = scopeContext
        self.denyReason = denyReason
    }

    func currentScopeContext() -> ComputerUseScopeContext {
        scopeContext
    }

    func focusedDenyReason() -> ComputerUseAccessibilityDenyReason? {
        denyReason
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
    ) async throws -> PhoneControlVerifyingKey {
        fetchCount += 1
        XCTAssertEqual(uid, expectedUID)
        XCTAssertEqual(connectionId, expectedConnectionID)
        XCTAssertEqual(peerNodeId, expectedPeerNodeID)
        return .ed25519(publicKey)
    }
}

private func confirmedPhoneValidator(
    uid: String,
    peerNodeId: String,
    publicKey: Curve25519.Signing.PublicKey
) -> PhoneControlAuthorityValidator {
    let backing = InMemoryControllerKeyPinBacking()
    let pinStore = ControllerKeyPinStore(backing: backing)
    let advertisedKey = publicKey.rawRepresentation.base64EncodedString()
    _ = pinStore.verifyOrPin(
        advertisedKeyBase64: advertisedKey,
        uid: uid,
        peerNodeId: peerNodeId
    )
    _ = pinStore.confirm(
        advertisedKeyBase64: advertisedKey,
        uid: uid,
        peerNodeId: peerNodeId
    )
    return isolatedPhoneControlAuthorityValidator(controllerPinStore: pinStore)
}

private func isolatedPhoneControlAuthorityValidator(
    controllerPinStore: ControllerKeyPinStore? = ControllerKeyPinStore()
) -> PhoneControlAuthorityValidator {
    let storeURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("openburnbar-phone-control-receiver-tests", isDirectory: true)
        .appendingPathComponent("\(UUID().uuidString)-replay-counters.json")
    return PhoneControlAuthorityValidator(
        controllerPinStore: controllerPinStore,
        replayCounterStore: PhoneControlReplayCounterStore(fileURL: storeURL)
    )
}
#endif
