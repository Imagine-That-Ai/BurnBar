// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

// MARK: - BudgetCostEstimating

/// Pricing source for `BudgetEnforcement`'s rough per-request cost estimate. The two
/// enforcement twins estimated identically (input tokens ≈ characters / 4 plus an
/// assumed output budget) but priced differently: macOS looks up per-model pricing
/// from `ModelPricing` (OpenBurnBarLogParsers, which sits *above* Kernel and cannot
/// be imported here), while iOS uses a flat Sonnet-ballpark rate. Backends inject
/// their estimator at `configure` time so the estimate math lives here, once.
public protocol BudgetCostEstimating: Sendable {
    func estimateCost(model: String, inputCharacters: Int, assumedOutputTokens: Int) -> Double
}

// MARK: - FlatRateBudgetCostEstimator

/// Flat per-million-token pricing. The iOS backend injects `.mobileDefault`
/// ($3/MTok input, $15/MTok output — Claude 3.5 Sonnet ballpark); a conservative
/// estimate the daemon refines with exact per-model pricing.
public struct FlatRateBudgetCostEstimator: BudgetCostEstimating, Sendable {
    public let inputPerMToken: Double
    public let outputPerMToken: Double

    public init(inputPerMToken: Double, outputPerMToken: Double) {
        self.inputPerMToken = inputPerMToken
        self.outputPerMToken = outputPerMToken
    }

    /// The flat rate the iOS enforcement twin always estimated with.
    public static let mobileDefault = FlatRateBudgetCostEstimator(
        inputPerMToken: 3.0,
        outputPerMToken: 15.0
    )

    public func estimateCost(model: String, inputCharacters: Int, assumedOutputTokens: Int) -> Double {
        let inputTokens = max(0, inputCharacters) / 4
        let inputUSD = Double(inputTokens) * inputPerMToken / 1_000_000.0
        let outputUSD = Double(assumedOutputTokens) * outputPerMToken / 1_000_000.0
        return inputUSD + outputUSD
    }
}
