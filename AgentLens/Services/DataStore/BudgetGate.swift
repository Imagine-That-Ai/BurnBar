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

// MARK: - Collaborator seams

/// The slice of `BudgetSettings` that `BudgetGate` reads. Extracted to a protocol so the
/// gate can be exercised against in-memory fakes (and so a future provider can back the
/// rules with something other than SQLite) without dragging in `BudgetRulesStore`.
@MainActor
protocol BudgetRuleProviding: AnyObject {
    var rules: [BudgetRule] { get }
    var globalRules: [BudgetRule] { get }
    func rules(forCredential providerID: String, accountID: String?) -> [BudgetRule]
    func rules(forProject projectName: String) -> [BudgetRule]
}

extension BudgetSettings: BudgetRuleProviding {}

/// The single ledger read `BudgetGate` performs per rule. Extracted to a protocol so tests
/// can inject a ledger that throws on demand — the failure path is the whole point of the
/// budget gate (a swallowed read used to fail OPEN, letting an over-budget request through).
protocol BudgetLedgerReading: Sendable {
    func currentSpend(forRule rule: BudgetRule, reference: Date) async throws -> Double
}

// `BudgetLedger.currentSpend(forRule:reference:)` already matches the protocol requirement
// (its `reference` default arg is irrelevant to witness matching), so the conformance is
// satisfied by the existing actor method with no shim.
extension BudgetLedger: BudgetLedgerReading {}

// MARK: - BudgetGate

/// Pure gate decisioning over `BudgetSettings` + `BudgetLedger`. Stateless apart from a
/// reference to its two collaborators — both the daemon plane and the AgentLens plane
/// call `evaluate` and translate the returned `BudgetGateDecision` into protocol-specific
/// responses (HTTP 402 with `BurnBar-Budget-Limit` header on the daemon; thrown
/// `BudgetBlockedError` on the AgentLens client).
@MainActor
final class BudgetGate {
    private let settings: any BudgetRuleProviding
    private let ledger: any BudgetLedgerReading
    private let warningThreshold: Double

    init(settings: BudgetSettings, ledger: BudgetLedger, warningThreshold: Double = 0.8) {
        self.settings = settings
        self.ledger = ledger
        self.warningThreshold = warningThreshold
    }

    /// Test/seam initializer. Lets callers inject in-memory rule providers and a ledger that
    /// can fail, so the fail-closed path below is reachable without a live SQLite queue.
    init(
        ruleProvider: any BudgetRuleProviding,
        ledger: any BudgetLedgerReading,
        warningThreshold: Double = 0.8
    ) {
        self.settings = ruleProvider
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
            let decision: BudgetGateDecision
            do {
                let used = try await ledger.currentSpend(forRule: rule, reference: reference)
                let projected = used + max(0, estimatedCost)
                decision = classify(rule: rule, used: used, projected: projected)
            } catch {
                // FAIL CLOSED. A failed ledger read means current spend is UNKNOWN. The
                // previous `(try?...) ?? 0` coerced the unknown to 0, so a rule that was
                // actually at/over its limit evaluated as well under budget and let the
                // request through — a silent fail-open on the budget-enforcement decision.
                // Reject (or, for warn-only rules, surface a warning) instead of allowing a
                // possibly-over-budget request, and make the read failure observable.
                AppLogger.dataStore.error(
                    "budget_gate_ledger_read_failed",
                    metadata: [
                        "ruleScope": rule.scope.rawValue,
                        "ruleBehavior": rule.behavior.rawValue,
                        "errorClass": "\(String(describing: type(of: error)))"
                    ]
                )
                decision = failClosedDecision(for: rule)
            }
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

    /// The decision to return when the ledger read fails and current spend is unknown.
    ///
    /// Block-capable behaviors fail closed to `.block` (the same path a known over-limit
    /// rule takes), so an unreadable ledger can never let an over-budget request through.
    /// `.warnOnly` is contractually non-blocking — it must always let the request through —
    /// so it cannot fail closed to `.block`; instead it fails to `.warn` so the failed read
    /// is still surfaced to the user rather than silently allowed.
    private func failClosedDecision(for rule: BudgetRule) -> BudgetGateDecision {
        let limit = rule.amountUSD
        switch rule.behavior {
        case .warnOnly:
            return .warn(rule: rule, usedPercent: 1.0, used: limit, limit: limit)
        case .warnThenBlock, .hardBlock, .hardBlockWithFallback:
            return .block(rule: rule, used: limit, limit: limit, fallback: nil)
        }
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
