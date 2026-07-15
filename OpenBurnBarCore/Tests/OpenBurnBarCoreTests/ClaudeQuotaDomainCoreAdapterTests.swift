import Foundation
@testable import OpenBurnBarCore
// Merge (train ← origin/main): P-13 moved the ProviderQuota adapters (incl. main's
// #1590 `ClaudeQuotaDomainCoreAdapter` / `DomainCoreQuotaMigrationMode`, both
// `internal`) into `OpenBurnBarQuota`. `@testable import OpenBurnBarCore` only
// re-exports Quota's *public* API through the umbrella shim, so this test reaches
// the internal adapter via `@testable import OpenBurnBarQuota` — identical to the
// train's `ZAIQuotaAdapterTests` AE-TESTABLE pattern (CoreTests already deps Quota).
@testable import OpenBurnBarQuota
import XCTest

final class ClaudeQuotaDomainCoreAdapterTests: XCTestCase {
    func testLegacyClaudeStatuslineMatchesCanonicalContract() throws {
        let input = try Data(contentsOf: fixtureURL("claude-statusline-input.json"))
        let expected = try JSONDecoder().decode(
            ExpectedSnapshot.self,
            from: Data(contentsOf: fixtureURL("claude-statusline-expected.json"))
        )

        let rateLimits = ClaudeRateLimits(from: input)
        let buckets = ClaudeQuotaDomainCoreAdapter.buckets(
            from: rateLimits,
            environment: ["OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE": "legacy"],
            quotaLogger: NoOpQuotaLogger()
        )

        assertBuckets(buckets, match: expected.buckets)
    }

    func testShadowModeNeverChangesReturnedBuckets() throws {
        let input = try Data(contentsOf: fixtureURL("claude-statusline-input.json"))
        let rateLimits = ClaudeRateLimits(from: input)
        let legacy = ClaudeQuotaDomainCoreAdapter.buckets(
            from: rateLimits,
            environment: ["OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE": "legacy"],
            quotaLogger: NoOpQuotaLogger()
        )
        let logger = RecordingQuotaLogger()
        let shadow = ClaudeQuotaDomainCoreAdapter.buckets(
            from: rateLimits,
            environment: ["OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE": "shadow"],
            quotaLogger: logger
        )

        XCTAssertEqual(shadow, legacy)
        if ClaudeQuotaDomainCoreAdapter.isNativeAvailable {
            XCTAssertEqual(logger.messages, [])
            XCTAssertEqual(logger.comparisons.count, 1)
            XCTAssertEqual(logger.comparisons.first?.operation, "claude_quota")
            XCTAssertEqual(logger.comparisons.first?.outcome, .match)
        } else {
            XCTAssertEqual(logger.messages.count, 1)
            XCTAssertTrue(logger.messages[0].contains("native_unavailable"))
            XCTAssertEqual(logger.comparisons.count, 1)
            XCTAssertEqual(logger.comparisons.first?.operation, "claude_quota")
            XCTAssertEqual(logger.comparisons.first?.outcome, .mismatch)
            XCTAssertEqual(logger.comparisons.first?.mismatchCategory, .nativeUnavailable)
            XCTAssertEqual(logger.comparisons.first?.coreVersion, "0.0.0-unavailable")
        }
    }

    func testRustModeMatchesCanonicalContractWhenNativeCoreIsLinked() throws {
        try XCTSkipUnless(ClaudeQuotaDomainCoreAdapter.isNativeAvailable)
        let input = try Data(contentsOf: fixtureURL("claude-statusline-input.json"))
        let expected = try JSONDecoder().decode(
            ExpectedSnapshot.self,
            from: Data(contentsOf: fixtureURL("claude-statusline-expected.json"))
        )

        let buckets = ClaudeQuotaDomainCoreAdapter.buckets(
            from: ClaudeRateLimits(from: input),
            environment: ["OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE": "rust"],
            quotaLogger: NoOpQuotaLogger()
        )

        assertBuckets(buckets, match: expected.buckets)
    }

    func testUnknownMigrationModeFailsClosedToLegacy() {
        XCTAssertEqual(
            DomainCoreQuotaMigrationMode.resolve(
                environment: ["OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE": "surprise"]
            ),
            .legacy
        )
    }

    func testShadowRustFailureReturnsLegacyAndEmitsOneCategorizedReceipt() throws {
        enum SyntheticError: Error { case failed }
        let input = try Data(contentsOf: fixtureURL("claude-statusline-input.json"))
        let rateLimits = ClaudeRateLimits(from: input)
        let expected = ClaudeQuotaLegacy.buckets(from: rateLimits)
        let logger = RecordingQuotaLogger()
        var order: [String] = []

        let actual = ClaudeQuotaDomainCoreAdapter.buckets(
            from: rateLimits,
            environment: ["OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE": "shadow"],
            quotaLogger: logger,
            shadowLegacyProbe: {
                order.append("legacy")
                return expected
            },
            shadowRustProbe: {
                order.append("rust")
                throw SyntheticError.failed
            }
        )

        XCTAssertEqual(actual, expected)
        XCTAssertEqual(order, ["legacy", "rust"])
        XCTAssertEqual(logger.comparisons.count, 1)
        XCTAssertEqual(logger.comparisons.first?.outcome, .mismatch)
        XCTAssertEqual(logger.comparisons.first?.mismatchCategory, .nativeError)
    }

    func testSharedShadowCategoryClassifiesEveryFailureMode() {
        enum SyntheticError: Error { case failed }
        XCTAssertNil(DomainCoreQuotaShadowCategory.classify(.success((1, false)), equivalent: { $0 == 1 }))
        XCTAssertEqual(
            DomainCoreQuotaShadowCategory.classify(.success((1, false)), equivalent: { $0 == 2 }),
            .resultMismatch
        )
        XCTAssertEqual(
            DomainCoreQuotaShadowCategory.classify(.success((1, true)), equivalent: { _ in true }),
            .invalidResult
        )
        XCTAssertEqual(
            DomainCoreQuotaShadowCategory.classify(.failure(DomainCoreQuotaShadowProbeError.nativeUnavailable), equivalent: { (_: Int) in true }),
            .nativeUnavailable
        )
        XCTAssertEqual(
            DomainCoreQuotaShadowCategory.classify(.failure(SyntheticError.failed), equivalent: { (_: Int) in true }),
            .nativeError
        )
    }

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../tests/fixtures/domain-core/quota/v1/\(name)")
            .standardizedFileURL
    }

    private func assertBuckets(
        _ actual: [ProviderQuotaBucket],
        match expected: [ExpectedBucket],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (actualBucket, expectedBucket) in zip(actual, expected) {
            XCTAssertEqual(actualBucket.key, expectedBucket.key, file: file, line: line)
            XCTAssertEqual(actualBucket.label, expectedBucket.label, file: file, line: line)
            XCTAssertEqual(
                actualBucket.windowKind.rawValue.lowercased(),
                expectedBucket.windowKind.lowercased(),
                file: file,
                line: line
            )
            assertOptionalDoubleEqual(actualBucket.usedValue, expectedBucket.usedValue, file: file, line: line)
            assertOptionalDoubleEqual(actualBucket.limitValue, expectedBucket.limitValue, file: file, line: line)
            assertOptionalDoubleEqual(actualBucket.remainingValue, expectedBucket.remainingValue, file: file, line: line)
            assertOptionalDoubleEqual(actualBucket.usedPercent, expectedBucket.usedPercent, file: file, line: line)
            XCTAssertEqual(
                actualBucket.resetsAt?.timeIntervalSince1970,
                expectedBucket.resetsAtUnix.map(Double.init),
                file: file,
                line: line
            )
            XCTAssertEqual(actualBucket.unit.rawValue, expectedBucket.unit.lowercased(), file: file, line: line)
            XCTAssertEqual(actualBucket.isEstimated, expectedBucket.isEstimated, file: file, line: line)
        }
    }
}

private struct ExpectedSnapshot: Decodable {
    let buckets: [ExpectedBucket]
}

private struct ExpectedBucket: Decodable {
    let key: String
    let label: String
    let windowKind: String
    let usedValue: Double?
    let limitValue: Double?
    let remainingValue: Double?
    let usedPercent: Double?
    let resetsAtUnix: Int64?
    let unit: String
    let isEstimated: Bool
}

private final class RecordingQuotaLogger: QuotaLogger, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    private var comparisonStorage: [DomainCoreQuotaShadowComparison] = []

    var messages: [String] {
        lock.withLock { storage }
    }

    var comparisons: [DomainCoreQuotaShadowComparison] {
        lock.withLock { comparisonStorage }
    }

    func log(_ message: String) {
        lock.withLock { storage.append(message) }
    }

    func recordDomainCoreShadowComparison(_ comparison: DomainCoreQuotaShadowComparison) {
        lock.withLock { comparisonStorage.append(comparison) }
    }
}

private extension XCTestCase {
    func assertOptionalDoubleEqual(
        _ expression1: Double?,
        _ expression2: Double?,
        accuracy: Double = 0.000_001,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch (expression1, expression2) {
        case (nil, nil): break
        case let (.some(lhs), .some(rhs)):
            XCTAssertEqual(lhs, rhs, accuracy: accuracy, file: file, line: line)
        default:
            XCTFail("Optional values differ: \(String(describing: expression1)) != \(String(describing: expression2))", file: file, line: line)
        }
    }
}
