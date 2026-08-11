import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import OpenBurnBarKernel
import XCTest

final class SafariNativeBridgeControllerTests: XCTestCase {
    func test_codecRejectsUnknownTopLevelFieldAndProtocolMismatch() throws {
        let unknown: [String: Any] = [
            "protocolVersion": BurnBarSafariBridgeWire.protocolVersion,
            "id": "request-1",
            "method": "bridge.poll",
            "params": [
                "sessionId": "session-1",
                "knownTabs": []
            ],
            "smuggledMethod": "daemon.config.update"
        ]
        XCTAssertThrowsError(
            try BurnBarSafariNativeBridgeCodec.decodeRequest(from: unknown)
        ) { error in
            XCTAssertEqual(
                (error as? BurnBarSafariBridgeFailure)?.payload.code,
                "invalid_bridge_schema"
            )
        }

        var mismatch = unknown
        mismatch.removeValue(forKey: "smuggledMethod")
        mismatch["protocolVersion"] = BurnBarSafariBridgeWire.protocolVersion + 1
        XCTAssertThrowsError(
            try BurnBarSafariNativeBridgeCodec.decodeRequest(from: mismatch)
        ) { error in
            XCTAssertEqual(
                (error as? BurnBarSafariBridgeFailure)?.payload.code,
                "protocol_mismatch"
            )
        }
    }

    func test_helloBootstrapsBeforeAttachAndEmitsFractionalISODate() throws {
        let recorder = SafariRPCRecorder { method, _ in
            switch method {
            case .safariBootstrap:
                return try BurnBarSafariNativeBridgeCodec.daemonJSONValue(
                    BurnBarSafariBootstrapResponse(
                        daemonVersion: "1.0.34",
                        protocolVersion: BurnBarSafariProtocol.currentVersion,
                        gatewayBaseURL: "http://127.0.0.1:8317",
                        gatewayBearerToken: "scoped-token",
                        gatewayAvailable: true,
                        computerUseAvailable: true,
                        learningAvailable: true,
                        learningOptedIn: false,
                        tier: "burnbar_pro"
                    )
                )
            case .safariSessionAttach:
                return try BurnBarSafariNativeBridgeCodec.daemonJSONValue(
                    BurnBarSafariSessionAttachResponse(
                        sessionId: "session-attached",
                        protocolVersion: BurnBarSafariProtocol.currentVersion,
                        leaseExpiresAt: Date(timeIntervalSince1970: 1_786_345_678.125),
                        pollAfterMillis: 240
                    )
                )
            default:
                XCTFail("unexpected method \(method.rawValue)")
                throw SafariTestFailure.unexpected(method.rawValue)
            }
        }
        let controller = try makeController(recorder: recorder)
        let response = try responseObject(controller.handle(propertyList: helloRequest()))
        XCTAssertNil(response["error"])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["sessionId"] as? String, "session-attached")
        XCTAssertEqual(result["protocolVersion"] as? Int, BurnBarSafariProtocol.currentVersion)
        XCTAssertEqual(result["pollAfterMillis"] as? Int, 240)
        let lease = try XCTUnwrap(result["leaseExpiresAt"] as? String)
        XCTAssertNotNil(
            lease.range(
                of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#,
                options: .regularExpression
            ),
            "WebExtension dates must be emitted as fractional ISO-8601: \(lease)"
        )
        XCTAssertEqual(
            recorder.methods,
            [
                BurnBarRPCMethod.safariBootstrap,
                BurnBarRPCMethod.safariSessionAttach
            ],
            "hello must bootstrap first, then attach exactly once"
        )
    }

    func test_completeAcceptsWholeSecondISODateAndSendsDefaultCodableDate() throws {
        let recorder = SafariRPCRecorder { method, _ in
            XCTAssertEqual(method, .safariCommandComplete)
            return try BurnBarSafariNativeBridgeCodec.daemonJSONValue(
                BurnBarSafariCommandCompletionResponse(accepted: true)
            )
        }
        let controller = try makeController(recorder: recorder)
        let capturedAt = "2026-08-10T15:04:05Z"
        let request: [String: Any] = [
            "protocolVersion": BurnBarSafariBridgeWire.protocolVersion,
            "id": "complete-1",
            "method": "bridge.complete",
            "params": [
                "sessionId": "session-1",
                "commandId": "command-1",
                "ok": true,
                "result": ["clicked": true],
                "pageState": pageState(capturedAt: capturedAt),
                "tabs": []
            ]
        ]
        let response = try responseObject(controller.handle(propertyList: request))
        XCTAssertNil(response["error"])

        let sent = try XCTUnwrap(recorder.calls.first?.params)
        let decoded = try BurnBarSafariNativeBridgeCodec.decodeDaemonValue(
            BurnBarSafariCommandCompletionRequest.self,
            from: sent
        )
        XCTAssertEqual(
            decoded.pageState.capturedAt.timeIntervalSince1970,
            1_786_374_245,
            accuracy: 0.001
        )
        guard case .object(let sentObject) = sent,
              case .object(let state)? = sentObject["pageState"],
              case .number = state["capturedAt"] else {
            return XCTFail("daemon boundary must retain default Swift Codable Date numbers")
        }
    }

    func test_pollTranslatesDefaultDaemonDatesBackToISO() throws {
        let recorder = SafariRPCRecorder { method, _ in
            XCTAssertEqual(method, .safariCommandPoll)
            return try BurnBarSafariNativeBridgeCodec.daemonJSONValue(
                BurnBarSafariCommandPollResponse(
                    command: BurnBarSafariCommand(
                        commandId: "command-7",
                        sessionId: "session-1",
                        action: .click,
                        arguments: .object(["selector": .string("#buy")]),
                        targetTabId: 4,
                        expectedNavigationEpoch: 2,
                        issuedAt: Date(timeIntervalSince1970: 1_786_345_000),
                        expiresAt: Date(timeIntervalSince1970: 1_786_345_030)
                    ),
                    leaseExpiresAt: Date(timeIntervalSince1970: 1_786_345_060),
                    pollAfterMillis: 180
                )
            )
        }
        let controller = try makeController(recorder: recorder)
        let request: [String: Any] = [
            "protocolVersion": BurnBarSafariBridgeWire.protocolVersion,
            "id": "poll-1",
            "method": "bridge.poll",
            "params": [
                "sessionId": "session-1",
                "activePage": pageState(capturedAt: "2026-08-10T15:04:05.250Z"),
                "knownTabs": []
            ]
        ]
        let response = try responseObject(controller.handle(propertyList: request))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertTrue((result["leaseExpiresAt"] as? String)?.contains("T") == true)
        let command = try XCTUnwrap(result["command"] as? [String: Any])
        XCTAssertTrue((command["issuedAt"] as? String)?.hasSuffix("Z") == true)
        XCTAssertTrue((command["expiresAt"] as? String)?.hasSuffix("Z") == true)
    }

    func test_nativeAskAndArbitraryAliasesFailClosedWithoutDaemonCalls() throws {
        let recorder = SafariRPCRecorder { method, _ in
            XCTFail("unsupported aliases must not reach daemon method \(method.rawValue)")
            return .null
        }
        let controller = try makeController(recorder: recorder)

        let ask = popupRequest(
            id: "popup-ask",
            action: "ask",
            payload: ["safariSessionId": "session-1"]
        )
        let askResponse = try responseObject(controller.handle(propertyList: ask))
        XCTAssertEqual(
            (askResponse["error"] as? [String: Any])?["code"] as? String,
            "native_ask_unsupported"
        )

        let smuggled = popupRequest(
            id: "popup-smuggled",
            action: "daemon.config.update",
            payload: [
                "safariSessionId": "session-1",
                "method": "daemon.config.update"
            ]
        )
        let smuggledResponse = try responseObject(controller.handle(propertyList: smuggled))
        XCTAssertEqual(
            (smuggledResponse["error"] as? [String: Any])?["code"] as? String,
            "unsupported_popup_action"
        )
        XCTAssertTrue(recorder.calls.isEmpty)
    }

    func test_popupSessionBindingCannotBeSubstitutedInsidePayload() throws {
        let recorder = SafariRPCRecorder { _, _ in
            XCTFail("mismatched session must not reach daemon")
            return .null
        }
        let controller = try makeController(recorder: recorder)
        let request: [String: Any] = [
            "protocolVersion": BurnBarSafariBridgeWire.protocolVersion,
            "id": "popup-session-mismatch",
            "method": "bridge.popupAction",
            "params": [
                "sessionId": "session-authoritative",
                "action": "catalog",
                "payload": ["safariSessionId": "session-substituted"]
            ]
        ]
        let response = try responseObject(controller.handle(propertyList: request))
        XCTAssertEqual(
            (response["error"] as? [String: Any])?["code"] as? String,
            "safari_session_mismatch"
        )
        XCTAssertTrue(recorder.calls.isEmpty)
    }

    func test_handoffUsesDedicatedBoundedRPCAndPreservesApprovedPagePackage() throws {
        let recorder = SafariRPCRecorder { method, params in
            XCTAssertEqual(method, .safariHandoff)
            let request = try BurnBarSafariNativeBridgeCodec.decodeDaemonValue(
                BurnBarSafariHandoffRequest.self,
                from: params
            )
            XCTAssertEqual(request.safariSessionId, "session-1")
            XCTAssertEqual(request.targetHarness, "codex")
            XCTAssertEqual(request.prompt, "Compare the visible plans.")
            XCTAssertEqual(request.pageState.tabId, 4)
            XCTAssertEqual(request.pageState.url, "https://example.com/products")
            XCTAssertEqual(request.pageState.navigationEpoch, 2)
            XCTAssertEqual(request.readableMarkdown, "# Plans\n\nStarter is $10.")
            XCTAssertEqual(
                request.accessibilitySnapshot,
                #"[ref=obb-1] [role=button] [name="Choose Starter"]"#
            )
            XCTAssertEqual(request.screenshotJPEG, Data([0xFF, 0xD8, 0xFF, 0xD9]))
            XCTAssertEqual(request.screenshotWidth, 1024)
            XCTAssertEqual(request.screenshotHeight, 768)
            XCTAssertFalse(request.screenshotTruncated)
            guard case .object(let object) = params else {
                throw SafariTestFailure.unexpected("handoff params were not an object")
            }
            XCTAssertEqual(
                Set(object.keys),
                Set([
                    "safariSessionId", "targetHarness", "prompt", "pageState",
                    "readableMarkdown", "accessibilitySnapshot", "screenshotJPEG",
                    "screenshotWidth", "screenshotHeight", "screenshotTruncated"
                ]),
                "The browser must not choose a daemon method, argv, or package path."
            )
            return try BurnBarSafariNativeBridgeCodec.daemonJSONValue(
                BurnBarSafariHandoffResponse(
                    runId: "safari-handoff-run",
                    phase: .completed,
                    launched: true,
                    running: false
                )
            )
        }
        let controller = try makeController(recorder: recorder)

        let response = try responseObject(
            controller.handle(
                propertyList: popupRequest(
                    id: "popup-handoff",
                    action: "handoff",
                    payload: handoffPayload()
                )
            )
        )

        XCTAssertNil(response["error"])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let output = try XCTUnwrap(result["output"] as? [String: Any])
        XCTAssertEqual(output["runId"] as? String, "safari-handoff-run")
        XCTAssertEqual(output["phase"] as? String, BurnBarRunPhase.completed.rawValue)
        XCTAssertEqual(output["launched"] as? Bool, true)
        XCTAssertEqual(output["running"] as? Bool, false)
        XCTAssertEqual(recorder.methods, [.safariHandoff])
        XCTAssertFalse(recorder.methods.contains(.runResume))
    }

    func test_approvalUsesDedicatedSafariIdentityWithoutComputerUseSubstitution() throws {
        let recorder = SafariRPCRecorder { method, params in
            XCTAssertEqual(method, .safariApprovalRespond)
            let request = try BurnBarSafariNativeBridgeCodec.decodeDaemonValue(
                BurnBarSafariApprovalRespondRequest.self,
                from: params
            )
            XCTAssertEqual(request.safariSessionId, "session-1")
            XCTAssertEqual(request.approvalId, "approval-7")
            XCTAssertEqual(request.decision, .allowOnce)
            guard case .object(let object) = params else {
                throw SafariTestFailure.unexpected("approval params were not an object")
            }
            XCTAssertEqual(
                Set(object.keys),
                Set(["safariSessionId", "approvalId", "decision"])
            )
            XCTAssertNil(object["sessionId"])
            XCTAssertNil(object["computerUseSessionId"])
            return try BurnBarSafariNativeBridgeCodec.daemonJSONValue(
                BurnBarSafariApprovalRespondResponse(
                    accepted: true,
                    approvalId: "approval-7",
                    runId: "run-7"
                )
            )
        }
        let controller = try makeController(recorder: recorder)

        let response = try responseObject(
            controller.handle(
                propertyList: popupRequest(
                    id: "popup-approval",
                    action: "approval",
                    payload: [
                        "safariSessionId": "session-1",
                        "approvalId": "approval-7",
                        "decision": "allow_once"
                    ]
                )
            )
        )

        XCTAssertNil(response["error"])
        XCTAssertEqual(recorder.methods, [.safariApprovalRespond])
        XCTAssertFalse(recorder.methods.contains(.approvalRespond))
        XCTAssertFalse(recorder.methods.contains(.computerUseApprovalRespond))
    }

    func test_learningRecallRequiresAttachedSessionAndUsesOnlyTypedReadRPC() throws {
        let recalled = """
        ## What you know about me
        <untrusted-content provenance="safari_learning_recall">
        - [memory_id=memory-1; forget_id=proposal-1] Prefers annual totals.
        </untrusted-content>
        """
        let recorder = SafariRPCRecorder { method, params in
            switch method {
            case .safariSessionStatus:
                let request = try BurnBarSafariNativeBridgeCodec.decodeDaemonValue(
                    BurnBarSafariSessionStatusRequest.self,
                    from: params
                )
                XCTAssertEqual(request.sessionId, "session-1")
                return try BurnBarSafariNativeBridgeCodec.daemonJSONValue(
                    self.attachedLearningStatus()
                )

            case .learningRecall:
                let request = try BurnBarSafariNativeBridgeCodec.decodeDaemonValue(
                    BurnBarSafariLearningRecallRequest.self,
                    from: params
                )
                XCTAssertEqual(request.query, "Compare the visible plans.")
                XCTAssertEqual(request.limit, 8)
                return try BurnBarSafariNativeBridgeCodec.daemonJSONValue(
                    BurnBarSafariLearningRecallResponse(
                        untrustedContext: recalled
                    )
                )

            default:
                XCTFail("unexpected learning recall method \(method.rawValue)")
                throw SafariTestFailure.unexpected(method.rawValue)
            }
        }
        let controller = try makeController(recorder: recorder)

        let response = try responseObject(
            controller.handle(
                propertyList: popupRequest(
                    id: "popup-learning-recall",
                    action: "learning.recall",
                    payload: [
                        "safariSessionId": "session-1",
                        "query": "  Compare the visible plans.  ",
                        "limit": 8
                    ]
                )
            )
        )

        XCTAssertNil(response["error"])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let output = try XCTUnwrap(result["output"] as? [String: Any])
        XCTAssertEqual(output["untrustedContext"] as? String, recalled)
        XCTAssertEqual(
            recorder.methods,
            [.safariSessionStatus, .learningRecall]
        )
    }

    func test_learningCorrectionUsesLiveAttachedPageAndFixedObservationShape() throws {
        let proposal = BurnBarSafariLearningProposal(
            proposalId: "proposal-correction-1",
            kind: .memory,
            title: "Price comparison preference",
            content: "Always compare annual totals before monthly prices.",
            reason: "The user explicitly corrected the comparison behavior.",
            expectedOutcome: "Future plan comparisons prioritize annual totals.",
            sourceURL: "https://example.com",
            sourceObservationId: "safari-correction:correction-1"
        )
        let recorder = SafariRPCRecorder { method, params in
            switch method {
            case .safariSessionStatus:
                return try BurnBarSafariNativeBridgeCodec.daemonJSONValue(
                    self.attachedLearningStatus()
                )

            case .learningPropose:
                let request = try BurnBarSafariNativeBridgeCodec.decodeDaemonValue(
                    BurnBarSafariLearningProposalRequest.self,
                    from: params
                )
                let observation = request.observation
                XCTAssertEqual(
                    observation.observationId,
                    "safari-correction:correction-1"
                )
                XCTAssertEqual(observation.safariSessionId, "session-1")
                XCTAssertNil(observation.runId)
                XCTAssertEqual(
                    observation.sourceURL,
                    "https://example.com/products"
                )
                XCTAssertEqual(observation.sourceTitle, "Example")
                XCTAssertEqual(observation.trigger, .userCorrection)
                XCTAssertEqual(observation.actionCount, 1)
                XCTAssertEqual(
                    observation.content,
                    "Always compare annual totals before monthly prices."
                )
                XCTAssertEqual(
                    observation.tags,
                    ["safari_extension", "explicit_user_correction"]
                )
                return try BurnBarSafariNativeBridgeCodec.daemonJSONValue(
                    BurnBarSafariLearningProposalResponse(
                        proposal: proposal
                    )
                )

            default:
                XCTFail("unexpected learning proposal method \(method.rawValue)")
                throw SafariTestFailure.unexpected(method.rawValue)
            }
        }
        let controller = try makeController(recorder: recorder)

        let response = try responseObject(
            controller.handle(
                propertyList: popupRequest(
                    id: "popup-learning-correction",
                    action: "learning.propose",
                    payload: [
                        "safariSessionId": "session-1",
                        "correctionId": "correction-1",
                        "correction": "  Always compare annual totals before monthly prices.  ",
                        "tabId": 4,
                        "url": "https://example.com/products"
                    ]
                )
            )
        )

        XCTAssertNil(response["error"])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let output = try XCTUnwrap(result["output"] as? [String: Any])
        let encodedProposal = try XCTUnwrap(
            output["proposal"] as? [String: Any]
        )
        XCTAssertEqual(
            encodedProposal["proposalId"] as? String,
            "proposal-correction-1"
        )
        XCTAssertEqual(
            recorder.methods,
            [.safariSessionStatus, .learningPropose]
        )
    }

    func test_learningCorrectionRejectsStalePageAndMethodSmugglingBeforeWrite()
        throws {
        let staleRecorder = SafariRPCRecorder { method, _ in
            XCTAssertEqual(method, .safariSessionStatus)
            return try BurnBarSafariNativeBridgeCodec.daemonJSONValue(
                self.attachedLearningStatus(
                    url: "https://example.com/another-page"
                )
            )
        }
        let staleController = try makeController(recorder: staleRecorder)
        let staleResponse = try responseObject(
            staleController.handle(
                propertyList: popupRequest(
                    id: "popup-learning-stale",
                    action: "learning.propose",
                    payload: [
                        "safariSessionId": "session-1",
                        "correctionId": "correction-stale",
                        "correction": "Use annual totals for every comparison.",
                        "tabId": 4,
                        "url": "https://example.com/products"
                    ]
                )
            )
        )
        XCTAssertEqual(
            (staleResponse["error"] as? [String: Any])?["code"] as? String,
            "invalid_learning_correction"
        )
        XCTAssertEqual(staleRecorder.methods, [.safariSessionStatus])

        let smugglingRecorder = SafariRPCRecorder { method, _ in
            XCTFail("smuggled learning request reached \(method.rawValue)")
            return .null
        }
        let smugglingController = try makeController(
            recorder: smugglingRecorder
        )
        let smuggledResponse = try responseObject(
            smugglingController.handle(
                propertyList: popupRequest(
                    id: "popup-learning-smuggled",
                    action: "learning.propose",
                    payload: [
                        "safariSessionId": "session-1",
                        "correctionId": "correction-smuggled",
                        "correction": "Use annual totals for every comparison.",
                        "tabId": 4,
                        "url": "https://example.com/products",
                        "method": "daemon.config.update"
                    ]
                )
            )
        )
        XCTAssertEqual(
            (smuggledResponse["error"] as? [String: Any])?["code"] as? String,
            "invalid_bridge_schema"
        )
        XCTAssertTrue(smugglingRecorder.calls.isEmpty)
    }

    func test_learningUpdateAndRollbackUseVersionedTypedRPCs() throws {
        let updatedProposal = BurnBarSafariLearningProposal(
            proposalId: "proposal-1",
            version: 5,
            kind: .memory,
            title: "Updated preference",
            content: "Prefer annual totals.",
            reason: "User edit",
            expectedOutcome: "Accurate comparisons",
            sourceURL: "https://example.com",
            sourceObservationId: "observation-1"
        )
        let rolledBackProposal = BurnBarSafariLearningProposal(
            proposalId: "proposal-1",
            version: 6,
            kind: .memory,
            title: "Original preference",
            content: "Compare complete totals.",
            reason: "Rollback",
            expectedOutcome: "Restore prior behavior",
            sourceURL: "https://example.com",
            sourceObservationId: "observation-1"
        )
        let recorder = SafariRPCRecorder { method, params in
            switch method {
            case .safariSessionStatus:
                return try BurnBarSafariNativeBridgeCodec.daemonJSONValue(
                    self.attachedLearningStatus()
                )

            case .learningUpdate:
                let request = try BurnBarSafariNativeBridgeCodec.decodeDaemonValue(
                    BurnBarSafariLearningUpdateRequest.self,
                    from: params
                )
                XCTAssertEqual(request.proposalId, "proposal-1")
                XCTAssertEqual(request.expectedVersion, 4)
                XCTAssertEqual(request.title, "Updated preference")
                XCTAssertEqual(request.content, "Prefer annual totals.")
                return try BurnBarSafariNativeBridgeCodec.daemonJSONValue(
                    BurnBarSafariLearningProposalResponse(
                        proposal: updatedProposal
                    )
                )

            case .learningRollback:
                let request = try BurnBarSafariNativeBridgeCodec.decodeDaemonValue(
                    BurnBarSafariLearningRollbackRequest.self,
                    from: params
                )
                XCTAssertEqual(request.proposalId, "proposal-1")
                XCTAssertEqual(request.targetVersion, 2)
                return try BurnBarSafariNativeBridgeCodec.daemonJSONValue(
                    BurnBarSafariLearningProposalResponse(
                        proposal: rolledBackProposal
                    )
                )

            default:
                XCTFail("unexpected learning edit method \(method.rawValue)")
                throw SafariTestFailure.unexpected(method.rawValue)
            }
        }
        let controller = try makeController(recorder: recorder)

        let updateResponse = try responseObject(
            controller.handle(
                propertyList: popupRequest(
                    id: "popup-learning-update",
                    action: "learning.update",
                    payload: [
                        "safariSessionId": "session-1",
                        "proposalId": "proposal-1",
                        "expectedVersion": 4,
                        "title": "Updated preference",
                        "content": "Prefer annual totals."
                    ]
                )
            )
        )
        XCTAssertNil(updateResponse["error"])

        let rollbackResponse = try responseObject(
            controller.handle(
                propertyList: popupRequest(
                    id: "popup-learning-rollback",
                    action: "learning.rollback",
                    payload: [
                        "safariSessionId": "session-1",
                        "proposalId": "proposal-1",
                        "targetVersion": 2
                    ]
                )
            )
        )
        XCTAssertNil(rollbackResponse["error"])
        XCTAssertEqual(
            recorder.methods,
            [
                .safariSessionStatus,
                .learningUpdate,
                .safariSessionStatus,
                .learningRollback
            ]
        )
    }

    func test_handoffRejectsPathsMethodsFullPageCaptureAndMalformedJPEGBeforeRPC() throws {
        let recorder = SafariRPCRecorder { method, _ in
            XCTFail("invalid hand-off must not reach daemon method \(method.rawValue)")
            return .null
        }
        let controller = try makeController(recorder: recorder)

        var smuggled = handoffPayload()
        smuggled["method"] = "daemon.config.update"
        smuggled["briefingPath"] = "/tmp/attacker-controlled.md"
        let smuggledResponse = try responseObject(
            controller.handle(
                propertyList: popupRequest(
                    id: "popup-handoff-smuggled",
                    action: "handoff",
                    payload: smuggled
                )
            )
        )
        XCTAssertEqual(
            (smuggledResponse["error"] as? [String: Any])?["code"] as? String,
            "invalid_bridge_schema"
        )

        var fullPage = handoffPayload()
        var fullPageScreenshot = try XCTUnwrap(
            fullPage["screenshot"] as? [String: Any]
        )
        fullPageScreenshot["source"] = "full-page"
        fullPage["screenshot"] = fullPageScreenshot
        let fullPageResponse = try responseObject(
            controller.handle(
                propertyList: popupRequest(
                    id: "popup-handoff-full-page",
                    action: "handoff",
                    payload: fullPage
                )
            )
        )
        XCTAssertEqual(
            (fullPageResponse["error"] as? [String: Any])?["code"] as? String,
            "handoff_payload_too_large"
        )

        var malformed = handoffPayload()
        var malformedScreenshot = try XCTUnwrap(
            malformed["screenshot"] as? [String: Any]
        )
        malformedScreenshot["dataUrl"] = "data:image/png;base64,iVBORw0KGgo="
        malformedScreenshot["mediaType"] = "image/png"
        malformedScreenshot["byteLength"] = 8
        malformed["screenshot"] = malformedScreenshot
        let malformedResponse = try responseObject(
            controller.handle(
                propertyList: popupRequest(
                    id: "popup-handoff-not-jpeg",
                    action: "handoff",
                    payload: malformed
                )
            )
        )
        XCTAssertEqual(
            (malformedResponse["error"] as? [String: Any])?["code"] as? String,
            "invalid_screenshot"
        )
        XCTAssertTrue(recorder.calls.isEmpty)
    }

    func test_chunkCommitExecutesOnlyDeclaredOriginalMethodAndUsesCommitResponseID() throws {
        let recorder = SafariRPCRecorder { method, _ in
            XCTAssertEqual(method, .safariCommandPoll)
            return try BurnBarSafariNativeBridgeCodec.daemonJSONValue(
                BurnBarSafariCommandPollResponse(
                    command: nil,
                    leaseExpiresAt: Date(timeIntervalSince1970: 1_786_345_060),
                    pollAfterMillis: 200
                )
            )
        }
        let controller = try makeController(recorder: recorder)
        let original: [String: Any] = [
            "protocolVersion": BurnBarSafariBridgeWire.protocolVersion,
            "id": "original-poll-id",
            "method": "bridge.poll",
            "params": [
                "sessionId": "session-1",
                "activePage": NSNull(),
                "knownTabs": []
            ]
        ]
        let payload = try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys])
        let digest = SHA256Test.hex(payload)
        let midpoint = payload.count / 2
        let chunks = [payload.subdata(in: 0..<midpoint), payload.subdata(in: midpoint..<payload.count)]

        _ = controller.handle(propertyList: [
            "protocolVersion": BurnBarSafariBridgeWire.protocolVersion,
            "id": "chunk-begin-id",
            "method": "bridge.chunk.begin",
            "params": [
                "transferId": "transfer-1",
                "originalMethod": "bridge.poll",
                "byteLength": payload.count,
                "chunkCount": chunks.count,
                "sha256": digest
            ]
        ])
        for (index, chunk) in chunks.enumerated() {
            _ = controller.handle(propertyList: [
                "protocolVersion": BurnBarSafariBridgeWire.protocolVersion,
                "id": "chunk-\(index)",
                "method": "bridge.chunk.append",
                "params": [
                    "transferId": "transfer-1",
                    "index": index,
                    "data": chunk.base64EncodedString()
                ]
            ])
        }
        let committed = try responseObject(controller.handle(propertyList: [
            "protocolVersion": BurnBarSafariBridgeWire.protocolVersion,
            "id": "chunk-commit-id",
            "method": "bridge.chunk.commit",
            "params": ["transferId": "transfer-1"]
        ]))
        XCTAssertEqual(committed["id"] as? String, "chunk-commit-id")
        XCTAssertNil(committed["error"])
        XCTAssertNotNil(committed["result"])
        XCTAssertEqual(recorder.methods, [.safariCommandPoll])
    }

    private func makeController(
        recorder: SafariRPCRecorder
    ) throws -> BurnBarSafariNativeBridgeController {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("safari-controller-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return BurnBarSafariNativeBridgeController(
            daemon: recorder.transport,
            chunkStore: BurnBarSafariBridgeChunkStore(
                trustedRoot: root,
                profileIdentifier: "tests"
            )
        )
    }

    private func helloRequest() -> [String: Any] {
        [
            "protocolVersion": BurnBarSafariBridgeWire.protocolVersion,
            "id": "hello-1",
            "method": "bridge.hello",
            "params": [
                "extensionInstanceId": "extension-instance-1",
                "clientName": "OpenBurnBar Safari WebExtension/1.0.34",
                "supportedProtocolVersions": [BurnBarSafariProtocol.currentVersion],
                "activePage": pageState(capturedAt: "2026-08-10T15:04:05Z"),
                "capabilities": [
                    "captureVisibleTab": true,
                    "scripting": true,
                    "nativeMessaging": true,
                    "activeTabPermission": true,
                    "siteAccessGranted": true
                ]
            ]
        ]
    }

    private func pageState(capturedAt: String) -> [String: Any] {
        [
            "tabId": 4,
            "windowId": 2,
            "url": "https://example.com/products",
            "title": "Example",
            "navigationEpoch": 2,
            "isActive": true,
            "isTopFrame": true,
            "capturedAt": capturedAt
        ]
    }

    private func attachedLearningStatus(
        url: String = "https://example.com/products"
    ) -> BurnBarSafariSessionStatusResponse {
        BurnBarSafariSessionStatusResponse(
            sessionId: "session-1",
            attached: true,
            leaseExpiresAt: Date(timeIntervalSince1970: 1_786_345_100),
            activePage: BurnBarSafariPageState(
                tabId: 4,
                windowId: 2,
                url: url,
                title: "Example",
                navigationEpoch: 2,
                isActive: true,
                isTopFrame: true,
                capturedAt: Date(timeIntervalSince1970: 1_786_345_000)
            ),
            ownedTabIds: [4]
        )
    }

    private func popupRequest(
        id: String,
        action: String,
        payload: [String: Any]
    ) -> [String: Any] {
        [
            "protocolVersion": BurnBarSafariBridgeWire.protocolVersion,
            "id": id,
            "method": "bridge.popupAction",
            "params": [
                "sessionId": "session-1",
                "action": action,
                "payload": payload
            ]
        ]
    }

    private func handoffPayload() -> [String: Any] {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        return [
            "safariSessionId": "session-1",
            "prompt": "Compare the visible plans.",
            "agentId": "codex",
            "pageContext": [
                "pageState": pageState(capturedAt: "2026-08-10T15:04:05.250Z"),
                "viewport": [
                    "width": 1024,
                    "height": 768,
                    "scrollX": 0,
                    "scrollY": 0,
                    "pageWidth": 1024,
                    "pageHeight": 1600,
                    "devicePixelRatio": 2,
                    "visualViewportOffsetLeft": 0,
                    "visualViewportOffsetTop": 0,
                    "visualViewportScale": 1
                ],
                "markdown": "# Plans\n\nStarter is $10.",
                "snapshot": #"[ref=obb-1] [role=button] [name="Choose Starter"]"#,
                "nodes": [],
                "truncated": false,
                "sensitive": false,
                "capturedAt": "2026-08-10T15:04:05.250Z"
            ],
            "screenshot": [
                "dataUrl": "data:image/jpeg;base64,\(jpeg.base64EncodedString())",
                "mediaType": "image/jpeg",
                "width": 1024,
                "height": 768,
                "byteLength": jpeg.count,
                "source": "viewport",
                "truncated": false
            ],
            "tabId": 4
        ]
    }

    private func responseObject(_ value: Any) throws -> [String: Any] {
        try XCTUnwrap(value as? [String: Any])
    }
}

private final class SafariRPCRecorder: @unchecked Sendable {
    struct Call {
        let method: BurnBarRPCMethod
        let params: BurnBarJSONValue
    }

    typealias Responder = @Sendable (
        BurnBarRPCMethod,
        BurnBarJSONValue
    ) throws -> BurnBarJSONValue

    private let lock = NSLock()
    private var storage: [Call] = []
    private let responder: Responder

    init(responder: @escaping Responder) {
        self.responder = responder
    }

    var transport: BurnBarSafariDaemonRPCTransport {
        BurnBarSafariDaemonRPCTransport { [self] method, _, params in
            lock.lock()
            storage.append(Call(method: method, params: params))
            lock.unlock()
            return try responder(method, params)
        }
    }

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var methods: [BurnBarRPCMethod] {
        calls.map(\.method)
    }
}

private enum SafariTestFailure: Error {
    case unexpected(String)
}

private enum SHA256Test {
    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
