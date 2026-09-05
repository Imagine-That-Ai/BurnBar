import XCTest
@testable import OpenBurnBar

/// B8: the timeline model is the view half of a memory's history. Its loader
/// closure stands in for whichever history is being read — today the app's own
/// `memory_audit` ledger via `ControlPlaneStore.memoryTimeline`, tomorrow a
/// daemon-forwarded engine read — which is why every result carries `source`.
/// The contract it must satisfy is documented on `MemoryTimelineModel`.
@MainActor
final class MemoryTimelineModelTests: XCTestCase {

    private func revision(
        seq: Int,
        event: String,
        writerDevice: String? = nil,
        after: String? = nil,
        before: String? = nil,
        meta: [String: String] = [:]
    ) -> MemoryTimelineModel.RevisionItem {
        MemoryTimelineModel.RevisionItem(
            seq: seq,
            event: event,
            actor: "user",
            ts: "2026-09-05T10:0\(seq):00Z",
            before: before,
            after: after,
            writerDevice: writerDevice,
            meta: meta
        )
    }

    /// Revisions render in `seq` order whatever order the read returned them in —
    /// the timeline is a history, so out-of-order rows would read as a lie.
    func test_timeline_returns_revisions_in_order() async {
        let created = revision(seq: 1, event: "memory.add", writerDevice: "macbook-air")
        let updated = revision(seq: 2, event: "memory.update", writerDevice: "macbook-pro")
        let retired = revision(seq: 3, event: "memory.delete", writerDevice: "macbook-pro")

        let model = MemoryTimelineModel(memoryID: "mem_123") { memoryID, projectPath in
            XCTAssertEqual(memoryID, "mem_123")
            XCTAssertNil(projectPath)
            return MemoryTimelineModel.TimelineResult(
                memoryID: memoryID,
                revisions: [updated, retired, created]
            )
        }

        await model.load()

        XCTAssertFalse(model.isRefused)
        XCTAssertFalse(model.isNotFound)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.revisions.map(\.seq), [1, 2, 3])
        XCTAssertEqual(model.revisions.map(\.displayEvent), ["Created", "Updated", "Retired"])
        XCTAssertEqual(model.source, MemoryTimelineSource.appAudit)
    }

    /// The writing device is the point of the packet: a member with two machines
    /// has to be able to see which one wrote a revision — when the history being
    /// read records one at all.
    func test_timeline_reports_the_writing_device_per_revision() async {
        let model = MemoryTimelineModel(memoryID: "mem_456") { memoryID, _ in
            MemoryTimelineModel.TimelineResult(
                memoryID: memoryID,
                revisions: [
                    self.revision(seq: 1, event: "created", writerDevice: "studio-ultra"),
                    self.revision(seq: 2, event: "synced", writerDevice: nil)
                ],
                writerDevice: "studio-ultra"
            )
        }

        await model.load()

        XCTAssertEqual(model.revisions.map(\.writerDevice), ["studio-ultra", nil])
        XCTAssertEqual(model.revisions[1].displayEvent, "Synced")
        XCTAssertEqual(model.writerDevice, "studio-ultra")
    }

    /// A foreign memory id is refused, and the refusal renders NOTHING — no
    /// revisions, no lineage, no last-helped. Even a server that refused and
    /// answered anyway cannot leak through this model.
    func test_a_refused_foreign_memory_shows_no_content() async {
        let model = MemoryTimelineModel(
            memoryID: "mem_foreign",
            projectPath: "/tmp/project-a"
        ) { memoryID, projectPath in
            XCTAssertEqual(projectPath, "/tmp/project-a")
            return MemoryTimelineModel.TimelineResult(
                status: MemoryTimelineRecord.statusRefused,
                memoryID: memoryID,
                revisions: [self.revision(seq: 1, event: "created", after: "leaked body")],
                lastHelpedAt: "2026-09-05T10:30:00Z",
                lastHelpedSource: "recall_serve",
                code: "FOREIGN_PROJECT",
                validFrom: "2026-01-01T00:00:00Z",
                supersededBy: "mem_leak",
                writerDevice: "leaked-device"
            )
        }

        await model.load()

        XCTAssertTrue(model.isRefused)
        XCTAssertEqual(model.code, "FOREIGN_PROJECT")
        XCTAssertTrue(model.revisions.isEmpty)
        XCTAssertNil(model.lastHelpedAt)
        XCTAssertNil(model.lastHelpedSource)
        XCTAssertNil(model.validFrom)
        XCTAssertNil(model.supersededBy)
        XCTAssertNil(model.writerDevice)
    }

    /// "Last helped" carries its source, because a recall-serve event and a
    /// history event mean different things to a member deciding whether to keep
    /// a memory. The app's own ledger can only justify `history`.
    func test_last_helped_carries_its_source() async {
        for source in ["recall_serve", MemoryTimelineRecord.lastHelpedSourceHistory] {
            let model = MemoryTimelineModel(memoryID: "mem_helped") { memoryID, _ in
                MemoryTimelineModel.TimelineResult(
                    memoryID: memoryID,
                    lastHelpedAt: "2026-09-05T10:30:00Z",
                    lastHelpedSource: source
                )
            }

            await model.load()

            XCTAssertEqual(model.lastHelpedAt, "2026-09-05T10:30:00Z")
            XCTAssertEqual(model.lastHelpedSource, source)
        }
    }

    /// An id the history does not know is `not_found` — a distinct state from a
    /// successful read with no events, which the view must not render as
    /// "this memory has never been touched".
    func test_an_unknown_memory_is_not_found_rather_than_an_empty_success() async {
        let notFound = MemoryTimelineModel(memoryID: "mem_gone") { memoryID, _ in
            MemoryTimelineModel.TimelineResult(
                status: MemoryTimelineRecord.statusNotFound,
                memoryID: memoryID
            )
        }
        await notFound.load()
        XCTAssertTrue(notFound.isNotFound)
        XCTAssertFalse(notFound.isRefused)
        XCTAssertTrue(notFound.revisions.isEmpty)
        XCTAssertNil(notFound.errorMessage)

        let emptyOK = MemoryTimelineModel(memoryID: "mem_quiet") { memoryID, _ in
            MemoryTimelineModel.TimelineResult(memoryID: memoryID)
        }
        await emptyOK.load()
        XCTAssertFalse(emptyOK.isNotFound)
        XCTAssertTrue(emptyOK.revisions.isEmpty)
    }

    /// The app's ledger keeps no revision contents, and the result says so, so
    /// the view can tell the member "not retained" instead of leaving nil
    /// `before`/`after` to read as "unchanged".
    func test_a_result_that_retains_no_revision_bodies_says_so() async {
        let model = MemoryTimelineModel(memoryID: "mem_bodies") { memoryID, _ in
            MemoryTimelineModel.TimelineResult(
                memoryID: memoryID,
                revisions: [self.revision(seq: 1, event: "memory.add")]
            )
        }

        await model.load()

        XCTAssertFalse(model.revisionBodiesRetained)
        XCTAssertTrue(model.revisions.allSatisfy { $0.before == nil && $0.after == nil })
    }

    /// A read that never came back leaves the model empty and says why, rather
    /// than presenting an empty history as a fact about the memory.
    func test_a_failed_read_surfaces_an_error_and_no_revisions() async {
        let model = MemoryTimelineModel(memoryID: "mem_err") { _, _ in
            throw MemoryTimelineError.historyUnavailable("no such table: memory_audit")
        }

        await model.load()

        XCTAssertEqual(model.errorMessage, "History unavailable — no such table: memory_audit")
        XCTAssertFalse(model.isLoading)
        XCTAssertFalse(model.isRefused)
        XCTAssertFalse(model.isNotFound)
        XCTAssertTrue(model.revisions.isEmpty)
    }
}
