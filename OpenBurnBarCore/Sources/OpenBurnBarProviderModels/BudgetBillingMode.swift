import Foundation

// Budget billing mode (3.2: extracted so the provider endpoint registry references it without a UsageModels edge).

// MARK: - BudgetBillingMode

/// Whether the credential being charged costs marginal $ per token or runs on a flat-rate plan.
/// Subscription credentials short-circuit `BudgetGate.evaluate` to `.allow` so a Claude Pro
/// OAuth key never gets blocked by these limits.
public enum BudgetBillingMode: String, Codable, CaseIterable, Hashable, Sendable {
    case perUsage
    case subscription
    case unknown
}
