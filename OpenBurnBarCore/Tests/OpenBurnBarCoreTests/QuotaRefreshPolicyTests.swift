import XCTest
@testable import OpenBurnBarCore

final class QuotaRefreshPolicyTests: XCTestCase {
    func test_policyMatchesSharedFixture() throws {
        let fixture = try loadFixture()
        XCTAssertGreaterThanOrEqual(fixture.cases.count, 12)

        for testCase in fixture.cases {
            let now = try Self.parseDate(testCase.now)
            let fetchedAt = try Self.parseDate(testCase.fetchedAt)
            let resetsAt = try testCase.resetsAt.map(Self.parseDate)
            let lastProbeAt = try testCase.lastProbeAt.map(Self.parseDate)
            let tier = try XCTUnwrap(QuotaSignalTier(rawValue: testCase.tierValue), testCase.name)
            let windowKind = try XCTUnwrap(ProviderQuotaWindowKind(rawValue: testCase.windowKind), testCase.name)

            XCTAssertEqual(tier.contractName, testCase.tier, testCase.name)

            let ttl = QuotaRefreshPolicy.adaptiveTTL(
                remainingFraction: testCase.remainingFraction,
                windowKind: windowKind,
                resetsAt: resetsAt,
                now: now
            )
            XCTAssertEqual(ttl, TimeInterval(testCase.expectedTTLSeconds), accuracy: 0.001, testCase.name)

            let nextRefreshAt = QuotaRefreshPolicy.nextRefreshAfter(
                QuotaRefreshPolicySnapshot(
                    fetchedAt: fetchedAt,
                    remainingFraction: testCase.remainingFraction,
                    windowKind: windowKind,
                    resetsAt: resetsAt
                ),
                now: now
            )
            XCTAssertEqual(Self.formatDate(nextRefreshAt), testCase.expectedNextRefreshAt, testCase.name)

            let shouldSpendProbe = QuotaRefreshPolicy.shouldSpendProbe(
                lastProbeAt: lastProbeAt,
                probesToday: testCase.probesToday,
                dailyProbeBudget: testCase.dailyProbeBudget,
                now: now
            )
            XCTAssertEqual(shouldSpendProbe, testCase.expectedShouldSpendProbe, testCase.name)
        }
    }

    func test_providersDueForRefresh_skipsHighRemainingInsideAdaptiveTTL() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let high = makeSnapshot(
            provider: .codex,
            fetchedAt: now.addingTimeInterval(-20 * 60),
            remaining: 80,
            limit: 100
        )
        let due = QuotaRefreshPolicy.providersDueForRefresh(
            [.codex, .claudeCode],
            snapshots: [.codex: high],
            now: now
        )
        XCTAssertEqual(due, [.claudeCode])
        XCTAssertTrue(QuotaRefreshPolicy.isFresh(high, now: now))
    }

    func test_providersDueForRefresh_includesLowRemainingAfterThreeMinutes() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let low = makeSnapshot(
            provider: .codex,
            fetchedAt: now.addingTimeInterval(-4 * 60),
            remaining: 10,
            limit: 100
        )
        let due = QuotaRefreshPolicy.providersDueForRefresh(
            [.codex],
            snapshots: [.codex: low],
            now: now
        )
        XCTAssertEqual(due, [.codex])
        XCTAssertFalse(QuotaRefreshPolicy.isFresh(low, now: now))
    }

    func test_policySnapshot_usesMinimumRemainingFraction() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = ProviderQuotaSnapshot(
            id: "codex_default",
            provider: AgentProvider.codex.rawValue,
            providerID: AgentProvider.codex.providerID,
            sourceKind: .officialAPI,
            sourceId: "default",
            fetchedAt: now,
            source: "officialAPI",
            confidence: .high,
            buckets: [
                ProviderQuotaBucket(
                    key: "weekly",
                    label: "Weekly",
                    windowKind: .weekly,
                    usedValue: 10,
                    limitValue: 100,
                    remainingValue: 90,
                    usedPercent: 10,
                    resetsAt: nil,
                    unit: .requests,
                    isEstimated: false
                ),
                ProviderQuotaBucket(
                    key: "hourly",
                    label: "5h",
                    windowKind: .rollingHours,
                    usedValue: 80,
                    limitValue: 100,
                    remainingValue: 20,
                    usedPercent: 80,
                    resetsAt: nil,
                    unit: .requests,
                    isEstimated: false
                )
            ],
            updatedAt: now
        )
        let policy = QuotaRefreshPolicy.policySnapshot(from: snapshot)
        XCTAssertEqual(policy.remainingFraction ?? -1, 0.2, accuracy: 0.0001)
        XCTAssertEqual(policy.windowKind, .weekly)
    }

    private func makeSnapshot(
        provider: AgentProvider,
        fetchedAt: Date,
        remaining: Double,
        limit: Double
    ) -> ProviderQuotaSnapshot {
        ProviderQuotaSnapshot(
            id: "\(provider.rawValue)_default",
            provider: provider.rawValue,
            providerID: provider.providerID,
            sourceKind: .officialAPI,
            sourceId: "default",
            fetchedAt: fetchedAt,
            source: "officialAPI",
            confidence: .high,
            buckets: [
                ProviderQuotaBucket(
                    key: "monthly",
                    label: "Monthly",
                    windowKind: .monthly,
                    usedValue: limit - remaining,
                    limitValue: limit,
                    remainingValue: remaining,
                    usedPercent: ((limit - remaining) / limit) * 100,
                    resetsAt: nil,
                    unit: .requests,
                    isEstimated: false
                )
            ],
            updatedAt: fetchedAt
        )
    }

    private func loadFixture() throws -> FixtureFile {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "quota-refresh-policy-fixtures", withExtension: "json")
        )
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(FixtureFile.self, from: data)
    }

    private static func parseDate(_ value: String) throws -> Date {
        if let parsed = fractionalFormatter.date(from: value) ?? plainFormatter.date(from: value) {
            return parsed
        }
        throw NSError(
            domain: "QuotaRefreshPolicyTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Invalid fixture date: \(value)"]
        )
    }

    private static func formatDate(_ value: Date) -> String {
        fractionalFormatter.string(from: value)
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

private struct FixtureFile: Decodable {
    let cases: [FixtureCase]
}

private struct FixtureCase: Decodable {
    let name: String
    let tier: String
    let tierValue: Int
    let now: String
    let fetchedAt: String
    let remainingFraction: Double?
    let windowKind: String
    let resetsAt: String?
    let expectedTTLSeconds: Int
    let expectedNextRefreshAt: String
    let lastProbeAt: String?
    let probesToday: Int
    let dailyProbeBudget: Int
    let expectedShouldSpendProbe: Bool
}
