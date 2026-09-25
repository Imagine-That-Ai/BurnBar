// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import OpenBurnBarUsageModels

// MARK: - BudgetRuleProviding shared filtering

/// In-memory rule filtering shared by the macOS and iOS `BudgetSettings` facades.
/// Both twins filtered their `rules` cache identically; the defaults below are that
/// logic, once. Backends keep their persistence, refresh, migration, and analytics
/// seams platform-side.
extension BudgetRuleProviding {
    /// Every credential-scope rule for the given `(providerID, accountID)` pair.
    public func rules(forCredential providerID: String, accountID: String?) -> [BudgetRule] {
        rules.filter {
            guard $0.scope == .credential, $0.providerID == providerID else { return false }
            if let accountID {
                return $0.accountID == accountID
            }
            return $0.accountID == nil || $0.accountID?.isEmpty == true
        }
    }

    /// Every project-scope rule for the given free-text project name.
    public func rules(forProject projectName: String) -> [BudgetRule] {
        rules.filter { $0.scope == .project && $0.projectName == projectName }
    }

    public var globalRules: [BudgetRule] { rules.filter { $0.scope == .global } }
    public var organizationRules: [BudgetRule] { rules.filter { $0.scope == .organization } }
    public var credentialRules: [BudgetRule] { rules.filter { $0.scope == .credential } }
    public var projectRules: [BudgetRule] { rules.filter { $0.scope == .project } }

    /// The most permissive global rule (the largest amount). Used by `BudgetGate` when
    /// no credential- or project-scope rule matches a request.
    public var primaryGlobalRule: BudgetRule? {
        rules
            .filter { $0.scope == .global }
            .max(by: { $0.amountUSD < $1.amountUSD })
    }
}

// MARK: - BudgetLedgerReading snapshot

extension BudgetLedgerReading {
    /// Cheaper "fast path" check for batch gate evaluation — runs one spend read per
    /// rule and returns the totals keyed by `rule.id`.
    ///
    /// Fail-closed contract: a rule whose spend read **succeeds** is always present in
    /// the result — including the legitimate `0.0` for "no matching rows". A rule whose
    /// spend read **fails** is deliberately *omitted* and reported through
    /// `onReadFailure`, so the gate never silently treats an unreadable ledger as zero
    /// accumulated spend. Callers MUST treat a missing key as at-limit / blocked.
    public func snapshot(
        forRules rules: [BudgetRule],
        reference: Date = Date(),
        onReadFailure: (@Sendable (BudgetRule, any Error) -> Void)? = nil
    ) async -> [String: Double] {
        var result: [String: Double] = [:]
        for rule in rules {
            do {
                result[rule.id] = try await currentSpend(forRule: rule, reference: reference)
            } catch {
                // Do NOT default to 0: a swallowed read failure would report zero
                // accumulated spend and let an over-limit request through (fail-open).
                onReadFailure?(rule, error)
            }
        }
        return result
    }
}
