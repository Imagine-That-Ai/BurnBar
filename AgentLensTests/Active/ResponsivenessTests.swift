import AppKit
import GRDB
import OpenBurnBarCore
import XCTest
@testable import OpenBurnBar

@MainActor
final class ResponsivenessTests: XCTestCase {
    func testManualScrollPausesFollowingUntilBottomOrExplicitResume() {
        var follow = ChatScrollFollowState()
        XCTAssertTrue(follow.shouldFollow)
        follow.userScrolled(distanceToBottom: 500, isScrolling: true)
        XCTAssertFalse(follow.shouldFollow)
        follow.userScrolled(distanceToBottom: 500, isScrolling: false)
        XCTAssertFalse(follow.shouldFollow, "A finished gesture must not snap back down.")
        follow.userScrolled(distanceToBottom: 20, isScrolling: true)
        XCTAssertFalse(follow.shouldFollow, "Momentum still owns the scroll view.")
        follow.userScrolled(distanceToBottom: 20, isScrolling: false)
        XCTAssertTrue(follow.shouldFollow)
        follow.pause()
        XCTAssertFalse(follow.shouldFollow, "Citation navigation owns the viewport.")
        follow.resume()
        XCTAssertTrue(follow.shouldFollow)
        follow.userScrolled(distanceToBottom: .nan, isScrolling: false)
        XCTAssertFalse(follow.shouldFollow)
    }

    func testThreadChangesResumeOnceWithoutUndoingCitationOwnership() {
        var follow = ChatScrollFollowState()
        follow.switchThread(to: "first")
        follow.pause()
        follow.switchThread(to: "first")
        XCTAssertFalse(follow.shouldFollow)
        follow.switchThread(to: "second")
        XCTAssertTrue(follow.shouldFollow)
        follow.pause()
        follow.switchThread(to: "second")
        XCTAssertFalse(follow.shouldFollow, "Late thread observers must not undo a citation jump.")
    }

    func testNativeScrollProbeIgnoresLayoutButReportsUserScrollAndDetaches() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let document = FlippedTranscriptDocument(frame: NSRect(x: 0, y: 0, width: 300, height: 2_000))
        scroll.documentView = document
        let probe = ChatScrollViewportProbe.ProbeView()
        var readings: [(CGFloat, Bool)] = []
        probe.onUserScroll = { readings.append(($0, $1)) }
        document.addSubview(probe)
        probe.attachIfNeeded()

        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        XCTAssertTrue(readings.isEmpty, "Layout alone cannot disengage sticky-bottom.")
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        XCTAssertEqual(readings.last?.1, true)
        XCTAssertGreaterThan(readings.last?.0 ?? 0, 1_000)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 1_800))
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        XCTAssertEqual(readings.last?.1, false)
        XCTAssertLessThanOrEqual(readings.last?.0 ?? .infinity, 64)
        probe.detach()
        let count = readings.count
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        XCTAssertEqual(readings.count, count)
    }

    func testTranscriptPreparationPreservesAllContentAndExportOverride() async throws {
        let text = (0..<1_000).map { "## You\nQuestion \($0)\n## Assistant\nAnswer \($0)\n```swift\nlet n = \($0)\n```" }
            .joined(separator: "\n")
        let input = SessionTranscriptInput(record: record(text), overrideBody: "# Export override")
        let result = try await SessionTranscriptPreparation.prepare(input)
        XCTAssertEqual(result.blocks.count, 3_000)
        XCTAssertEqual(result.blocks.first?.content, "Question 0")
        XCTAssertEqual(result.blocks.last?.content, "let n = 999")
        XCTAssertEqual(result.markdown, "# Export override")
        XCTAssertEqual(result.blocks.map(\.content), TranscriptBlockParser.parse(text).map(\.content))
    }

    func testCancelledTranscriptPreparationDoesNotPublishPartialContent() async {
        for text in ["", String(repeating: "## You\nQuestion\n", count: 20_000)] {
            let input = SessionTranscriptInput(record: record(text), overrideBody: nil)
            let task = Task { try await SessionTranscriptPreparation.prepare(input) }
            task.cancel()
            do {
                _ = try await task.value
                XCTFail("A superseded preparation must not publish.")
            } catch is CancellationError {
                // Expected: a newer source revision owns the result.
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testCancellationInterruptsLargeSectionsAndTagStripping() {
        let sections = ["```swift\n", "## You\n", "## Assistant\n", "## Assistant\n```swift\n", "Human:\n", "Assistant:\n", "Plain\n"]
        let transcripts = sections.map { $0 + String(repeating: "line\n", count: 5_000) }
            + [String(repeating: "| key | value |\n", count: 5_000)]
        for transcript in transcripts {
            var checks = 0
            let blocks = TranscriptBlockParser.parse(transcript) {
                checks += 1
                return checks == 32
            }
            XCTAssertTrue(blocks.isEmpty)
            XCTAssertEqual(checks, 32, "Each long section must observe cancellation before completion.")
        }
        var checks = 0
        let stripped = TranscriptBlockParser.stripSystemTags("<system-reminder>Hidden</system-reminder>Visible") {
            checks += 1
            return checks == 3
        }
        XCTAssertTrue(stripped.isEmpty)
        XCTAssertEqual(checks, 3)
    }

    func testTranscriptExportUpdateReusesBlocksButTextRevisionInvalidatesThem() async throws {
        let input = SessionTranscriptInput(record: record("## You\nOriginal"), overrideBody: nil)
        let first = try await SessionTranscriptPreparation.prepare(input)
        let exported = try await SessionTranscriptPreparation.prepare(
            SessionTranscriptInput(record: input.record, overrideBody: "# Cloud export"),
            reusing: first
        )
        XCTAssertEqual(exported.markdown, "# Cloud export")
        XCTAssertEqual(exported.blocks.map(\.content), first.blocks.map(\.content))
        first.blocks.withUnsafeBufferPointer { original in
            exported.blocks.withUnsafeBufferPointer { reused in
                XCTAssertEqual(original.baseAddress, reused.baseAddress, "Export updates must not allocate new blocks.")
            }
        }
        let updated = try await SessionTranscriptPreparation.prepare(
            SessionTranscriptInput(record: record("## Assistant\nUpdated"), overrideBody: nil),
            reusing: exported
        )
        XCTAssertEqual(updated.sourceText, "## Assistant\nUpdated")
        XCTAssertEqual(updated.blocks.first?.content, "Updated")
        XCTAssertNotEqual(updated.markdown, exported.markdown)
    }

    func testWindowProbeSharesScrollOwnershipAndIgnoresOtherWindows() async {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        window.contentView?.addSubview(scroll)
        let probe = BurnBarKernelVisibilityProbe.ProbeView()
        var states: [BurnBarKernelWindowState] = []
        let initial = expectation(description: "Initial window state")
        let started = expectation(description: "Scrolling started")
        let ended = expectation(description: "Scrolling ended")
        probe.onChange = {
            states.append($0)
            if states.count == 1 {
                initial.fulfill()
            } else if $0.isScrolling {
                started.fulfill()
            } else {
                ended.fulfill()
            }
        }
        window.contentView?.addSubview(probe)
        await fulfillment(of: [initial], timeout: 2)
        let center = NotificationCenter.default
        center.post(name: NSScrollView.willStartLiveScrollNotification, object: NSScrollView())
        await Task.yield()
        XCTAssertFalse(states.last?.isScrolling ?? true)
        center.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(states.last?.isScrolling, true)
        center.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        await fulfillment(of: [ended], timeout: 2)
        XCTAssertEqual(states.last?.isScrolling, false)
        let count = states.count
        probe.detach()
        center.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        await Task.yield()
        XCTAssertEqual(states.count, count)
    }

    func testRemovingAScrollingPageDoesNotLeaveTheNextPagePaused() async {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let first = NSScrollView()
        let second = NSScrollView()
        let probe = BurnBarKernelVisibilityProbe.ProbeView()
        let started = expectation(description: "First page is scrolling")
        let settled = expectation(description: "Second page finished scrolling")
        var phase = 0
        probe.onChange = { state in
            if phase == 0, state.isScrolling {
                phase = 1
                started.fulfill()
            } else if phase == 2, !state.isScrolling {
                phase = 3
                settled.fulfill()
            }
        }
        window.contentView?.addSubview(first)
        window.contentView?.addSubview(probe)
        let center = NotificationCenter.default
        center.post(name: NSScrollView.willStartLiveScrollNotification, object: first)
        await fulfillment(of: [started], timeout: 2)
        // Navigation can remove the old scroller before an end notification.
        first.removeFromSuperview()
        window.contentView?.addSubview(second)
        phase = 2
        center.post(name: NSScrollView.willStartLiveScrollNotification, object: second)
        center.post(name: NSScrollView.didEndLiveScrollNotification, object: second)
        await fulfillment(of: [settled], timeout: 2)
        probe.detach()
    }

    func testWatcherLifecycleIsSerializedAndReleasesItsContext() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        weak var released: FileTreeEventStream?
        autoreleasepool {
            let stream = FileTreeEventStream(root: root, queue: DispatchQueue(label: "test.artifact-watcher")) { _ in }
            released = stream
            DispatchQueue.concurrentPerform(iterations: 16) { _ in
                XCTAssertTrue(stream.start())
                stream.stop()
            }
            stream.stop()
        }
        // FSEvents releases its retained context asynchronously after invalidation.
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while released != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(released)
    }

    func testDatabaseStartupRunsOpenerOffMainAndKeepsPresentationCold() async throws {
        let store = try await DataStoreCoordinator.openForStartup {
            XCTAssertFalse(Thread.isMainThread)
            return try DataStoreActor(databaseQueue: DatabaseQueue(), runMigrations: false)
        }
        XCTAssertNil(store.lastRefresh)
        XCTAssertTrue(store.usages.isEmpty)
    }

    func testDatabaseStartupPropagatesFailureWithoutCreatingFallbackStore() async {
        do {
            _ = try await DataStoreCoordinator.openForStartup { throw StartupProbeError.expected }
            XCTFail("Failed open must reach recovery, not an empty library.")
        } catch StartupProbeError.expected {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRetentionIsThrottledWithoutSuppressingNextDueRun() async throws {
        let store = try DataStore(databaseQueue: DatabaseQueue(), runMigrations: true, refreshOnInit: false)
        let orchestrator = RefreshOrchestrator(
            dataStore: store,
            settingsManager: .shared,
            quotaService: ProviderQuotaService(
                appPaths: OpenBurnBar.OpenBurnBarAppPaths(applicationSupportRoot: FileManager.default.temporaryDirectory),
                homeDirectoryURL: FileManager.default.temporaryDirectory,
                refreshProviders: []
            )
        )
        let now = Date()
        await orchestrator.runRetentionPurgeIfNeeded(now: now)
        let old = ViewTestFixtures.makeUsage(provider: .codex, sessionId: "expired-maintenance-probe")
        try await store.insert(old)
        try await store.actor.dbQueue.write { db in
            try db.execute(sql: "UPDATE token_usage SET startTime = ?, endTime = ?", arguments: [
                Date(timeIntervalSince1970: 1), Date(timeIntervalSince1970: 2)
            ])
        }
        await orchestrator.runRetentionPurgeIfNeeded(now: now.addingTimeInterval(10))
        let before = try await store.fetchAllUsage()
        XCTAssertEqual(before.count, 1)
        await orchestrator.runRetentionPurgeIfNeeded(now: now.addingTimeInterval(3_600))
        let after = try await store.fetchAllUsage()
        XCTAssertTrue(after.isEmpty)
    }

    func testUsageRetentionPreservesBoundaryAndAdvancesMarkerOnlyForDeletes() async throws {
        let store = try DataStore(databaseQueue: DatabaseQueue(), runMigrations: true, refreshOnInit: false)
        let cutoff = Date(timeIntervalSince1970: 1_700_000_000)
        for (id, offset) in [("expired", -1.0), ("boundary", 0.0), ("recent", 1.0)] {
            try await store.insert(ViewTestFixtures.makeUsage(
                provider: .codex, sessionId: id,
                startTime: cutoff.addingTimeInterval(offset), endTime: cutoff.addingTimeInterval(offset)
            ))
        }
        let before = await store.usageTableWriteMarker()
        let removed = try await store.reapUsageOlderThan(cutoff)
        XCTAssertEqual(removed, 1)
        let remaining = try await store.fetchAllUsage()
        XCTAssertEqual(Set(remaining.map(\.sessionId)), ["boundary", "recent"])
        let after = await store.usageTableWriteMarker()
        XCTAssertGreaterThan(after, before)
        let repeated = try await store.reapUsageOlderThan(cutoff)
        XCTAssertEqual(repeated, 0)
        let unchanged = await store.usageTableWriteMarker()
        XCTAssertEqual(unchanged, after)
    }

    private func record(_ text: String) -> ConversationRecord {
        ConversationRecord(
            id: "transcript-probe", provider: .codex, sessionId: "probe", projectName: "Fixture",
            startTime: nil, endTime: nil, messageCount: 0, userWordCount: 0, assistantWordCount: 0,
            keyFiles: [], keyCommands: [], keyTools: [], inferredTaskTitle: "Fixture",
            lastAssistantMessage: "", fullText: text, fileModifiedAt: nil, sourceType: .cliAssistant
        )
    }
}

private enum StartupProbeError: Error { case expected }

private final class FlippedTranscriptDocument: NSView {
    override var isFlipped: Bool { true }
}
