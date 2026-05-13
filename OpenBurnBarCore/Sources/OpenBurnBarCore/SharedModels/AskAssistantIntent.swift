import AppIntents
import Foundation

// MARK: - AssistantRuntimeOption (AppEnum)

@available(iOS 17.0, macOS 14.0, *)
public enum AssistantRuntimeOption: String, AppEnum {
    case hermes
    case pi

    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Assistant")
    }

    public static var caseDisplayRepresentations: [AssistantRuntimeOption: DisplayRepresentation] {
        [
            .hermes: DisplayRepresentation(title: "Hermes"),
            .pi:     DisplayRepresentation(title: "Pi")
        ]
    }

    public var runtimeID: AssistantRuntimeID {
        switch self {
        case .hermes: return .hermes
        case .pi:     return .pi
        }
    }
}

// MARK: - AskAssistantIntent
//
// Widget AppIntent fired by the "Ask Hermes" / "Ask Pi" chips on
// `DashboardLargeView` and `DashboardExtraLargeView`. When tapped:
//   1. iOS launches the host app (because `openAppWhenRun = true`).
//   2. `perform()` runs *in the host app's process* — it stashes the
//      optional `prompt` into `AssistantPendingPrompt.shared.{hermes|pi}`
//      and posts `ShowAssistantsTab` with the runtime so `AssistantsTabRoot`
//      flips the pill and routes the user.
//   3. `HermesConversationListView` / `PiConversationListView` observe the
//      pending-prompt slot and either focus the composer (empty prompt)
//      or auto-send (prefilled prompt).

@available(iOS 17.0, macOS 14.0, *)
public struct AskAssistantIntent: AppIntent {
    public static let title: LocalizedStringResource = "Ask Assistant"
    public static let description = IntentDescription(
        "Open Hermes or Pi from the BurnBar widget — optionally with a prompt pre-filled."
    )
    public static let openAppWhenRun: Bool = true

    @Parameter(title: "Assistant", default: .hermes)
    public var assistant: AssistantRuntimeOption

    @Parameter(title: "Prompt")
    public var prompt: String?

    public init() {}

    public init(assistant: AssistantRuntimeOption, prompt: String? = nil) {
        self.assistant = assistant
        self.prompt = prompt
    }

    @MainActor
    public func perform() async throws -> some IntentResult {
        let runtime = assistant.runtimeID
        AssistantPendingPrompt.shared.stash(assistant: runtime, prompt: prompt)

        var userInfo: [AnyHashable: Any] = ["runtime": runtime.rawValue]
        if let trimmed = prompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmed.isEmpty {
            userInfo["prompt"] = trimmed
        }
        NotificationCenter.default.post(
            name: Notification.Name("ShowAssistantsTab"),
            object: nil,
            userInfo: userInfo
        )
        return .result()
    }
}
