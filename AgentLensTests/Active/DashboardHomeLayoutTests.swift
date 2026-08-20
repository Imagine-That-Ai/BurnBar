import XCTest
@testable import OpenBurnBar

/// Home's layout rules.
///
/// Every rule under test is a `static func` on `DashboardHomeRailMetrics`
/// precisely so it can be tested without mounting a view — `@State` cannot be
/// mutated on an unmounted SwiftUI view, which is the constraint
/// `DashboardViewIntegrationTests` documents and works around the same way.
final class DashboardHomeLayoutTests: XCTestCase {

    // MARK: - Width bands

    func test_bandClassification() {
        XCTAssertEqual(DashboardHomeRailMetrics.band(forWidth: 970, current: .wide), .narrow)
        XCTAssertEqual(DashboardHomeRailMetrics.band(forWidth: 1010, current: .narrow), .medium)
        XCTAssertEqual(DashboardHomeRailMetrics.band(forWidth: 1200, current: .medium), .wide)
    }

    /// The two dead zones. A `GeometryReader` reports sub-pixel changes when a
    /// divider is parked near a threshold, and a hard cutoff makes the rail
    /// flicker between states — the failure the overview lane layout already
    /// documents.
    func test_deadBandsHoldTheCurrentBand() {
        XCTAssertEqual(DashboardHomeRailMetrics.band(forWidth: 990, current: .narrow), .narrow)
        XCTAssertEqual(DashboardHomeRailMetrics.band(forWidth: 990, current: .medium), .medium)
        XCTAssertEqual(DashboardHomeRailMetrics.band(forWidth: 1170, current: .medium), .medium)
        XCTAssertEqual(DashboardHomeRailMetrics.band(forWidth: 1170, current: .wide), .wide)
    }

    func test_zeroWidthHoldsRatherThanCollapsing() {
        // The first layout pass can report zero before the window has a frame.
        XCTAssertEqual(DashboardHomeRailMetrics.band(forWidth: 0, current: .wide), .wide)
    }

    // MARK: - Rail width

    func test_railWidthClamps() {
        XCTAssertEqual(DashboardHomeRailMetrics.resolvedWidth(stored: 100, band: .wide),
                       DashboardHomeRailMetrics.minWidth)
        XCTAssertEqual(DashboardHomeRailMetrics.resolvedWidth(stored: 9_000, band: .wide),
                       DashboardHomeRailMetrics.maxWidth)
    }

    /// The medium band caps the *rendered* width without touching storage, so
    /// widening the window gives the user their chosen width back.
    func test_mediumBandCapsWithoutMutatingStorage() {
        let stored: CGFloat = 460
        XCTAssertEqual(DashboardHomeRailMetrics.resolvedWidth(stored: stored, band: .medium),
                       DashboardHomeRailMetrics.mediumBandWidthCap)
        XCTAssertEqual(DashboardHomeRailMetrics.resolvedWidth(stored: stored, band: .wide), stored,
                       "Returning to the wide band must restore the stored width")
    }

    func test_narrowBandStubsTheRail() {
        XCTAssertEqual(DashboardHomeRailMetrics.resolvedWidth(stored: 460, band: .narrow),
                       DashboardHomeRailMetrics.collapsedStubWidth)
    }

    // MARK: - Automatic vs intentional collapse

    /// An automatic collapse must never be mistaken for the user's intent —
    /// the same separation `resolvedSidebarVisibility` keeps between a manual
    /// override and a route default.
    func test_narrowBandHidesTheRailWithoutChangingUserIntent() {
        XCTAssertFalse(DashboardHomeRailMetrics.railIsExpanded(userWantsRail: true, band: .narrow))
        XCTAssertTrue(DashboardHomeRailMetrics.railIsExpanded(userWantsRail: true, band: .medium))
        XCTAssertFalse(DashboardHomeRailMetrics.railIsExpanded(userWantsRail: false, band: .wide))
    }

    // MARK: - Split fraction

    func test_splitFractionClamps() {
        XCTAssertEqual(DashboardHomeRailMetrics.clampSplit(0.01), DashboardHomeRailMetrics.minSplitFraction)
        XCTAssertEqual(DashboardHomeRailMetrics.clampSplit(0.99), DashboardHomeRailMetrics.maxSplitFraction)
        XCTAssertEqual(DashboardHomeRailMetrics.clampSplit(0.5), 0.5)
    }

    // MARK: - Composition at the window minimum

    /// The whole point of the width budget: at the 1040pt window minimum, with
    /// the rail at its default, the inbox list must still be at its floor
    /// rather than being crushed below it.
    func test_inboxSurvivesAtTheWindowMinimum() {
        let detailWidth: CGFloat = 1036   // 1040 minus window chrome
        let railWidth = DashboardHomeRailMetrics.defaultWidth
        let inboxWidth = detailWidth - railWidth - ResizableSectionDivider.thickness

        XCTAssertEqual(InboxView.listPaneWidth(forTotalWidth: inboxWidth), 260,
                       "The inbox list pane should sit exactly at its 260pt floor")

        let detailPane = inboxWidth - 260 - 1
        XCTAssertGreaterThan(detailPane, 400,
                             "The inbox reading pane must keep a usable width at the window minimum")
    }

    // MARK: - Panel order

    func test_panelOrderNormalization() {
        XCTAssertEqual(DashboardHomeRailPanel.ordered(from: "quota,fleet"), [.quota, .fleet])
        XCTAssertEqual(DashboardHomeRailPanel.ordered(from: ""), DashboardHomeRailPanel.allCases,
                       "An empty key must fall back to every panel")
        XCTAssertEqual(DashboardHomeRailPanel.ordered(from: "quota"), [.quota, .fleet],
                       "A panel missing from storage must be appended, so a new panel appears automatically")
        XCTAssertEqual(DashboardHomeRailPanel.ordered(from: "bogus,quota"), [.quota, .fleet],
                       "An unknown raw value must be dropped rather than crashing the rail")
    }

    func test_panelOrderRoundTrips() {
        let order: [DashboardHomeRailPanel] = [.quota, .fleet]
        XCTAssertEqual(DashboardHomeRailPanel.ordered(from: DashboardHomeRailPanel.encode(order)), order)
    }

    // MARK: - Panel state

    func test_panelStateRoundTrips() {
        let state = ["fleet": DashboardHomeRailPanelState(collapsed: true, fraction: 0.4)]
        let decoded = DashboardHomeRailPanelState.decode(DashboardHomeRailPanelState.encode(state))
        XCTAssertEqual(decoded["fleet"]?.collapsed, true)
        XCTAssertEqual(decoded["fleet"]?.fraction, 0.4)
    }

    func test_corruptPanelStateFallsBackToDefaults() {
        XCTAssertTrue(DashboardHomeRailPanelState.decode("not json at all").isEmpty)
        XCTAssertTrue(DashboardHomeRailPanelState.decode("").isEmpty)
    }

    // MARK: - Fleet row budget

    /// The rail already knows how tall its fleet panel is; before this it showed
    /// six rows regardless, so a panel dragged tall held six agents above a field
    /// of nothing.
    func test_fleetRowLimitFollowsPanelHeight() {
        let short = LiveAgentFleetPanel.visibleRowLimit(forHeight: 160)
        let tall = LiveAgentFleetPanel.visibleRowLimit(forHeight: 700)
        XCTAssertGreaterThan(tall, short, "A taller panel must show more agents")
        XCTAssertGreaterThan(tall, 6, "The old flat cap of 6 must no longer bind a tall panel")
    }

    /// Never fewer than three, or a short panel says less than the collapsed
    /// stub it is supposed to be an expansion of.
    func test_fleetRowLimitKeepsAFloor() {
        XCTAssertEqual(LiveAgentFleetPanel.visibleRowLimit(forHeight: 10), 3)
        // The first layout pass can report zero before the rail has a frame.
        XCTAssertEqual(LiveAgentFleetPanel.visibleRowLimit(forHeight: 0), 3)
    }

    // MARK: - Fleet mode availability

    /// The timeline is gated out until the watchers are armed rather than
    /// shipped present-and-empty — the `OnboardingWizardStep.availableCases`
    /// precedent.
    func test_timelineIsUnavailableWithoutRealTimeCoverage() {
        let without = DashboardHomeFleetMode.availableCases(hasRealTimeCoverage: false)
        XCTAssertFalse(without.contains(.timeline))
        XCTAssertTrue(without.contains(.rows))

        let with = DashboardHomeFleetMode.availableCases(hasRealTimeCoverage: true)
        XCTAssertTrue(with.contains(.timeline))
    }
}
