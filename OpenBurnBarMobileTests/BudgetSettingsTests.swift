import XCTest
@testable import OpenBurnBarMobile
import OpenBurnBarCore

final class BudgetSettingsTests: XCTestCase {
    @MainActor
    func testAddAndRemoveRules() async throws {
        let store = BudgetRulesStore()
        let settings = BudgetSettings(store: store)

        XCTAssertEqual(settings.rules.count, 0)

        let rule = BudgetRule(
            scope: .global,
            label: "Test Rule",
            amountUSD: 50.0,
            period: .month
        )

        // Add rule
        let added = await settings.upsertRule(rule, source: "test")
        XCTAssertEqual(added.amountUSD, 50.0)
        XCTAssertEqual(settings.rules.count, 1)
        XCTAssertEqual(settings.rules.first?.id, rule.id)
        XCTAssertEqual(settings.globalRules.count, 1)

        // Delete rule
        await settings.deleteRule(id: rule.id, source: "test")
        XCTAssertEqual(settings.rules.count, 0)
        XCTAssertEqual(settings.globalRules.count, 0)
    }

    @MainActor
    func testPauseAndResumeRules() async throws {
        let store = BudgetRulesStore()
        let settings = BudgetSettings(store: store)

        let rule = BudgetRule(
            scope: .credential,
            providerID: "anthropic",
            label: "Anthropic Rule",
            amountUSD: 100.0,
            period: .week
        )

        await settings.upsertRule(rule, source: "test")
        XCTAssertFalse(settings.rules.first?.isPaused() ?? true)

        // Pause rule for 1 hour
        let resumeTime = Date().addingTimeInterval(3600)
        await settings.pauseRule(id: rule.id, until: resumeTime, source: "test")

        XCTAssertTrue(settings.rules.first?.isPaused() ?? false)
        XCTAssertEqual(settings.rules.first?.pausedUntil, resumeTime)

        // Resume rule
        await settings.resumeRule(id: rule.id, source: "test")
        XCTAssertFalse(settings.rules.first?.isPaused() ?? true)
        XCTAssertNil(settings.rules.first?.pausedUntil)
    }

    @MainActor
    func testLegacyMigration() async throws {
        let key = "dailyBudget"

        // Setup legacy AppStorage value in UserDefaults
        UserDefaults.standard.set(75.50, forKey: key)
        XCTAssertEqual(UserDefaults.standard.double(forKey: key), 75.50)

        let store = BudgetRulesStore()
        let settings = BudgetSettings(store: store)

        // Trigger initialization & migration task.
        // We yield execution to let the back-ground migration Task run.
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms

        // Verify migration succeeded
        XCTAssertEqual(settings.rules.count, 1)
        let migratedRule = settings.rules.first
        XCTAssertEqual(migratedRule?.scope, .global)
        XCTAssertEqual(migratedRule?.amountUSD, 75.50)
        XCTAssertEqual(migratedRule?.period, .day)
        XCTAssertEqual(migratedRule?.behavior, .warnOnly)

        // Verify legacy key was cleared
        XCTAssertEqual(UserDefaults.standard.double(forKey: key), 0.0)
    }
}
