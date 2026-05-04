import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarMobile

final class OpenBurnBarMobileTests: XCTestCase {

    // MARK: - Shared Model Compatibility

    func testAgentProviderRoundTrip() {
        let provider = AgentProvider.minimax
        XCTAssertEqual(provider.displayName, "MiniMax")
        XCTAssertEqual(provider.persistedToken, "minimax")
        XCTAssertEqual(AgentProvider.fromPersistedToken("minimax"), .minimax)
        XCTAssertNil(AgentProvider.fromPersistedToken("unknown"))
    }

    func testTokenUsageCodable() throws {
        let usage = TokenUsage(
            provider: .claudeCode,
            sessionId: "sess-1",
            projectName: "Test",
            model: "claude-3",
            inputTokens: 100,
            outputTokens: 50,
            costUSD: 0.01,
            startTime: Date(),
            endTime: Date()
        )
        let data = try JSONEncoder().encode(usage)
        let decoded = try JSONDecoder().decode(TokenUsage.self, from: data)
        XCTAssertEqual(decoded.provider, usage.provider)
        XCTAssertEqual(decoded.totalTokens, 150)
        XCTAssertEqual(decoded.cost, 0.01)
    }

    func testProviderQuotaBucketProgress() {
        let bucket = ProviderQuotaBucket(
            name: "Tokens",
            used: 75,
            limit: 100,
            remaining: 25,
            window: "monthly"
        )
        XCTAssertEqual(bucket.used / bucket.limit, 0.75, accuracy: 0.001)
        XCTAssertEqual((bucket.remaining / bucket.limit) * 100, 25, accuracy: 0.001)
    }

    func testUsageRollupDocCodable() throws {
        let doc = UsageRollupDoc(
            windowKey: .today,
            totals: RollupTotals(requests: 10, tokens: 1000, costUsd: 0.50),
            providerSummaries: [
                RollupProviderSummary(provider: "minimax", totalRequests: 5, totalTokens: 500)
            ],
            modelSummaries: [],
            deviceSummaries: [],
            dailyPoints: [RollupDailyPoint(date: Date(), value: 1000)],
            computedAt: Date(),
            schemaVersion: 1
        )
        let data = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(UsageRollupDoc.self, from: data)
        XCTAssertEqual(decoded.windowKey, .today)
        XCTAssertEqual(decoded.totals.tokens, 1000)
    }

    // MARK: - Formatting

    func testCostFormatting() {
        XCTAssertEqual(1.5.formatAsCost(), "$1.50")
        XCTAssertEqual(0.0.formatAsCost(), "$0.00")
        XCTAssertEqual(1234.5.formatAsCost(), "$1,234.50")
        XCTAssertEqual(1_500_000.0.formatAsCost(), "$1,500,000.00")
    }

    func testCostCompactFormatting() {
        XCTAssertEqual(1.5.formatAsCostCompact(), "$1.50")
        XCTAssertEqual(1234.5.formatAsCostCompact(), "$1,234.50")
    }

    func testTokenFormatting() {
        XCTAssertEqual(1500.formatAsTokens(), "1.5K")
        XCTAssertEqual(1_500_000.formatAsTokens(), "1.5M")
        XCTAssertEqual(500.formatAsTokens(), "500")
        XCTAssertEqual(1234.formatAsTokens(), "1.2K")
    }

    func testTokenRawFormatting() {
        XCTAssertEqual(500.formatAsTokensRaw(), "500")
        XCTAssertEqual(1234.formatAsTokensRaw(), "1,234")
        XCTAssertEqual(1_500_000.formatAsTokensRaw(), "1,500,000")
    }

    // MARK: - Provider Connection Types

    func testProviderConnectionStatusRawValue() {
        XCTAssertEqual(ProviderConnectionStatus.connected.rawValue, "connected")
        XCTAssertEqual(ProviderConnectionStatus.error.rawValue, "error")
    }

    // MARK: - Self-hosted Runner URL Validation

    func testValidatedRunnerURLAcceptsHTTPS() {
        XCTAssertNotNil(SelfHostedQuotaRunnerStore.validatedRunnerURL("https://runner.example.com"))
        XCTAssertNotNil(SelfHostedQuotaRunnerStore.validatedRunnerURL("  https://runner.example.com/path  "))
    }

    func testValidatedRunnerURLAcceptsLocalhost() {
        XCTAssertNotNil(SelfHostedQuotaRunnerStore.validatedRunnerURL("http://localhost:8080"))
        XCTAssertNotNil(SelfHostedQuotaRunnerStore.validatedRunnerURL("http://127.0.0.1:3000"))
    }

    func testValidatedRunnerURLRejectsInvalidSchemes() {
        XCTAssertNil(SelfHostedQuotaRunnerStore.validatedRunnerURL("ftp://runner.example.com"))
        XCTAssertNil(SelfHostedQuotaRunnerStore.validatedRunnerURL("http://192.168.1.1"))
        XCTAssertNil(SelfHostedQuotaRunnerStore.validatedRunnerURL(""))
        XCTAssertNil(SelfHostedQuotaRunnerStore.validatedRunnerURL("not-a-url"))
    }

    // MARK: - Mobile Refresh Policy

    func testCanRefreshFromMobileForCloudAccounts() {
        let account = ProviderAccountDoc(
            id: "test-cloud",
            providerID: .openAI,
            label: "Test",
            status: .connected,
            credentialKind: .bearer,
            storageScope: .cloudRefreshable,
            redactedLabel: "t***",
            schemaVersion: 2,
            createdAt: Date(),
            updatedAt: Date()
        )
        XCTAssertTrue(ProviderAccountStorageVisual.canRefreshFromMobile(account: account))
    }

    func testCanRefreshFromMobileForLocalOnlySelfHosted() {
        let claudeAccount = ProviderAccountDoc(
            id: "test-claude",
            providerID: .claudeCode,
            label: "Test",
            status: .connected,
            credentialKind: .bearer,
            storageScope: .localOnly,
            redactedLabel: "t***",
            schemaVersion: 2,
            createdAt: Date(),
            updatedAt: Date()
        )
        XCTAssertTrue(ProviderAccountStorageVisual.canRefreshFromMobile(account: claudeAccount))

        let codexAccount = ProviderAccountDoc(
            id: "test-codex",
            providerID: .codex,
            label: "Test",
            status: .connected,
            credentialKind: .session,
            storageScope: .localOnly,
            redactedLabel: "t***",
            schemaVersion: 2,
            createdAt: Date(),
            updatedAt: Date()
        )
        XCTAssertTrue(ProviderAccountStorageVisual.canRefreshFromMobile(account: codexAccount))
    }

    func testCanRefreshFromMobileForLocalOnlyOtherProviders() {
        let openAIAccount = ProviderAccountDoc(
            id: "test-local",
            providerID: .openAI,
            label: "Test",
            status: .connected,
            credentialKind: .bearer,
            storageScope: .localOnly,
            redactedLabel: "t***",
            schemaVersion: 2,
            createdAt: Date(),
            updatedAt: Date()
        )
        XCTAssertFalse(ProviderAccountStorageVisual.canRefreshFromMobile(account: openAIAccount))
    }
}
