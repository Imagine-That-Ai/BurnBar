import XCTest
@testable import OpenBurnBar

/// B8: the timeline model is the app half of the project-scoped timeline read.
/// The loader closure stands in for `burnbar_memory_timeline`; the contract it
/// must satisfy is documented on `MemoryTimelineModel`.
@MainActor
final class MemoryTimelineModelTests: XCTestCase {

    private func revision(
        seq: Int,
        event: String,
        writerDevice: String? = nil,
        after: String? = nil,
        before: String? = nil
    ) -> MemoryTimelineModel.RevisionItem {
        MemoryTimelineModel.RevisionItem(
            seq: seq,
            event: event,
            actor: "user",
            timestamp: "2026-09-05T10:0\(seq):00Z",
            before: before,
            after: after,
            writerDevice: writerDevice
        )
    }

    /// Revisions render in `seq` order whatever order the read returned them in —
    /// the timeline is a history, so out-of-order rows would read as a lie.
    func test_timeline_returns_revisions_in_order() async {
        let created = revision(seq: 1, event: "created", writerDevice: "macbook-air", after: "Initial fact")
        let updated = revision(
            seq: 2,
            event: "updated",
            writerDevice: "macbook-pro",
            after: "Updated fact",
            before: "Initial fact"
        )
        let retired = revision(seq: 3, event: "retired", writerDevice: "macbook-pro")

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
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.revisions.map(\.seq), [1, 2, 3])
        XCTAssertEqual(model.revisions.map(\.displayEvent), ["Created", "Updated", "Retired"])
        XCTAssertEqual(model.revisions[1].before, "Initial fact")
        XCTAssertEqual(model.revisions[1].after, "Updated fact")
    }

    /// The writing device is the point of the packet: a member with two machines
    /// has to be able to see which one wrote a revision.
    func test_timeline_reports_the_writing_device_per_revision() async {
        let model = MemoryTimelineModel(memoryID: "mem_456") { memoryID, _ in
            MemoryTimelineModel.TimelineResult(
                memoryID: memoryID,
                revisions: [
                    self.revision(seq: 1, event: "created", writerDevice: "studio-ultra"),
                    self.revision(seq: 2, event: "synced", writerDevice: nil)
                ]
            )
        }

        await model.load()

        XCTAssertEqual(model.revisions.map(\.writerDevice), ["studio-ultra", nil])
        XCTAssertEqual(model.revisions[1].displayEvent, "Synced")
    }

    /// A foreign memory id is refused, and the refusal renders NOTHING — no
    /// revisions, no last-helped, no body. Even a server that refused and
    /// answered anyway cannot leak through this model.
    func test_a_refused_foreign_memory_shows_no_content() async {
        let model = MemoryTimelineModel(
            memoryID: "mem_foreign",
            projectPath: "/tmp/project-a"
        ) { memoryID, projectPath in
            XCTAssertEqual(projectPath, "/tmp/project-a")
            return MemoryTimelineModel.TimelineResult(
                status: "refused",
                memoryID: memoryID,
                revisions: [self.revision(seq: 1, event: "created", after: "leaked body")],
                lastHelpedAt: "2026-09-05T10:30:00Z",
                lastHelpedSource: "recall_serve",
                refusalCode: "FOREIGN_PROJECT"
            )
        }

        await model.load()

        XCTAssertTrue(model.isRefused)
        XCTAssertEqual(model.refusalCode, "FOREIGN_PROJECT")
        XCTAssertTrue(model.revisions.isEmpty)
        XCTAssertNil(model.lastHelpedAt)
        XCTAssertNil(model.lastHelpedSource)
    }

    /// "Last helped" carries its source, because a recall-serve event and a
    /// history event mean different things to a member deciding whether to keep
    /// a memory.
    func test_last_helped_carries_its_source() async {
        for source in ["recall_serve", "history"] {
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

    /// A read that never came back leaves the model empty and says why, rather
    /// than presenting an empty history as a fact about the memory.
    func test_a_failed_read_surfaces_an_error_and_no_revisions() async {
        struct TimelineUnavailable: LocalizedError {
            var errorDescription: String? { "Network timeout" }
        }

        let model = MemoryTimelineModel(memoryID: "mem_err") { _, _ in
            throw TimelineUnavailable()
        }

        await model.load()

        XCTAssertEqual(model.errorMessage, "Network timeout")
        XCTAssertFalse(model.isLoading)
        XCTAssertFalse(model.isRefused)
        XCTAssertTrue(model.revisions.isEmpty)
    }
}
