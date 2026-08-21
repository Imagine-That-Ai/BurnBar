import XCTest
@testable import OpenBurnBar

/// Sidebar customization and layout rules tests.
///
/// Follows the testing style established in `DashboardHomeLayoutTests.swift`.
/// Pure static logic is tested without mounting a view.
final class DashboardSidebarLayoutTests: XCTestCase {

    // MARK: - Section Order Normalization

    func test_sectionOrderNormalization() {
        let raw = "models,providers"
        let ordered = DashboardSidebarSection.ordered(from: raw)
        XCTAssertEqual(ordered.prefix(2), [.models, .providers])
        XCTAssertEqual(ordered.count, DashboardSidebarSection.allCases.count,
                       "Missing sections must be appended automatically")
    }

    func test_emptyOrderFallsBackToAllCases() {
        XCTAssertEqual(DashboardSidebarSection.ordered(from: ""), DashboardSidebarSection.allCases,
                       "An empty string must fall back to all cases in default order")
        XCTAssertEqual(DashboardSidebarSection.ordered(from: "   "), DashboardSidebarSection.allCases,
                       "Whitespace-only string must fall back to all cases")
    }

    func test_missingSectionsAppendedAutomatically() {
        let raw = "projects,quota"
        let ordered = DashboardSidebarSection.ordered(from: raw)
        XCTAssertEqual(ordered.prefix(2), [.projects, .quota])
        for section in DashboardSidebarSection.allCases {
            XCTAssertTrue(ordered.contains(section), "Order must contain \(section)")
        }
    }

    func test_unknownSectionsDroppedGracefully() {
        let raw = "bogus,unknown_section,providers,invalid,models"
        let ordered = DashboardSidebarSection.ordered(from: raw)
        XCTAssertEqual(ordered.prefix(2), [.providers, .models],
                       "Unknown/invalid section raw values must be safely dropped")
        XCTAssertFalse(ordered.contains(where: { $0.rawValue == "bogus" }))
    }

    func test_sectionOrderRoundTrips() {
        let customOrder: [DashboardSidebarSection] = [
            .inbox,
            .fleet,
            .quota,
            .sessions,
            .projects,
            .models,
            .providers
        ]
        let encoded = DashboardSidebarSection.encode(customOrder)
        let decoded = DashboardSidebarSection.ordered(from: encoded)
        XCTAssertEqual(decoded, customOrder)
    }

    // MARK: - Pure Move Reordering Helper

    func test_moveSectionUp() {
        let initial: [DashboardSidebarSection] = [.providers, .models, .projects]
        let moved = DashboardSidebarSection.moveSection(.models, by: -1, in: initial)
        XCTAssertEqual(moved, [.models, .providers, .projects])
    }

    func test_moveSectionDown() {
        let initial: [DashboardSidebarSection] = [.providers, .models, .projects]
        let moved = DashboardSidebarSection.moveSection(.models, by: 1, in: initial)
        XCTAssertEqual(moved, [.providers, .projects, .models])
    }

    func test_moveSectionOutOfBoundsClamps() {
        let initial: [DashboardSidebarSection] = [.providers, .models, .projects]
        let movedTop = DashboardSidebarSection.moveSection(.providers, by: -1, in: initial)
        XCTAssertEqual(movedTop, initial, "Moving the first section up must do nothing")

        let movedBottom = DashboardSidebarSection.moveSection(.projects, by: 1, in: initial)
        XCTAssertEqual(movedBottom, initial, "Moving the last section down must do nothing")
    }

    // MARK: - Section State Persistence

    func test_sectionStateRoundTrips() {
        let state: [String: DashboardSidebarSectionState] = [
            "providers": DashboardSidebarSectionState(collapsed: true, isVisible: true),
            "inbox": DashboardSidebarSectionState(collapsed: false, isVisible: false)
        ]
        let encoded = DashboardSidebarSectionState.encode(state)
        let decoded = DashboardSidebarSectionState.decode(encoded)
        XCTAssertEqual(decoded["providers"]?.collapsed, true)
        XCTAssertEqual(decoded["providers"]?.isVisible, true)
        XCTAssertEqual(decoded["inbox"]?.collapsed, false)
        XCTAssertEqual(decoded["inbox"]?.isVisible, false)
    }

    func test_corruptSectionStateFallsBackToEmpty() {
        XCTAssertTrue(DashboardSidebarSectionState.decode("invalid json").isEmpty)
        XCTAssertTrue(DashboardSidebarSectionState.decode("").isEmpty)
    }

    func test_toggleCollapsedHelper() {
        let state: [String: DashboardSidebarSectionState] = [:]
        let toggled = DashboardSidebarSectionState.toggleCollapsed(.providers, in: state)
        XCTAssertEqual(toggled["providers"]?.collapsed, true)

        let toggledAgain = DashboardSidebarSectionState.toggleCollapsed(.providers, in: toggled)
        XCTAssertEqual(toggledAgain["providers"]?.collapsed, false)
    }

    func test_toggleVisibilityHelper() {
        let state: [String: DashboardSidebarSectionState] = [:]
        let toggled = DashboardSidebarSectionState.toggleVisibility(.quota, in: state)
        XCTAssertEqual(toggled["quota"]?.isVisible, false)

        let toggledAgain = DashboardSidebarSectionState.toggleVisibility(.quota, in: toggled)
        XCTAssertEqual(toggledAgain["quota"]?.isVisible, true)
    }
}
