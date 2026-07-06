import Foundation
import OpenBurnBarCore

// MARK: - Errors

/// Thrown by the mobile budget gate when a rule blocks an outbound request.
/// The budgeting UI catches this and renders a blocked state with raise / override /
/// settings actions.
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
/// reference to its two collaborators — both the Hermes chat path and any daemon-proxied
/// gateway reach `evaluate` and translate the returned `BudgetGateDecision` into
/// protocol-specific responses (e.g. thrown `BudgetBlockedError` on the mobile client).
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
            let used = await ledger.currentSpend(forRule: rule, reference: reference)
            let projected = used + max(0, estimatedCost)
            let decision = await classify(
                rule: rule,
                used: used,
                projected: projected,
                estimatedCost: max(0, estimatedCost),
                projectName: projectName,
                reference: reference
            )
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
        rules.append(contentsOf: settings.organizationRules.filter { rule in
            guard let identifier = Self.nonEmpty(rule.identifier) else { return false }
            return identifier == credential.slotID || identifier == credential.displayLabel
        })
        if let projectName, !projectName.isEmpty {
            rules.append(contentsOf: settings.rules(forProject: projectName))
        }
        rules.append(contentsOf: settings.globalRules)
        return rules.filter { $0.isEnabled && $0.amountUSD > 0 }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func classify(
        rule: BudgetRule,
        used: Double,
        projected: Double,
        estimatedCost: Double,
        projectName: String?,
        reference: Date
    ) async -> BudgetGateDecision {
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
                let fallback = await resolveFallback(
                    for: rule,
                    estimatedCost: estimatedCost,
                    projectName: projectName,
                    reference: reference
                )
                return .block(rule: rule, used: used, limit: limit, fallback: fallback)
            } else if projectedPercent >= warningThreshold {
                return .warn(rule: rule, usedPercent: usedPercent, used: used, limit: limit)
            }
            return .allow
        }
    }

    /// Resolves the ordered fallback rule IDs attached to a hard-block rule into the first
    /// concrete credential identity callers can promote. Fallback IDs point at credential
    /// budget rules, not secrets; the billing mode stays `.unknown` so a later gate evaluation
    /// never accidentally treats the destination as a subscription credential. A candidate is
    /// only returned when its own rule would not hard-block the same estimated request.
    private func resolveFallback(
        for blockingRule: BudgetRule,
        estimatedCost: Double,
        projectName: String?,
        reference: Date
    ) async -> BudgetCredentialIdentity? {
        let requestedIDs = blockingRule.fallbackCredentialIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !requestedIDs.isEmpty else { return nil }

        var rulesByID: [String: BudgetRule] = [:]
        for rule in settings.rules where rulesByID[rule.id] == nil {
            rulesByID[rule.id] = rule
        }
        for id in requestedIDs {
            guard let candidate = rulesByID[id],
                  let identity = fallbackIdentity(for: candidate, blockedBy: blockingRule),
                  await fallbackCanAccept(
                    identity,
                    estimatedCost: estimatedCost,
                    projectName: projectName,
                    reference: reference
                  ) else {
                continue
            }
            return identity
        }
        return nil
    }

    private func fallbackIdentity(
        for candidate: BudgetRule,
        blockedBy blockingRule: BudgetRule
    ) -> BudgetCredentialIdentity? {
        guard candidate.id != blockingRule.id,
              candidate.scope == .credential,
              candidate.isEnabled,
              candidate.amountUSD > 0,
              let providerID = normalized(candidate.providerID) else {
            return nil
        }

        let slotID = normalized(candidate.accountID) ?? "default"
        if blockingRule.scope == .credential,
           normalized(blockingRule.providerID) == providerID,
           (normalized(blockingRule.accountID) ?? "default") == slotID {
            return nil
        }

        return BudgetCredentialIdentity(
            providerID: providerID,
            slotID: slotID,
            displayLabel: candidate.displayLabel,
            billingMode: .unknown
        )
    }

    private func fallbackCanAccept(
        _ identity: BudgetCredentialIdentity,
        estimatedCost: Double,
        projectName: String?,
        reference: Date
    ) async -> Bool {
        let fallbackRules = matchingRules(credential: identity, projectName: projectName)
        guard !fallbackRules.isEmpty else { return true }

        for rule in fallbackRules {
            if rule.isPaused(at: reference) {
                continue
            }

            let used = await ledger.currentSpend(forRule: rule, reference: reference)
            if fallbackRuleWouldBlock(rule, used: used, estimatedCost: estimatedCost) {
                return false
            }
        }
        return true
    }

    private func fallbackRuleWouldBlock(
        _ rule: BudgetRule,
        used: Double,
        estimatedCost: Double
    ) -> Bool {
        let projected = used + max(0, estimatedCost)
        switch rule.behavior {
        case .warnOnly:
            return false
        case .warnThenBlock, .hardBlock, .hardBlockWithFallback:
            return projected >= rule.amountUSD
        }
    }

    private func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Exposes all active rules (credential + project + global) for the Hermes context
    /// builder. Does not query the ledger — callers fetch spend separately.
    func rulesForContext() -> [BudgetRule] {
        settings.rules.filter { $0.isEnabled && $0.amountUSD > 0 }
    }

    /// Exposes the ledger's current spend for a rule — wrapped so callers don't have to
    /// hold a separate `BudgetLedger` reference.
    func ledgerSpend(forRule rule: BudgetRule, reference: Date = Date()) async throws -> Double {
        await ledger.currentSpend(forRule: rule, reference: reference)
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
