import XCTest
@testable import OpenBurnBarCore
#if canImport(UserNotifications)
import UserNotifications

@MainActor
final class BudgetNotificationCenterTests: XCTestCase {
    func testWarningNotificationsAreDebouncedPerRuleAndPeriod() {
        var delivered: [(UNNotificationContent, String)] = []
        let center = BudgetNotificationCenter(deliveryHandler: { content, identifier in
            delivered.append((content, identifier))
        })
        let rule = BudgetRule(
            id: "rule_daily",
            scope: .global,
            label: "Daily cap",
            amountUSD: 20,
            period: .day
        )
        let periodStart = Date(timeIntervalSince1970: 1_725_000_000)

        center.emitWarning(rule: rule, used: 16, limit: 20, periodStart: periodStart)
        center.emitWarning(rule: rule, used: 18, limit: 20, periodStart: periodStart)

        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(center.warningDebounceCount, 1)
        XCTAssertEqual(delivered[0].0.title, "Budget warning · Daily cap")
        XCTAssertEqual(delivered[0].0.userInfo["ruleID"] as? String, "rule_daily")
        XCTAssertEqual(delivered[0].0.userInfo["kind"] as? String, "warning")
        XCTAssertEqual(delivered[0].1, "burnbar.budget.warn.rule_daily.1725000000.0")
    }

    func testResetWarningDebounceAllowsNextWarning() {
        var delivered: [String] = []
        let center = BudgetNotificationCenter(deliveryHandler: { _, identifier in
            delivered.append(identifier)
        })
        let rule = BudgetRule(
            id: "rule_monthly",
            scope: .global,
            label: "Monthly cap",
            amountUSD: 100,
            period: .month
        )
        let periodStart = Date(timeIntervalSince1970: 1_725_000_000)

        center.emitWarning(rule: rule, used: 80, limit: 100, periodStart: periodStart)
        center.resetWarningDebounce()
        center.emitWarning(rule: rule, used: 90, limit: 100, periodStart: periodStart)

        XCTAssertEqual(delivered.count, 2)
        XCTAssertEqual(center.warningDebounceCount, 1)
    }

    func testBlockNotificationsAlwaysFire() {
        var delivered: [(UNNotificationContent, String)] = []
        let center = BudgetNotificationCenter(deliveryHandler: { content, identifier in
            delivered.append((content, identifier))
        })
        let rule = BudgetRule(
            id: "rule_block",
            scope: .global,
            label: "All usage",
            amountUSD: 10,
            period: .day
        )
        let reference = Date(timeIntervalSince1970: 1_725_000_123)

        center.emitBlock(rule: rule, used: 10.25, limit: 10, reference: reference)
        center.emitBlock(rule: rule, used: 10.50, limit: 10, reference: reference)

        XCTAssertEqual(delivered.count, 2)
        XCTAssertEqual(delivered[0].0.title, "Budget reached · All usage")
        XCTAssertEqual(delivered[0].0.userInfo["ruleID"] as? String, "rule_block")
        XCTAssertEqual(delivered[0].0.userInfo["kind"] as? String, "block")
        XCTAssertEqual(delivered[0].1, "burnbar.budget.block.rule_block.1725000123.0")
    }
}
#endif
