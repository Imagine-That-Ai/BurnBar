// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import OpenBurnBarUsageModels

// MARK: - BudgetContextSpendFallback

/// Spend assumed by `budgetContextSection()` when a rule's ledger read fails.
/// The twins diverged here: macOS rendered unknown spend as `$0`, iOS rendered it
/// as the rule limit (fail-closed display). Backends pass their historical value at
/// `configure` time so the context prompt each plane injects is byte-identical to
/// before the consolidation.
public enum BudgetContextSpendFallback: Sendable {
    /// Render unknown spend as `$0` (macOS historical behavior).
    case zero
    /// Render unknown spend as the rule limit (iOS historical behavior).
    case limit
}

// MARK: - BudgetEnforcement

/// Process-wide entry point that gate-aware call sites use without restructuring their
/// initializers. The AgentLens chat client, the mobile Hermes chat path, and the daemon
/// HTTP gateway all reach `BudgetEnforcement.shared.evaluate(...)` to ask the gate for
/// a decision.
///
/// Unified from the macOS and iOS `BudgetEnforcement` twins. The twins shared their
/// evaluate/notify/context-section logic and differed only in injected backends, which
/// are now `configure` parameters: the notification center (`BudgetNotificationEmitting`,
/// implemented per-platform over `UNUserNotificationCenter`), the forecast backend
/// (`BudgetForecasting`, GRDB on macOS / rollups on iOS), the cost estimator
/// (`BudgetCostEstimating`, per-model pricing on macOS / flat rate on iOS), and the
/// context-section ledger fallback. The user-scoped configuration tracking is the iOS
/// twin's (macOS passes no user ID and never calls the user-scoped queries).
///
/// At app launch, the runtime calls `configure(...)` once; until then `evaluate`
/// returns `.allow` so test harnesses and detached subprocesses keep working.
@MainActor
public final class BudgetEnforcement {
    public static let shared = BudgetEnforcement()

    private var gate: BudgetGate?
    private var notificationCenter: (any BudgetNotificationEmitting)?
    private var forecast: (any BudgetForecasting)?
    private var costEstimator: any BudgetCostEstimating = FlatRateBudgetCostEstimator.mobileDefault
    private var contextSpendFallback: BudgetContextSpendFallback = .zero
    private var configuredUserID: String?

    private init() {}

    /// Wire the gate built at app startup. Safe to call multiple times — the latest gate
    /// wins (handy when a sign-out flow rebuilds the database queue or the signed-in
    /// user changes).
    public func configure(
        userID: String? = nil,
        gate: BudgetGate,
        notifications: (any BudgetNotificationEmitting)? = nil,
        forecast: (any BudgetForecasting)? = nil,
        costEstimator: any BudgetCostEstimating,
        contextSpendFallback: BudgetContextSpendFallback
    ) {
        self.gate = gate
        self.notificationCenter = notifications
        self.forecast = forecast
        self.costEstimator = costEstimator
        self.contextSpendFallback = contextSpendFallback
        self.configuredUserID = userID
        notifications?.requestAuthorizationIfNeeded()
    }

    public var isConfigured: Bool { gate != nil }

    public func isConfigured(forUserID userID: String) -> Bool {
        gate != nil && configuredUserID == userID
    }

    public func resetIfConfiguredForDifferentUser(_ userID: String) {
        guard gate != nil, configuredUserID != userID else { return }
        reset()
    }

    public func resetForTesting() {
        reset()
    }

    private func reset() {
        gate = nil
        notificationCenter = nil
        forecast = nil
        configuredUserID = nil
    }

    /// Exposed for views that want live forecast projections.
    public var forecastService: (any BudgetForecasting)? { forecast }

    public func evaluate(
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
    public func budgetContextSection() async -> String? {
        guard let gate else { return nil }
        let rules = gate.rulesForContext()
        guard !rules.isEmpty else { return nil }

        var lines: [String] = ["## Budgets & per-usage credentials"]
        var activeBlocks: [String] = []
        let now = Date()
        for rule in rules.prefix(8) {
            let fallbackSpend: Double
            switch contextSpendFallback {
            case .zero: fallbackSpend = 0
            case .limit: fallbackSpend = rule.amountUSD
            }
            let used = (try? await gate.ledgerSpend(forRule: rule, reference: now)) ?? fallbackSpend // try?-ok(context-prompt display only)
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
    /// usage insert refines the ledger to exact pricing. Priced by the estimator injected
    /// at `configure` time (per-model pricing on macOS, flat rate on iOS).
    public func estimateCost(model: String, inputCharacters: Int, assumedOutputTokens: Int = 1024) -> Double {
        costEstimator.estimateCost(
            model: model,
            inputCharacters: inputCharacters,
            assumedOutputTokens: assumedOutputTokens
        )
    }
}
