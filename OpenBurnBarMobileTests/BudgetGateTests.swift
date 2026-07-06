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
    func testGateFailsClosedWhenSpendSnapshotUnreadable() async throws {
        let settings = makeSettings()

        let rule = BudgetRule(
            scope: .global,
            label: "Unreadable global cap",
            amountUSD: 100.0,
            period: .month,
            behavior: .hardBlock
        )
        await settings.upsertRule(rule, source: "test")

        let mockSource = MockSpendDataSource(spend: 0, isReadable: false)
        let ledger = BudgetLedger(dataSource: mockSource)
        let gate = BudgetGate(settings: settings, ledger: ledger, warningThreshold: 0.8)

        let decision = await gate.evaluate(
            credential: BudgetCredentialIdentity(
                providerID: "openai",
                slotID: "key_1",
                displayLabel: "OpenAI Key",
                billingMode: .perUsage
            ),
            estimatedCost: 1.0
        )

        guard case .block(let activeRule, let used, let limit, let fallback) = decision else {
            XCTFail("Expected unreadable spend to fail closed with .block, got \(decision)")
            return
        }
        XCTAssertEqual(activeRule.id, rule.id)
        XCTAssertEqual(used, rule.amountUSD)
        XCTAssertEqual(limit, rule.amountUSD)
        XCTAssertNil(fallback)
    }

    @MainActor
    func testGateAllowsReadableEmptySnapshotAsZeroSpend() async throws {
        let settings = makeSettings()

        let rule = BudgetRule(
            scope: .global,
            label: "Readable empty global cap",
            amountUSD: 100.0,
            period: .month,
            behavior: .hardBlock
        )
        await settings.upsertRule(rule, source: "test")

        let mockSource = MockSpendDataSource(rollupsByWindow: [:], isReadable: true)
        let ledger = BudgetLedger(dataSource: mockSource)
        let gate = BudgetGate(settings: settings, ledger: ledger, warningThreshold: 0.8)

        let decision = await gate.evaluate(
            credential: BudgetCredentialIdentity(
                providerID: "openai",
                slotID: "key_1",
                displayLabel: "OpenAI Key",
                billingMode: .perUsage
            ),
            estimatedCost: 1.0
        )

        if case .allow = decision {
            // Success: readable empty rollups are a legitimate zero-spend snapshot.
        } else {
            XCTFail("Expected readable empty spend snapshot to allow under-limit request, got \(decision)")
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
    func testHardBlockWithFallbackSkipsFallbackBlockedByAnotherMatchingRule() async throws {
        let settings = makeSettings()

        let fallbackRule = BudgetRule(
            scope: .credential,
            providerID: "anthropic",
            accountID: "shared-slot",
            label: "Claude fallback",
            amountUSD: 100.0,
            period: .month,
            behavior: .warnThenBlock
        )
        let siblingBlocker = BudgetRule(
            scope: .credential,
            providerID: "anthropic",
            accountID: "shared-slot",
            label: "Claude sibling cap",
            amountUSD: 5.0,
            period: .month,
            behavior: .hardBlock
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
            fallbackCredentialIDs: [fallbackRule.id, viableRule.id]
        )

        for rule in [blockingRule, fallbackRule, siblingBlocker, viableRule] {
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
                    accountID: "shared-slot",
                    accountLabel: "Claude fallback",
                    totalRequests: 1,
                    totalTokens: 100,
                    totalCost: 5.0
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
    func testHardBlockWithFallbackReturnsNilWhenGlobalRuleBlocksFallback() async throws {
        let settings = makeSettings()

        let fallbackRule = BudgetRule(
            scope: .credential,
            providerID: "anthropic",
            accountID: "cheap-slot",
            label: "Claude fallback",
            amountUSD: 100.0,
            period: .month,
            behavior: .warnThenBlock
        )
        let globalBlocker = BudgetRule(
            scope: .global,
            label: "Global cap",
            amountUSD: 5.0,
            period: .month,
            behavior: .hardBlock
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

        for rule in [blockingRule, fallbackRule, globalBlocker] {
            await settings.upsertRule(rule, source: "test")
        }

        let mockSource = MockSpendDataSource(
            spend: 5.0,
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
                    accountID: "cheap-slot",
                    accountLabel: "Claude fallback",
                    totalRequests: 1,
                    totalTokens: 100,
                    totalCost: 1.0
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

        guard case .block(_, _, _, let fallback) = decision else {
            XCTFail("Expected .block without fallback, got \(decision)")
            return
        }
        XCTAssertNil(fallback)
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
    func testOrganizationLedgerAggregatesOnlyMatchingAccountSessionSpend() async throws {
        let source = MockSpendDataSource(
            spend: 100,
            accountSummaries: [
                accountSummary(providerID: "openai", accountID: "acct-a", accountLabel: "Acme Org", totalCost: 10),
                accountSummary(providerID: "anthropic", accountID: "acct-b", accountLabel: "Acme Org", totalCost: 7),
                accountSummary(providerID: "openai", accountID: "acct-other", accountLabel: "Other Org", totalCost: 83)
            ]
        )
        let ledger = BudgetLedger(dataSource: source)
        await ledger.recordSessionCost(providerID: "openai", accountID: "acct-a", cost: 2)
        await ledger.recordSessionCost(providerID: "anthropic", accountID: "acct-b", cost: 3)
        await ledger.recordSessionCost(providerID: "factory", accountID: "fresh-acct", accountLabel: "Acme Org", cost: 4)
        await ledger.recordSessionCost(providerID: "openai", accountID: "acct-other", accountLabel: "Other Org", cost: 50)

        let rule = BudgetRule(
            scope: .organization,
            identifier: "Acme Org",
            label: "Acme Org",
            amountUSD: 100,
            period: .month,
            behavior: .hardBlock
        )

        let spend = try await ledger.currentSpend(forRule: rule)

        XCTAssertEqual(spend, 26, accuracy: 0.0001)
    }

    @MainActor
    func testOrganizationLedgerDoesNotFallbackToFullSessionSpendWhenNoAccountsMatch() async throws {
        let source = MockSpendDataSource(
            spend: 100,
            accountSummaries: [
                accountSummary(providerID: "openai", accountID: "acct-other", accountLabel: "Other Org", totalCost: 10)
            ]
        )
        let ledger = BudgetLedger(dataSource: source)
        await ledger.recordSessionCost(providerID: "openai", accountID: "acct-other", accountLabel: "Other Org", cost: 90)

        let rule = BudgetRule(
            scope: .organization,
            identifier: "Acme Org",
            label: "Acme Org",
            amountUSD: 100,
            period: .month,
            behavior: .hardBlock
        )

        let spend = try await ledger.currentSpend(forRule: rule)

        XCTAssertEqual(spend, 0, accuracy: 0.0001)
    }

    @MainActor
    func testGateBlocksMatchingOrganizationRule() async throws {
        let settings = makeSettings()
        let rule = BudgetRule(
            scope: .organization,
            identifier: "Acme Org",
            label: "Acme Org",
            amountUSD: 20,
            period: .month,
            behavior: .hardBlock
        )
        await settings.upsertRule(rule, source: "test")

        let source = MockSpendDataSource(
            spend: 100,
            accountSummaries: [
                accountSummary(providerID: "openai", accountID: "acct-a", accountLabel: "Acme Org", totalCost: 19),
                accountSummary(providerID: "openai", accountID: "acct-b", accountLabel: "Other Org", totalCost: 81)
            ]
        )
        let ledger = BudgetLedger(dataSource: source)
        let gate = BudgetGate(settings: settings, ledger: ledger, warningThreshold: 0.8)

        let decision = await gate.evaluate(
            credential: BudgetCredentialIdentity(
                providerID: "openai",
                slotID: "acct-a",
                displayLabel: "Acme Org",
                billingMode: .perUsage
            ),
            estimatedCost: 2
        )

        if case .block(let activeRule, let used, let limit, _) = decision {
            XCTAssertEqual(activeRule.id, rule.id)
            XCTAssertEqual(used, 19, accuracy: 0.0001)
            XCTAssertEqual(limit, 20, accuracy: 0.0001)
        } else {
            XCTFail("Expected .block decision for matching organization rule, got \(decision)")
        }
    }

    @MainActor
    func testGateBlocksAccountLabelOrganizationRuleWhenRelayLabelIsRuntime() async throws {
        let settings = makeSettings()
        let rule = BudgetRule(
            scope: .organization,
            identifier: "Acme Org",
            label: "Acme Org",
            amountUSD: 20,
            period: .month,
            behavior: .hardBlock
        )
        await settings.upsertRule(rule, source: "test")

        let source = MockSpendDataSource(
            spend: 100,
            accountSummaries: [
                accountSummary(providerID: "openai", accountID: "acct-a", accountLabel: "Acme Org", totalCost: 19),
                accountSummary(providerID: "openai", accountID: "acct-b", accountLabel: "Other Org", totalCost: 81)
            ]
        )
        let ledger = BudgetLedger(dataSource: source)
        let gate = BudgetGate(settings: settings, ledger: ledger, warningThreshold: 0.8)

        let decision = await gate.evaluate(
            credential: BudgetCredentialIdentity(
                providerID: "codex",
                slotID: "default",
                displayLabel: "codex",
                billingMode: .perUsage
            ),
            estimatedCost: 2
        )

        if case .block(let activeRule, let used, let limit, _) = decision {
            XCTAssertEqual(activeRule.id, rule.id)
            XCTAssertEqual(used, 19, accuracy: 0.0001)
            XCTAssertEqual(limit, 20, accuracy: 0.0001)
        } else {
            XCTFail("Expected account-label organization rule to block with runtime display label, got \(decision)")
        }
    }

    // MARK: - Wave 4 item 2: org-scope membership discovery across rollup windows

    @MainActor
    func testOrganizationLedgerCountsMemberAccountRenamedInWindow() async throws {
        // In the rule's 30-day window the account summary carries a renamed label, so a
        // direct label/ID match misses its spend. The `today` window still carries the org
        // label for the same accountID — membership discovery (the rollup equivalent of the
        // macOS ledger's providerAccountID subquery) must attribute the 30-day spend.
        let source = MockSpendDataSource(rollupsByWindow: [
            .thirtyDays: rollupDoc(
                windowKey: .thirtyDays,
                costUsd: 60,
                accountSummaries: [
                    accountSummary(providerID: "openai", accountID: "acct-x", accountLabel: "Personal", totalCost: 60)
                ]
            ),
            .today: rollupDoc(
                windowKey: .today,
                costUsd: 5,
                accountSummaries: [
                    accountSummary(providerID: "openai", accountID: "acct-x", accountLabel: "Acme Org", totalCost: 5)
                ]
            )
        ])
        let ledger = BudgetLedger(dataSource: source)

        let rule = BudgetRule(
            scope: .organization,
            identifier: "Acme Org",
            label: "Acme Org",
            amountUSD: 50,
            period: .month,
            behavior: .hardBlock
        )

        let spend = try await ledger.currentSpend(forRule: rule)

        XCTAssertEqual(spend, 60, accuracy: 0.0001)
    }

    @MainActor
    func testGateBlocksOrganizationRuleForRenamedMemberAccount() async throws {
        let settings = makeSettings()
        let rule = BudgetRule(
            scope: .organization,
            identifier: "Acme Org",
            label: "Acme Org",
            amountUSD: 50,
            period: .month,
            behavior: .hardBlock
        )
        await settings.upsertRule(rule, source: "test")

        let source = MockSpendDataSource(rollupsByWindow: [
            .thirtyDays: rollupDoc(
                windowKey: .thirtyDays,
                costUsd: 60,
                accountSummaries: [
                    accountSummary(providerID: "openai", accountID: "acct-x", accountLabel: "Personal", totalCost: 60)
                ]
            ),
            .today: rollupDoc(
                windowKey: .today,
                costUsd: 5,
                accountSummaries: [
                    accountSummary(providerID: "openai", accountID: "acct-x", accountLabel: "Acme Org", totalCost: 5)
                ]
            )
        ])
        let ledger = BudgetLedger(dataSource: source)
        let gate = BudgetGate(settings: settings, ledger: ledger, warningThreshold: 0.8)

        let decision = await gate.evaluate(
            credential: BudgetCredentialIdentity(
                providerID: "openai",
                slotID: "acct-x",
                displayLabel: "Acme Org",
                billingMode: .perUsage
            ),
            estimatedCost: 1
        )

        guard case .block(let activeRule, let used, let limit, _) = decision else {
            XCTFail("Expected org rule to count renamed member account's spend and block, got \(decision)")
            return
        }
        XCTAssertEqual(activeRule.id, rule.id)
        XCTAssertEqual(used, 60, accuracy: 0.0001)
        XCTAssertEqual(limit, 50, accuracy: 0.0001)
    }

    // MARK: - Wave 4 item 3: project scope fails closed on iOS

    @MainActor
    func testProjectScopeCurrentSpendThrowsUnsupported() async throws {
        let source = MockSpendDataSource(spend: 0)
        let ledger = BudgetLedger(dataSource: source)
        let rule = BudgetRule(
            scope: .project,
            projectName: "acme-app",
            label: "Acme project cap",
            amountUSD: 10,
            period: .month,
            behavior: .hardBlock
        )

        do {
            let spend = try await ledger.currentSpend(forRule: rule)
            XCTFail("Expected project-scope spend read to throw (no per-project rollups on iOS), got \(spend)")
        } catch let error as BudgetLedgerReadError {
            XCTAssertEqual(error, .projectScopeUnsupported)
        }
    }

    @MainActor
    func testGateFailsClosedForProjectRuleOnIOS() async throws {
        let settings = makeSettings()
        let rule = BudgetRule(
            scope: .project,
            projectName: "acme-app",
            label: "Acme project cap",
            amountUSD: 10,
            period: .month,
            behavior: .hardBlock
        )
        await settings.upsertRule(rule, source: "test")

        // Snapshot is readable and rollups exist — but rollups carry no per-project
        // breakdown, so project spend is unknowable on iOS. The gate must fail closed
        // (block) rather than treat unknowable spend as $0 and silently enforce nothing.
        let source = MockSpendDataSource(spend: 0)
        let ledger = BudgetLedger(dataSource: source)
        let gate = BudgetGate(settings: settings, ledger: ledger, warningThreshold: 0.8)

        let decision = await gate.evaluate(
            credential: BudgetCredentialIdentity(
                providerID: "openai",
                slotID: "key_1",
                displayLabel: "OpenAI Key",
                billingMode: .perUsage
            ),
            projectName: "acme-app",
            estimatedCost: 1
        )

        guard case .block(let activeRule, let used, let limit, _) = decision else {
            XCTFail("Project-scope rule must fail closed on iOS (spend unknowable), got \(decision)")
            return
        }
        XCTAssertEqual(activeRule.id, rule.id)
        XCTAssertEqual(used, 10, accuracy: 0.0001)
        XCTAssertEqual(limit, 10, accuracy: 0.0001)
    }

    @MainActor
    func testGateWarnOnlyProjectRuleSurfacesWarningOnIOS() async throws {
        let settings = makeSettings()
        let rule = BudgetRule(
            scope: .project,
            projectName: "acme-app",
            label: "Acme project advisory",
            amountUSD: 10,
            period: .month,
            behavior: .warnOnly
        )
        await settings.upsertRule(rule, source: "test")

        let source = MockSpendDataSource(spend: 0)
        let ledger = BudgetLedger(dataSource: source)
        let gate = BudgetGate(settings: settings, ledger: ledger, warningThreshold: 0.8)

        let decision = await gate.evaluate(
            credential: BudgetCredentialIdentity(
                providerID: "openai",
                slotID: "key_1",
                displayLabel: "OpenAI Key",
                billingMode: .perUsage
            ),
            projectName: "acme-app",
            estimatedCost: 1
        )

        guard case .warn(let activeRule, let usedPercent, _, _) = decision else {
            XCTFail("Warn-only project rule must surface the unknown state as .warn on iOS, got \(decision)")
            return
        }
        XCTAssertEqual(activeRule.id, rule.id)
        XCTAssertEqual(usedPercent, 1.0, accuracy: 0.0001)
    }

    // MARK: - Wave 4 item 5: fallback self-exclusion accountID normalization

    @MainActor
    func testFallbackWithExplicitAccountResolvesWhenBlockingRuleHasNilAccount() async throws {
        let settings = makeSettings()

        let fallbackRule = BudgetRule(
            scope: .credential,
            providerID: "openrouter",
            accountID: "backup-slot",
            label: "OpenRouter backup",
            amountUSD: 100.0,
            period: .month,
            behavior: .warnThenBlock
        )
        // Blocking rule has an empty accountID (the default slot — synced rules can carry
        // "" where the editor stores nil). It must normalize to "default" on BOTH sides of
        // the self-exclusion comparison so a candidate with an explicit, different account
        // is still eligible as a fallback.
        let blockingRule = BudgetRule(
            scope: .credential,
            providerID: "openrouter",
            accountID: "",
            label: "OpenRouter default",
            amountUSD: 50.0,
            period: .month,
            behavior: .hardBlockWithFallback,
            fallbackCredentialIDs: [fallbackRule.id]
        )

        await settings.upsertRule(blockingRule, source: "test")
        await settings.upsertRule(fallbackRule, source: "test")

        let source = MockSpendDataSource(
            spend: 50.0,
            accountSummaries: [
                accountSummary(providerID: "openrouter", accountID: "primary-key", accountLabel: "OpenRouter primary", totalCost: 50.0)
            ]
        )
        let ledger = BudgetLedger(dataSource: source)
        let gate = BudgetGate(settings: settings, ledger: ledger, warningThreshold: 0.8)

        let decision = await gate.evaluate(
            credential: BudgetCredentialIdentity(
                providerID: "openrouter",
                slotID: "",
                displayLabel: "OpenRouter",
                billingMode: .perUsage
            ),
            estimatedCost: 1.0
        )

        guard case .block(let activeRule, _, _, let fallback?) = decision else {
            XCTFail("Expected .block with an explicit-account fallback candidate, got \(decision)")
            return
        }
        XCTAssertEqual(activeRule.id, blockingRule.id)
        XCTAssertEqual(fallback.providerID, "openrouter")
        XCTAssertEqual(fallback.slotID, "backup-slot")
    }

    @MainActor
    func testFallbackSelfExcludedWhenBothRulesDefaultAccount() async throws {
        let settings = makeSettings()

        // Candidate points at the same provider with a whitespace-only accountID; the
        // blocking rule carries "". After trim+default normalization both sides are the
        // "default" slot, i.e. the same credential that is blocked. The gate must never
        // offer the blocked credential as its own fallback.
        let candidateRule = BudgetRule(
            scope: .credential,
            providerID: "openrouter",
            accountID: "  ",
            label: "OpenRouter default duplicate",
            amountUSD: 100.0,
            period: .month,
            behavior: .warnThenBlock
        )
        let blockingRule = BudgetRule(
            scope: .credential,
            providerID: "openrouter",
            accountID: "",
            label: "OpenRouter default",
            amountUSD: 50.0,
            period: .month,
            behavior: .hardBlockWithFallback,
            fallbackCredentialIDs: [candidateRule.id]
        )

        await settings.upsertRule(blockingRule, source: "test")
        await settings.upsertRule(candidateRule, source: "test")

        let source = MockSpendDataSource(
            spend: 50.0,
            accountSummaries: [
                accountSummary(providerID: "openrouter", accountID: "primary-key", accountLabel: "OpenRouter primary", totalCost: 50.0)
            ]
        )
        let ledger = BudgetLedger(dataSource: source)
        let gate = BudgetGate(settings: settings, ledger: ledger, warningThreshold: 0.8)

        let decision = await gate.evaluate(
            credential: BudgetCredentialIdentity(
                providerID: "openrouter",
                slotID: "",
                displayLabel: "OpenRouter",
                billingMode: .perUsage
            ),
            estimatedCost: 1.0
        )

        guard case .block(let activeRule, _, _, let fallback) = decision else {
            XCTFail("Expected .block, got \(decision)")
            return
        }
        XCTAssertEqual(activeRule.id, blockingRule.id)
        XCTAssertNil(fallback, "A default-slot candidate must be excluded as its own fallback")
    }

    private func rollupDoc(
        windowKey: RollupWindowKey,
        costUsd: Double,
        accountSummaries: [RollupProviderAccountSummary]
    ) -> UsageRollupDoc {
        UsageRollupDoc(
            windowKey: windowKey,
            totals: RollupTotals(requests: 1, tokens: 100, costUsd: costUsd),
            providerSummaries: [],
            accountSummaries: accountSummaries,
            modelSummaries: [],
            deviceSummaries: [],
            dailyPoints: [],
            computedAt: Date(),
            schemaVersion: 1
        )
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

    private func accountSummary(
        providerID: String,
        accountID: String,
        accountLabel: String,
        totalCost: Double
    ) -> RollupProviderAccountSummary {
        RollupProviderAccountSummary(
            providerID: ProviderID(rawValue: providerID),
            accountID: accountID,
            accountLabel: accountLabel,
            totalRequests: 1,
            totalTokens: 100,
            totalCost: totalCost
        )
    }
}

// MARK: - Mocks

@MainActor
final class MockSpendDataSource: BudgetSpendDataSource {
    var rollupsByWindow: [RollupWindowKey: UsageRollupDoc] = [:]
    var budgetSpendSnapshotIsReadable: Bool

    init(spend: Double, accountSummaries: [RollupProviderAccountSummary] = [], isReadable: Bool = true) {
        self.budgetSpendSnapshotIsReadable = isReadable
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

    init(rollupsByWindow: [RollupWindowKey: UsageRollupDoc], isReadable: Bool = true) {
        self.rollupsByWindow = rollupsByWindow
        self.budgetSpendSnapshotIsReadable = isReadable
    }
}
