import CryptoKit
import Foundation
import OpenBurnBarComputerUseCore
import XCTest
@testable import OpenBurnBar

/// F3 — the unrestricted YOLO shell always leaves a forensic record keyed by
/// a non-reversible command digest, and F9 — the restricted shell's Seatbelt
/// profile denies reads of OpenBurnBar's own on-disk state and the home-root
/// credential files added in this hardening pass.
final class AgentToolBrokerShellAuditTests: XCTestCase {

    // MARK: - F3 command audit digest

    func test_commandAuditDigestIsTruncatedSHA256NotPlaintext() {
        let command = "export AWS_SECRET_ACCESS_KEY=hunter2 && aws s3 sync"
        let digest = AgentToolBroker.commandAuditDigest(command)

        // 8 bytes of SHA-256 → 16 lowercase hex chars; never the plaintext.
        XCTAssertEqual(digest.count, 16)
        XCTAssertNil(digest.range(of: "[^0-9a-f]", options: .regularExpression))
        XCTAssertFalse(digest.contains("hunter2"))

        let expected = SHA256.hash(data: Data(command.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(digest, expected)
    }

    func test_commandAuditDigestIsDeterministicAndCommandSensitive() {
        XCTAssertEqual(
            AgentToolBroker.commandAuditDigest("ls -la"),
            AgentToolBroker.commandAuditDigest("ls -la")
        )
        XCTAssertNotEqual(
            AgentToolBroker.commandAuditDigest("ls -la"),
            AgentToolBroker.commandAuditDigest("ls -lA"),
            "attribution requires distinct commands to hash distinctly"
        )
    }

    // MARK: - F3 unrestricted shell gate + audited dispatch

    private func jsonPayload(from result: AgentToolExecutionPayload) throws -> [String: Any] {
        let data = try XCTUnwrap(result.content.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func makeWorkspace() throws -> URL {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-shell-audit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: workspace) }
        return workspace
    }

    func test_unrestrictedShellRequiresYOLOTrustedModeAndCapability() async throws {
        let workspace = try makeWorkspace()
        // Manual trust mode with the capability is NOT enough.
        let manualGrant = AgentCapabilityGrant.sessionGrant(
            runtimeID: .hermes,
            threadID: "thread-audit",
            capabilities: [.shellUnrestricted],
            trustMode: .manual,
            now: Date(),
            duration: 60
        )
        let manualBroker = AgentToolBroker(grant: manualGrant, workspaceURL: workspace)
        let denied = try jsonPayload(from: await manualBroker.invokeOpenAITool(
            name: "shell_run_unrestricted",
            arguments: #"{"command":"echo should-not-run"}"#,
            callID: "call-audit-denied",
            runID: "run-audit"
        ))
        XCTAssertEqual(denied["ok"] as? Bool, false)
        XCTAssertEqual(denied["status"] as? String, "denied")
        XCTAssertEqual(
            (denied["reason"] as? String)?.contains("unrestricted shell requires YOLO trusted mode"),
            true,
            "denial must name the YOLO gate, got \(denied["reason"] ?? "nil")"
        )
    }

    func test_unrestrictedShellDispatchesWithForensicAuditUnderYOLO() async throws {
        let workspace = try makeWorkspace()
        let grant = AgentCapabilityGrant.sessionGrant(
            runtimeID: .hermes,
            threadID: "thread-audit",
            capabilities: [.shellUnrestricted],
            trustMode: .trusted,
            now: Date(),
            duration: 60
        )
        let broker = AgentToolBroker(grant: grant, workspaceURL: workspace)
        // The dispatch path constructs the F3 audit line (grant id, runtime,
        // command digest + length — never plaintext) before running the command.
        let payload = try jsonPayload(from: await broker.invokeOpenAITool(
            name: "shell_run_unrestricted",
            arguments: #"{"command":"echo audit-probe-ok"}"#,
            callID: "call-audit-ok",
            runID: "run-audit"
        ))
        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(payload["exitCode"] as? Int, 0)
        XCTAssertEqual((payload["stdout"] as? String)?.contains("audit-probe-ok"), true)
        XCTAssertEqual(payload["timedOut"] as? Bool, false)
    }

    // MARK: - F9 restricted-shell secret denial additions

    func test_sandboxProfileDeniesOpenBurnBarOwnStateAndNewCredentialPaths() {
        let home = "/Users/probe"
        let profile = AgentToolBroker.restrictedShellSandboxProfile(
            workspacePath: "/Users/probe/project",
            homePath: home
        )

        // F9: the app's OWN on-disk state (encrypted DB, replay counters,
        // audit chain, queued grants) is denied to the restricted shell.
        for subpath in [
            "/Library/Application Support/com.openburnbar.AgentLens",
            "/.openburnbar",
            "/.config/openburnbar",
            "/.terraform.d",
            "/.cloudflared",
            "/.config/git",
            "/Library/Application Support/Slack"
        ] {
            XCTAssertTrue(
                profile.contains("(deny file-read* (subpath \"\(home)\(subpath)\"))"),
                "missing F9 secret-subpath deny for \(subpath)"
            )
        }

        // F9: home-root credential file literals.
        for literal in [
            "/.env", "/.envrc",
            "/.cargo/credentials", "/.cargo/credentials.toml",
            "/.gem/credentials", "/.config/configstore/firebase-tools.json"
        ] {
            XCTAssertTrue(
                profile.contains("(deny file-read* (literal \"\(home)\(literal)\"))"),
                "missing F9 secret-literal deny for \(literal)"
            )
        }

        // The pre-existing guarantees hold around the additions.
        XCTAssertTrue(profile.contains("(deny network*)"))
        XCTAssertTrue(profile.contains("(allow file-write* (subpath \"/Users/probe/project\"))"))
    }
}
