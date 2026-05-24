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

    func testFlameToneAddsProviderFamilyShadesWithoutChangingBaseResolver() throws {
        let driver = SwarmColorDriver(
            mode: .active,
            providers: [.init(provider: .codex, weight: 1)],
            totalBurnRateUSD: 1
        )

        let base = try XCTUnwrap(driver.resolveColor(for: 0.42))
        let toneA = try XCTUnwrap(driver.resolveFlameTone(
            for: 0.42,
            toneSeed: 0.12,
            role: "logo-flame-inner"
        ))
        let toneB = try XCTUnwrap(driver.resolveFlameTone(
            for: 0.42,
            toneSeed: 0.72,
            role: "logo-flame-inner"
        ))

        XCTAssertEqual(base, DesignSystemColors.providerRGBA(for: .codex))
        XCTAssertNotEqual(toneA, base)
        XCTAssertNotEqual(toneA, toneB)
        XCTAssertEqual(try XCTUnwrap(driver.resolveColor(for: 0.42)), base)
    }

    func testFlameToneKeepsConcurrentProvidersVisiblyDistinct() throws {
        let driver = SwarmColorDriver(
            mode: .active,
            providers: [
                .init(provider: .claudeCode, weight: 0.5),
                .init(provider: .codex, weight: 0.5)
            ],
            totalBurnRateUSD: 1
        )

        let claudeTone = try XCTUnwrap(driver.resolveFlameTone(
            for: 0.25,
            toneSeed: 0.44,
            role: "logo-flame-outer"
        ))
        let codexTone = try XCTUnwrap(driver.resolveFlameTone(
            for: 0.75,
            toneSeed: 0.44,
            role: "logo-flame-outer"
        ))

        XCTAssertNotEqual(claudeTone, codexTone)
    }

    func testActiveProvidersKeepsEveryConcurrentProvider() {
        let driver = SwarmColorDriver(
            mode: .active,
            providers: [
                .init(provider: .codex, weight: 0.34),
                .init(provider: .claudeCode, weight: 0.33),
                .init(provider: .xAI, weight: 0.33)
            ],
            totalBurnRateUSD: 1
        )

        XCTAssertEqual(driver.activeProviders, [.codex, .claudeCode, .xAI])
    }

    func testFlameToneReturnsNilWithoutProviders() {
        let driver = SwarmColorDriver(mode: .active, providers: [], totalBurnRateUSD: 1)

        XCTAssertNil(driver.resolveFlameTone(
            for: 0.42,
            toneSeed: 0.12,
            role: "logo-flame-inner"
        ))
    }
}
