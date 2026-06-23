import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

@MainActor
final class CLIAgentSessionActionDaemonDispatcherTests: XCTestCase {
    func testResumeRequiresMacApprovalBeforeDaemonResume() async throws {
        let dispatcher = CLIAgentSessionActionDaemonDispatcher(
            resumeRunner: { _, _, _, _ in
                XCTFail("Resume runner must not execute without Mac approval.")
                return BurnBarRunResumeResponse(kind: "spawned")
            }
        )

        let response = try await dispatcher.perform(
            CLIAgentSessionActionRequest(sessionID: "session-approval-required", action: .resume)
        )

        XCTAssertEqual(response.status, .error)
        XCTAssertEqual(response.errorCode, "mac_approval_required")
    }

    func testRejectedMacApprovalDoesNotRunDaemonResume() async throws {
        let approvalSpy = SessionActionApprovalSpy(decision: .reject)
        let dispatcher = CLIAgentSessionActionDaemonDispatcher(
            resumeRunner: { _, _, _, _ in
                XCTFail("Resume runner must not execute after rejected Mac approval.")
                return BurnBarRunResumeResponse(kind: "spawned")
            },
            approvalPresenter: { request in
                await approvalSpy.present(request)
            }
        )

        let response = try await dispatcher.perform(
            CLIAgentSessionActionRequest(
                sessionID: "session-rejected",
                action: .handoff,
                targetRuntime: "codex"
            )
        )

        let requests = await approvalSpy.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.toolKind, "cli.session.handoff")
        XCTAssertEqual(requests.first?.sessionId, "session-rejected")
        XCTAssertEqual(response.status, .error)
        XCTAssertEqual(response.errorCode, "mac_approval_required")
    }

    func testApprovedResumeRunsDaemonResumeInSpawnMode() async throws {
        let approvalSpy = SessionActionApprovalSpy(decision: .approve)
        let runnerSpy = SessionActionResumeRunnerSpy(
            response: BurnBarRunResumeResponse(
                kind: "spawned",
                argv: ["codex"],
                targetHarness: "codex",
                pid: 123
            )
        )
        let dispatcher = CLIAgentSessionActionDaemonDispatcher(
            resumeRunner: { sessionID, targetHarness, targetModel, mode in
                await runnerSpy.run(
                    sessionID: sessionID,
                    targetHarness: targetHarness,
                    targetModel: targetModel,
                    mode: mode
                )
            },
            approvalPresenter: { request in
                await approvalSpy.present(request)
            }
        )

        let response = try await dispatcher.perform(
            CLIAgentSessionActionRequest(
                sessionID: "session-approved",
                action: .resume,
                targetRuntime: "codex",
                targetModelID: "gpt-5.5"
            )
        )

        let approvals = await approvalSpy.requests()
        XCTAssertEqual(approvals.first?.title, "Resume CLI session")
        XCTAssertEqual(approvals.first?.toolKind, "cli.session.resume")

        let invocations = await runnerSpy.invocations()
        XCTAssertEqual(invocations.count, 1)
        XCTAssertEqual(invocations.first?.sessionID, "session-approved")
        XCTAssertEqual(invocations.first?.targetHarness, "codex")
        XCTAssertEqual(invocations.first?.targetModel, "gpt-5.5")
        XCTAssertEqual(invocations.first?.mode, .spawn)
        XCTAssertEqual(response.status, .nativeResume)
        XCTAssertEqual(response.pid, 123)
    }

    func testPackageOnlyDoesNotRequireApprovalAndUsesOpenMode() async throws {
        let runnerSpy = SessionActionResumeRunnerSpy(
            response: BurnBarRunResumeResponse(
                kind: "ported",
                targetHarness: "claude",
                briefingPath: "/tmp/package.md"
            )
        )
        let dispatcher = CLIAgentSessionActionDaemonDispatcher(
            resumeRunner: { sessionID, targetHarness, targetModel, mode in
                await runnerSpy.run(
                    sessionID: sessionID,
                    targetHarness: targetHarness,
                    targetModel: targetModel,
                    mode: mode
                )
            },
            approvalPresenter: { request in
                XCTFail("Package-only session actions must not require Mac approval: \(request.approvalId)")
                return HermesRealtimeRelayApprovalResponse(
                    approvalId: request.approvalId,
                    decision: .reject,
                    respondedBy: "mac",
                    respondedAt: Date()
                )
            }
        )

        let response = try await dispatcher.perform(
            CLIAgentSessionActionRequest(
                sessionID: "session-package-only",
                action: .packageOnly,
                targetRuntime: "claude"
            )
        )

        let invocations = await runnerSpy.invocations()
        XCTAssertEqual(invocations.count, 1)
        XCTAssertEqual(invocations.first?.sessionID, "session-package-only")
        XCTAssertEqual(invocations.first?.targetHarness, "claude")
        XCTAssertEqual(invocations.first?.mode, .open)
        XCTAssertEqual(response.status, .packageOnly)
        XCTAssertEqual(response.briefingPath, "/tmp/package.md")
    }
}

private actor SessionActionApprovalSpy {
    private var capturedRequests: [HermesRealtimeRelayApprovalRequest] = []
    private let decision: HermesRealtimeRelayApprovalResponse.Decision

    init(decision: HermesRealtimeRelayApprovalResponse.Decision) {
        self.decision = decision
    }

    func present(_ request: HermesRealtimeRelayApprovalRequest) -> HermesRealtimeRelayApprovalResponse {
        capturedRequests.append(request)
        return HermesRealtimeRelayApprovalResponse(
            approvalId: request.approvalId,
            decision: decision,
            respondedBy: "mac",
            respondedAt: Date()
        )
    }

    func requests() -> [HermesRealtimeRelayApprovalRequest] {
        capturedRequests
    }
}

private actor SessionActionResumeRunnerSpy {
    struct Invocation: Equatable {
        let sessionID: String
        let targetHarness: String?
        let targetModel: String?
        let mode: BurnBarResumeMode
    }

    private var capturedInvocations: [Invocation] = []
    private let response: BurnBarRunResumeResponse

    init(response: BurnBarRunResumeResponse) {
        self.response = response
    }

    func run(
        sessionID: String,
        targetHarness: String?,
        targetModel: String?,
        mode: BurnBarResumeMode
    ) -> BurnBarRunResumeResponse {
        capturedInvocations.append(
            Invocation(
                sessionID: sessionID,
                targetHarness: targetHarness,
                targetModel: targetModel,
                mode: mode
            )
        )
        return response
    }

    func invocations() -> [Invocation] {
        capturedInvocations
    }
}
