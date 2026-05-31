import Foundation
import OpenBurnBarCore

@MainActor
protocol CLIAgentRelayChatTransporting: AnyObject {
    func stream(
        runtime: CLIAgentRuntime,
        threadID: String,
        prompt: String,
        title: String,
        parentSessionID: String?,
        resumeAction: String?,
        presentationMode: CLIAgentChatPresentationMode,
        onEvent: @escaping @MainActor (CLIAgentRelayChatEvent) -> Void
    ) async throws

    func performSessionAction(_ request: CLIAgentSessionActionRequest) async throws -> CLIAgentSessionActionResponse
}

@MainActor
final class CLIAgentRelayChatTransport: CLIAgentRelayChatTransporting {
    static let shared = CLIAgentRelayChatTransport()

    private let hermesService: HermesService
    private let relayTransport: HermesRelayTransporting
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        hermesService: HermesService = .shared,
        relayTransport: HermesRelayTransporting = HermesCompositeRelayTransport.shared
    ) {
        self.hermesService = hermesService
        self.relayTransport = relayTransport
    }

    func stream(
        runtime: CLIAgentRuntime,
        threadID: String,
        prompt: String,
        title: String,
        parentSessionID: String?,
        resumeAction: String?,
        presentationMode: CLIAgentChatPresentationMode = .nativeChat,
        onEvent: @escaping @MainActor (CLIAgentRelayChatEvent) -> Void
    ) async throws {
        let preferred = CLIAgentModelPreferences.preferredModelID(for: runtime.assistantRuntime)?.nonEmpty
        let modelID: String?
        if preferred == nil {
            modelID = nil
        } else {
            let catalog = try await hermesService.fetchCLIRuntimeModelCatalog(runtime: runtime.assistantRuntime)
            modelID = try CLIAgentModelPreferences.validatedPreferredModelID(
                for: runtime.assistantRuntime,
                options: catalog.options.map(AssistantModelOption.init(cliOption:))
            )?.nonEmpty
        }
        try await stream(
            runtimeRawValue: runtime.rawValue,
            threadID: threadID,
            prompt: prompt,
            title: title,
            modelID: modelID,
            parentSessionID: parentSessionID,
            resumeAction: resumeAction,
            presentationMode: presentationMode,
            onEvent: onEvent
        )
    }

    func stream(
        runtimeID: AssistantRuntimeID,
        threadID: String,
        prompt: String,
        title: String,
        modelID: String?,
        parentSessionID: String?,
        resumeAction: String?,
        presentationMode: CLIAgentChatPresentationMode = .nativeChat,
        onEvent: @escaping @MainActor (CLIAgentRelayChatEvent) -> Void
    ) async throws {
        try await stream(
            runtimeRawValue: runtimeID.rawValue,
            threadID: threadID,
            prompt: prompt,
            title: title,
            modelID: modelID,
            parentSessionID: parentSessionID,
            resumeAction: resumeAction,
            presentationMode: presentationMode,
            onEvent: onEvent
        )
    }

    private func stream(
        runtimeRawValue: String,
        threadID: String,
        prompt: String,
        title: String,
        modelID: String?,
        parentSessionID: String?,
        resumeAction: String?,
        presentationMode: CLIAgentChatPresentationMode,
        onEvent: @escaping @MainActor (CLIAgentRelayChatEvent) -> Void
    ) async throws {
        // Budget gate: evaluate before dispatching so spending limits are
        // enforced even when the Mac daemon isn't running its own gate.
        if BudgetEnforcement.shared.isConfigured {
            let credential = MobileCredentialIdentity.make(
                providerHint: runtimeRawValue,
                bearerToken: nil,
                displayLabel: runtimeRawValue
            )
            let estimatedCost = BudgetEnforcement.estimateCost(
                model: modelID ?? runtimeRawValue,
                inputCharacters: prompt.count
            )
            let decision = await BudgetEnforcement.shared.evaluate(
                credential: credential,
                estimatedCost: estimatedCost
            )
            if case .block(let rule, let used, let limit, let fallback) = decision {
                throw BudgetBlockedError(
                    rule: rule,
                    used: used,
                    limit: limit,
                    fallback: fallback,
                    resetAt: rule.period.nextReset(reference: Date())
                )
            }
        }

        let request = CLIAgentRelayChatRequest(
            runtime: runtimeRawValue,
            prompt: prompt,
            clientThreadID: threadID,
            modelID: modelID,
            title: title,
            parentSessionID: parentSessionID,
            resumeAction: resumeAction,
            presentationMode: presentationMode
        )
        let body = try encoder.encode(request)
        let payload = try await hermesService.macRelayPayloadForCLIAgentChat(
            body: body,
            sessionID: threadID
        )
        var decodeError: Error?
        try await relayTransport.sendStreaming(payload, timeout: 600) { [decoder] rawEvent in
            guard decodeError == nil else { return }
            do {
                let event = try decoder.decode(CLIAgentRelayChatEvent.self, from: Data(rawEvent.utf8))
                onEvent(event)
            } catch {
                decodeError = error
            }
        }
        if let decodeError {
            throw decodeError
        }
    }

    func performSessionAction(_ request: CLIAgentSessionActionRequest) async throws -> CLIAgentSessionActionResponse {
        let body = try encoder.encode(request)
        let payload = try await hermesService.macRelayPayloadForCLIAgentSessionAction(
            body: body,
            sessionID: "cli-session-action-\(request.sessionID)"
        )
        let data = try await relayTransport.sendUnary(payload, timeout: 60)
        return try decoder.decode(CLIAgentSessionActionResponse.self, from: data)
    }
}
