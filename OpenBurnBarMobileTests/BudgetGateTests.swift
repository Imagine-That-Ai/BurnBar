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
    func testHardBlockWithFallbackResolvesConfiguredCredential() async throws {
        let settings = makeSettings()

        let fallbackRule = BudgetRule(
            scope: .credential,
            providerID: "anthropic",
            accountID: "cheap-slot",
            label: "Claude Haiku fallback",
            amountUSD: 100.0,
            period: .month,
            behavior: .warnThenBlock
        )
        let blockingRule = BudgetRule(
            scope: .credential,
            providerID: "openrouter",
            accountID: "key_1",
            label: "OpenRouter primary",
            amountUSD: 50.0,
            period: .month,
            behavior: .hardBlockWithFallback,
            fallbackCredentialIDs: [fallbackRule.id]
        )

        await settings.upsertRule(blockingRule, source: "test")
        await settings.upsertRule(fallbackRule, source: "test")

        let mockSource = MockSpendDataSource(
            spend: 50.0,
            accountSummaries: [
                RollupProviderAccountSummary(
                    providerID: ProviderID(rawValue: "openrouter"),
                    accountID: "key_1",
                    accountLabel: "OpenRouter primary",
                    totalRequests: 1,
                    totalTokens: 100,
                    totalCost: 50.0
                )
            ]
        )
        let ledger = BudgetLedger(dataSource: mockSource)
        let gate = BudgetGate(settings: settings, ledger: ledger, warningThreshold: 0.8)

        let credential = BudgetCredentialIdentity(
            providerID: "openrouter",
            slotID: "key_1",
            displayLabel: "OpenRouter Key",
            billingMode: .perUsage
        )

        let decision = await gate.evaluate(
            credential: credential,
            estimatedCost: 1.0
        )

        guard case .block(let activeRule, _, _, let fallback?) = decision else {
            XCTFail("Expected .block with fallback, got \(decision)")
            return
        }
        XCTAssertEqual(activeRule.id, blockingRule.id)
        XCTAssertEqual(fallback.providerID, "anthropic")
        XCTAssertEqual(fallback.slotID, "cheap-slot")
        XCTAssertEqual(fallback.displayLabel, fallbackRule.displayLabel)
        XCTAssertEqual(fallback.billingMode, .unknown)
    }

    @MainActor
    func testHardBlockWithFallbackSkipsMissingNonCredentialAndDisabledFallbacks() async throws {
        let settings = makeSettings()

        let projectRule = BudgetRule(
            scope: .project,
            projectName: "demo",
            label: "Project rule",
            amountUSD: 100.0,
            period: .month,
            behavior: .warnThenBlock
        )
        let disabledRule = BudgetRule(
            scope: .credential,
            providerID: "xai",
            accountID: "disabled-slot",
            label: "Disabled fallback",
            amountUSD: 100.0,
            period: .month,
            behavior: .warnThenBlock,
            isEnabled: false
        )
        let viableRule = BudgetRule(
            scope: .credential,
            providerID: "openai",
            accountID: "fallback-slot",
            label: "OpenAI fallback",
            amountUSD: 100.0,
            period: .month,
            behavior: .warnThenBlock
        )
        let blockingRule = BudgetRule(
            scope: .credential,
            providerID: "openrouter",
            accountID: "key_1",
            label: "OpenRouter primary",
            amountUSD: 50.0,
            period: .month,
            behavior: .hardBlockWithFallback,
            fallbackCredentialIDs: ["missing", projectRule.id, disabledRule.id, viableRule.id]
        )

        for rule in [blockingRule, projectRule, disabledRule, viableRule] {
            await settings.upsertRule(rule, source: "test")
        }

        let mockSource = MockSpendDataSource(
            spend: 50.0,
            accountSummaries: [
                RollupProviderAccountSummary(
                    providerID: ProviderID(rawValue: "openrouter"),
                    accountID: "key_1",
                    accountLabel: "OpenRouter primary",
                    totalRequests: 1,
                    totalTokens: 100,
                    totalCost: 50.0
                )
            ]
        )
        let ledger = BudgetLedger(dataSource: mockSource)
        let gate = BudgetGate(settings: settings, ledger: ledger, warningThreshold: 0.8)

        let decision = await gate.evaluate(
            credential: BudgetCredentialIdentity(
                providerID: "openrouter",
                slotID: "key_1",
                displayLabel: "OpenRouter Key",
                billingMode: .perUsage
            ),
            estimatedCost: 1.0
        )

        guard case .block(_, _, _, let fallback?) = decision else {
            XCTFail("Expected .block with viable fallback, got \(decision)")
            return
        }
        XCTAssertEqual(fallback.providerID, "openai")
        XCTAssertEqual(fallback.slotID, "fallback-slot")
    }

    @MainActor
    func testHardBlockWithFallbackSkipsFallbackWhoseOwnCapWouldBlock() async throws {
        let settings = makeSettings()

        let exhaustedRule = BudgetRule(
            scope: .credential,
            providerID: "anthropic",
            accountID: "exhausted-slot",
            label: "Claude exhausted fallback",
            amountUSD: 25.0,
            period: .month,
            behavior: .warnThenBlock
        )
        let viableRule = BudgetRule(
            scope: .credential,
            providerID: "openai",
            accountID: "fallback-slot",
            label: "OpenAI fallback",
            amountUSD: 100.0,
            period: .month,
            behavior: .warnThenBlock
        )
        let blockingRule = BudgetRule(
            scope: .credential,
            providerID: "openrouter",
            accountID: "key_1",
            label: "OpenRouter primary",
            amountUSD: 50.0,
            period: .month,
            behavior: .hardBlockWithFallback,
            fallbackCredentialIDs: [exhaustedRule.id, viableRule.id]
        )

        for rule in [blockingRule, exhaustedRule, viableRule] {
            await settings.upsertRule(rule, source: "test")
        }

        let mockSource = MockSpendDataSource(
            spend: 0,
            accountSummaries: [
                RollupProviderAccountSummary(
                    providerID: ProviderID(rawValue: "openrouter"),
                    accountID: "key_1",
                    accountLabel: "OpenRouter primary",
                    totalRequests: 1,
                    totalTokens: 100,
                    totalCost: 50.0
                ),
                RollupProviderAccountSummary(
                    providerID: ProviderID(rawValue: "anthropic"),
                    accountID: "exhausted-slot",
                    accountLabel: "Claude exhausted fallback",
                    totalRequests: 1,
                    totalTokens: 100,
                    totalCost: 25.0
                ),
                RollupProviderAccountSummary(
                    providerID: ProviderID(rawValue: "openai"),
                    accountID: "fallback-slot",
                    accountLabel: "OpenAI fallback",
                    totalRequests: 1,
                    totalTokens: 100,
                    totalCost: 2.0
                )
            ]
        )
        let ledger = BudgetLedger(dataSource: mockSource)
        let gate = BudgetGate(settings: settings, ledger: ledger, warningThreshold: 0.8)

        let decision = await gate.evaluate(
            credential: BudgetCredentialIdentity(
                providerID: "openrouter",
                slotID: "key_1",
                displayLabel: "OpenRouter Key",
                billingMode: .perUsage
            ),
            estimatedCost: 1.0
        )

        guard case .block(_, _, _, let fallback?) = decision else {
            XCTFail("Expected .block with viable fallback, got \(decision)")
            return
        }
        XCTAssertEqual(fallback.providerID, "openai")
        XCTAssertEqual(fallback.slotID, "fallback-slot")
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

    init(spend: Double, accountSummaries: [RollupProviderAccountSummary] = []) {
        let rollup = UsageRollupDoc(
            windowKey: .thirtyDays,
            totals: RollupTotals(requests: 10, tokens: 1000, costUsd: spend),
            providerSummaries: [],
            accountSummaries: accountSummaries,
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
