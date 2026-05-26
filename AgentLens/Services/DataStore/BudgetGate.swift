import Foundation
import OpenBurnBarCore

// MARK: - Errors

/// Thrown by the AgentLens-plane gate (`OpenAICompatibleChatGatewayClient`) when a rule
/// blocks an outbound request. `ChatSessionController` catches this and renders a
/// `BudgetBlockedCard` with raise / override / settings actions.
struct BudgetBlockedError: Error, LocalizedError, Sendable {
    let rule: BudgetRule
    let used: Double
    let limit: Double
    let fallback: BudgetCredentialIdentity?
    let resetAt: Date?

    var errorDescription: String? {
        "Budget limit reached on \(rule.displayLabel): $\(String(format: "%.2f", used)) of $\(String(format: "%.2f", limit))."
    }
}

// MARK: - BudgetGate

/// Pure gate decisioning over `BudgetSettings` + `BudgetLedger`. Stateless apart from a
/// reference to its two collaborators — both the daemon plane and the AgentLens plane
/// call `evaluate` and translate the returned `BudgetGateDecision` into protocol-specific
/// responses (HTTP 402 with `BurnBar-Budget-Limit` header on the daemon; thrown
/// `BudgetBlockedError` on the AgentLens client).
@MainActor
final class BudgetGate {
    private let settings: BudgetSettings
    private let ledger: BudgetLedger
    private let warningThreshold: Double

    init(settings: BudgetSettings, ledger: BudgetLedger, warningThreshold: Double = 0.8) {
        self.settings = settings
        self.ledger = ledger
        self.warningThreshold = warningThreshold
    }

    /// Returns the most restrictive decision across every rule matching the credential
    /// (credential-scope rules + project-scope rules visible from the call site +
    /// global rules). Subscription credentials short-circuit to `.allow` before any
    /// query runs so a Claude Pro OAuth key never gets gated by this code.
    func evaluate(
        credential: BudgetCredentialIdentity,
        projectName: String? = nil,
        estimatedCost: Double,
        reference: Date = Date()
    ) async -> BudgetGateDecision {
        if credential.billingMode == .subscription {
            return .allow
        }

        let candidates = matchingRules(credential: credential, projectName: projectName)
        guard !candidates.isEmpty else { return .allow }

        var worst: BudgetGateDecision = .allow
        for rule in candidates {
            if rule.isPaused(at: reference) {
                if let pausedUntil = rule.pausedUntil {
                    let paused: BudgetGateDecision = .paused(rule: rule, resumeAt: pausedUntil)
                    worst = pickMoreRestrictive(worst, paused)
                }
                continue
            }
            let used = (try? await ledger.currentSpend(forRule: rule, reference: reference)) ?? 0
            let projected = used + max(0, estimatedCost)
            let decision = classify(rule: rule, used: used, projected: projected)
            worst = pickMoreRestrictive(worst, decision)
        }
        return worst
    }

    /// Looks up every active rule matching the credential / project. Returns rules in
    /// descending strictness order (credential first, then project, then global) so the
    /// evaluator can stop early once a block is observed if a future optimization adds
    /// short-circuiting.
    private func matchingRules(credential: BudgetCredentialIdentity, projectName: String?) -> [BudgetRule] {
        var rules: [BudgetRule] = []
        rules.append(contentsOf: settings.rules(forCredential: credential.providerID, accountID: credential.slotID))
        if let projectName, !projectName.isEmpty {
            rules.append(contentsOf: settings.rules(forProject: projectName))
        }
        rules.append(contentsOf: settings.globalRules)
        return rules.filter { $0.isEnabled && $0.amountUSD > 0 }
    }

    private func classify(rule: BudgetRule, used: Double, projected: Double) -> BudgetGateDecision {
        let limit = rule.amountUSD
        let projectedPercent = limit > 0 ? projected / limit : 0
        let usedPercent = limit > 0 ? used / limit : 0

        switch rule.behavior {
        case .warnOnly:
            if projectedPercent >= 1.0 {
                return .warn(rule: rule, usedPercent: usedPercent, used: used, limit: limit)
            } else if projectedPercent >= warningThreshold {
                return .warn(rule: rule, usedPercent: usedPercent, used: used, limit: limit)
            }
            return .allow

        case .warnThenBlock:
            if projectedPercent >= 1.0 {
                return .block(rule: rule, used: used, limit: limit, fallback: nil)
            } else if projectedPercent >= warningThreshold {
                return .warn(rule: rule, usedPercent: usedPercent, used: used, limit: limit)
            }
            return .allow

        case .hardBlock:
            if projectedPercent >= 1.0 {
                return .block(rule: rule, used: used, limit: limit, fallback: nil)
            }
            return .allow

        case .hardBlockWithFallback:
            if projectedPercent >= 1.0 {
                // Fallback resolution is left to Phase 4 part B — for now we surface the
                // intent and let callers fall through to their existing failover logic.
                return .block(rule: rule, used: used, limit: limit, fallback: nil)
            } else if projectedPercent >= warningThreshold {
                return .warn(rule: rule, usedPercent: usedPercent, used: used, limit: limit)
            }
            return .allow
        }
    }

    /// Exposes all active rules (credential + project + global) for the Hermes context
    /// builder. Does not query the ledger — callers fetch spend separately.
    func rulesForContext() -> [BudgetRule] {
        settings.rules.filter { $0.isEnabled && $0.amountUSD > 0 }
    }

    /// Exposes the ledger's current spend for a rule — wrapped so callers don't have to
    /// hold a separate `BudgetLedger` reference.
    func ledgerSpend(forRule rule: BudgetRule, reference: Date = Date()) async throws -> Double {
        try await ledger.currentSpend(forRule: rule, reference: reference)
    }

    /// Orders decisions by strictness: paused < allow < warn < block.
    private func pickMoreRestrictive(_ lhs: BudgetGateDecision, _ rhs: BudgetGateDecision) -> BudgetGateDecision {
        priority(rhs) > priority(lhs) ? rhs : lhs
    }

    private func priority(_ decision: BudgetGateDecision) -> Int {
        switch decision {
        case .allow: return 0
        case .paused: return 1
        case .warn: return 2
        case .block: return 3
        }
    }
}
