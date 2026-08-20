import XCTest
@testable import OpenBurnBarCore

/// Locks the shared **DashboardLayout** contract that the macOS overview (and
/// any future iOS/Android parity) keys off of:
///
///  1. The `UserDefaults` round-trip and its safe default (`.atelier`, the
///     design phase's "keeper"), since the layout is read via
///     `DashboardLayout.current` and persisted under a stable shared key.
///  2. The case set + raw values, which are persisted strings — renaming a case
///     or changing a raw value orphans saved preferences.
final class DashboardLayoutContractTests: XCTestCase {

    private let storageKey = DashboardLayout.storageKey

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: storageKey)
        super.tearDown()
    }

    // MARK: - Persistence contract

    func test_storageKey_isTheStableSharedString() {
        XCTAssertEqual(DashboardLayout.storageKey, "dashboardLayout",
                       "All surfaces persist the layout under this exact key — changing it orphans saved preferences.")
    }

    func test_current_defaultsToAtelier_whenUnset() {
        XCTAssertEqual(DashboardLayout.current, .atelier,
                       "The keeper is the out-of-box default.")
    }

    func test_current_readsStoredValue() {
        for layout in DashboardLayout.allCases {
            UserDefaults.standard.set(layout.rawValue, forKey: storageKey)
            XCTAssertEqual(DashboardLayout.current, layout)
        }
    }

    func test_current_fallsBackToAtelier_onGarbage() {
        UserDefaults.standard.set("not-a-layout", forKey: storageKey)
        XCTAssertEqual(DashboardLayout.current, .atelier)
    }

    // MARK: - Case set + raw values (persisted strings; do not churn)

    func test_caseSet_isStable() {
        XCTAssertEqual(
            DashboardLayout.allCases,
            [.classic, .aurora, .nebula, .constellation, .cockpit, .atelier, .stream, .atlas]
        )
    }

    /// The raw values are storage ids, not names.
    ///
    /// The display names changed (Classic became Ledger, Aurora became Focus,
    /// and so on) precisely so these strings would not have to. Every surface
    /// that persists the layout — macOS, the Linux desktop, Windows — writes
    /// these, and an unparseable value silently resets the user's choice.
    func test_rawValues_areStable() {
        XCTAssertEqual(DashboardLayout.classic.rawValue, "classic")
        XCTAssertEqual(DashboardLayout.aurora.rawValue, "aurora")
        XCTAssertEqual(DashboardLayout.nebula.rawValue, "nebula")
        XCTAssertEqual(DashboardLayout.constellation.rawValue, "constellation")
        XCTAssertEqual(DashboardLayout.cockpit.rawValue, "cockpit")
        XCTAssertEqual(DashboardLayout.atelier.rawValue, "atelier")
        XCTAssertEqual(DashboardLayout.stream.rawValue, "stream")
        XCTAssertEqual(DashboardLayout.atlas.rawValue, "atlas")
    }

    // MARK: - Presentation metadata

    func test_displayName_nonEmpty_forEveryCase() {
        for layout in DashboardLayout.allCases {
            XCTAssertFalse(layout.displayName.isEmpty)
            XCTAssertFalse(layout.symbolName.isEmpty)
            XCTAssertFalse(layout.tagline.isEmpty, "\(layout.rawValue) has no tagline")
        }
    }

    /// Names and taglines are how a user tells eight layouts apart, so a
    /// copy-paste duplicate is a real defect rather than cosmetic.
    func test_displayNamesAndTaglines_areDistinct() {
        let names = DashboardLayout.allCases.map(\.displayName)
        XCTAssertEqual(Set(names).count, names.count, "duplicate display name in \(names)")
        let taglines = DashboardLayout.allCases.map(\.tagline)
        XCTAssertEqual(Set(taglines).count, taglines.count, "duplicate tagline in \(taglines)")
        let symbols = DashboardLayout.allCases.map(\.symbolName)
        XCTAssertEqual(Set(symbols).count, symbols.count, "duplicate symbol in \(symbols)")
    }

    /// The display names are the user-visible contract that the docs, the
    /// Appearance settings labels, and the switcher gallery all repeat.
    func test_displayNames_matchTheShippedNames() {
        XCTAssertEqual(DashboardLayout.classic.displayName, "Ledger")
        XCTAssertEqual(DashboardLayout.aurora.displayName, "Focus")
        XCTAssertEqual(DashboardLayout.nebula.displayName, "Bento")
        XCTAssertEqual(DashboardLayout.constellation.displayName, "Ask")
        XCTAssertEqual(DashboardLayout.cockpit.displayName, "Cockpit")
        XCTAssertEqual(DashboardLayout.atelier.displayName, "Canvas")
        XCTAssertEqual(DashboardLayout.stream.displayName, "Stream")
        XCTAssertEqual(DashboardLayout.atlas.displayName, "Atlas")
    }

    func test_kernelForward_classification() {
        XCTAssertTrue(DashboardLayout.atelier.isKernelForward)
        XCTAssertTrue(DashboardLayout.constellation.isKernelForward)
        XCTAssertFalse(DashboardLayout.classic.isKernelForward)
        XCTAssertFalse(DashboardLayout.aurora.isKernelForward)
        XCTAssertFalse(DashboardLayout.nebula.isKernelForward)
        XCTAssertFalse(DashboardLayout.cockpit.isKernelForward)
        XCTAssertFalse(DashboardLayout.stream.isKernelForward)
        XCTAssertFalse(DashboardLayout.atlas.isKernelForward)
    }

    // MARK: - Codable round-trip

    func test_codable_roundTrip() throws {
        for layout in DashboardLayout.allCases {
            let data = try JSONEncoder().encode(layout)
            let decoded = try JSONDecoder().decode(DashboardLayout.self, from: data)
            XCTAssertEqual(decoded, layout)
        }
    }
}
