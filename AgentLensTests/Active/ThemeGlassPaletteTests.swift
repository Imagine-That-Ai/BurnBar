import OpenBurnBarCore
import SwiftUI
import XCTest
@testable import OpenBurnBar

/// Covers `ThemeGlassPalette.glass(for:)`, the mapping that gives the dashboard
/// sidebar's Liquid Glass rail a distinct identity per `DashboardLayout`
/// (`Theme/ThemeGlassPalette.swift`). The palette is the testable seam — the
/// opacities and compositing live in the SwiftUI `SidebarThemeGlass` view.
final class ThemeGlassPaletteTests: XCTestCase {

    // MARK: - Totality

    func testEveryLayoutResolvesToItsOwnStableID() {
        // The mapping must be total — the rail always has an identity, including
        // the default layout — and the id must track the layout's raw value so
        // the look stays stable as cases are added/reordered.
        for layout in DashboardLayout.allCases {
            XCTAssertEqual(
                ThemeGlassPalette.glass(for: layout).id,
                layout.rawValue,
                "Palette id must match the layout key for \(layout)."
            )
        }
    }

    // MARK: - Distinctness

    func testEveryLayoutHasADistinctPaletteIdentity() {
        // One identity per layout — no two layouts collapse onto the same rail,
        // so switching layout is always visible on the sidebar.
        let ids = DashboardLayout.allCases.map { ThemeGlassPalette.glass(for: $0).id }
        XCTAssertEqual(
            Set(ids).count,
            DashboardLayout.allCases.count,
            "Each dashboard layout should yield a distinct sidebar glass identity."
        )
    }

    // MARK: - Default

    func testDefaultLayoutCarriesTheAtelierIdentity() {
        // `atelier` is the shipped default backdrop; the rail should match it
        // out of the box.
        XCTAssertEqual(ThemeGlassPalette.glass(for: .atelier).id, DashboardLayout.atelier.rawValue)
    }
}
