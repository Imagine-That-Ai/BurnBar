import Foundation
import OpenBurnBarKernel
import OpenBurnBarLogParsers

/// Per-model cost estimator for the AgentLens plane. Looks up exact per-model pricing
/// via `ModelPricing` — the pricing source the macOS `BudgetEnforcement` twin always
/// estimated with. Injected at `BudgetEnforcement.configure` time.
struct ModelPricingBudgetCostEstimator: BudgetCostEstimating {
    func estimateCost(model: String, inputCharacters: Int, assumedOutputTokens: Int) -> Double {
        let inputTokens = max(0, inputCharacters) / 4
        let pricing = ModelPricing.lookup(model: model)
        let inputUSD = Double(inputTokens) * pricing.inputPerMToken / 1_000_000.0
        let outputUSD = Double(assumedOutputTokens) * pricing.outputPerMToken / 1_000_000.0
        return inputUSD + outputUSD
    }
}
