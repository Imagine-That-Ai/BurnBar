import XCTest
@testable import OpenBurnBarMobile
import OpenBurnBarCore

final class BudgetGateTests: XCTestCase {
    @MainActor
    func testGateAllowsUnderLimit() async throws {
        let settings = makeSettings()

        let rule = BudgetRule(
            scope: .global,
            label: "Test Global",
            amountUSD: 100.0,
            period: .month,
            behavior: .warnThenBlock
        )

        await settings.upsertRule(rule, source: "test")

        // Mock data source with $50 spend
        let mockSource = MockSpendDataSource(spend: 50.0)
        let ledger = BudgetLedger(dataSource: mockSource)
        let gate = BudgetGate(settings: settings, ledger: ledger, warningThreshold: 0.8)

        let credential = BudgetCredentialIdentity(
            providerID: "openai",
            slotID: "key_1",
            displayLabel: "OpenAI Key",
            billingMode: .perUsage
        )

        let decision = await gate.evaluate(
            credential: credential,
            estimatedCost: 1.0
        )

        if case .allow = decision {
            // Success
        } else {
            XCTFail("Expected .allow decision, got \(decision)")
        }
    }

    @MainActor
    func testGateWarnsAtEightyPercent() async throws {
        let settings = makeSettings()

        let rule = BudgetRule(
            scope: .global,
            label: "Test Global",
            amountUSD: 100.0,
            period: .month,
            behavior: .warnThenBlock
        )

        await settings.upsertRule(rule, source: "test")

        // Mock data source with $81 spend (81% used)
        let mockSource = MockSpendDataSource(spend: 81.0)
        let ledger = BudgetLedger(dataSource: mockSource)
        let gate = BudgetGate(settings: settings, ledger: ledger, warningThreshold: 0.8)

        let credential = BudgetCredentialIdentity(
            providerID: "openai",
            slotID: "key_1",
            displayLabel: "OpenAI Key",
            billingMode: .perUsage
        )

        let decision = await gate.evaluate(
            credential: credential,
            estimatedCost: 1.0
        )

        if case .warn(let activeRule, let usedPercent, let used, let limit) = decision {
            XCTAssertEqual(activeRule.id, rule.id)
            XCTAssertEqual(usedPercent, 0.81, accuracy: 0.001)
            XCTAssertEqual(used, 81.0)
            XCTAssertEqual(limit, 100.0)
        } else {
            XCTFail("Expected .warn decision, got \(decision)")
        }
    }

    @MainActor
    func testGateBlocksAtOneHundredPercent() async throws {
        let settings = makeSettings()

        let rule = BudgetRule(
            scope: .global,
            label: "Test Global",
            amountUSD: 100.0,
            period: .month,
            behavior: .warnThenBlock
        )

        await settings.upsertRule(rule, source: "test")

        // Mock data source with $101 spend (101% used)
        let mockSource = MockSpendDataSource(spend: 101.0)
        let ledger = BudgetLedger(dataSource: mockSource)
        let gate = BudgetGate(settings: settings, ledger: ledger, warningThreshold: 0.8)

        let credential = BudgetCredentialIdentity(
            providerID: "openai",
            slotID: "key_1",
            displayLabel: "OpenAI Key",
            billingMode: .perUsage
        )

        let decision = await gate.evaluate(
            credential: credential,
            estimatedCost: 1.0
        )

        if case .block(let activeRule, let used, let limit, _) = decision {
            XCTAssertEqual(activeRule.id, rule.id)
            XCTAssertEqual(used, 101.0)
            XCTAssertEqual(limit, 100.0)
        } else {
            XCTFail("Expected .block decision, got \(decision)")
        }
    }

    @MainActor
    func testSubscriptionBypass() async throws {
        let settings = makeSettings()

        let rule = BudgetRule(
            scope: .global,
            label: "Test Global",
            amountUSD: 100.0,
            period: .month,
            behavior: .hardBlock
        )

        await settings.upsertRule(rule, source: "test")

        // Spend is $150 (way over limit)
        let mockSource = MockSpendDataSource(spend: 150.0)
        let ledger = BudgetLedger(dataSource: mockSource)
        let gate = BudgetGate(settings: settings, ledger: ledger, warningThreshold: 0.8)

        // Subscription key (Claude Pro OAuth key prefix `sk-ant-oat*`)
        let credential = BudgetCredentialIdentity(
            providerID: "anthropic",
            slotID: "oat_1",
            displayLabel: "Claude Pro Key",
            billingMode: .subscription
        )

        let decision = await gate.evaluate(
            credential: credential,
            estimatedCost: 1.0
        )

        if case .allow = decision {
            // Success: subscription keys bypass the budget gate
        } else {
            XCTFail("Expected .allow decision for subscription credential, got \(decision)")
        }
    }

    @MainActor
    func testPausedRuleAllows() async throws {
        let settings = makeSettings()

        let rule = BudgetRule(
            scope: .global,
            label: "Test Global",
            amountUSD: 100.0,
            period: .month,
            behavior: .hardBlock,
            pausedUntil: Date().addingTimeInterval(3600) // Paused for 1 hour
        )

        await settings.upsertRule(rule, source: "test")

        // Spend is $120 (over limit)
        let mockSource = MockSpendDataSource(spend: 120.0)
        let ledger = BudgetLedger(dataSource: mockSource)
        let gate = BudgetGate(settings: settings, ledger: ledger, warningThreshold: 0.8)

        let credential = BudgetCredentialIdentity(
            providerID: "openai",
            slotID: "key_1",
            displayLabel: "OpenAI Key",
            billingMode: .perUsage
        )

        let decision = await gate.evaluate(
            credential: credential,
            estimatedCost: 1.0
        )

        if case .paused(let activeRule, _) = decision {
            XCTAssertEqual(activeRule.id, rule.id)
        } else {
            XCTFail("Expected .paused decision, got \(decision)")
        }
    }

    @MainActor
    private func makeSettings() -> BudgetSettings {
        let suiteName = "BudgetGateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return BudgetSettings(
            store: BudgetRulesStore(forceTestingMode: true),
            legacyBudgetDefaults: defaults,
            migrateLegacyBudget: false
        )
    }
}

// MARK: - Mocks

@MainActor
final class MockSpendDataSource: BudgetSpendDataSource {
    var rollupsByWindow: [RollupWindowKey: UsageRollupDoc] = [:]

    init(spend: Double) {
        let rollup = UsageRollupDoc(
            windowKey: .thirtyDays,
            totals: RollupTotals(requests: 10, tokens: 1000, costUsd: spend),
            providerSummaries: [],
            modelSummaries: [],
            deviceSummaries: [],
            dailyPoints: [],
            computedAt: Date(),
            schemaVersion: 1
        )
        self.rollupsByWindow = [
            .thirtyDays: rollup,
            .today: rollup,
            .sevenDays: rollup,
            .allTime: rollup
        ]
    }
}
