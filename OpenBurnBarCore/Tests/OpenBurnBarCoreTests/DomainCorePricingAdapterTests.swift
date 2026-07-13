import Foundation
@testable import OpenBurnBarCore
import XCTest

final class DomainCorePricingAdapterTests: XCTestCase {
    func testCanonicalCostVectorsAcrossAvailableModes() throws {
        let fixture = try loadFixture()
        XCTAssertEqual(fixture.schema, "openburnbar.domain-core.pricing.v1")

        for vector in fixture.costVectors {
            for mode in availableModes {
                var legacyCalls = 0
                let actual = DomainCorePricingAdapter.cost(
                    inputPerMToken: vector.rates.inputPerMToken,
                    outputPerMToken: vector.rates.outputPerMToken,
                    cacheCreationPerMToken: vector.rates.cacheCreationPerMToken,
                    cacheReadPerMToken: vector.rates.cacheReadPerMToken,
                    inputTokens: Int(vector.buckets.inputTokens),
                    outputTokens: Int(vector.buckets.outputTokens),
                    cacheCreationTokens: Int(vector.buckets.cacheCreationTokens),
                    cacheReadTokens: Int(vector.buckets.cacheReadTokens),
                    environment: migrationEnvironment(mode),
                    legacy: {
                        legacyCalls += 1
                        let cacheCreationRate = vector.rates.cacheCreationPerMToken
                            ?? vector.rates.inputPerMToken
                        return Double(vector.buckets.inputTokens) / 1_000_000
                            * vector.rates.inputPerMToken
                            + Double(vector.buckets.outputTokens) / 1_000_000
                            * vector.rates.outputPerMToken
                            + Double(vector.buckets.cacheCreationTokens) / 1_000_000
                            * cacheCreationRate
                            + Double(vector.buckets.cacheReadTokens) / 1_000_000
                            * vector.rates.cacheReadPerMToken
                    }
                )
                XCTAssertEqual(actual.bitPattern, vector.expectedCostUsd.bitPattern)
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

    private var availableModes: [DomainCorePricingMigrationMode] {
        DomainCorePricingAdapter.isNativeAvailable ? [.legacy, .shadow, .rust] : [.legacy]
    }

    private func migrationEnvironment(_ mode: DomainCorePricingMigrationMode) -> [String: String] {
        ["OPENBURNBAR_DOMAIN_CORE_PRICING_MODE": mode.rawValue]
    }

    private func loadFixture() throws -> PricingFixture {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("tests/fixtures/domain-core/pricing/v1/pricing-kat.json")
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
    let expectedCostUsd: Double
}

private struct PricingRatesFixture: Decodable {
    let inputPerMToken: Double
    let outputPerMToken: Double
    let cacheCreationPerMToken: Double?
    let cacheReadPerMToken: Double
}

private struct PricingBucketsFixture: Decodable {
    let inputTokens: Double
    let outputTokens: Double
    let cacheCreationTokens: Double
    let cacheReadTokens: Double
}
