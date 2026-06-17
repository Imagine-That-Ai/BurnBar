import Foundation
#if canImport(UserNotifications)
import UserNotifications

/// Fires user notifications on budget thresholds.
///
/// Debounces warning notifications to one per `(rule, period)` so a chatty day
/// does not spam the user. Block notifications always fire because the user
/// needs to act when a request is denied.
@MainActor
public final class BudgetNotificationCenter {
    public typealias DeliveryHandler = @MainActor (UNNotificationContent, String) -> Void

    private let center: UNUserNotificationCenter?
    private let deliveryHandler: DeliveryHandler?
    private var authorized = false
    private var warningSeen: Set<String> = []

    public init(
        center: UNUserNotificationCenter? = nil,
        deliveryHandler: DeliveryHandler? = nil
    ) {
        self.deliveryHandler = deliveryHandler
        self.center = center ?? (deliveryHandler == nil ? .current() : nil)
    }

    public func requestAuthorizationIfNeeded() {
        guard let center else {
            authorized = true
            return
        }
        Task { @MainActor in
            do {
                authorized = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                authorized = false
            }
        }
    }

    /// Schedule a warning notification once per `(rule.id, periodWindow)` until the period resets.
    public func emitWarning(rule: BudgetRule, used: Double, limit: Double, periodStart: Date?) {
        let key = warningKey(rule: rule, periodStart: periodStart)
        guard !warningSeen.contains(key) else { return }
        warningSeen.insert(key)

        let usedPercent = limit > 0 ? Int((used / limit) * 100) : 0
        let content = UNMutableNotificationContent()
        content.title = "Budget warning · \(rule.displayLabel)"
        content.body = "$\(String(format: "%.2f", used)) of $\(String(format: "%.2f", limit)) (\(usedPercent)%) — heading toward the cap."
        content.sound = .default
        content.userInfo = ["ruleID": rule.id, "kind": "warning"]
        deliver(
            content: content,
            identifier: "burnbar.budget.warn.\(rule.id).\(periodStart?.timeIntervalSince1970 ?? 0)"
        )
    }

    /// Always-fire 100% block notification.
    public func emitBlock(rule: BudgetRule, used: Double, limit: Double, reference: Date = Date()) {
        let content = UNMutableNotificationContent()
        content.title = "Budget reached · \(rule.displayLabel)"
        content.body = "$\(String(format: "%.2f", used)) ≥ $\(String(format: "%.2f", limit)). New requests on this scope are blocked until you raise the limit or the period resets."
        content.sound = .defaultCritical
        content.userInfo = ["ruleID": rule.id, "kind": "block"]
        deliver(content: content, identifier: "burnbar.budget.block.\(rule.id).\(reference.timeIntervalSince1970)")
    }

    /// Resets the warning debounce when a period rolls over.
    public func resetWarningDebounce() {
        warningSeen.removeAll(keepingCapacity: true)
    }

    var warningDebounceCount: Int {
        warningSeen.count
    }

    private func warningKey(rule: BudgetRule, periodStart: Date?) -> String {
        "\(rule.id)#\(periodStart?.timeIntervalSince1970 ?? 0)"
    }

    private func deliver(content: UNNotificationContent, identifier: String) {
        if let deliveryHandler {
            deliveryHandler(content, identifier)
            return
        }

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        center?.add(request) { _ in }
    }
}
#endif
