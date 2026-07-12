import Foundation
import OpenBurnBarCore
import os

// MARK: - BudgetGate platform seams (iOS)
//
// The gate itself lives in OpenBurnBarCore (`Budget/BudgetGate.swift`) — this file only
// binds it to the mobile plane: concrete collaborator conformances plus a convenience
// initializer that routes ledger read failures through `os.Logger` with the same message
// format the in-app gate logged before the de-fork.

private let budgetGateLogger = Logger(subsystem: "com.openburnbar.mobile", category: "BudgetGate")

extension BudgetSettings: BudgetRuleProviding {}

// `BudgetLedger.currentSpend(forRule:reference:)` already matches the protocol requirement
// (its `reference` default arg is irrelevant to witness matching), so the conformance is
// satisfied by the existing actor method with no shim.
extension BudgetLedger: BudgetLedgerReading {}

extension BudgetGate {
    /// Production initializer for the mobile plane. Preserves the pre-de-fork logging
    /// pipeline: ledger read failures are reported through the mobile `os.Logger` as
    /// `budget_gate_ledger_read_failed` / `budget_gate_fallback_ledger_read_failed` with
    /// scope= behavior= error= fields.
    convenience init(settings: BudgetSettings, ledger: BudgetLedger, warningThreshold: Double = 0.8) {
        self.init(
            ruleProvider: settings,
            ledger: ledger,
            warningThreshold: warningThreshold,
            onLedgerReadFailure: { rule, error, isFallbackPath in
                let event = isFallbackPath
                    ? "budget_gate_fallback_ledger_read_failed"
                    : "budget_gate_ledger_read_failed"
                budgetGateLogger.error(
                    "\(event, privacy: .public) scope=\(rule.scope.rawValue, privacy: .public) behavior=\(rule.behavior.rawValue, privacy: .public) error=\(String(describing: type(of: error)), privacy: .public)"
                )
            }
        )
    }
}
