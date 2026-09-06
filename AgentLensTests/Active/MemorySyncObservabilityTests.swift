import XCTest
import OpenBurnBarKernel
@testable import OpenBurnBar

/// E19 (app half): the memory sync-status row.
///
/// The row's whole value is that it reports what this Mac actually observed, so
/// these tests are about the ways it could lie:
///
///  * inventing a `0` for a store it could not read (it must render `—`),
///  * aging a consent marker the daemon reads as NO consent — an absent row,
///    or the ambiguous two-row table nothing in the tree picks a winner from,
///  * reporting another member's marker as this member's,
///  * forking the health card's surface: the row must reuse the card's
///    formatter, placeholder and stat row, and must NOT emit a second
///    `SYNC_MARKER_STALE`, which the card above it already owns.
///
/// The real-store half (`ControlPlaneStore.memorySyncObservabilitySnapshot`)
/// is covered by `MemorySyncObservabilityStoreTests`.
@MainActor
final class MemorySyncObservabilityTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func model(
        accountUid: String? = "uid-1",
        facts: TimeInterval? = nil,
        receipts: TimeInterval? = nil,
        marker: TimeInterval? = nil,
        markerAccount: String? = "uid-1",
        markerAmbiguous: Bool = false,
        parked: Int? = nil,
        merged: Int? = nil
    ) -> MemorySyncStatusModel {
        let reading: MemoryDeviceSyncMarkerReading
        if markerAmbiguous || marker == nil {
            reading = .absent
        } else {
            reading = MemoryDeviceSyncMarkerReading(
                accountUid: markerAccount,
                refreshedAt: marker.map { now.addingTimeInterval(-$0) }
            )
        }
        return MemorySyncStatusModel(
            snapshot: MemorySyncObservabilitySnapshot(
                accountUid: accountUid,
                memoryFactsWatermarkAt: facts.map { now.addingTimeInterval(-$0) },
                forgetReceiptsWatermarkAt: receipts.map { now.addingTimeInterval(-$0) },
                deviceSyncMarker: reading,
                parkedInboxRows: parked,
                mergedInboxRows: merged
            ),
            now: now
        )
    }

    private func value(_ model: MemorySyncStatusModel, _ title: String) throws -> String {
        try XCTUnwrap(model.statRows.first { $0.title == title }).value
    }

    // MARK: - Unreachable renders `—`, never `0`

    func test_an_unreadable_store_renders_dashes_and_never_zero() throws {
        // Every field absent: nobody signed in, nothing ever pulled, no marker.
        let model = self.model(accountUid: nil)

        for title in ["Facts cursor", "Receipts cursor", "Consent marker", "Parked", "Merged (30 d)"] {
            let rendered = try value(model, title)
            XCTAssertEqual(rendered, ProjectMemoryHealthCardModel.placeholder, title)
            XCTAssertNotEqual(rendered, "0", "\(title) must never claim zero for something it did not observe")
        }
    }

    func test_a_real_zero_is_rendered_as_zero_and_not_as_a_placeholder() throws {
        // The other half of the claim: when the count IS observed and IS zero,
        // the row says zero. Otherwise `—` would just mean "small".
        let model = self.model(parked: 0, merged: 0)
        XCTAssertEqual(try value(model, "Parked"), "0")
        XCTAssertEqual(try value(model, "Merged (30 d)"), "0")
    }

    func test_the_two_counters_this_mac_does_not_hold_are_labelled_rather_than_zeroed() throws {
        let model = self.model(parked: 4, merged: 9)
        XCTAssertEqual(try value(model, "Rejected"), ProjectMemoryHealthCardModel.placeholder)
        XCTAssertEqual(try value(model, "Skipped"), ProjectMemoryHealthCardModel.placeholder)
        XCTAssertTrue(MemorySyncStatusModel.counterProvenanceNote.contains("not measured here"))
        XCTAssertTrue(MemorySyncStatusModel.counterProvenanceNote.contains("memory engine"))
    }

    func test_the_permanent_skipped_floor_is_labelled_as_expected() {
        let note = MemorySyncStatusModel.permanentSkippedFloorNote
        XCTAssertTrue(note.contains("projectID"), "the floor's CAUSE must be named")
        XCTAssertTrue(note.contains("not a fault"), "the floor must be labelled as expected, not as a failure")
        XCTAssertTrue(note.contains("memory_facts"), "the collection the floor lives in must be named")
    }

    // MARK: - Counts are reported, not invented

    func test_the_inbox_counts_are_reported_verbatim() throws {
        let model = self.model(parked: 7, merged: 31)
        XCTAssertEqual(try value(model, "Parked"), "7")
        XCTAssertEqual(try value(model, "Merged (30 d)"), "31")
        XCTAssertEqual(model.parkedRows, 7)
        XCTAssertEqual(model.mergedRows, 31)
    }

    // MARK: - The consent marker, on the daemon's own reading rule

    func test_a_present_marker_naming_this_member_is_aged() throws {
        XCTAssertEqual(try value(model(marker: 600), "Consent marker"), "10 min ago")
    }

    func test_an_ambiguous_marker_table_renders_no_consent_and_never_just_now() throws {
        // Two rows in the table. The daemon counts BEFORE it looks at
        // freshness, so this is a NO-CONSENT state however fresh either row is
        // — and the diagnostic a member opens *because* memories are not
        // arriving must not answer "just now".
        let ambiguous = model(marker: 1, markerAmbiguous: true)
        XCTAssertEqual(try value(ambiguous, "Consent marker"), ProjectMemoryHealthCardModel.placeholder)
        XCTAssertNotEqual(try value(ambiguous, "Consent marker"), "just now")
    }

    func test_no_marker_at_all_renders_the_same_no_consent_state() throws {
        // Zero rows and two rows are the SAME answer — the daemon reads both as
        // no consent — so they must render identically.
        XCTAssertEqual(
            try value(model(marker: nil), "Consent marker"),
            try value(model(marker: 1, markerAmbiguous: true), "Consent marker")
        )
        XCTAssertEqual(try value(model(marker: nil), "Consent marker"), ProjectMemoryHealthCardModel.placeholder)
    }

    func test_a_marker_naming_another_member_is_named_rather_than_aged() throws {
        // The shared-Mac case the marker design exists for: the daemon scopes
        // every drain to the member the marker names, so reporting its age to
        // somebody else would be a true number about the wrong account.
        let foreign = model(marker: 60, markerAccount: "uid-other")
        XCTAssertEqual(try value(foreign, "Consent marker"), MemorySyncStatusModel.markerNamesAnotherMember)
        XCTAssertNotEqual(try value(foreign, "Consent marker"), "just now")
    }

    func test_the_dash_on_the_marker_is_explained_and_points_at_the_card() {
        let note = MemorySyncStatusModel.markerReadingNote
        XCTAssertTrue(note.contains("NO consent"), "a dash on the marker must be labelled, not left to be read as a bug")
        XCTAssertTrue(note.contains("more than one"), "the ambiguous-table state must be named")
        XCTAssertTrue(
            note.contains("Memory health card"),
            "the row must point at the surface that OWNS marker staleness rather than judging it itself"
        )
    }

    // MARK: - The row does not fork the health card

    func test_the_health_card_is_the_only_emitter_of_the_stale_marker_code() {
        // B1: the Memory health card ships in the same Settings section and
        // already emits SYNC_MARKER_STALE at the daemon's own bound. This row
        // is health-card INPUT — ages and counts — so a marker far past that
        // bound must move nothing here, while the card still raises it. Two
        // emitters of one code, 40px apart, is the regression.
        let staleBy = 10 * BurnBarMemoryDeviceSyncMarker.maxAge
        let refreshedAt = now.addingTimeInterval(-staleBy)

        let cardFindings = MemoryHealthLocalFindings.findings(
            snapshot: MemoryHealthLocalSnapshot(
                auditChainLinks: [],
                pendingReviewCount: 0,
                lastMemoryFactsPullAt: nil,
                deviceSyncMarkerRefreshedAt: refreshedAt
            ),
            secretScannerAvailable: true,
            now: now
        )
        XCTAssertTrue(
            cardFindings.contains { $0.code == MemoryHealthLocalFindings.syncMarkerStale },
            "The card must still own the finding this row deliberately does not duplicate"
        )

        let row = model(marker: staleBy)
        let mirror = Mirror(reflecting: row)
        XCTAssertFalse(
            mirror.children.contains { ($0.label ?? "").lowercased().contains("alert") },
            "The sync row must not carry an alert list of its own; the health card owns the findings"
        )
        for statRow in row.statRows {
            XCTAssertEqual(statRow.emphasis, .neutral, "\(statRow.title): the row reports, the card judges")
        }
    }

    func test_the_row_renders_the_health_card_s_age_buckets_verbatim() {
        // Comparing the row against the very formatter it calls would be true
        // by construction, so the expectations here are written INDEPENDENTLY:
        // the exact strings the health card ships. A re-forked formatter with
        // different buckets fails on the string; a formatter whose buckets
        // move at all fails on both halves at once, which is the point — the
        // two surfaces sit in one scroll and must not describe the same age
        // two different ways.
        let expected: [(TimeInterval, String)] = [
            (0, "just now"),
            (30, "just now"),
            (600, "10 min ago"),
            (7_200, "2 h ago"),
            (172_800, "2 d ago"),
            // A watermark stamped in the FUTURE (a clock skew between this Mac
            // and the writer) clamps to zero rather than rendering a negative
            // age.
            (-600, "just now")
        ]
        for (seconds, rendered) in expected {
            let instant = now.addingTimeInterval(-seconds)
            let row = MemorySyncStatusModel(
                snapshot: MemorySyncObservabilitySnapshot(
                    accountUid: "uid-1",
                    memoryFactsWatermarkAt: instant
                ),
                now: now
            ).factsWatermarkAge
            XCTAssertEqual(row, rendered, "seconds=\(seconds)")
            XCTAssertEqual(
                MemoryHealthLocalFindings.age(of: instant, now: now),
                rendered,
                "seconds=\(seconds): the card must render the same age the row does"
            )
        }
        XCTAssertEqual(MemoryHealthLocalFindings.unmeasured, ProjectMemoryHealthCardModel.placeholder)
    }

    // MARK: - Rendering

    func test_the_row_states_when_it_was_read() {
        // m2: the row is a one-shot read, so the ages are ages as of one
        // instant. It carries that instant rather than pretending to tick.
        XCTAssertEqual(model(marker: 60).readAt, now)
    }

    func test_the_row_reports_every_ledger_it_claims_to() {
        let titles = model().statRows.map(\.title)
        XCTAssertEqual(
            titles,
            ["Facts cursor", "Receipts cursor", "Consent marker", "Parked", "Merged (30 d)", "Rejected", "Skipped"],
            "Both cursors and the marker are the point of this row; dropping one is the regression"
        )
    }
}
