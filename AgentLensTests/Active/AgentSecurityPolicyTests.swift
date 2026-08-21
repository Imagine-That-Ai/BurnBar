import Foundation
import SwiftUI
import OpenBurnBarComputerUseCore
import XCTest
@testable import OpenBurnBar

/// Security-decision tests for the agentic remediation (2026-06-13):
/// T-TOOL-02 (distribution gate + per-N re-auth), T-AI-01 (default-deny wrap),
/// T-AI-06 (secret scrubbing + no-retention header), T-TOOL-01/05/07 (CLI lane
/// content tagging), T-TOOL-10 (home-data deny for restricted shell).
final class AgentSecurityPolicyTests: XCTestCase {

    // MARK: - T-TOOL-02(a): spawned CLI bypass flags are never emitted

    func test_dangerousFlagGate_neverAllowsVendorBypassFlags() {
        XCTAssertFalse(
            AgentDistributionGate.allowsDangerousAutonomyFlag(
                isDistributionBuild: false,
                hasFreshLocalAuthProof: false
            ),
            "developer/debug builds must not get a vendor bypass flag"
        )
        XCTAssertFalse(
            AgentDistributionGate.allowsDangerousAutonomyFlag(
                isDistributionBuild: true,
                hasFreshLocalAuthProof: false
            ),
            "distribution builds must fail closed"
        )
        XCTAssertFalse(
            AgentDistributionGate.allowsDangerousAutonomyFlag(
                isDistributionBuild: true,
                hasFreshLocalAuthProof: true
            ),
            "fresh local-auth proof gates OpenBurnBar broker actions, not vendor process bypasses"
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

    // MARK: - T-TOOL-02(a): arg builders never emit vendor bypasses

    func test_claudeArguments_trustedGrantNeverEmitsVendorBypass() {
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
        XCTAssertFalse(withProof.contains("--dangerously-skip-permissions"))
        XCTAssertEqual(value(after: "--permission-mode", in: withProof), "acceptEdits")

        let withoutProof = CLIArgumentBuilder.claudeArguments(
            prompt: "p",
            capabilityGrant: yolo,
            hasFreshLocalAuthProof: false
        )
        XCTAssertFalse(withoutProof.contains("--dangerously-skip-permissions"))
        XCTAssertEqual(value(after: "--permission-mode", in: withoutProof), "acceptEdits")
    }

    func test_codexArguments_trustedGrantNeverEmitsVendorBypass() {
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
        XCTAssertFalse(args.contains("--dangerously-bypass-approvals-and-sandbox"))
        XCTAssertEqual(value(after: "--sandbox", in: args), "workspace-write")
    }

    func test_junieArguments_useHeadlessTaskAndPreserveModelSelection() {
        let trusted = AgentCapabilityGrant.sessionGrant(
            runtimeID: .junie,
            threadID: "t",
            capabilities: Set(AgentDesktopCapability.allCases),
            trustMode: .trusted,
            now: Date(),
            duration: 60
        )
        let args = CLIArgumentBuilder.junieArguments(
            prompt: "Ship it",
            model: "sonnet",
            capabilityGrant: trusted
        )

        XCTAssertFalse(args.contains("--prompt"))
        XCTAssertEqual(value(after: "--model", in: args), "sonnet")
        XCTAssertEqual(value(after: "--task", in: args), "Ship it")
    }

    func test_junieArguments_constrainTaskPromptWhenGrantDoesNotAllowWritesOrShell() throws {
        let readOnly = AgentCapabilityGrant.sessionGrant(
            runtimeID: .junie,
            threadID: "t",
            capabilities: [.workspaceRead],
            trustMode: .step,
            now: Date(),
            duration: 60
        )
        let args = CLIArgumentBuilder.junieArguments(
            prompt: "Inspect this",
            capabilityGrant: readOnly
        )
        let task = try XCTUnwrap(value(after: "--task", in: args))
        XCTAssertTrue(task.contains("Inspect this"))
        XCTAssertTrue(task.contains("Do not edit files."))
        XCTAssertTrue(task.contains("Do not execute shell commands."))

        let trusted = AgentCapabilityGrant.sessionGrant(
            runtimeID: .junie,
            threadID: "t",
            capabilities: Set(AgentDesktopCapability.allCases),
            trustMode: .trusted,
            now: Date(),
            duration: 60
        )
        let trustedArgs = CLIArgumentBuilder.junieArguments(
            prompt: "Ship it",
            capabilityGrant: trusted
        )
        XCTAssertEqual(value(after: "--task", in: trustedArgs), "Ship it")
    }

    func test_junieChatLaunch_failsClosedWithoutFullActiveGrant() {
        XCTAssertFalse(
            CLIAgentJunieMissionPolicy.chatLaunchPermitted(nil),
            "a relay chat with no grant must not spawn Junie"
        )

        let readOnly = AgentCapabilityGrant.sessionGrant(
            runtimeID: .junie,
            threadID: "t",
            capabilities: [.workspaceRead],
            trustMode: .step,
            now: Date(),
            duration: 60
        )
        XCTAssertFalse(
            CLIAgentJunieMissionPolicy.chatLaunchPermitted(readOnly),
            "a read-only grant must not spawn Junie"
        )

        let now = Date()
        let expired = AgentCapabilityGrant.sessionGrant(
            runtimeID: .junie,
            threadID: "t",
            capabilities: Set(AgentDesktopCapability.allCases),
            trustMode: .trusted,
            now: now.addingTimeInterval(-120),
            duration: 60
        )
        XCTAssertFalse(
            CLIAgentJunieMissionPolicy.chatLaunchPermitted(expired, now: now),
            "an expired grant must not spawn Junie"
        )

        let full = AgentCapabilityGrant.sessionGrant(
            runtimeID: .junie,
            threadID: "t",
            capabilities: Set(AgentDesktopCapability.allCases),
            trustMode: .trusted,
            now: now,
            duration: 60
        )
        XCTAssertTrue(
            CLIAgentJunieMissionPolicy.chatLaunchPermitted(full, now: now),
            "an active full grant permits Junie"
        )

        let revoked = full.revoked()
        XCTAssertFalse(
            CLIAgentJunieMissionPolicy.chatLaunchPermitted(revoked, now: now),
            "a revoked grant must not spawn Junie"
        )
    }

    @MainActor
    func test_junieChatStream_failsClosedBeforeResolvingExecutable() async {
        let bridge = CLIBridge()
        var receivedError: Error?

        do {
            for try await _ in bridge.chatJunieStream(
                systemPrompt: "system",
                userMessage: "user"
            ) {}
        } catch {
            receivedError = error
        }

        guard let bridgeError = receivedError as? CLIBridgeError else {
            XCTFail("expected Junie grant error, got \(String(describing: receivedError))")
            return
        }
        guard case .junieRequiresFullGrant = bridgeError else {
            XCTFail("expected Junie full-grant refusal, got \(bridgeError)")
            return
        }
        XCTAssertTrue(
            bridgeError.localizedDescription.contains("read-only mode"),
            "the refusal should explain why Junie cannot run without the full grant"
        )
    }

    @MainActor
    func test_junieChatStream_refusesWhenLiveStoreGrantWasRevoked() async {
        let bridge = CLIBridge()
        let threadID = "junie-live-revoke-\(UUID().uuidString)"
        let grant = AgentCapabilityGrant.sessionGrant(
            runtimeID: .junie,
            threadID: threadID,
            capabilities: Set(AgentDesktopCapability.allCases),
            trustMode: .trusted,
            now: Date(),
            duration: 600
        )
        AgentCapabilityGrantStore.shared.activate(grant)
        // A phone-side revoke updates the live store while the caller's
        // captured grant value still looks active.
        AgentCapabilityGrantStore.shared.revoke(runtimeID: .junie, threadID: threadID)

        var receivedError: Error?
        do {
            for try await _ in bridge.chatJunieStream(
                systemPrompt: "system",
                userMessage: "user",
                capabilityGrant: grant
            ) {}
        } catch {
            receivedError = error
        }

        guard case .junieRequiresFullGrant? = receivedError as? CLIBridgeError else {
            XCTFail("a store-revoked grant must refuse the Junie launch, got \(String(describing: receivedError))")
            return
        }
    }

    // MARK: - fx permission flags (T-TOOL-02(a))

    func test_fxArguments_neverEmitYoloAndGateAutoOnFullGrant() {
        let full = AgentCapabilityGrant.sessionGrant(
            runtimeID: .fx,
            threadID: "t",
            capabilities: Set(AgentDesktopCapability.allCases),
            trustMode: .trusted,
            now: Date(),
            duration: 60
        )
        let fullArgs = CLIArgumentBuilder.fxArguments(
            prompt: "Ship it",
            capabilityGrant: full
        )
        XCTAssertEqual(Array(fullArgs.prefix(2)), ["ask", "--json"])
        XCTAssertTrue(fullArgs.contains("--auto"), "a full desktop grant may pass --auto")
        XCTAssertFalse(fullArgs.contains("--yolo"), "--yolo must never be passed")
        XCTAssertEqual(fullArgs.last, "Ship it")

        let manualFull = AgentCapabilityGrant.sessionGrant(
            runtimeID: .fx,
            threadID: "t",
            capabilities: Set(AgentDesktopCapability.allCases),
            trustMode: .manual,
            now: Date(),
            duration: 60
        )
        let manualFullArgs = CLIArgumentBuilder.fxArguments(
            prompt: "Ship it",
            capabilityGrant: manualFull
        )
        XCTAssertFalse(
            manualFullArgs.contains("--auto"),
            "a manual full-capability grant must keep fx approval prompts enabled"
        )
        XCTAssertFalse(manualFullArgs.contains("--yolo"), "--yolo must never be passed")

        let readOnly = AgentCapabilityGrant.sessionGrant(
            runtimeID: .fx,
            threadID: "t",
            capabilities: [.workspaceRead],
            trustMode: .step,
            now: Date(),
            duration: 60
        )
        let readOnlyArgs = CLIArgumentBuilder.fxArguments(
            prompt: "Inspect this",
            capabilityGrant: readOnly
        )
        XCTAssertFalse(readOnlyArgs.contains("--auto"), "a read-only grant must not pass --auto")
        XCTAssertFalse(readOnlyArgs.contains("--yolo"), "--yolo must never be passed")

        let noGrant = CLIArgumentBuilder.fxArguments(prompt: "Inspect this")
        XCTAssertFalse(noGrant.contains("--auto"), "no grant must not pass --auto")
        XCTAssertFalse(noGrant.contains("--yolo"), "--yolo must never be passed")
    }

    func test_fxArguments_resumeSessionIDAndNoModelFlag() {
        let args = CLIArgumentBuilder.fxArguments(
            prompt: "Continue",
            model: "sonnet",
            resumeSessionID: "1770000000000-1770000000000000000-a1b2c3d4e5f60718"
        )
        XCTAssertEqual(Array(args.prefix(2)), ["ask", "--json"])
        XCTAssertEqual(value(after: "--resume", in: args), "1770000000000-1770000000000000000-a1b2c3d4e5f60718")
        XCTAssertFalse(args.contains("--model"), "fx has no --model flag")
        XCTAssertFalse(args.contains("sonnet"), "the model must not leak into fx arguments")
        XCTAssertEqual(args.last, "Continue")
    }

    func test_fxMissionPolicy_autoReviewPermittedMirrorsArgumentGate() {
        let now = Date()
        let full = AgentCapabilityGrant.sessionGrant(
            runtimeID: .fx,
            threadID: "t",
            capabilities: Set(AgentDesktopCapability.allCases),
            trustMode: .trusted,
            now: now,
            duration: 60
        )
        XCTAssertTrue(CLIAgentFxMissionPolicy.autoReviewPermitted(full, now: now))
        XCTAssertTrue(CLIAgentFxMissionPolicy.hasFullDesktopCapabilities(full))

        let manualFull = AgentCapabilityGrant.sessionGrant(
            runtimeID: .fx,
            threadID: "t",
            capabilities: Set(AgentDesktopCapability.allCases),
            trustMode: .manual,
            now: now,
            duration: 60
        )
        XCTAssertTrue(CLIAgentFxMissionPolicy.hasFullDesktopCapabilities(manualFull))
        XCTAssertFalse(
            CLIAgentFxMissionPolicy.autoReviewPermitted(manualFull, now: now),
            "full capabilities do not override a manual approval policy"
        )

        let readOnly = AgentCapabilityGrant.sessionGrant(
            runtimeID: .fx,
            threadID: "t",
            capabilities: [.workspaceRead],
            trustMode: .step,
            now: now,
            duration: 60
        )
        XCTAssertFalse(CLIAgentFxMissionPolicy.autoReviewPermitted(readOnly, now: now))
        XCTAssertFalse(CLIAgentFxMissionPolicy.hasFullDesktopCapabilities(readOnly))

        let expired = AgentCapabilityGrant.sessionGrant(
            runtimeID: .fx,
            threadID: "t",
            capabilities: Set(AgentDesktopCapability.allCases),
            trustMode: .trusted,
            now: now.addingTimeInterval(-120),
            duration: 60
        )
        XCTAssertFalse(CLIAgentFxMissionPolicy.autoReviewPermitted(expired, now: now))
        XCTAssertFalse(CLIAgentFxMissionPolicy.autoReviewPermitted(nil, now: now))
    }

    // MARK: - T-TOOL-10: restricted shell home-data deny

    func test_restrictedShellProfile_deniesHomeDataByDefaultWithExplicitWorkspaceAndToolchainReads() {
        let profile = AgentToolBroker.restrictedShellSandboxProfile(
            workspacePath: "/Users/probe/project",
            homePath: "/Users/probe"
        )
        XCTAssertTrue(profile.contains("(deny default)"))
        XCTAssertFalse(profile.contains("(allow default)"))
        XCTAssertTrue(profile.contains("(allow file-read-data (require-not (subpath \"/Users/probe\")))"))
        XCTAssertTrue(profile.contains("(deny file-read-data (require-all (regex \"^/private/\")"))
        XCTAssertTrue(profile.contains("(allow file-read* (subpath \"/usr/bin\"))"))
        XCTAssertTrue(profile.contains("(allow file-read* (subpath \"/Users/probe/project\"))"))
        XCTAssertTrue(profile.contains("(allow file-read* (subpath \"/Users/probe/.cargo/bin\"))"))
        XCTAssertFalse(profile.contains("(allow file-read* (subpath \"/Users/probe\"))"))
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

    // MARK: - Pet Junie surface must advertise "unavailable", never "ready"

    /// Junie fails closed without a full desktop capability grant
    /// (`CLIBridgeError.junieRequiresFullGrant`) and the pet surface never
    /// plumbs one. Advertising `.ready` would offer a pet that silently answers
    /// from the local fallback instead of Junie, so the probe must report
    /// `.unavailable` regardless of whether the `junie` executable is present.
    @MainActor
    func test_petJunieProvider_advertisesUnavailableRatherThanReady() async {
        let provider = CLIBridgeChatProvider(
            id: .junie,
            bridge: CLIBridge(),
            keychain: PetKeychainStore(),
            workspace: nil
        )
        let status = await provider.checkAuth()
        XCTAssertEqual(
            status, .unavailable,
            "pet Junie must fail closed as .unavailable, never .ready"
        )
        XCTAssertNotEqual(status, .ready, "advertising ready would promise a grant the pet never holds")
    }

    /// The chip copy is user-facing: `.unavailable` must read as a distinct,
    /// honest state rather than borrowing another status' wording.
    func test_petAuthStatus_unavailableHasItsOwnLabel() {
        XCTAssertEqual(PetAuthStatus.unavailable.label, "Unavailable")
        XCTAssertNotEqual(PetAuthStatus.unavailable.label, PetAuthStatus.error.label)
        XCTAssertNotEqual(PetAuthStatus.unavailable.label, PetAuthStatus.needsLogin.label)
    }

    /// `.unavailable` is "cannot run on this surface", not a fault: it must be
    /// muted like `.unknown`, never coloured as `.error`.
    func test_petAuthStatus_unavailableChipReadsAsMutedNotError() {
        XCTAssertEqual(PetAuthStatus.unavailable.chipColor, DesignSystem.Colors.textMuted)
        XCTAssertEqual(PetAuthStatus.unavailable.chipColor, PetAuthStatus.unknown.chipColor)
        XCTAssertNotEqual(PetAuthStatus.unavailable.chipColor, PetAuthStatus.error.chipColor)
        XCTAssertEqual(PetAuthStatus.ready.chipColor, DesignSystem.Colors.success)
        XCTAssertEqual(PetAuthStatus.needsLogin.chipColor, DesignSystem.Colors.warning)
    }

}
