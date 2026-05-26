import Foundation
import UserNotifications
import OpenBurnBarCore

/// Fires UNUserNotifications on budget thresholds. Requests authorization on first use,
/// builds `UNMutableNotificationContent`, and schedules with a
/// `UNTimeIntervalNotificationTrigger` for immediate delivery.
///
/// Debounces 80% warnings to one per (rule, period) so a chatty day doesn't spam the
/// user. 100% blocks always fire because the user explicitly needs to act.
@MainActor
final class BudgetNotificationCenter {
    private let center = UNUserNotificationCenter.current()
    private var authorized = false
    private var warningSeen: Set<String> = []

    func requestAuthorizationIfNeeded() {
        Task { @MainActor in
            do {
                authorized = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                authorized = false
            }
        }
    }

    /// Schedule a warning notification — one per (rule.id, periodWindow) until the period resets.
    func emitWarning(rule: BudgetRule, used: Double, limit: Double, periodStart: Date?) {
        let key = warningKey(rule: rule, periodStart: periodStart)
        guard !warningSeen.contains(key) else { return }
        warningSeen.insert(key)

        let usedPercent = limit > 0 ? Int((used / limit) * 100) : 0
        let content = UNMutableNotificationContent()
        content.title = "Budget warning · \(rule.displayLabel)"
        content.body = "$\(String(format: "%.2f", used)) of $\(String(format: "%.2f", limit)) (\(usedPercent)%) — heading toward the cap."
        content.sound = .default
        content.userInfo = ["ruleID": rule.id, "kind": "warning"]
        deliver(content: content, identifier: "burnbar.budget.warn.\(rule.id).\(periodStart?.timeIntervalSince1970 ?? 0)")
    }

    /// Always-fire 100% block notification. Includes a "Raise limit" / "Open Budget Settings"
    /// hint in the body since custom actions require a category registration which a future
    /// polish pass can layer in.
    func emitBlock(rule: BudgetRule, used: Double, limit: Double) {
        let content = UNMutableNotificationContent()
        content.title = "Budget reached · \(rule.displayLabel)"
        content.body = "$\(String(format: "%.2f", used)) ≥ $\(String(format: "%.2f", limit)). New requests on this scope are blocked until you raise the limit or the period resets."
        content.sound = .defaultCritical
        content.userInfo = ["ruleID": rule.id, "kind": "block"]
        deliver(content: content, identifier: "burnbar.budget.block.\(rule.id).\(Date().timeIntervalSince1970)")
    }

    /// Resets the warning debounce when a period rolls over. Call from a daily timer.
    func resetWarningDebounce() {
        warningSeen.removeAll(keepingCapacity: true)
    }

    // MARK: - Helpers

    private func warningKey(rule: BudgetRule, periodStart: Date?) -> String {
        "\(rule.id)#\(periodStart?.timeIntervalSince1970 ?? 0)"
    }

    private func deliver(content: UNNotificationContent, identifier: String) {
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        center.add(request) { _ in }
    }
}
