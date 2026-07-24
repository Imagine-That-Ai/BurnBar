import Foundation

// MARK: - AssistantQuickPrompt
//
// A small, curated catalog of widget-friendly prompts shared by:
//   • The "Ask Hermes" / "Ask Pi" chip rows on the bigger BurnBar widgets
//     (iOS `DashboardLargeView` / `DashboardExtraLargeView` and Android
//     `BurnBarLargeWidget` / `BurnBarMediumWidget`).
//   • Any future surface that wants to suggest a one-tap question — e.g. a
//     Hermes welcome screen or a Pi onboarding tip.
//
// Each prompt has a *default assistant* hint so the chip routes to the
// assistant the prompt is most likely to want, but both runtimes accept any
// prompt — the hint is a soft suggestion. If the preferred runtime is
// unreachable at tap time, callers may transparently fall back to the other.

public enum AssistantQuickPromptID: String, Codable, CaseIterable, Hashable, Sendable {
    case burnToday
    case forecastEoD
    case cacheRecap
    case topThree
    case summarizeSession
    case codeReview
}

public struct AssistantQuickPrompt: Codable, Hashable, Sendable, Identifiable {
    public let id: AssistantQuickPromptID
    /// Short label rendered on a widget chip — fits ~10 characters comfortably.
    public let chipLabel: String
    /// Full prompt the assistant receives when the chip is tapped.
    public let fullPrompt: String
    /// Soft preference; the user can still flip runtimes once inside the app.
    public let preferredAssistant: AssistantRuntimeID

    public init(
        id: AssistantQuickPromptID,
        chipLabel: String,
        fullPrompt: String,
        preferredAssistant: AssistantRuntimeID
    ) {
        self.id = id
        self.chipLabel = chipLabel
        self.fullPrompt = fullPrompt
        self.preferredAssistant = preferredAssistant
    }
}

public enum AssistantQuickPromptCatalog {
    /// Order matters — Large widgets surface the first 3, ExtraLarge / Android
    /// Large second-row surface the first 6.
    public static let all: [AssistantQuickPrompt] = [
        .init(
            id: .burnToday,
            chipLabel: "Burn?",
            fullPrompt: "What's my burn today, and where's it going?",
            preferredAssistant: .hermes
        ),
        .init(
            id: .forecastEoD,
            chipLabel: "Forecast",
            fullPrompt: "Forecast my spend through end of day.",
            preferredAssistant: .hermes
        ),
        .init(
            id: .cacheRecap,
            chipLabel: "Cache",
            fullPrompt: "Recap my cache hit rate and what I'd save by raising it.",
            preferredAssistant: .hermes
        ),
        .init(
            id: .topThree,
            chipLabel: "Top 3",
            fullPrompt: "Show me my top three providers and what changed since yesterday.",
            preferredAssistant: .hermes
        ),
        .init(
            id: .summarizeSession,
            chipLabel: "Summarize",
            fullPrompt: "Summarize my last project session in three bullets.",
            preferredAssistant: .pi
        ),
        .init(
            id: .codeReview,
            chipLabel: "Code review",
            fullPrompt: "What are the top issues in my staged diff right now?",
            preferredAssistant: .pi
        )
    ]

    /// Prompts that should land in Hermes by default. Used by the Large
    /// widget's narrow second row, which only fits ~3 chips.
    public static let hermesShortlist: [AssistantQuickPrompt] = all.filter { $0.preferredAssistant == .hermes }

    public static func prompt(for id: AssistantQuickPromptID) -> AssistantQuickPrompt? {
        all.first { $0.id == id }
    }
}
