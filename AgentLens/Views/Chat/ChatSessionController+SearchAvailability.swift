import Foundation
import SwiftUI
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
#if canImport(AppKit)
import AppKit
#endif

extension ChatSessionController {

    func validateChatBackendAvailability() async -> Bool {
        if isElderWandActive {
            await probeBurnBarGatewayAvailability()
            if let routingError = selectedModelRoutingError(for: chatBackend) {
                await appendAndPersistAssistantError(
                    routingError,
                    logContext: "Elder Wand gateway unavailable"
                )
                return false
            }
            return true
        }

        switch chatBackend {
        case .hermes:
            // Re-resolve the bearer fallback every send: a Settings token
            // cleared mid-session must not leave the cached ~/.hermes/.env key
            // nil'd out from the last explicit-token probe.
            await refreshHermesEnvFallbackBearerToken()
            // Re-probe when unavailable, but ALSO when the last probe saw the
            // key rejected — the user may have just fixed the token in
            // Settings, and this send should self-heal without a restart.
            if !hermesAvailable || hermesCatalogAuthRejected {
                await probeHermesAvailability()
            }
            if !hermesAvailable {
                await appendAndPersistAssistantError(
                    await hermesUnavailableMessage(),
                    logContext: "Hermes unavailable"
                )
                return false
            }
            if hermesCatalogAuthRejected {
                // Fail fast with the exact fix, instead of letting the send
                // reach the gateway just to be bounced on auth (and instead of
                // paying the retrieval pass first).
                await appendAndPersistAssistantError(
                    Self.hermesAuthRejectedMessage(
                        settingsTokenPresent: !settingsManager.hermesBearerToken
                            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        envKeyPresent: hermesEnvFallbackKeyPresent
                    ),
                    logContext: "Hermes auth rejected"
                )
                return false
            }
        case .openclaw:
            if !openClawAvailable {
                await probeOpenClawAvailability()
            }
            if !openClawAvailable {
                await appendAndPersistAssistantError(
                    "OpenClaw gateway is unavailable. Start the gateway (default 127.0.0.1:18789) and set the URL/token in Settings → Chat.",
                    logContext: "OpenClaw unavailable"
                )
                return false
            }
        case .piAgent:
            if !piAgentAvailable {
                await probePiAgentAvailability()
            }
            if !piAgentAvailable {
                await appendAndPersistAssistantError(
                    "Pi agent gateway is unavailable. Open Settings → Chat Gateway and choose Open Pi + Gateway, or check the gateway URL/token under Pi Agent Instances.",
                    logContext: "Pi unavailable"
                )
                return false
            }
        case .codex, .claude, .droid, .forge, .antigravity, .cursorAgent, .openClaude, .omp, .junie:
            guard settingsManager.cliAssistantAllowed else {
                await appendAndPersistAssistantError(
                    "Mac CLI assistants are off. Use the Enable button above the chat composer, or turn on Settings → Privacy & Indexing → Mac CLI Assistants.",
                    logContext: "CLI disabled"
                )
                return false
            }
            guard await validateSelectedCLIAssistantAvailability() else { return false }
        }
        return true
    }

    private func validateSelectedCLIAssistantAvailability() async -> Bool {
        let requirement: (executable: String, message: String, logContext: String)?
        switch chatBackend {
        case .droid:
            requirement = (
                "droid",
                "Droid CLI was not found. Install Factory Droid and ensure `droid` is on your PATH.",
                "Droid not found"
            )
        case .forge:
            requirement = (
                "forge",
                "Forge CLI was not found. Install Forge and ensure `forge` is on your PATH.",
                "Forge not found"
            )
        case .antigravity:
            requirement = (
                "agy",
                "Antigravity CLI was not found. Install Google Antigravity and ensure `agy` is on your PATH.",
                "Antigravity not found"
            )
        case .cursorAgent:
            requirement = (
                "cursor-agent",
                "Cursor Agent CLI was not found. Install Cursor Agent and ensure `cursor-agent` is on your PATH.",
                "Cursor Agent not found"
            )
        case .openClaude:
            requirement = (
                "openclaude",
                "OpenClaude CLI was not found. Install OpenClaude and ensure `openclaude` is on your PATH.",
                "OpenClaude not found"
            )
        case .omp:
            requirement = (
                "omp",
                "OMP CLI was not found. Install Oh My Pi and ensure `omp` is on your PATH.",
                "OMP not found"
            )
        case .junie:
            requirement = (
                "junie",
                "Junie CLI was not found. Install JetBrains Junie and ensure `junie` is on your PATH.",
                "Junie not found"
            )
        case .codex:
            requirement = (
                "codex",
                "Codex CLI was not found. Install with `npm i -g @openai/codex` or `brew install codex` and ensure `codex` is on your PATH.",
                "Codex not found"
            )
        case .claude:
            requirement = (
                "claude",
                "Claude Code CLI was not found. Install the native installer or Homebrew package and ensure `claude` is on your PATH.",
                "Claude not found"
            )
        case .hermes, .openclaw, .piAgent:
            requirement = nil
        }
        guard let requirement else { return true }
        if !(await cliBridge.isExecutableAvailable(named: requirement.executable)) {
            await appendAndPersistAssistantError(requirement.message, logContext: requirement.logContext)
            return false
        }
        return true
    }

    private func appendAndPersistAssistantError(_ content: String, logContext: String) async {
        let err = ChatMessageRecord(role: .assistant, content: content, cliUsed: nil)
        messages.append(err)
        do {
            try await dataStore.saveChatMessage(err, threadID: activeThreadID)
        } catch {
            AppLogger.chat.silentFailure("saveChatMessage (\(logContext))", error: error)
        }
        refreshHistory()
    }

    func hermesUnavailableMessage() async -> String {
        if await hermesHealthReachable() {
            let model = effectiveChatModel(for: .hermes).trimmingCharacters(in: .whitespacesAndNewlines)
            let modelLine = model.isEmpty ? "" : " Current requested model: \(model)."
            return "Hermes gateway is running, but OpenBurnBar could not read its live model catalog. Wait a few seconds and retry, or choose a live Hermes model from Settings → Chat.\(modelLine)"
        }
        return "Hermes isn’t running. Click Open Hermes + Gateway and OpenBurnBar will enable the local API server and start the gateway. If you set API_SERVER_KEY in ~/.hermes/.env, OpenBurnBar will reuse it locally."
    }
}
