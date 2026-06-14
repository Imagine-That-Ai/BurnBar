import Foundation
import OpenBurnBarComputerUseCore
import XCTest
@testable import OpenBurnBar

/// Security-decision tests for the agentic remediation (2026-06-13):
/// T-TOOL-02 (distribution gate + per-N re-auth), T-AI-01 (default-deny wrap),
/// T-AI-06 (secret scrubbing + no-retention header), T-TOOL-01/05/07 (CLI lane
/// content tagging), T-TOOL-10 (default-deny read allow-list).
final class AgentSecurityPolicyTests: XCTestCase {

    // MARK: - T-TOOL-02(a): local-auth gate for dangerous-autonomy flags

    func test_dangerousFlagGate_requiresFreshLocalAuthInEveryBuild() {
        XCTAssertFalse(
            AgentDistributionGate.allowsDangerousAutonomyFlag(
                isDistributionBuild: false,
                hasFreshLocalAuthProof: false
            ),
            "developer/debug builds must not get an unauthenticated YOLO flag bypass"
        )
        XCTAssertFalse(
            AgentDistributionGate.allowsDangerousAutonomyFlag(
                isDistributionBuild: true,
                hasFreshLocalAuthProof: false
            ),
            "distribution build must fail closed without a fresh local-auth proof"
        )
        XCTAssertTrue(
            AgentDistributionGate.allowsDangerousAutonomyFlag(
                isDistributionBuild: true,
                hasFreshLocalAuthProof: true
            ),
            "fresh local-auth proof is the only condition that allows dangerous flags"
        )
    }

    // MARK: - T-TOOL-02(b) / T-AI-07: per-N-action re-auth cadence

    func test_reauthCadence_firstActionAlwaysRequiresReauth() {
        let cadence = AgentReauthCadence(interval: 5)
        XCTAssertTrue(
            cadence.requiresReauthBeforeNextAction,
            "the first unrestricted-shell action must prove presence"
        )
    }

    func test_reauthCadence_requiresReauthEveryIntervalActions() {
        var cadence = AgentReauthCadence(interval: 3)
        // Start of burst: re-auth, then run 3 actions before the next checkpoint.
        XCTAssertTrue(cadence.requiresReauthBeforeNextAction)
        cadence.recordReauth()
        XCTAssertFalse(cadence.requiresReauthBeforeNextAction)
        cadence.recordAction() // 1
        XCTAssertFalse(cadence.requiresReauthBeforeNextAction)
        cadence.recordAction() // 2
        XCTAssertFalse(cadence.requiresReauthBeforeNextAction)
        cadence.recordAction() // 3
        XCTAssertTrue(
            cadence.requiresReauthBeforeNextAction,
            "after `interval` actions a fresh re-auth must be required"
        )
    }

    // MARK: - T-AI-01: default-deny untrusted tool-output wrapping

    func test_untrustedToolOutputPolicy_unknownToolIsWrappedByDefault() {
        XCTAssertTrue(
            UntrustedToolOutputPolicy.shouldWrap(toolName: "some_brand_new_tool"),
            "an unknown tool's output must be wrapped (default-deny)"
        )
        XCTAssertTrue(UntrustedToolOutputPolicy.shouldWrap(toolName: "browser_screenshot"))
        XCTAssertTrue(UntrustedToolOutputPolicy.shouldWrap(toolName: "clipboard_read"))
    }

    func test_wrappedToolResultContent_unknownToolOutputIsWrapped() {
        let wrapped = OpenAICompatibleChatGatewayClient.wrappedToolResultContent(
            toolName: "totally_unknown_tool",
            content: "raw external bytes"
        )
        XCTAssertTrue(wrapped.contains("<UNTRUSTED_CONTENT"))
        XCTAssertTrue(wrapped.contains("tool_result:totally_unknown_tool"))
        XCTAssertTrue(wrapped.contains("raw external bytes"))
    }

    // MARK: - T-AI-06: secret scrubbing + no-retention header

    func test_secretScrubber_redactsCommonCredentialShapes() {
        let samples = [
            "sk-ant-abcdefghijklmnopqrstuvwxyz0123",
            "AKIAIOSFODNN7EXAMPLE",
            "ghp_0123456789abcdefghijklmnopqrstuvwx",
            "AIzaSyA1234567890abcdefghijklmnopqrstu"
        ]
        for secret in samples {
            let scrubbed = AgentSecretScrubber.scrub("value is \(secret) end")
            XCTAssertFalse(scrubbed.contains(secret), "secret \(secret) survived scrubbing")
            XCTAssertTrue(scrubbed.contains("[REDACTED:"), "scrub must mark the redaction")
        }
    }

    func test_secretScrubber_leavesPlainTextUntouched() {
        let text = "the quick brown fox jumps over the lazy dog"
        XCTAssertEqual(AgentSecretScrubber.scrub(text), text)
        XCTAssertFalse(AgentSecretScrubber.containsSecret(text))
    }

    func test_wrappedToolResultContent_scrubsSecretsFromToolOutput() {
        let wrapped = OpenAICompatibleChatGatewayClient.wrappedToolResultContent(
            toolName: "shell_run",
            content: #"{"stdout":"export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE"}"#
        )
        XCTAssertFalse(wrapped.contains("AKIAIOSFODNN7EXAMPLE"))
        XCTAssertTrue(wrapped.contains("[REDACTED:aws_access_key_id]"))
    }

    func test_noRetentionHeadersAppliedToRequest() {
        var request = URLRequest(url: URL(string: "https://example.invalid/v1/chat/completions")!)
        OpenAICompatibleChatGatewayClient.applyNoRetentionHeaders(to: &request)
        XCTAssertEqual(request.value(forHTTPHeaderField: "OpenAI-Data-Storage"), "deny")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Data-Retention"), "none")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Model-Training"), "disabled")
    }

    func test_scrubMessageContent_scrubsStringAndPartsContent() {
        let stringMsg = OpenAICompatibleChatGatewayClient.scrubMessageContent([
            "role": "user",
            "content": "token sk-ant-abcdefghijklmnopqrstuvwxyz0123 here"
        ])
        XCTAssertFalse((stringMsg["content"] as? String)?.contains("sk-ant-abcdefghijklmnop") ?? true)

        let multimodal = OpenAICompatibleChatGatewayClient.scrubMessageContent([
            "role": "user",
            "content": [
                ["type": "text", "text": "key ghp_0123456789abcdefghijklmnopqrstuvwx"],
                ["type": "image_url", "image_url": ["url": "data:..."]]
            ]
        ])
        let parts = multimodal["content"] as? [[String: Any]]
        XCTAssertEqual(parts?.count, 2)
        XCTAssertFalse((parts?.first?["text"] as? String)?.contains("ghp_0123456789") ?? true)
    }

    // MARK: - T-TOOL-02(a): arg builders accept the fresh-auth proof + gate

    func test_claudeArguments_yoloFlagGatedByDistributionAndFreshAuth() {
        let yolo = AgentCapabilityGrant.sessionGrant(
            runtimeID: .claude,
            threadID: "t",
            capabilities: Set(AgentDesktopCapability.allCases),
            trustMode: .trusted,
            now: Date(),
            duration: 60
        )
        let withProof = CLIArgumentBuilder.claudeArguments(
            prompt: "p",
            capabilityGrant: yolo,
            hasFreshLocalAuthProof: true
        )
        XCTAssertTrue(withProof.contains("--dangerously-skip-permissions"))

        let withoutProof = CLIArgumentBuilder.claudeArguments(
            prompt: "p",
            capabilityGrant: yolo,
            hasFreshLocalAuthProof: false
        )
        XCTAssertFalse(withoutProof.contains("--dangerously-skip-permissions"))
        XCTAssertEqual(value(after: "--permission-mode", in: withoutProof), "acceptEdits")
    }

    func test_codexArguments_acceptsFreshAuthProofParameter() {
        let yolo = AgentCapabilityGrant.sessionGrant(
            runtimeID: .codex,
            threadID: "t",
            capabilities: Set(AgentDesktopCapability.allCases),
            trustMode: .trusted,
            now: Date(),
            duration: 60
        )
        let args = CLIArgumentBuilder.codexArguments(
            prompt: "p",
            capabilityGrant: yolo,
            hasFreshLocalAuthProof: true
        )
        XCTAssertTrue(args.contains("--dangerously-bypass-approvals-and-sandbox"))
    }

    // MARK: - T-TOOL-10: default-deny read allow-list

    func test_restrictedShellProfile_readsAreDefaultDenyWithAllowlist() {
        let profile = AgentToolBroker.restrictedShellSandboxProfile(
            workspacePath: "/Users/probe/project",
            homePath: "/Users/probe"
        )
        // Terminal read default-deny present.
        XCTAssertTrue(profile.contains("(deny file-read*)"))
        // Workspace + key system roots are read-allowed.
        XCTAssertTrue(profile.contains("(allow file-read* (subpath \"/Users/probe/project\"))"))
        XCTAssertTrue(profile.contains("(allow file-read* (subpath \"/usr\"))"))
        XCTAssertTrue(profile.contains("(allow file-read* (subpath \"/System\"))"))
        // The home directory itself is NOT broadly read-allowed (only listed
        // toolchain subpaths), so a generic ~/Documents read is denied by default.
        XCTAssertFalse(profile.contains("(allow file-read* (subpath \"/Users/probe\"))"))
        // Network + write confinement still hold.
        XCTAssertTrue(profile.contains("(deny network*)"))
        XCTAssertTrue(profile.contains("(allow file-write* (subpath \"/Users/probe/project\"))"))
    }

    // MARK: - T-TOOL-01/05/07: spawned-CLI lane content tagging

    func test_spawnedCLIContentTagging_wrapsUntrustedWorkspaceContent() {
        let tagged = SpawnedCLIContentTagging.tagUntrusted(
            "contents of a fetched web page",
            provenance: "web_fetch"
        )
        XCTAssertTrue(tagged.contains("<UNTRUSTED_CONTENT"))
        XCTAssertTrue(tagged.contains("spawned_cli:web_fetch"))
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else { return nil }
        return arguments[valueIndex]
    }
}
