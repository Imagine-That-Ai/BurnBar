import Foundation
import OpenBurnBarComputerUseCore
import XCTest
@testable import OpenBurnBar

/// T-TOOL-02(b) / T-AI-07: the unrestricted (YOLO) shell path requires periodic
/// fresh local-auth re-authorization. Without a wired re-authorizer it fails
/// CLOSED, and the re-auth gate is the same chokepoint an obeyed prompt injection
/// would hit when it tries to run shell — so it cannot run unbounded.
final class AgentToolBrokerReauthTests: XCTestCase {

    private func jsonPayload(from result: AgentToolExecutionPayload) throws -> [String: Any] {
        let data = try XCTUnwrap(result.content.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func makeWorkspace() throws -> URL {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-reauth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: workspace) }
        return workspace
    }

    private func yoloGrant() -> AgentCapabilityGrant {
        AgentCapabilityGrant.sessionGrant(
            runtimeID: .hermes,
            threadID: "thread-reauth",
            capabilities: [.shellUnrestricted],
            trustMode: .trusted,
            now: Date(),
            duration: 60
        )
    }

    func test_unrestrictedShellFailsClosedWithoutReauthorizer() async throws {
        let workspace = try makeWorkspace()
        // Privileged-init overload but NO unrestrictedShellReauthorizer wired.
        let broker = AgentToolBroker(
            grant: yoloGrant(),
            workspaceURL: workspace,
            privilegedActionApprover: { _, _ in true }
        )
        XCTAssertTrue(
            broker.unrestrictedShellRequiresReauthNow,
            "the first unrestricted-shell action must require re-auth"
        )
        let denied = try jsonPayload(from: await broker.invokeOpenAITool(
            name: "shell_run_unrestricted",
            arguments: #"{"command":"echo injected-should-not-run"}"#,
            callID: "call-1",
            runID: "run-1"
        ))
        XCTAssertEqual(denied["ok"] as? Bool, false)
        XCTAssertEqual(denied["status"] as? String, "denied")
        XCTAssertEqual(
            (denied["reason"] as? String)?.contains("re-authorization"),
            true,
            "denial must name the re-auth gate, got \(denied["reason"] ?? "nil")"
        )
    }

    func test_unrestrictedShellDeniedWhenReauthDeclined() async throws {
        let workspace = try makeWorkspace()
        let broker = AgentToolBroker(
            grant: yoloGrant(),
            workspaceURL: workspace,
            privilegedActionApprover: { _, _ in true },
            unrestrictedShellReauthorizer: { _ in false } // operator declines
        )
        let denied = try jsonPayload(from: await broker.invokeOpenAITool(
            name: "shell_run_unrestricted",
            arguments: #"{"command":"echo injected-should-not-run"}"#,
            callID: "call-1",
            runID: "run-1"
        ))
        XCTAssertEqual(denied["ok"] as? Bool, false)
        XCTAssertEqual(
            (denied["reason"] as? String)?.contains("declined"),
            true
        )
    }

    func test_unrestrictedShellRunsAfterSuccessfulReauth_thenRequiresReauthAgain() async throws {
        let workspace = try makeWorkspace()
        let broker = AgentToolBroker(
            grant: yoloGrant(),
            workspaceURL: workspace,
            privilegedActionApprover: { _, _ in true },
            unrestrictedShellReauthorizer: { _ in true } // operator proves presence
        )
        // First action: re-auth required, succeeds, command runs.
        let ok = try jsonPayload(from: await broker.invokeOpenAITool(
            name: "shell_run_unrestricted",
            arguments: #"{"command":"echo reauth-ok"}"#,
            callID: "call-1",
            runID: "run-1"
        ))
        XCTAssertEqual(ok["ok"] as? Bool, true)
        XCTAssertEqual((ok["stdout"] as? String)?.contains("reauth-ok"), true)
        // Within the cadence window the next action does NOT require re-auth.
        XCTAssertFalse(broker.unrestrictedShellRequiresReauthNow)
    }

    // MARK: - T-AI-07: injection -> shell regression

    func test_injectionCannotRunUnboundedShellAcrossManyCalls() async throws {
        let workspace = try makeWorkspace()
        // Model the worst case: an obeyed injection that fires the unrestricted
        // shell repeatedly. With no re-authorizer the gate denies EVERY call, so
        // the injection runs zero commands regardless of how many it attempts.
        let broker = AgentToolBroker(
            grant: yoloGrant(),
            workspaceURL: workspace,
            privilegedActionApprover: { _, _ in true }
        )
        let marker = workspace.appendingPathComponent("pwned.txt")
        for i in 0..<10 {
            let result = try jsonPayload(from: await broker.invokeOpenAITool(
                name: "shell_run_unrestricted",
                arguments: #"{"command":"touch \#(marker.path)"}"#,
                callID: "call-\(i)",
                runID: "run-injection"
            ))
            XCTAssertEqual(result["status"] as? String, "denied")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            "injection must not have executed any shell command"
        )
    }
}
