import Foundation
@testable import OpenBurnBarCore
import XCTest

final class DomainCoreQuotaConsumerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_783_036_800)

    func testCodexCanonicalFixtureInLegacyShadowAndRustModes() throws {
        let payload = try fixtureData("codex-usage-input.json")
        let expected = try expectedSnapshot("codex-usage-expected.json")

        for mode in migrationModes {
            let logger = ConsumerRecordingQuotaLogger()
            let actual = try CodexOAuthQuotaFetcher.parseUsageSnapshot(
                payload,
                now: now,
                environment: migrationEnvironment(mode),
                quotaLogger: logger
            )

            assertSnapshot(actual, matches: expected)
            assertNoMismatch(logger, mode: mode)
        }
    }

    func testCursorCanonicalFixtureInLegacyShadowAndRustModes() throws {
        let payload = try fixtureData("cursor-usage-summary-input.json")
        let expected = try expectedSnapshot("cursor-usage-summary-expected.json")

        for mode in migrationModes {
            let logger = ConsumerRecordingQuotaLogger()
            let actual = try CursorQuotaAdapter().parseUsageSnapshot(
                payload,
                userEmail: nil,
                now: now,
                environment: migrationEnvironment(mode),
                quotaLogger: logger
            )

            assertSnapshot(actual, matches: expected)
            assertNoMismatch(logger, mode: mode)
        }
    }

    func testAnthropicCanonicalFixtureInLegacyShadowAndRustModes() throws {
        let payload = try fixtureData("anthropic-ratelimit-headers-input.json")
        let expected = try expectedSnapshot("anthropic-ratelimit-headers-expected.json")
        let response = try anthropicResponse(from: payload)
        let headers = AnthropicCredentialProbe.RateLimitHeaders.parse(from: response)

        for mode in migrationModes {
            let logger = ConsumerRecordingQuotaLogger()
            let actual = AnthropicRateLimitDomainCoreAdapter.snapshot(
                payload: payload,
                shape: .oauthBearer,
                now: now,
                environment: migrationEnvironment(mode),
                quotaLogger: logger
            ) {
                ClaudeQuotaAdapter().legacyHeaderProbeSnapshot(
                    headers: headers,
                    shape: .oauthBearer,
                    now: now
                )
            }

            assertSnapshot(try XCTUnwrap(actual), matches: expected)
            assertNoMismatch(logger, mode: mode)
        }
    }

    func testSafeQuotaFFIShimReadsLinkedCoreVersion() throws {
        try XCTSkipUnless(DomainCoreQuotaConsumerSupport.isNativeAvailable)
        XCTAssertNotEqual(
            DomainCoreQuotaConsumerSupport.safeCoreVersion(),
            "0.0.0-unavailable"
        )
    }

    func testRustModeDoesNotEvaluateLegacyParsersWhenNativeCoreIsLinked() throws {
        try XCTSkipUnless(DomainCoreQuotaConsumerSupport.isNativeAvailable)
        var codexLegacyCalls = 0
        _ = try CodexQuotaDomainCoreAdapter.snapshot(
            payload: fixtureData("codex-usage-input.json"),
            now: now,
            environment: migrationEnvironment(.rust),
            quotaLogger: NoOpQuotaLogger()
        ) {
            codexLegacyCalls += 1
            throw DomainCoreQuotaConsumerError.invalidPayload
        }
        XCTAssertEqual(codexLegacyCalls, 0)

        var cursorLegacyCalls = 0
        _ = try CursorQuotaDomainCoreAdapter.snapshot(
            payload: fixtureData("cursor-usage-summary-input.json"),
            userEmail: nil,
            now: now,
            environment: migrationEnvironment(.rust),
            quotaLogger: NoOpQuotaLogger()
        ) {
            cursorLegacyCalls += 1
            throw DomainCoreQuotaConsumerError.invalidPayload
        }
        XCTAssertEqual(cursorLegacyCalls, 0)

        var anthropicLegacyCalls = 0
        _ = AnthropicRateLimitDomainCoreAdapter.snapshot(
            payload: try fixtureData("anthropic-ratelimit-headers-input.json"),
            shape: .oauthBearer,
            now: now,
            environment: migrationEnvironment(.rust),
            quotaLogger: NoOpQuotaLogger()
        ) {
            anthropicLegacyCalls += 1
            return nil
        }
        XCTAssertEqual(anthropicLegacyCalls, 0)
    }

    func testShadowDiagnosticsDoNotContainProviderPayloadValues() throws {
        try XCTSkipUnless(DomainCoreQuotaConsumerSupport.isNativeAvailable)
        let logger = ConsumerRecordingQuotaLogger()
        let sentinel = "private-provider-payload-sentinel"
        let malformed = Data("private-provider-payload-sentinel".utf8)
        let legacy = canonicalFallbackSnapshot(provider: .codex)

        let result = try CodexQuotaDomainCoreAdapter.snapshot(
            payload: malformed,
            now: now,
            environment: migrationEnvironment(.shadow),
            quotaLogger: logger,
            legacy: { legacy }
        )

        XCTAssertEqual(result, legacy)
        XCTAssertEqual(logger.messages.count, 1)
        let message = try XCTUnwrap(logger.messages.first)
        XCTAssertFalse(message.contains(sentinel))
        XCTAssertTrue(message.contains("legacy_count="))
        XCTAssertTrue(message.contains("rust_count="))
        XCTAssertEqual(logger.comparisons.count, 1)
        XCTAssertEqual(logger.comparisons.first?.mismatchCategory, .invalidResult)
    }

    private var migrationModes: [DomainCoreQuotaMigrationMode] {
        DomainCoreQuotaConsumerSupport.isNativeAvailable ? [.legacy, .shadow, .rust] : [.legacy, .shadow]
    }

    private func migrationEnvironment(_ mode: DomainCoreQuotaMigrationMode) -> [String: String] {
        ["OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE": mode.rawValue]
    }

    private func assertNoMismatch(
        _ logger: ConsumerRecordingQuotaLogger,
        mode: DomainCoreQuotaMigrationMode,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expectedComparisonCount = mode == .shadow ? 1 : 0
        XCTAssertEqual(logger.comparisons.count, expectedComparisonCount, file: file, line: line)
        if let comparison = logger.comparisons.single {
            if DomainCoreQuotaConsumerSupport.isNativeAvailable {
                XCTAssertEqual(comparison.outcome, .match, file: file, line: line)
                XCTAssertNil(comparison.mismatchCategory, file: file, line: line)
            } else {
                XCTAssertEqual(comparison.outcome, .mismatch, file: file, line: line)
                XCTAssertEqual(comparison.mismatchCategory, .nativeUnavailable, file: file, line: line)
                XCTAssertEqual(comparison.coreVersion, "0.0.0-unavailable", file: file, line: line)
            }
            XCTAssertGreaterThanOrEqual(comparison.legacyMicros, 0, file: file, line: line)
            XCTAssertGreaterThanOrEqual(comparison.rustMicros, 0, file: file, line: line)
        }
        if mode == .shadow, !DomainCoreQuotaConsumerSupport.isNativeAvailable {
            XCTAssertEqual(logger.messages.count, 1, file: file, line: line)
            XCTAssertTrue(logger.messages[0].contains("native_unavailable"), file: file, line: line)
        } else {
            XCTAssertEqual(logger.messages, [], file: file, line: line)
        }
    }

    private func fixtureData(_ name: String) throws -> Data {
        try Data(contentsOf: fixtureURL(name))
    }

    private func expectedSnapshot(_ name: String) throws -> ConsumerExpectedSnapshot {
        try JSONDecoder().decode(ConsumerExpectedSnapshot.self, from: fixtureData(name))
    }

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../tests/fixtures/domain-core/quota/v1/\(name)")
            .standardizedFileURL
    }

    private func anthropicResponse(from payload: Data) throws -> HTTPURLResponse {
        let headerFields = try JSONDecoder().decode([String: String].self, from: payload)
        return try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://api.anthropic.com/v1/messages")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: headerFields
        ))
    }

    private func canonicalFallbackSnapshot(provider: AgentProvider) -> ProviderQuotaSnapshot {
        ProviderQuotaSnapshot(
            provider: provider,
            fetchedAt: now,
            source: .officialAPI,
            confidence: .exact,
            managementURL: nil,
            statusMessage: "fallback",
            buckets: []
        )
    }

    private func assertSnapshot(
        _ actual: ProviderQuotaSnapshot,
        matches expected: ConsumerExpectedSnapshot,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expectedProvider: AgentProvider? = switch expected.provider {
        case "codex": .codex
        case "cursor": .cursor
        case "claudeCode": .claudeCode
        default: nil
        }
        XCTAssertEqual(actual.quotaProvider, expectedProvider, file: file, line: line)
        XCTAssertEqual(actual.sourceKind, expected.source.nativeValue, file: file, line: line)
        XCTAssertEqual(actual.confidence, expected.confidence.nativeValue, file: file, line: line)
        XCTAssertEqual(actual.statusMessage, expected.statusMessage, file: file, line: line)
        XCTAssertEqual(actual.buckets.count, expected.buckets.count, file: file, line: line)
        for (actualBucket, expectedBucket) in zip(actual.buckets, expected.buckets) {
            XCTAssertEqual(actualBucket.key, expectedBucket.key, file: file, line: line)
            XCTAssertEqual(actualBucket.label, expectedBucket.label, file: file, line: line)
            XCTAssertEqual(actualBucket.windowKind.rawValue.lowercased(), expectedBucket.windowKind.lowercased(), file: file, line: line)
            assertOptionalDouble(actualBucket.usedValue, expectedBucket.usedValue, file: file, line: line)
            assertOptionalDouble(actualBucket.limitValue, expectedBucket.limitValue, file: file, line: line)
            assertOptionalDouble(actualBucket.remainingValue, expectedBucket.remainingValue, file: file, line: line)
            assertOptionalDouble(actualBucket.usedPercent, expectedBucket.usedPercent, file: file, line: line)
            assertOptionalDouble(
                actualBucket.resetsAt?.timeIntervalSince1970,
                expectedBucket.resetsAtUnix.map(Double.init),
                accuracy: 0.001,
                file: file,
                line: line
            )
            XCTAssertEqual(actualBucket.unit.rawValue, expectedBucket.unit.lowercased(), file: file, line: line)
            XCTAssertEqual(actualBucket.isEstimated, expectedBucket.isEstimated, file: file, line: line)
        }
    }

    private func assertOptionalDouble(
        _ lhs: Double?,
        _ rhs: Double?,
        accuracy: Double = 0.000_001,
        file: StaticString,
        line: UInt
    ) {
        switch (lhs, rhs) {
        case (nil, nil): break
        case let (.some(left), .some(right)):
            XCTAssertEqual(left, right, accuracy: accuracy, file: file, line: line)
        default:
            XCTFail("Optional values differ", file: file, line: line)
        }
    }
}

private struct ConsumerExpectedSnapshot: Decodable {
    let provider: String
    let source: ConsumerExpectedSource
    let confidence: ConsumerExpectedConfidence
    let statusMessage: String
    let buckets: [ConsumerExpectedBucket]
}

private enum ConsumerExpectedSource: String, Decodable {
    case officialAPI = "OfficialApi"
    case localCLI = "LocalCli"
    case localSession = "LocalSession"

    var nativeValue: ProviderQuotaSourceKind {
        switch self {
        case .officialAPI: .officialAPI
        case .localCLI: .localCLI
        case .localSession: .localSession
        }
    }
}

private enum ConsumerExpectedConfidence: String, Decodable {
    case exact = "Exact"

    var nativeValue: ProviderQuotaConfidence { .exact }
}

private struct ConsumerExpectedBucket: Decodable {
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

private final class ConsumerRecordingQuotaLogger: QuotaLogger, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    private var comparisonStorage: [DomainCoreQuotaShadowComparison] = []

    var messages: [String] { lock.withLock { storage } }
    var comparisons: [DomainCoreQuotaShadowComparison] { lock.withLock { comparisonStorage } }

    func log(_ message: String) {
        lock.withLock { storage.append(message) }
    }

    func recordDomainCoreShadowComparison(_ comparison: DomainCoreQuotaShadowComparison) {
        lock.withLock { comparisonStorage.append(comparison) }
    }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
