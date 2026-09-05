import GRDB
import OpenBurnBarCore
import XCTest
@testable import OpenBurnBar

/// B11: the card aggregates output that already exists — the counters
/// `daemon.memory.analytics` serves and the checks this Mac can run itself.
/// These tests pin it field-for-field against a response shaped exactly like
/// `BurnBarProjectCodeMemoryStore.memoryAnalytics` emits, and hold the two lines
/// the card must never cross: it may not claim engine doctor findings it never
/// ran, and it may not render an unreachable daemon as a project with zero
/// memories.
@MainActor
final class ProjectMemoryHealthCardTests: XCTestCase {

    private static let analytics = BurnBarProjectMemoryAnalyticsResponse(
        traceID: "trace-fixture",
        projectID: "proj_fixture_openburnbar_123",
        total: 42,
        byKind: ["fact": 30, "decision": 12],
        byScope: ["project": 40, "personal": 2],
        lastAuditHash: "b8f1c0de"
    )

    private func emptySnapshot(
        links: [MemoryAuditChainLink] = [],
        pendingReviewCount: Int = 0,
        lastPull: Date? = nil,
        markerRefreshedAt: Date? = nil
    ) -> MemoryHealthLocalSnapshot {
        MemoryHealthLocalSnapshot(
            auditChainLinks: links,
            pendingReviewCount: pendingReviewCount,
            lastMemoryFactsPullAt: lastPull,
            deviceSyncMarkerRefreshedAt: markerRefreshedAt
        )
    }

    // MARK: - Counters

    func test_health_card_matches_the_analytics_response_exactly_for_a_fixture_project() {
        let analytics = Self.analytics
        let card = ProjectMemoryHealthCardModel(
            analytics: analytics,
            projectName: "OpenBurnBar",
            projectRoot: "/Users/dewclaw/Documents/Projects/BurnBar"
        )

        XCTAssertEqual(card.projectID, analytics.projectID)
        XCTAssertEqual(card.projectName, "OpenBurnBar")
        XCTAssertEqual(card.projectRoot, "/Users/dewclaw/Documents/Projects/BurnBar")
        XCTAssertEqual(card.totalMemories, analytics.total)
        XCTAssertEqual(card.byKind, analytics.byKind)
        XCTAssertEqual(card.byScope, analytics.byScope)
        XCTAssertEqual(card.lastAuditHash, analytics.lastAuditHash)
        XCTAssertEqual(card.status, "ok")
        XCTAssertTrue(card.auditChainOK, "an unreported chain is not a broken one")
        XCTAssertEqual(card.errorCount, 0)
        XCTAssertEqual(card.warningCount, 0)
    }

    /// The rendered stats are pinned, not just the parsed model: this is what the
    /// member sees, placeholders included.
    func test_health_card_renders_a_placeholder_when_sync_observability_is_absent() {
        let card = ProjectMemoryHealthCardModel(
            analytics: Self.analytics,
            snapshot: emptySnapshot(),
            secretScannerAvailable: true
        )

        XCTAssertEqual(
            card.statRows.map { [$0.title, $0.value] },
            [
                ["Memories", "42"],
                ["Audit chain", "Intact"],
                ["Last pull", "—"],
                ["Marker age", "—"],
                ["Kinds", "2"]
            ],
            "a sync that has never run has no age, and the card says so"
        )
        XCTAssertEqual(card.lastPullAge, ProjectMemoryHealthCardModel.placeholder)
        XCTAssertEqual(card.markerAge, ProjectMemoryHealthCardModel.placeholder)
    }

    /// A minimal payload — a healthy store with nothing to report — must not
    /// invent counts, findings, or a broken audit chain.
    func test_a_minimal_analytics_payload_reports_nothing_rather_than_zeroes_it_did_not_measure() {
        let card = ProjectMemoryHealthCardModel(
            analytics: BurnBarProjectMemoryAnalyticsResponse(
                traceID: "trace-minimal",
                projectID: "proj_minimal_fixture",
                total: 0,
                byKind: [:],
                byScope: [:],
                lastAuditHash: nil
            ),
            snapshot: emptySnapshot(),
            secretScannerAvailable: true
        )

        XCTAssertEqual(card.status, "ok")
        XCTAssertEqual(card.projectID, "proj_minimal_fixture")
        XCTAssertNil(card.projectName)
        XCTAssertNil(card.projectRoot)
        XCTAssertEqual(card.totalMemories, 0, "the daemon answered zero; that is a measurement")
        XCTAssertNil(card.lastAuditHash)
        XCTAssertTrue(card.findings.isEmpty)
        XCTAssertTrue(card.auditChainOK)
        XCTAssertEqual(
            card.statRows.map(\.title),
            ["Memories", "Audit chain", "Last pull", "Marker age"],
            "counters the daemon did not report get no row at all"
        )
    }

    // MARK: - Audit chain

    /// A broken audit chain is the one thing on this card that must shout — and
    /// it is measured here, by walking `prev_hash`, not taken on trust.
    func test_a_broken_audit_chain_is_flagged() {
        let intact = [
            MemoryAuditChainLink(seq: 1, prevHash: nil, hash: "h1"),
            MemoryAuditChainLink(seq: 2, prevHash: "h1", hash: "h2"),
            MemoryAuditChainLink(seq: 3, prevHash: "h2", hash: "h3")
        ]
        XCTAssertNil(MemoryHealthLocalFindings.brokenChainSeq(in: intact))

        let broken = [
            MemoryAuditChainLink(seq: 15, prevHash: nil, hash: "h15"),
            MemoryAuditChainLink(seq: 16, prevHash: "h15", hash: "h16"),
            MemoryAuditChainLink(seq: 17, prevHash: "TAMPERED", hash: "h17")
        ]
        XCTAssertEqual(MemoryHealthLocalFindings.brokenChainSeq(in: broken), 17)

        let card = ProjectMemoryHealthCardModel(
            analytics: Self.analytics,
            snapshot: emptySnapshot(links: broken),
            secretScannerAvailable: true
        )

        XCTAssertFalse(card.auditChainOK)
        XCTAssertEqual(card.errorCount, 1)
        XCTAssertEqual(card.status, "degraded")
        let auditRow = card.statRows.first { $0.title == "Audit chain" }
        XCTAssertEqual(auditRow?.value, "Broken")
        XCTAssertEqual(auditRow?.emphasis, .bad)
        XCTAssertEqual(card.findings.first?.code, MemoryHealthLocalFindings.auditChainBroken)
        XCTAssertEqual(card.findings.first?.detail.contains("seq 17"), true)
    }

    // MARK: - No engine doctor claims

    /// The engine's doctor runs inside the Python engine against a store no
    /// Swift process reads. The card must therefore (a) carry only codes this
    /// Mac can actually measure and (b) say out loud that engine findings are
    /// not among them, so an empty list never reads as a clean bill of health.
    func test_the_card_does_not_claim_engine_doctor_findings_it_did_not_run() {
        let card = ProjectMemoryHealthCardModel(
            analytics: Self.analytics,
            snapshot: emptySnapshot(pendingReviewCount: 99, markerRefreshedAt: Date(timeIntervalSince1970: 0)),
            secretScannerAvailable: false,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertFalse(card.findings.isEmpty, "the app-producible checks did run")
        for finding in card.findings {
            XCTAssertTrue(
                MemoryHealthLocalFindings.allCodes.contains(finding.code),
                "\(finding.code) is not a code this Mac can measure"
            )
        }
        XCTAssertEqual(
            Set(card.findings.map(\.code)),
            [
                MemoryHealthLocalFindings.secretCorpusUnavailable,
                MemoryHealthLocalFindings.syncMarkerStale,
                MemoryHealthLocalFindings.pendingReviewBacklog
            ]
        )
        // Engine-only codes never appear.
        for engineCode in ["UNDECRYPTABLE_ROWS", "EMBEDDINGS_UNAVAILABLE", "LARGE_STORE"] {
            XCTAssertFalse(card.findings.contains { $0.code == engineCode })
        }
        XCTAssertEqual(
            card.engineDoctorNote,
            MemoryHealthLocalFindings.engineDoctorNotMeasuredNote
        )
        XCTAssertTrue(card.engineDoctorNote.contains("not measured here"))
    }

    // MARK: - Ages come from the watermarks

    /// The two ages are read from the real sync bookkeeping — the `memory_facts`
    /// watermark and the device-sync consent marker — not from a guess or a
    /// timer.
    func test_last_pull_and_marker_age_come_from_the_sync_watermarks() async throws {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        let store = ControlPlaneStore(dbQueue: queue)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let pulledAt = now.addingTimeInterval(-240)          // 4 minutes ago
        let markerRefreshedAt = now.addingTimeInterval(-7_200) // 2 hours ago

        try await queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO remote_sync_watermarks
                    (accountUid, collectionKind, lastSyncedAt, lastProcessedRemoteUpdateAt, version)
                VALUES (?, ?, ?, ?, 1)
                """,
                arguments: ["uid-1", RemoteSyncCollectionKind.memoryFacts.rawValue, pulledAt, pulledAt]
            )
            try db.execute(
                sql: """
                INSERT INTO remote_sync_watermarks
                    (accountUid, collectionKind, lastSyncedAt, lastProcessedRemoteUpdateAt, version)
                VALUES (?, ?, ?, NULL, 1)
                """,
                arguments: ["uid-1", BurnBarMemoryDeviceSyncMarker.collectionKind, markerRefreshedAt]
            )
        }

        let snapshot = try await store.memoryHealthLocalSnapshot(accountUid: "uid-1")
        XCTAssertEqual(
            try XCTUnwrap(snapshot.lastMemoryFactsPullAt).timeIntervalSince1970,
            pulledAt.timeIntervalSince1970,
            accuracy: 1
        )
        XCTAssertEqual(
            try XCTUnwrap(snapshot.deviceSyncMarkerRefreshedAt).timeIntervalSince1970,
            markerRefreshedAt.timeIntervalSince1970,
            accuracy: 1
        )

        let card = ProjectMemoryHealthCardModel(
            analytics: Self.analytics,
            snapshot: snapshot,
            secretScannerAvailable: true,
            now: now
        )
        XCTAssertEqual(card.statRows.first { $0.title == "Last pull" }?.value, "4 min ago")
        XCTAssertEqual(card.statRows.first { $0.title == "Marker age" }?.value, "2 h ago")

        // A marker older than its own age bound is a warning, not a silent pass.
        XCTAssertTrue(card.findings.contains { $0.code == MemoryHealthLocalFindings.syncMarkerStale })

        // Nobody signed in: the pull age is absent, not "never".
        let anonymous = try await store.memoryHealthLocalSnapshot(accountUid: nil)
        XCTAssertNil(anonymous.lastMemoryFactsPullAt)
        XCTAssertEqual(
            MemoryHealthLocalFindings.age(of: anonymous.lastMemoryFactsPullAt, now: now),
            ProjectMemoryHealthCardModel.placeholder
        )
    }

    // MARK: - Unreachable daemon

    /// The daemon owns the counters. When it cannot be asked, every counter is
    /// a dash — rendering `0` would tell the member their project has no
    /// memories, which nothing observed.
    func test_an_unreachable_daemon_renders_dashes_rather_than_zero() {
        let card = ProjectMemoryHealthCardModel(
            analytics: nil,
            snapshot: emptySnapshot(),
            secretScannerAvailable: true
        )

        XCTAssertNil(card.totalMemories)
        XCTAssertEqual(card.status, ProjectMemoryHealthCardModel.statusUnavailable)
        XCTAssertEqual(
            card.statRows.first { $0.title == "Memories" }?.value,
            ProjectMemoryHealthCardModel.placeholder
        )
        for row in card.statRows {
            XCTAssertNotEqual(row.value, "0", "\(row.title) must not report a zero nobody measured")
        }
        XCTAssertTrue(card.byKind.isEmpty)
        XCTAssertTrue(card.byScope.isEmpty)
    }
}
