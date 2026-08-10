import XCTest
@testable import OpenBurnBar

/// Guards the two promises the deck's registry makes:
///
///  1. every shipped tile carries the metadata its chrome depends on, and
///  2. the deck and the Settings sidebar agree about which features this build
///     ships — the drift `OpenBurnBarBuildGates` exists to prevent.
@MainActor
final class ControlDeckRegistryTests: XCTestCase {

    // MARK: Metadata completeness

    func test_everyKindCarriesEditorialCopy() {
        for kind in ControlKind.allCases {
            XCTAssertFalse(kind.title.isEmpty, "\(kind.rawValue) has no title")
            XCTAssertFalse(kind.whyItMatters.isEmpty, "\(kind.rawValue) has no microcopy")
            XCTAssertFalse(kind.systemImage.isEmpty, "\(kind.rawValue) has no symbol")
            XCTAssertFalse(kind.searchKeywords.isEmpty, "\(kind.rawValue) is unreachable from ⌘K")
        }
    }

    /// The headline budget: at four columns a tile is roughly 274pt wide and the
    /// headline is `lineLimit(1)`. The *title* is the eyebrow, so it must stay
    /// short enough to sit beside a control without truncating.
    func test_titlesFitTheEyebrow() {
        for kind in ControlKind.allCases {
            XCTAssertLessThanOrEqual(kind.title.count, 22, "\(kind.rawValue) title is too long")
        }
    }

    func test_spansAreWithinTheGrid() {
        for kind in ControlKind.allCases {
            XCTAssertGreaterThanOrEqual(kind.defaultSpan, 1, "\(kind.rawValue)")
            XCTAssertLessThanOrEqual(kind.defaultSpan, ControlDeckLayout.maxSpan, "\(kind.rawValue)")
        }
    }

    func test_settingsItemIDsResolveToRealManifestItems() {
        let manifestIDs = Set(SettingsManifest.all.map(\.id))
        for kind in ControlKind.allCases {
            guard let itemID = kind.settingsItemID else { continue }
            XCTAssertTrue(
                manifestIDs.contains(itemID),
                "\(kind.rawValue) deep-links to \"\(itemID)\", which is not in the settings manifest"
            )
        }
    }

    func test_rawValuesAreStableIdentifiers() {
        // The raw value is the persistence key inside `controlDeck.layout.v1`.
        // Renaming one silently drops a user's arrangement for that tile.
        XCTAssertEqual(
            ControlKind.allCases.map(\.rawValue).sorted(),
            ["alerts", "appearance", "charts", "engineRoom", "pets", "textExpansion", "updates"]
        )
    }

    // MARK: Build-gate parity

    func test_deckAndSettingsAgreeOnUpdatesAvailability() {
        let settingsShowsUpdates = SettingsTab.visibleTabs.contains(.updates)
        let deckShowsUpdates = ControlKind.visibleKinds.contains(.updates)
        XCTAssertEqual(
            settingsShowsUpdates,
            deckShowsUpdates,
            "Settings and the Control Deck disagree about whether this build ships Updates"
        )
        XCTAssertEqual(settingsShowsUpdates, OpenBurnBarBuildGates.updatesAvailable)
    }

    func test_agentControlGateMatchesTheSettingsSidebar() {
        XCTAssertEqual(
            SettingsTab.visibleTabs.contains(.computerUse),
            OpenBurnBarBuildGates.agentControlAvailable
        )
    }

    func test_gatesAgreeWithTheCompiledBuildConfiguration() {
        #if DISTRIBUTION_MAS
        XCTAssertFalse(OpenBurnBarBuildGates.updatesAvailable)
        XCTAssertFalse(OpenBurnBarBuildGates.agentControlAvailable)
        XCTAssertFalse(OpenBurnBarBuildGates.globalTextExpansionAvailable)
        #else
        XCTAssertTrue(OpenBurnBarBuildGates.updatesAvailable)
        XCTAssertTrue(OpenBurnBarBuildGates.agentControlAvailable)
        XCTAssertTrue(OpenBurnBarBuildGates.globalTextExpansionAvailable)
        #endif
    }

    // MARK: Readout

    func test_readoutCountsNothingOnAColdMachine() {
        let readout = ControlDeckReadout(inputs: .init())
        // Appearance has no off state, so it is the only thing on by default.
        XCTAssertEqual(readout.on, [.appearance])
    }

    func test_readoutTreatsEitherExpansionSurfaceAsOn() {
        XCTAssertTrue(
            ControlDeckReadout(inputs: .init(textExpansionInApp: true)).isOn(.textExpansion)
        )
        XCTAssertTrue(
            ControlDeckReadout(inputs: .init(textExpansionEverywhere: true)).isOn(.textExpansion)
        )
        XCTAssertFalse(ControlDeckReadout(inputs: .init()).isOn(.textExpansion))
    }

    func test_readoutTreatsAMissingThresholdAsOff() {
        XCTAssertFalse(ControlDeckReadout(inputs: .init(spendAlertThreshold: nil)).isOn(.alerts))
        XCTAssertTrue(ControlDeckReadout(inputs: .init(spendAlertThreshold: 25)).isOn(.alerts))
    }

    func test_readoutCountsPerBand() {
        let readout = ControlDeckReadout(
            inputs: .init(chartsAIInsights: true, spendAlertThreshold: 25)
        )
        XCTAssertEqual(readout.onCount(in: .spend, among: [.charts, .alerts]), 2)
        XCTAssertEqual(readout.onCount(in: .house, among: [.charts, .alerts]), 0)
    }

    func test_readoutNeverReportsAKindThisBuildDoesNotShip() {
        let readout = ControlDeckReadout(inputs: .init(updatesAutomaticChecks: true))
        if !OpenBurnBarBuildGates.updatesAvailable {
            XCTAssertFalse(readout.isOn(.updates))
        }
    }
}
