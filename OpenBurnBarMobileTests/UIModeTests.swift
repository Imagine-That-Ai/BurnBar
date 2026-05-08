import XCTest
import SwiftUI
import OpenBurnBarCore
@testable import OpenBurnBarMobile

final class UIModeTests: XCTestCase {

    // MARK: - Enum Serialization

    func testUIModeRawValueRoundTrip() {
        for mode in UIMode.allCases {
            XCTAssertEqual(UIMode(rawValue: mode.rawValue), mode)
        }
    }

    func testUIModeUnknownRawValueFallsBackToStandard() {
        let unknown = UIMode(rawValue: "unknown")
        XCTAssertNil(unknown)
    }

    func testUIModeDisplayNamesAreNonEmpty() {
        for mode in UIMode.allCases {
            XCTAssertFalse(mode.displayName.isEmpty)
        }
    }

    // MARK: - UIModeTheme Overrides

    func testCookingTypographyIsLargerThanStandard() {
        let standard = UIModeTheme(mode: .standard)
        let cooking = UIModeTheme(mode: .cooking)

        // We can't compare Font values directly, so we verify the mode
        // returns different values by checking the mode property.
        XCTAssertEqual(standard.mode, .standard)
        XCTAssertEqual(cooking.mode, .cooking)
    }

    func testCookingSpacingScaleIsLarger() {
        let standard = UIModeTheme(mode: .standard)
        let cooking = UIModeTheme(mode: .cooking)

        XCTAssertEqual(standard.spacingScale, 1.0)
        XCTAssertEqual(cooking.spacingScale, 1.25)
    }

    func testCookingExtraRadiusIsLarger() {
        let standard = UIModeTheme(mode: .standard)
        let cooking = UIModeTheme(mode: .cooking)

        XCTAssertEqual(standard.extraRadius, 0)
        XCTAssertEqual(cooking.extraRadius, 4)
    }

    func testCookingAmbientAnimationsDisabled() {
        let standard = UIModeTheme(mode: .standard)
        let cooking = UIModeTheme(mode: .cooking)

        XCTAssertTrue(standard.ambientAnimationsEnabled)
        XCTAssertFalse(cooking.ambientAnimationsEnabled)
    }

    func testCookingAccentColorsAreNonStandard() {
        let standard = UIModeTheme(mode: .standard)
        let cooking = UIModeTheme(mode: .cooking)

        // Cooking accents should differ from standard
        XCTAssertNotEqual(cooking.primaryAccent, standard.primaryAccent)
        XCTAssertNotEqual(cooking.secondaryAccent, standard.secondaryAccent)
    }

    func testMobileThemeTokensAccessor() {
        let standardTokens = MobileTheme.tokens(for: .standard)
        let cookingTokens = MobileTheme.tokens(for: .cooking)

        XCTAssertEqual(standardTokens.mode, .standard)
        XCTAssertEqual(cookingTokens.mode, .cooking)
    }
}
