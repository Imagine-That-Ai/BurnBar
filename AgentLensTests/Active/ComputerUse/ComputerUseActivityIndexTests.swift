#if canImport(AppKit) && !DISTRIBUTION_MAS
import XCTest
import OpenBurnBarComputerUseCore
@testable import OpenBurnBar

/// Drives `ComputerUseActivityIndex` against a real temp directory.
///
/// The interesting cases are all failure-shaped — a session killed mid-write, a manifest
/// that will not decode, a directory with nothing in it. Those are exactly the states a
/// user is most likely to be looking at when they open this screen (something went wrong,
/// so they came to check), and exactly the states that are hard to produce from a live
/// session. Hence a temp directory rather than a fixture of happy-path output.
final class ComputerUseActivityIndexTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-activity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func index() -> ComputerUseActivityIndex {
        ComputerUseActivityIndex(baseDirectory: root)
    }

    // MARK: Fixture builders

    @discardableResult
    private func makeSession(
        id: String,
        startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        entries: [ComputerUseAuditEntry] = [],
        manifest: Bool = true,
        truncatedTail: Bool = false
    ) throws -> URL {
        let dir = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Build real types and serialise with the production encoder rather than
        // hand-writing JSON. An earlier version of this test hand-rolled the manifest and
        // silently tested a format the app never writes -- the canonical codec stores
        // dates as milliseconds since epoch, not `timeIntervalSinceReferenceDate`, so the
        // fixtures decoded into wrong timestamps and the ordering assertions passed for
        // the wrong reason. Encoding through `canonicalJSONEncoder` means these tests are
        // pinned to the real on-disk contract and will fail if that contract moves.
        let encoder = ComputerUseAuditHasher.canonicalJSONEncoder

        if manifest {
            let value = ComputerUseSessionManifest(
                sessionId: ComputerUseSessionID(rawValue: id),
                mode: .agentWatch,
                trustMode: .manual,
                startedAt: startedAt,
                userId: "u1",
                entitlementProductId: "test.product",
                actionCap: 100,
                sessionTimeoutSeconds: 600
            )
            try encoder.encode(value).write(to: dir.appendingPathComponent("manifest.json"))
        }

        var lines = try entries.map { try String(data: encoder.encode($0), encoding: .utf8) ?? "" }
        if truncatedTail {
            // A session killed mid-write leaves a half-line. Everything before it is
            // still real and must survive.
            lines.append("{\"sessionId\":\"\(id)\",\"entryIn")
        }
        if !lines.isEmpty {
            try Data(lines.joined(separator: "\n").utf8)
                .write(to: dir.appendingPathComponent("chain.jsonl"))
        }
        return dir
    }

    private func entry(
        _ index: Int,
        session: String,
        kind: String = "click",
        approvedBy: ComputerUseAuditEntry.ApprovedBy = .mac,
        beforeShot: String? = nil,
        afterShot: String? = nil,
        at seconds: TimeInterval = 0
    ) -> ComputerUseAuditEntry {
        ComputerUseAuditEntry(
            sessionId: session,
            entryIndex: index,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + seconds),
            actionKind: kind,
            actionSummary: "\(kind) something",
            actionDescriptorHashHex: String(repeating: "a", count: 64),
            beforeScreenshotHashHex: beforeShot,
            afterScreenshotHashHex: afterShot,
            approvalId: nil,
            approvedBy: approvedBy,
            scopeRuleId: nil,
            denyReason: approvedBy == .denied ? "user rejected" : nil,
            parentEntryHashHex: String(repeating: "b", count: 64),
            macAppVersion: "1.0.0",
            macHostNodeId: nil
        )
    }

    // MARK: Empty state

    func test_noSessionsYieldsReassuringSummaryNotAnError() {
        let sessions = index().sessions()
        XCTAssertTrue(sessions.isEmpty)
        let summary = index().plainLanguageSummary(sessions)
        XCTAssertTrue(
            summary.contains("No agent has seen or touched this Mac yet"),
            "the empty state must read as reassurance, not as a missing-data error: \(summary)"
        )
    }

    func test_missingBaseDirectoryIsEmptyNotACrash() {
        let missing = ComputerUseActivityIndex(
            baseDirectory: root.appendingPathComponent("does-not-exist", isDirectory: true)
        )
        XCTAssertTrue(missing.sessions().isEmpty)
        XCTAssertEqual(missing.totalSessionCount(), 0)
    }

    // MARK: Counting

    func test_countsActionsApprovalsRejectionsAndScreenshots() throws {
        try makeSession(id: "s1", entries: [
            entry(0, session: "s1", beforeShot: "aa", afterShot: "bb"),
            entry(1, session: "s1", kind: "type"),
            entry(2, session: "s1", approvedBy: .denied)
        ])

        let session = try XCTUnwrap(index().sessions().first)
        XCTAssertEqual(session.actionCount, 3)
        XCTAssertEqual(session.approvedCount, 2)
        XCTAssertEqual(session.rejectedCount, 1)
        XCTAssertEqual(session.screenshotCount, 2, "two hashes on one entry is two screenshots")
        XCTAssertFalse(session.panicHalted)
        XCTAssertFalse(session.isDegraded)
    }

    /// Screenshots are counted from the chain, not the folder, so a stray file left by a
    /// crashed session cannot inflate a number the user is being asked to trust.
    func test_screenshotCountIgnoresStrayFilesOnDisk() throws {
        let dir = try makeSession(id: "s1", entries: [entry(0, session: "s1")])
        let shots = dir.appendingPathComponent("screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        try Data("not a real capture".utf8).write(to: shots.appendingPathComponent("000001-orphan.png"))

        XCTAssertEqual(try XCTUnwrap(index().sessions().first).screenshotCount, 0)
    }

    func test_panicHaltIsSurfaced() throws {
        try makeSession(id: "s1", entries: [
            entry(0, session: "s1"),
            entry(1, session: "s1", approvedBy: .panic)
        ])
        XCTAssertTrue(try XCTUnwrap(index().sessions().first).panicHalted)
        XCTAssertTrue(index().plainLanguageSummary(index().sessions()).contains("halted early"))
    }

    // MARK: Damage tolerance

    /// The load-bearing one. A session killed mid-write is precisely when someone opens
    /// this screen; losing the preceding actions would be worst possible behaviour.
    func test_truncatedFinalLineKeepsEveryCompleteEntry() throws {
        try makeSession(
            id: "s1",
            entries: [entry(0, session: "s1"), entry(1, session: "s1")],
            truncatedTail: true
        )
        XCTAssertEqual(try XCTUnwrap(index().sessions().first).actionCount, 2)
    }

    func test_unreadableManifestDegradesTheRowRatherThanHidingIt() throws {
        let dir = try makeSession(id: "s1", entries: [entry(0, session: "s1")], manifest: false)
        try Data("{ not json".utf8).write(to: dir.appendingPathComponent("manifest.json"))

        let session = try XCTUnwrap(index().sessions().first)
        XCTAssertTrue(session.isDegraded, "a corrupt manifest must flag the row")
        XCTAssertEqual(session.actionCount, 1, "...and must not discard the chain")
        XCTAssertNotNil(session.startedAt, "falls back to the first entry's timestamp")
    }

    func test_sessionWithNoChainStillListed() throws {
        try makeSession(id: "s1")
        let session = try XCTUnwrap(index().sessions().first)
        XCTAssertEqual(session.actionCount, 0)
        XCTAssertNotNil(session.startedAt)
    }

    // MARK: Ordering and truncation honesty

    func test_sessionsAreNewestFirst() throws {
        try makeSession(id: "older", startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try makeSession(id: "newer", startedAt: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(index().sessions().map(\.sessionId), ["newer", "older"])
    }

    /// A limit must not quietly hide sessions on a screen whose whole job is disclosure.
    func test_limitTruncatesButTotalCountStillTellsTheTruth() throws {
        for i in 0..<5 {
            try makeSession(id: "s\(i)", startedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)))
        }
        XCTAssertEqual(index().sessions(limit: 2).count, 2)
        XCTAssertEqual(index().totalSessionCount(), 5, "the UI must be able to say how many were hidden")
    }

    func test_zeroLimitIsSafe() throws {
        try makeSession(id: "s1")
        XCTAssertTrue(index().sessions(limit: 0).isEmpty)
        XCTAssertTrue(index().sessions(limit: -1).isEmpty)
    }

    // MARK: Summary copy

    func test_summaryPluralisesAndReportsRejections() throws {
        try makeSession(id: "s1", entries: [
            entry(0, session: "s1"),
            entry(1, session: "s1", approvedBy: .denied)
        ])
        let summary = index().plainLanguageSummary(index().sessions())
        XCTAssertTrue(summary.contains("1 session,"), summary)
        XCTAssertTrue(summary.contains("2 actions"), summary)
        XCTAssertTrue(summary.contains("1 of them stopped by you"), summary)
    }

    func test_entriesForSessionAreReturnedInOrder() throws {
        try makeSession(id: "s1", entries: [
            entry(0, session: "s1", kind: "click", at: 0),
            entry(1, session: "s1", kind: "type", at: 10)
        ])
        XCTAssertEqual(index().entries(sessionId: "s1").map(\.actionKind), ["click", "type"])
    }
}
#endif
