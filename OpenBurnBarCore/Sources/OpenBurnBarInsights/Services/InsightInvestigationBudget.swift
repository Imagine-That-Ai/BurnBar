import Foundation

/// Budget caps for Tier-3 tool exploration.
///
/// Plan §4.7 — each investigation is bounded so a misbehaving model
/// cannot rack up unlimited tool calls or tokens.
public struct InsightInvestigationBudget: Sendable {
    /// Maximum tool calls per investigation. Plan default: 6.
    public let maxToolCalls: Int
    /// Maximum tokens the model may emit before the loop is aborted.
    public let maxOutputTokens: Int
    /// Maximum total latency budget for the investigation (seconds).
    public let maxDuration: TimeInterval

    public init(
        maxToolCalls: Int = 6,
        maxOutputTokens: Int = 4096,
        maxDuration: TimeInterval = 30
    ) {
        self.maxToolCalls = max(1, maxToolCalls)
        self.maxOutputTokens = max(256, maxOutputTokens)
        self.maxDuration = max(5, maxDuration)
    }

    public static let `default` = InsightInvestigationBudget()
    public static let generous = InsightInvestigationBudget(maxToolCalls: 10, maxOutputTokens: 8192, maxDuration: 60)
    public static let conservative = InsightInvestigationBudget(maxToolCalls: 3, maxOutputTokens: 2048, maxDuration: 15)
}
