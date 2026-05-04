import Foundation

/// Estimates the USD cost of a summary LLM call based on provider-specific
/// per-million-token pricing and checks cloud daily spend caps.
enum SummaryCostEstimator {

    /// Returns an estimated cost in USD for the given provider, model, and
    /// token counts.
    static func estimateCostUSD(
        provider: SummaryProviderID,
        model: String,
        inputTokens: Int,
        outputTokens: Int
    ) -> Double {
        let normalized = model.lowercased()
        let inputPerM: Double
        let outputPerM: Double

        switch provider {
        case .local, .mlx:
            return 0
        case .ollama:
            return 0
        case .minimax:
            inputPerM = 0.69
            outputPerM = 0.69
        case .zai:
            inputPerM = 0.07
            outputPerM = 0.07
        case .openrouter:
            if normalized.contains("gpt-5-nano") {
                inputPerM = 0.05
                outputPerM = 0.40
            } else if normalized.contains("qwen3.5-9b") {
                inputPerM = 0.05
                outputPerM = 0.15
            } else if normalized.contains("qwen") {
                inputPerM = 0.08
                outputPerM = 0.24
            } else {
                inputPerM = 0.10
                outputPerM = 0.40
            }
        }

        return (Double(inputTokens) * inputPerM / 1_000_000)
            + (Double(outputTokens) * outputPerM / 1_000_000)
    }

    /// Returns `true` when adding `estimatedCost` would exceed the user's
    /// configured daily cloud summary spend cap.
    static func exceedsCloudDailyCap(
        adding estimatedCost: Double,
        dailyCapUSD: Double?,
        spentTodayUSD: Double
    ) -> Bool {
        guard let cap = dailyCapUSD else { return false }
        return spentTodayUSD + max(estimatedCost, 0) > cap
    }
}
