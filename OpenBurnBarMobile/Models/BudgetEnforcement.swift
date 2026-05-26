import Foundation
import OpenBurnBarCore

/// Process-wide entry point that gate-aware call sites use without restructuring their
/// initializers. The mobile Hermes chat path and any daemon-proxied gateway both reach
/// `BudgetEnforcement.shared.evaluate(...)` to ask the gate for a decision.
///
/// At app launch, the runtime calls `configure(gate:)` once; until then `evaluate`
/// returns `.allow` so test harnesses and detached subprocesses keep working.
@MainActor
final class BudgetEnforcement {
    static let shared = BudgetEnforcement()

    private var gate: BudgetGate?
    private var notificationCenter: BudgetNotificationCenter?
    private var forecast: BudgetForecast?

    private init() {}

    /// Wire the gate built at App startup. Safe to call multiple times — the latest gate
    /// wins (handy when a sign-out flow rebuilds the database queue).
    func configure(gate: BudgetGate, notifications: BudgetNotificationCenter? = nil, forecast: BudgetForecast? = nil) {
        self.gate = gate
        self.notificationCenter = notifications
        self.forecast = forecast
        notifications?.requestAuthorizationIfNeeded()
    }

    var isConfigured: Bool { gate != nil }

    /// Exposed for views that want live forecast projections.
    var forecastService: BudgetForecast? { forecast }

    func evaluate(
        credential: BudgetCredentialIdentity,
        projectName: String? = nil,
        estimatedCost: Double,
        reference: Date = Date()
    ) async -> BudgetGateDecision {
        guard let gate else { return .allow }
        let decision = await gate.evaluate(
            credential: credential,
            projectName: projectName,
            estimatedCost: estimatedCost,
            reference: reference
        )
        await notify(for: decision, reference: reference)
        return decision
    }

    /// Renders a Markdown-flavored section describing every active budget rule with its
    /// current spend, forecast, and any active block. Injected into Hermes system prompts
    /// by the context builder so the assistant can answer "where is my spend?" without
    /// making a tool call when the context already has the answer.
    func budgetContextSection() async -> String? {
        guard let gate else { return nil }
        let rules = gate.rulesForContext()
        guard !rules.isEmpty else { return nil }

        var lines: [String] = ["## Budgets & per-usage credentials"]
        var activeBlocks: [String] = []
        let now = Date()
        for rule in rules.prefix(8) {
            let used = (try? await gate.ledgerSpend(forRule: rule, reference: now)) ?? 0
            let limit = rule.amountUSD
            let percent = limit > 0 ? Int((used / limit) * 100) : 0
            let label = rule.displayLabel
            let periodLabel: String
            switch rule.period {
            case .day: periodLabel = "today"
            case .week: periodLabel = "this week"
            case .month: periodLabel = "this month"
            case .allTime: periodLabel = "all time"
            }
            var line = "- \(label): $\(String(format: "%.2f", used)) of $\(String(format: "%.2f", limit)) \(periodLabel) (\(percent)%)"
            if rule.isPaused(at: now), let pausedUntil = rule.pausedUntil {
                line += " [paused until \(pausedUntil.formatted(date: .abbreviated, time: .shortened))]"
            }
            lines.append(line)
            if used >= limit && limit > 0 && rule.behavior != .warnOnly {
                activeBlocks.append("- \(label): $\(String(format: "%.2f", used)) ≥ $\(String(format: "%.2f", limit))")
            }
        }
        if !activeBlocks.isEmpty {
            lines.append("")
            lines.append("## Active blocks")
            lines.append(contentsOf: activeBlocks)
        }
        return lines.joined(separator: "\n")
    }

    /// Surfaces warnings (debounced per period) and blocks (always) to the user. Caller
    /// already chose to allow / abort — this is purely side-effect.
    private func notify(for decision: BudgetGateDecision, reference: Date) async {
        guard let notificationCenter else { return }
        switch decision {
        case .warn(let rule, _, let used, let limit):
            notificationCenter.emitWarning(
                rule: rule,
                used: used,
                limit: limit,
                periodStart: rule.period.windowStart(reference: reference)
            )
        case .block(let rule, let used, let limit, _):
            notificationCenter.emitBlock(rule: rule, used: used, limit: limit)
        case .allow, .paused:
            break
        }
    }

    // MARK: - Cost estimation

    /// Rough cost estimate for a request. Approximates input tokens from total character
    /// count (≈4 chars/token) and assumes a typical output budget of 1024 tokens. The gate
    /// uses this as a forward-looking delta — once the request completes, the canonical
    /// `token_usage` insert refines the ledger to exact pricing.
    ///
    /// Uses a simplified pricing table ($3/MTok input, $15/MTok output — Claude 3.5 Sonnet
    /// ballpark) since the mobile app doesn't ship `ModelPricing.lookup()`. This is a
    /// conservative estimate; the daemon refines with exact per-model pricing.
    nonisolated static func estimateCost(model: String, inputCharacters: Int, assumedOutputTokens: Int = 1024) -> Double {
        let inputTokens = max(0, inputCharacters) / 4
        // Simplified pricing: $3/MTok input, $15/MTok output (Claude 3.5 Sonnet ballpark)
        // This is a conservative estimate — the daemon refines with exact pricing
        let inputUSD = Double(inputTokens) * 3.0 / 1_000_000.0
        let outputUSD = Double(assumedOutputTokens) * 15.0 / 1_000_000.0
        return inputUSD + outputUSD
    }
}

/// Stable credential identity for mobile-plane requests. Hashes the bearer token so the
/// raw secret never leaves the call frame; the resulting slot ID lines up with what the
/// usage row would store under `providerAccountID`.
enum MobileCredentialIdentity {
    static func make(providerHint: String, bearerToken: String?, displayLabel: String) -> BudgetCredentialIdentity {
        let secret = bearerToken ?? ""
        let mode = BudgetCredentialIdentity.billingMode(forSecretPrefix: secret)
        let slotID = secret.isEmpty ? "default" : hashedSlotID(secret)
        return BudgetCredentialIdentity(
            providerID: providerHint,
            slotID: slotID,
            displayLabel: displayLabel,
            billingMode: mode
        )
    }

    private static func hashedSlotID(_ secret: String) -> String {
        // FNV-1a hash — cheap stable hash. Collisions are acceptable for slot identity
        // since the user labels their credentials.
        var hash: UInt64 = 14695981039346656037
        for byte in secret.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 36, uppercase: false)
    }
}
