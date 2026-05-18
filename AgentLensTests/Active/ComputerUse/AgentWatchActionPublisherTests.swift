#if canImport(AppKit) && !DISTRIBUTION_MAS
import XCTest
import OpenBurnBarCore
import OpenBurnBarMedia
@testable import OpenBurnBar

@MainActor
final class AgentWatchActionPublisherTests: XCTestCase {
    func testPublishesControlActionLogFrameWithSessionAndStreamClass() async throws {
        let capture = AgentWatchFrameCapture()
        let publisher = AgentWatchActionPublisher(
            sessionId: "session-watch",
            uid: "uid-watch",
            connectionId: "conn-watch",
            sink: { frame in await capture.record(frame) }
        )

        try await publisher.publish(event(
            kind: .approvalRequested,
            payload: .object(["summary": .string("Approve browser click")]),
            emittedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))

        let frame = try await capture.onlyFrame()
        XCTAssertEqual(frame.type, .controlActionLogEntry)
        XCTAssertEqual(frame.uid, "uid-watch")
        XCTAssertEqual(frame.connectionId, "conn-watch")
        XCTAssertEqual(frame.control?.streamClass, MediaStreamClass.controlActionLog.rawValue)
        XCTAssertEqual(frame.control?.sessionId, "session-watch")
        XCTAssertEqual(frame.control?.actionLogEntry?.entryIndex, 0)
        XCTAssertEqual(frame.control?.actionLogEntry?.actionKind, BurnBarRunJournalEventKind.approvalRequested.rawValue)
        XCTAssertEqual(frame.control?.actionLogEntry?.summary, "Approve browser click")
        XCTAssertEqual(frame.control?.actionLogEntry?.status, .awaitingApproval)
    }

    func testMapsJournalEventKindsToPhoneTimelineStatuses() async throws {
        let capture = AgentWatchFrameCapture()
        let publisher = AgentWatchActionPublisher(
            sessionId: "session-status",
            uid: "uid-status",
            connectionId: "conn-status",
            sink: { frame in await capture.record(frame) }
        )

        try await publisher.publish(event(kind: .runCreated, payload: .object(["title": .string("Started")]), emittedAt: Date(timeIntervalSince1970: 1)))
        try await publisher.publish(event(kind: .toolDispatched, payload: .object(["tool": .string("browser.click")]), emittedAt: Date(timeIntervalSince1970: 2)))
        try await publisher.publish(event(kind: .toolCompleted, payload: .object(["message": .string("Clicked")]), emittedAt: Date(timeIntervalSince1970: 3)))
        try await publisher.publish(event(kind: .runFailed, payload: .object(["error": .string("Timed out")]), emittedAt: Date(timeIntervalSince1970: 4)))
        try await publisher.publish(event(kind: .runCancelled, payload: nil, emittedAt: Date(timeIntervalSince1970: 5)))

        let entries = await capture.frames.compactMap(\.control?.actionLogEntry)
        XCTAssertEqual(entries.map(\.entryIndex), [0, 1, 2, 3, 4])
        XCTAssertEqual(entries.map(\.status), [.planned, .executing, .completed, .failed, .failed])
        XCTAssertEqual(entries.map(\.summary), ["Started", "browser.click", "Clicked", "Timed out", "run cancelled"])
    }

    func testDirectEntryPublishPreservesAuditMetadataForReceiver() async throws {
        let capture = AgentWatchFrameCapture()
        let publisher = AgentWatchActionPublisher(
            sessionId: "session-direct",
            uid: "uid-direct",
            connectionId: "conn-direct",
            sink: { frame in await capture.record(frame) }
        )
        let entry = HermesRealtimeRelayActionLogEntry(
            entryIndex: 42,
            timestamp: Date(timeIntervalSince1970: 42),
            actionKind: "browser.click",
            summary: "Click Submit",
            status: .completed,
            screenshotHashBlake3: "shot-hash",
            parentEntryBlake3: "audit-head"
        )

        try await publisher.publish(entry)

        let sent = try await capture.onlyFrame().control?.actionLogEntry
        XCTAssertEqual(sent, entry)
    }

    private func event(
        kind: BurnBarRunJournalEventKind,
        payload: BurnBarJSONValue?,
        emittedAt: Date
    ) -> BurnBarRunJournalEvent {
        BurnBarRunJournalEvent(
            eventID: "event-\(kind.rawValue)-\(emittedAt.timeIntervalSince1970)",
            runID: BurnBarRunID(rawValue: "run-agent-watch"),
            kind: kind,
            payload: payload,
            emittedAt: emittedAt
        )
    }
}

private actor AgentWatchFrameCapture {
    private(set) var frames: [HermesRealtimeRelayFrame] = []

    func record(_ frame: HermesRealtimeRelayFrame) {
        frames.append(frame)
    }

    func onlyFrame() throws -> HermesRealtimeRelayFrame {
        XCTAssertEqual(frames.count, 1)
        return try XCTUnwrap(frames.first)
    }
}
#endif
