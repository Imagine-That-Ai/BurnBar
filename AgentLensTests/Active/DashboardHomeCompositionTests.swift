import OpenBurnBarCore
import OpenBurnBarInboxModels
import SwiftUI
import ViewInspector
import XCTest
@testable import OpenBurnBar

// MARK: - Home composition tests
//
// The layout picker now governs Home as well as Overview, so the mapping from
// `DashboardLayout` to `DashboardHomeShell` is a contract: every layout must
// resolve, no two layouts may collapse onto the same Home surface, and the
// digest every bespoke shell reads must agree with `InboxModel`'s own definition
// of urgent/today/later.

@MainActor
final class DashboardHomeCompositionTests: XCTestCase {

    // MARK: Mapping

    func test_everyLayoutResolvesToADistinctShell() {
        var seen: [DashboardHomeShell: DashboardLayout] = [:]
        for layout in DashboardLayout.allCases {
            let shell = DashboardHomeComposition.resolve(layout: layout).shell
            if let clash = seen[shell] {
                XCTFail("\(layout) and \(clash) both resolve to \(shell); Home would look identical")
            }
            seen[shell] = layout
        }
        XCTAssertEqual(seen.count, DashboardLayout.allCases.count)
        XCTAssertEqual(Set(seen.keys), Set(DashboardHomeShell.allCases))
    }

    /// Pinned so a rename or reorder cannot silently move a user's Home.
    func test_shellMapping_isStable() {
        let expected: [DashboardLayout: DashboardHomeShell] = [
            .classic: .ledger,
            .aurora: .focus,
            .nebula: .bento,
            .constellation: .ask,
            .cockpit: .cockpit,
            .atelier: .canvas,
            .stream: .stream,
            .atlas: .atlas
        ]
        for (layout, shell) in expected {
            XCTAssertEqual(
                DashboardHomeComposition.resolve(layout: layout).shell,
                shell,
                "\(layout.displayName) must present the \(shell) Home surface"
            )
        }
    }

    /// The Reader/Triage/Board switcher may only appear where its options change
    /// the rendering — that is exactly the list-shaped shell.
    func test_onlyTheListShellHonorsTheInboxModeSwitcher() {
        for layout in DashboardLayout.allCases {
            let composition = DashboardHomeComposition.resolve(layout: layout)
            XCTAssertEqual(
                composition.honorsInboxMode,
                composition.shell == .ledger,
                "\(layout.displayName) offers a switcher its shell ignores"
            )
        }
    }

    /// The ambient shells are the ones that exist to be undistracted, so they are
    /// the ones that must not default to a rail.
    func test_ambientShellsDoNotDefaultToTheRail() {
        let ambient: Set<DashboardHomeShell> = [.focus, .canvas, .ask]
        for layout in DashboardLayout.allCases {
            let composition = DashboardHomeComposition.resolve(layout: layout)
            XCTAssertEqual(
                composition.prefersRail,
                ambient.contains(composition.shell) == false,
                "\(layout.displayName) rail default disagrees with its thesis"
            )
        }
    }

    /// The header button and ⌘⌥R must write the same key, and the two keys must
    /// stay independent so hiding the rail on Ledger does not hide it on Cockpit.
    func test_railToggleWritesTheKeyThatGovernsTheActiveShell() {
        let defaults = UserDefaults(suiteName: "home-composition-rail-\(UUID().uuidString)")!
        let ledger = DashboardHomeComposition.resolve(layout: .classic)
        let canvas = DashboardHomeComposition.resolve(layout: .atelier)

        XCTAssertEqual(ledger.railPreference.key, DashboardHomeRailMetrics.collapsedStorageKey)
        XCTAssertFalse(ledger.railPreference.showsWhenTrue)
        XCTAssertEqual(canvas.railPreference.key, DashboardHomeComposition.ambientRailStorageKey)
        XCTAssertTrue(canvas.railPreference.showsWhenTrue)

        ledger.toggleRail(in: defaults)
        XCTAssertTrue(defaults.bool(forKey: DashboardHomeRailMetrics.collapsedStorageKey))
        XCTAssertFalse(defaults.bool(forKey: DashboardHomeComposition.ambientRailStorageKey))

        canvas.toggleRail(in: defaults)
        XCTAssertTrue(defaults.bool(forKey: DashboardHomeComposition.ambientRailStorageKey))
        XCTAssertTrue(
            defaults.bool(forKey: DashboardHomeRailMetrics.collapsedStorageKey),
            "an ambient opt-in must not clear the rail-forward collapse flag"
        )

        defaults.removePersistentDomain(forName: defaults.description)
    }

    // MARK: Digest

    func test_digest_bandsRowsByPriorityWithoutLosingAny() {
        let digest = HomeInboxDigest(rows: [
            makeRow(id: "a", priority: .p1),
            makeRow(id: "b", priority: .p2),
            makeRow(id: "c", priority: .p3),
            makeRow(id: "d", priority: .p4)
        ])

        XCTAssertEqual(digest.urgent.map(\.id), ["a"])
        XCTAssertEqual(digest.today.map(\.id), ["b"])
        XCTAssertEqual(digest.later.map(\.id), ["c", "d"])
        XCTAssertEqual(digest.urgent.count + digest.today.count + digest.later.count, digest.total)
        XCTAssertEqual(digest.attentionCount, 2)
        XCTAssertEqual(digest.attentionLoad, 0.5, accuracy: 0.0001)
    }

    /// An empty inbox must read as 0%, never as a division by zero.
    func test_digest_ratiosAreZeroOnAnEmptyInbox() {
        let digest = HomeInboxDigest(rows: [])
        XCTAssertEqual(digest.attentionLoad, 0)
        XCTAssertEqual(digest.unreadShare, 0)
        XCTAssertNil(digest.lead)
        XCTAssertTrue(digest.days().isEmpty)
    }

    /// Focus and Canvas both lead with `lead`, so its ranking is load-bearing:
    /// priority first, then unread, then recency.
    func test_digest_leadPrefersPriorityThenUnreadThenRecency() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let digest = HomeInboxDigest(rows: [
            makeRow(id: "old-urgent", priority: .p1, lastSeenAt: now - 7200, readAt: now),
            makeRow(id: "fresh-urgent-unread", priority: .p1, lastSeenAt: now - 3600),
            makeRow(id: "fresh-today", priority: .p2, lastSeenAt: now)
        ])
        XCTAssertEqual(digest.lead?.id, "fresh-urgent-unread")

        let readOnly = HomeInboxDigest(rows: [
            makeRow(id: "older", priority: .p2, lastSeenAt: now - 60, readAt: now),
            makeRow(id: "newer", priority: .p2, lastSeenAt: now, readAt: now)
        ])
        XCTAssertEqual(readOnly.lead?.id, "newer")
    }

    func test_digest_unreadShareCountsOnlyOpenUnreadRows() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let digest = HomeInboxDigest(rows: [
            makeRow(id: "unread", lastSeenAt: now),
            makeRow(id: "read", lastSeenAt: now, readAt: now)
        ])
        XCTAssertEqual(digest.unreadCount, 1)
        XCTAssertEqual(digest.unreadShare, 0.5, accuracy: 0.0001)
    }

    /// Stream's only axis. Days descend, rows inside a day descend, and a
    /// recurrence seen again today belongs to today.
    func test_digest_daysDescendAndRowsDescendWithinADay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        // 1_780_012_800 is exactly a UTC midnight, so noon is that plus 12h.
        // Anchoring mid-day matters: an hour either side of midnight would land
        // the "early" row in the previous day and the assertion would be testing
        // the fixture rather than the grouping.
        let noon = Date(timeIntervalSince1970: 1_780_012_800 + 43_200)

        let digest = HomeInboxDigest(rows: [
            makeRow(id: "yesterday", lastSeenAt: noon - 86_400),
            makeRow(id: "today-early", lastSeenAt: noon - 3600),
            makeRow(id: "today-late", lastSeenAt: noon)
        ])

        let days = digest.days(calendar: calendar)
        XCTAssertEqual(days.count, 2)
        XCTAssertGreaterThan(days[0].date, days[1].date)
        XCTAssertEqual(days[0].rows.map(\.id), ["today-late", "today-early"])
        XCTAssertEqual(days[1].rows.map(\.id), ["yesterday"])
    }

    func test_digest_kindRankingSortsByItemCountThenOccurrences() {
        let digest = HomeInboxDigest(rows: [
            makeRow(id: "a", kind: .ciWaste, occurrenceCount: 1),
            makeRow(id: "b", kind: .ciWaste, occurrenceCount: 1),
            makeRow(id: "c", kind: .stuckPR, occurrenceCount: 40),
            makeRow(id: "d", kind: .uncommittedWork, occurrenceCount: 2)
        ])

        let ranking = digest.kindRanking
        XCTAssertEqual(ranking.first?.kind, .ciWaste)
        XCTAssertEqual(ranking.first?.count, 2)
        // Single-item kinds tie on count, so the busier one ranks higher.
        XCTAssertEqual(ranking[1].kind, .stuckPR)
        XCTAssertEqual(ranking[1].occurrences, 40)
        XCTAssertEqual(ranking.last?.kind, .uncommittedWork)
    }

    // MARK: Widening

    /// The digest now carries the whole system, not one table. Adding that must
    /// not disturb a single inbox-derived figure — the widening is additive, and
    /// this is the test that says so out loud.
    func test_digest_widenedSignalsLeaveTheInboxCutsUntouched() {
        let rows = [
            makeRow(id: "a", priority: .p1),
            makeRow(id: "b", priority: .p2),
            makeRow(id: "c", priority: .p4)
        ]
        let plain = HomeInboxDigest(rows: rows)
        let widened = HomeInboxDigest(
            rows: rows,
            signals: HomeSignalDigest.derive(
                window: .empty,
                rollingDailyAverage: 5,
                isScanning: false,
                quotaSnapshots: [],
                fleet: .empty
            )
        )

        XCTAssertEqual(widened.urgent.map(\.id), plain.urgent.map(\.id))
        XCTAssertEqual(widened.today.map(\.id), plain.today.map(\.id))
        XCTAssertEqual(widened.later.map(\.id), plain.later.map(\.id))
        XCTAssertEqual(widened.lead?.id, plain.lead?.id)
        XCTAssertEqual(widened.attentionLoad, plain.attentionLoad, accuracy: 0.0001)
        XCTAssertEqual(widened.payload, plain.payload, "payload follows the rows, not the signals")
        XCTAssertNotEqual(widened.signals, plain.signals, "…and the signals are the part that changed")
    }

    /// Home derives one digest and hands the same value to whichever shell the
    /// layout resolved to. A widened digest that any shell refuses to render
    /// would break seven surfaces at once, so every shell is exercised with one.
    func test_everyBespokeShellRendersAWidenedDigest() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let signals = HomeSignalDigest.derive(
            window: .empty,
            rollingDailyAverage: 4,
            isScanning: false,
            quotaSnapshots: [],
            fleet: HomeFleetSignal(
                rows: [],
                hasRealTimeCoverage: true,
                lastScanAt: now,
                sleepGapReason: nil
            )
        )
        let digest = HomeInboxDigest(
            rows: [makeRow(id: "a", kind: .costAnomaly, priority: .p1, lastSeenAt: now)],
            signals: signals
        )
        let ink = BackdropInk.resolve(liveBackdropActive: true, profile: .darkCanvasFallback)

        XCTAssertNoThrow(try HomeFocusShell(
            digest: digest, ink: ink, onOpenItem: { _ in }, onOpenInbox: {}
        ).inspect())
        XCTAssertNoThrow(try HomeCanvasShell(digest: digest, ink: ink, onOpenItem: { _ in }).inspect())
        XCTAssertNoThrow(try HomeStreamShell(digest: digest, ink: ink, onOpenItem: { _ in }).inspect())
        XCTAssertNoThrow(try HomeAtlasShell(digest: digest, ink: ink, onOpenItem: { _ in }).inspect())
        XCTAssertNoThrow(try HomeCockpitShell(
            digest: digest, ink: ink, activeAgentCount: 2, onOpenItem: { _ in }
        ).inspect())
        XCTAssertNoThrow(try HomeAskShell(
            digest: digest, ink: ink, onAsk: { _ in }, onOpenItem: { _ in }
        ).inspect())
    }

    // MARK: Rendering

    /// Every shell must render at its two hardest states: a populated inbox and
    /// an empty one. Empty is a designed state, not a blank plate.
    func test_everyBespokeShellRendersPopulatedAndEmpty() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let populated = HomeInboxDigest(rows: [
            makeRow(id: "a", kind: .ciWaste, priority: .p1, lastSeenAt: now, occurrenceCount: 6),
            makeRow(id: "b", kind: .stuckPR, priority: .p2, lastSeenAt: now - 3600),
            makeRow(id: "c", kind: .uncommittedWork, priority: .p3, lastSeenAt: now - 86_400)
        ])
        let empty = HomeInboxDigest(rows: [])
        let ink = BackdropInk.resolve(liveBackdropActive: true, profile: .darkCanvasFallback)

        for digest in [populated, empty] {
            XCTAssertNoThrow(try HomeFocusShell(
                digest: digest, ink: ink, onOpenItem: { _ in }, onOpenInbox: {}
            ).inspect())
            XCTAssertNoThrow(try HomeCanvasShell(
                digest: digest, ink: ink, onOpenItem: { _ in }
            ).inspect())
            XCTAssertNoThrow(try HomeStreamShell(
                digest: digest, ink: ink, onOpenItem: { _ in }
            ).inspect())
            XCTAssertNoThrow(try HomeAtlasShell(
                digest: digest, ink: ink, onOpenItem: { _ in }
            ).inspect())
            XCTAssertNoThrow(try HomeCockpitShell(
                digest: digest, ink: ink, activeAgentCount: 2, onOpenItem: { _ in }
            ).inspect())
            XCTAssertNoThrow(try HomeAskShell(
                digest: digest, ink: ink, onAsk: { _ in }, onOpenItem: { _ in }
            ).inspect())
        }
    }

    /// Ask builds its prompts from the live inbox rather than a stale hardcoded
    /// list, so an empty inbox must still offer something to ask.
    func test_askShellAlwaysOffersAtLeastOnePrompt() throws {
        for digest in [HomeInboxDigest(rows: []), HomeInboxDigest(rows: [makeRow(id: "a")])] {
            let shell = HomeAskShell(
                digest: digest,
                ink: BackdropInk.resolve(liveBackdropActive: false, profile: .lightCanvasFallback),
                onAsk: { _ in },
                onOpenItem: { _ in }
            )
            XCTAssertNoThrow(try shell.inspect())
        }
    }

    func test_dayLabelWordsTodayAndYesterday() {
        XCTAssertEqual(HomeShellCopy.dayLabel(Date()), "TODAY")
        XCTAssertEqual(HomeShellCopy.dayLabel(Date().addingTimeInterval(-86_400)), "YESTERDAY")
        XCTAssertFalse(HomeShellCopy.dayLabel(Date(timeIntervalSince1970: 0)).isEmpty)
    }

    func test_percentClampsOutOfRangeFractions() {
        XCTAssertEqual(HomeShellCopy.percent(-2), "0%")
        XCTAssertEqual(HomeShellCopy.percent(0.507), "51%")
        XCTAssertEqual(HomeShellCopy.percent(4), "100%")
    }

    // MARK: Fixtures

    private func makeRow(
        id: String,
        kind: BurnBarInboxItemKind = .stuckPR,
        priority: BurnBarInboxPriority = .p3,
        lastSeenAt: Date = Date(),
        readAt: Date? = nil,
        occurrenceCount: Int = 1
    ) -> ControlPlaneStore.AIInboxRow {
        ControlPlaneStore.AIInboxRow(
            summary: BurnBarInboxItemSummary(
                id: id,
                fingerprint: "fp_\(id)",
                kind: kind,
                priority: priority,
                state: .new,
                title: "Item \(id)",
                projectName: "burnbar",
                occurrenceCount: occurrenceCount,
                firstSeenAt: lastSeenAt,
                lastSeenAt: lastSeenAt
            ),
            summaryMarkdown: "Body of \(id)",
            payload: BurnBarInboxItemPayload(),
            readAt: readAt,
            archivedAt: nil,
            snoozedUntil: nil,
            feedback: nil
        )
    }
}
