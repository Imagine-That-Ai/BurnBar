// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import OpenBurnBarUsageModels

// MARK: - BudgetNotificationEmitting

/// The notification surface `BudgetEnforcement` drives. The macOS and iOS notification
/// centers both deliver through `UNUserNotificationCenter` (Apple-only API, so the
/// delivery stays platform-side); this protocol is the seam the Core enforcement
/// singleton programs against.
@MainActor
public protocol BudgetNotificationEmitting: AnyObject {
    func requestAuthorizationIfNeeded()
    func emitWarning(rule: BudgetRule, used: Double, limit: Double, periodStart: Date?)
    func emitBlock(rule: BudgetRule, used: Double, limit: Double)
}

// MARK: - BudgetNotificationContent

/// Shared notification copy + identifiers for the budget threshold notifications.
/// Both platform centers rendered these byte-identically (the macOS-only delta is the
/// Analytics tracking call, which stays in the macOS file).
public enum BudgetNotificationContent {
    public static func warningTitle(rule: BudgetRule) -> String {
        "Budget warning · \(rule.displayLabel)"
    }

    public static func warningBody(used: Double, limit: Double) -> String {
        let usedPercent = limit > 0 ? Int((used / limit) * 100) : 0
        return "$\(format(used)) of $\(format(limit)) (\(usedPercent)%) — heading toward the cap."
    }

    public static func blockTitle(rule: BudgetRule) -> String {
        "Budget reached · \(rule.displayLabel)"
    }

    public static func blockBody(used: Double, limit: Double) -> String {
        "$\(format(used)) ≥ $\(format(limit)). New requests on this scope are blocked until you raise the limit or the period resets."
    }

    public static func userInfo(ruleID: String, kind: String) -> [String: String] {
        ["ruleID": ruleID, "kind": kind]
    }

    public static func warningIdentifier(ruleID: String, periodStart: Date?) -> String {
        "burnbar.budget.warn.\(ruleID).\(periodStart?.timeIntervalSince1970 ?? 0)"
    }

    public static func blockIdentifier(ruleID: String, now: Date) -> String {
        "burnbar.budget.block.\(ruleID).\(now.timeIntervalSince1970)"
    }

    /// Debounce key: one warning per (rule, period window) until the period resets.
    public static func warningDebounceKey(ruleID: String, periodStart: Date?) -> String {
        "\(ruleID)#\(periodStart?.timeIntervalSince1970 ?? 0)"
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
