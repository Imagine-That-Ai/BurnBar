import Foundation
@testable import OpenBurnBarCore
@testable import OpenBurnBarLogParsers
import XCTest

final class DomainCorePricingAdapterTests: XCTestCase {
    func testCanonicalCostVectorsAcrossAvailableModes() throws {
        let fixture = try loadFixture()
        XCTAssertEqual(fixture.schema, "openburnbar.domain-core.pricing.v2")

        for vector in fixture.costVectors {
            for mode in availableModes {
                var legacyCalls = 0
                let actual = try XCTUnwrap(DomainCorePricingAdapter.cost(
                    inputPerMToken: vector.rates.inputUsdPerMToken,
                    outputPerMToken: vector.rates.outputUsdPerMToken,
                    cacheCreationPerMToken: vector.rates.cacheCreationUsdPerMToken,
                    cacheReadPerMToken: vector.rates.cacheReadUsdPerMToken,
                    inputTokens: Int(vector.buckets.inputTokens),
                    outputTokens: Int(vector.buckets.outputTokens),
                    cacheCreationTokens: Int(vector.buckets.cacheCreationTokens),
                    cacheReadTokens: Int(vector.buckets.cacheReadTokens),
                    environment: migrationEnvironment(mode),
                    legacy: {
                        legacyCalls += 1
                        let cacheCreationRate = vector.rates.cacheCreationUsdPerMToken
                            ?? vector.rates.inputUsdPerMToken
                        return Double(vector.buckets.inputTokens) / 1_000_000
                            * vector.rates.inputUsdPerMToken
                            + Double(vector.buckets.outputTokens) / 1_000_000
                            * vector.rates.outputUsdPerMToken
                            + Double(vector.buckets.cacheCreationTokens) / 1_000_000
                            * cacheCreationRate
                            + Double(vector.buckets.cacheReadTokens) / 1_000_000
                            * vector.rates.cacheReadUsdPerMToken
                    }
                ))
                XCTAssertLessThanOrEqual(
                    abs(actual * 1_000_000_000 - Double(vector.expectedCostNanoUsd)),
                    0.500_001
                )
                XCTAssertEqual(legacyCalls, mode == .rust ? 0 : 1)
            }
        }
    }

    func testInvalidModeIsLegacy() {
        XCTAssertEqual(
            DomainCorePricingMigrationMode.resolve(
                environment: ["OPENBURNBAR_DOMAIN_CORE_PRICING_MODE": "unexpected"]
            ),
            .legacy
        )
    }

    func testRustModeRejectsInvalidAndOverflowingInputWithoutLegacyFallback() {
        let cases: [(rate: Double, tokens: Int)] = [
            (-1, 1),
            (.nan, 1),
            (0.000_000_000_1, 1),
            (1, Int.max),
            (9_007_199.254_740_99, Int.max)
        ]
        for testCase in cases {
            var legacyCalls = 0
            let actual = DomainCorePricingAdapter.cost(
                inputPerMToken: testCase.rate,
                outputPerMToken: 1,
                cacheCreationPerMToken: nil,
                cacheReadPerMToken: 0,
                inputTokens: testCase.tokens,
                outputTokens: 0,
                cacheCreationTokens: 0,
                cacheReadTokens: 0,
                environment: migrationEnvironment(.rust),
                legacy: {
                    legacyCalls += 1
                    return -1
                }
            )
            XCTAssertNil(actual)
            XCTAssertEqual(legacyCalls, 0)
        }
    }

    func testShadowModeRemainsLegacyAuthoritativeWhenFixedPointRejectsInput() {
        XCTAssertEqual(
            DomainCorePricingAdapter.cost(
                inputPerMToken: -1,
                outputPerMToken: 1,
                cacheCreationPerMToken: nil,
                cacheReadPerMToken: 0,
                inputTokens: 1,
                outputTokens: 0,
                cacheCreationTokens: 0,
                cacheReadTokens: 0,
                environment: migrationEnvironment(.shadow),
                legacy: { 42 }
            ),
            42
        )
    }

    func testABIMismatchRejectionEmitsSanitizedShadowEvidence() {
        assertRejectedShadowEvidence(
            category: "native_error",
            coreVersion: "0.0.0-abi-mismatch"
        )
    }

    func testMissingNativeRejectionEmitsSanitizedShadowEvidence() {
        assertRejectedShadowEvidence(
            category: "native_unavailable",
            coreVersion: "0.0.0-native-unavailable"
        )
    }

    private var availableModes: [DomainCorePricingMigrationMode] {
        DomainCorePricingAdapter.isNativeAvailable ? [.legacy, .shadow, .rust] : [.legacy]
    }

    private func migrationEnvironment(_ mode: DomainCorePricingMigrationMode) -> [String: String] {
        ["OPENBURNBAR_DOMAIN_CORE_PRICING_MODE": mode.rawValue]
    }

    private func assertRejectedShadowEvidence(category: String, coreVersion: String) {
        var legacyCalls = 0
        let measurement = DomainCorePricingAdapter.measure {
            legacyCalls += 1
            return 42.125
        }
        var comparisons: [DomainCoreShadowComparison] = []

        let result = DomainCorePricingAdapter.rejected(
            mode: .shadow,
            event: "domain_core.pricing.test_rejection",
            category: category,
            coreVersion: coreVersion,
            legacyMeasurement: measurement,
            recordComparison: { comparisons.append($0) }
        )

        XCTAssertEqual(result, 42.125)
        XCTAssertEqual(legacyCalls, 1)
        XCTAssertEqual(comparisons.count, 1)
        XCTAssertEqual(comparisons.first?.domain, "pricing")
        XCTAssertEqual(comparisons.first?.slice, "token-cost")
        XCTAssertEqual(comparisons.first?.operation, "calculate_token_cost")
        XCTAssertEqual(comparisons.first?.outcome, "mismatch")
        XCTAssertEqual(comparisons.first?.mismatchCategory, category)
        XCTAssertEqual(comparisons.first?.coreVersion, coreVersion)
        XCTAssertEqual(comparisons.first?.rustMicros, 0)
    }

    private func loadFixture() throws -> PricingFixture {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("tests/fixtures/domain-core/pricing/v2/pricing-kat.json")
        return try JSONDecoder().decode(PricingFixture.self, from: Data(contentsOf: fixtureURL))
    }
}

private struct PricingFixture: Decodable {
    let schema: String
    let costVectors: [PricingCostVector]
}

private struct PricingCostVector: Decodable {
    let rates: PricingRatesFixture
    let buckets: PricingBucketsFixture
    let expectedCostNanoUsd: UInt64
}

private struct PricingRatesFixture: Decodable {
    let inputNanoUsdPerMToken: UInt64
    let outputNanoUsdPerMToken: UInt64
    let cacheCreationNanoUsdPerMToken: UInt64?
    let cacheReadNanoUsdPerMToken: UInt64

    var inputUsdPerMToken: Double { Double(inputNanoUsdPerMToken) / 1_000_000_000 }
    var outputUsdPerMToken: Double { Double(outputNanoUsdPerMToken) / 1_000_000_000 }
    var cacheCreationUsdPerMToken: Double? {
        cacheCreationNanoUsdPerMToken.map { Double($0) / 1_000_000_000 }
    }
    var cacheReadUsdPerMToken: Double { Double(cacheReadNanoUsdPerMToken) / 1_000_000_000 }
}

private struct PricingBucketsFixture: Decodable {
    let inputTokens: Double
    let outputTokens: Double
    let cacheCreationTokens: Double
    let cacheReadTokens: Double
}
