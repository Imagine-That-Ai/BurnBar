import XCTest
@testable import OpenBurnBarCore

/// Locks the shared **Editorial / Paper** skin foundation that every native
/// platform (iOS, iPad, macOS, Android) keys off of:
///
///  1. The `AppSkin` `UserDefaults` round-trip and its safe default, since the
///     dynamic color resolvers read `AppSkin.current` with no SwiftUI context.
///  2. The canonical editorial palette constants, mirrored verbatim from the
///     app.burnbar.ai console (`apps/console/styles/globals.css :root`). Drift
///     here would silently desync the paper look across the apps and the web.
final class AppSkinEditorialPaletteTests: XCTestCase {

    private let storageKey = AppSkin.storageKey

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: storageKey)
        super.tearDown()
    }

    // MARK: - AppSkin persistence contract

    func test_storageKey_isTheStableSharedString() {
        XCTAssertEqual(AppSkin.storageKey, "appSkin",
                       "All platforms persist the skin under this exact key — changing it orphans saved preferences.")
    }

    func test_current_defaultsToAurora_whenUnset() {
        XCTAssertEqual(AppSkin.current, .aurora)
    }

    func test_current_readsEditorialFromDefaults() {
        UserDefaults.standard.set(AppSkin.editorial.rawValue, forKey: storageKey)
        XCTAssertEqual(AppSkin.current, .editorial)
    }

    func test_current_fallsBackToAurora_onUnknownValue() {
        UserDefaults.standard.set("nonsense", forKey: storageKey)
        XCTAssertEqual(AppSkin.current, .aurora)
    }

    func test_rawValues_areStableWireStrings() {
        XCTAssertEqual(AppSkin.aurora.rawValue, "aurora")
        XCTAssertEqual(AppSkin.editorial.rawValue, "editorial")
        XCTAssertEqual(Set(AppSkin.allCases), [.aurora, .editorial])
    }

    // MARK: - Canonical editorial palette (mirrors apps/console/styles/globals.css)

    func test_editorialSurfaces_matchConsolePaper() {
        XCTAssertEqual(DesignSystemTokens.backgroundEditorial, "F6F4EF")      // --color-ink-void
        XCTAssertEqual(DesignSystemTokens.surfaceEditorial, "FFFEFB")         // --color-ink-elevated
        XCTAssertEqual(DesignSystemTokens.surfaceElevatedEditorial, "FFFEFB")
    }

    func test_editorialInk_matchesConsoleText() {
        XCTAssertEqual(DesignSystemTokens.textPrimaryEditorial, "16140F")     // --color-text-bright
        XCTAssertEqual(DesignSystemTokens.textSecondaryEditorial, "353027")   // --color-text-base
        XCTAssertEqual(DesignSystemTokens.textMutedEditorial, "6E685D")       // --color-text-mute
    }

    func test_editorialAccent_isTheSingleCoral() {
        XCTAssertEqual(DesignSystemTokens.emberEditorial, "F45B69")           // --accent
        XCTAssertEqual(DesignSystemTokens.blazeEditorial, "B3243C")           // --accent-deep
    }

    func test_editorialSemantics_useAALegibleTierColors() {
        XCTAssertEqual(DesignSystemTokens.successEditorial, "0C7C69")         // --color-tier-end-to-end
        XCTAssertEqual(DesignSystemTokens.warningEditorial, "8A6200")         // --color-tier-server-readable
        XCTAssertEqual(DesignSystemTokens.errorEditorial, "B22219")           // --color-seal-crimson
    }

    func test_editorialHairlines_carryAlpha_inAARRGGBBOrder() {
        // 8-digit hex is alpha-first (AARRGGBB); 0x1F ≈ 12%, 0x14 ≈ 8% ink.
        XCTAssertEqual(DesignSystemTokens.borderEditorial, "1F16140F")
        XCTAssertEqual(DesignSystemTokens.borderSubtleEditorial, "1416140F")
    }
}
