import XCTest
@testable import OpenBurnBarMobile

final class LivingThemeDeepLinkTests: XCTestCase {
    func testQualityProfilesUseDistinctFrameRateBudgets() {
        XCTAssertEqual(LivingThemeDeepLink.Quality.eco.maxFrameRate, 20)
        XCTAssertEqual(LivingThemeDeepLink.Quality.atelier.maxFrameRate, 30)
        XCTAssertEqual(LivingThemeDeepLink.Quality.cinema.maxFrameRate, 60)
    }

    func testParsesLivingThemeAndQuality() throws {
        let url = try XCTUnwrap(URL(string: "burnbar://living-theme?theme=fluid-aurora&quality=atelier"))

        XCTAssertEqual(
            LivingThemeDeepLink.parse(url),
            LivingThemeDeepLink(kernel: .fluidAurora, quality: .atelier)
        )
    }

    func testAcceptsLegacyHostAndKernelAlias() throws {
        let url = try XCTUnwrap(URL(string: "burnbar://live-wallpaper?kernel=aurora"))

        XCTAssertEqual(
            LivingThemeDeepLink.parse(url),
            LivingThemeDeepLink(kernel: .aurora, quality: .eco)
        )
    }

    func testRejectsUnknownThemeAndUnrelatedLinks() throws {
        XCTAssertNil(LivingThemeDeepLink.parse(try XCTUnwrap(URL(string: "burnbar://living-theme?theme=missing"))))
        XCTAssertNil(LivingThemeDeepLink.parse(try XCTUnwrap(URL(string: "burnbar://dashboard"))))
        XCTAssertNil(LivingThemeDeepLink.parse(try XCTUnwrap(URL(string: "https://imaginethat.ai/live"))))
    }
}
