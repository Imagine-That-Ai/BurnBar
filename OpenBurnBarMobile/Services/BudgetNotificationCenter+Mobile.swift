import Foundation
import UserNotifications
import OpenBurnBarKernel

/// Fires UNUserNotifications on budget thresholds. Requests authorization on first use,
/// builds `UNMutableNotificationContent`, and schedules with a
/// `UNTimeIntervalNotificationTrigger` for immediate delivery.
///
/// Debounces 80% warnings to one per (rule, period) so a chatty day doesn't spam the
/// user. 100% blocks always fire because the user explicitly needs to act.
///
/// The iOS notification backend. Delivery stays here (UNUserNotificationCenter is
/// Apple-only API); the copy/identifier builders live in OpenBurnBarKernel
/// (`BudgetNotificationContent`), shared with the macOS backend.
@MainActor
final class BudgetNotificationCenter: BudgetNotificationEmitting {
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
        let key = BudgetNotificationContent.warningDebounceKey(ruleID: rule.id, periodStart: periodStart)
        guard !warningSeen.contains(key) else { return }
        warningSeen.insert(key)

        let content = UNMutableNotificationContent()
        content.title = BudgetNotificationContent.warningTitle(rule: rule)
        content.body = BudgetNotificationContent.warningBody(used: used, limit: limit)
        content.sound = .default
        content.userInfo = BudgetNotificationContent.userInfo(ruleID: rule.id, kind: "warning")
        deliver(content: content, identifier: BudgetNotificationContent.warningIdentifier(ruleID: rule.id, periodStart: periodStart))
    }

    /// Always-fire 100% block notification. Includes a "Raise limit" / "Open Budget Settings"
    /// hint in the body since custom actions require a category registration which a future
    /// polish pass can layer in.
    func emitBlock(rule: BudgetRule, used: Double, limit: Double) {
        let content = UNMutableNotificationContent()
        content.title = BudgetNotificationContent.blockTitle(rule: rule)
        content.body = BudgetNotificationContent.blockBody(used: used, limit: limit)
        content.sound = .defaultCritical
        content.userInfo = BudgetNotificationContent.userInfo(ruleID: rule.id, kind: "block")
        deliver(content: content, identifier: BudgetNotificationContent.blockIdentifier(ruleID: rule.id, now: Date()))
    }

    /// Resets the warning debounce when a period rolls over. Call from a daily timer.
    func resetWarningDebounce() {
        warningSeen.removeAll(keepingCapacity: true)
    }

    // MARK: - Helpers

    private func deliver(content: UNNotificationContent, identifier: String) {
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        center.add(request) { _ in }
    }
}
