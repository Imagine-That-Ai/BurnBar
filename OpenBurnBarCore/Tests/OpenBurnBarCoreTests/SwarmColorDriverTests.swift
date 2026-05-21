import XCTest
@testable import OpenBurnBarCore

final class SwarmColorDriverTests: XCTestCase {
    func testActiveProviderWeightsResolveDistinctProviderColors() throws {
        let driver = SwarmColorDriver(
            mode: .active,
            providers: [
                .init(provider: .claudeCode, weight: 0.5),
                .init(provider: .codex, weight: 0.5)
            ],
            totalBurnRateUSD: 1
        )

        let claudeBand = try XCTUnwrap(driver.resolveColor(for: 0.25))
        let codexBand = try XCTUnwrap(driver.resolveColor(for: 0.75))

        XCTAssertEqual(claudeBand, DesignSystemColors.providerRGBA(for: .claudeCode))
        XCTAssertEqual(codexBand, DesignSystemColors.providerRGBA(for: .codex))
        XCTAssertNotEqual(claudeBand, codexBand)
    }
}
