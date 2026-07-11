import Foundation
import OpenBurnBarCore

// MARK: - BudgetGate platform seams (macOS)
//
// The gate itself lives in OpenBurnBarCore (`Budget/BudgetGate.swift`) — this file only
// binds it to the AgentLens plane: concrete collaborator conformances plus a convenience
// initializer that routes ledger read failures through `AppLogger` (same event names and
// metadata keys the in-app gate logged before the de-fork).

extension BudgetSettings: BudgetRuleProviding {}

// `BudgetLedger.currentSpend(forRule:reference:)` already matches the protocol requirement
// (its `reference` default arg is irrelevant to witness matching), so the conformance is
// satisfied by the existing actor method with no shim.
extension BudgetLedger: BudgetLedgerReading {}

extension BudgetGate {
    /// Production initializer for the AgentLens plane. Preserves the pre-de-fork logging
    /// pipeline: ledger read failures are reported through `AppLogger.dataStore` as
    /// `budget_gate_ledger_read_failed` / `budget_gate_fallback_ledger_read_failed` with
    /// ruleScope / ruleBehavior / errorClass metadata.
    convenience init(settings: BudgetSettings, ledger: BudgetLedger, warningThreshold: Double = 0.8) {
        self.init(
            ruleProvider: settings,
            ledger: ledger,
            warningThreshold: warningThreshold,
            onLedgerReadFailure: { rule, error, isFallbackPath in
                AppLogger.dataStore.error(
                    isFallbackPath ? "budget_gate_fallback_ledger_read_failed" : "budget_gate_ledger_read_failed",
                    metadata: [
                        "ruleScope": rule.scope.rawValue,
                        "ruleBehavior": rule.behavior.rawValue,
                        "errorClass": "\(String(describing: type(of: error)))"
                    ]
                )
            }
        )
    }
}
