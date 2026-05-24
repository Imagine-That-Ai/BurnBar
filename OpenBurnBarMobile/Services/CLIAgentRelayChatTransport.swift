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
        onEvent: @escaping @MainActor (CLIAgentRelayChatEvent) -> Void
    ) async throws
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
        onEvent: @escaping @MainActor (CLIAgentRelayChatEvent) -> Void
    ) async throws {
        let modelID = try CLIAgentModelPreferences.validatedPreferredModelID(for: runtime.assistantRuntime)?.nonEmpty
        try await stream(
            runtimeRawValue: runtime.rawValue,
            threadID: threadID,
            prompt: prompt,
            title: title,
            modelID: modelID,
            parentSessionID: parentSessionID,
            resumeAction: resumeAction,
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
        onEvent: @escaping @MainActor (CLIAgentRelayChatEvent) -> Void
    ) async throws {
        let request = CLIAgentRelayChatRequest(
            runtime: runtimeRawValue,
            prompt: prompt,
            clientThreadID: threadID,
            modelID: modelID,
            title: title,
            parentSessionID: parentSessionID,
            resumeAction: resumeAction
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
}
