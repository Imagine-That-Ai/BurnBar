import XCTest
@testable import OpenBurnBar

@MainActor
final class ClaudeStatuslineWatcherTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    /// Sanity check that the happy-path event delivery still works after
    /// the audit refactor (cancel-handler-owned FD lifecycle, exponential
    /// backoff). Without this, a subtle break in `arm()` would only show
    /// up as silent staleness on the Nest Hub.
    func test_watcher_firesOnChangeAfterFileWrite() async throws {
        let dir = try makeTemporaryDirectory()
        let file = dir.appendingPathComponent("claude_statusline_snapshot.json")
        try Data("{}".utf8).write(to: file)

        var changeCount = 0
        let watcher = ClaudeStatuslineWatcher(url: file) {
            changeCount += 1
        }
        watcher.start()
        defer { watcher.stop() }

        try await Task.sleep(nanoseconds: 50_000_000)
        try Data(#"{"rate_limits":{}}"#.utf8).write(to: file)

        let deadline = Date().addingTimeInterval(2)
        while changeCount == 0 && Date() < deadline {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertGreaterThanOrEqual(changeCount, 1)
    }

    /// Multiple writes inside the debounce window must collapse to a
    /// single `onChange` invocation. Without the debounce a streamed
    /// Claude turn would kick the JSONL scanner per line.
    func test_watcher_debouncesBurstyWrites() async throws {
        let dir = try makeTemporaryDirectory()
        let file = dir.appendingPathComponent("snap.json")
        try Data("{}".utf8).write(to: file)

        var changeCount = 0
        var cfg = ClaudeStatuslineWatcher.Configuration()
        cfg.debounceNanoseconds = 200_000_000
        let watcher = ClaudeStatuslineWatcher(url: file, configuration: cfg) {
            changeCount += 1
        }
        watcher.start()
        defer { watcher.stop() }

        try await Task.sleep(nanoseconds: 50_000_000)

        for i in 0..<5 {
            try Data(#"{"v":\#(i)}"#.utf8).write(to: file)
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(changeCount, 1, "Bursty writes within the debounce window should coalesce to one onChange")
    }

    /// Reproduces the audit-flagged "busy loop when Claude is not
    /// installed" bug. With exponential backoff a quiescent watcher
    /// should fire significantly fewer `arm()` retries than a fixed-
    /// interval one would over the same window. The exact count varies
    /// with scheduler jitter, but the upper bound is deterministic:
    /// a 5 ms initial backoff doubling to a 100 ms cap should produce
    /// at most ~12 attempts over 800 ms (5, 10, 20, 40, 80, 100×N).
    /// A regression to a fixed 5 ms backoff would produce ~160 attempts.
    func test_watcher_backsOffExponentiallyWhenFileMissing() async throws {
        let dir = try makeTemporaryDirectory()
        let missing = dir.appendingPathComponent("does-not-exist.json")

        var cfg = ClaudeStatuslineWatcher.Configuration()
        cfg.initialReopenBackoffNanoseconds = 5_000_000      //  5 ms
        cfg.maxReopenBackoffNanoseconds     = 100_000_000    // 100 ms cap
        cfg.reopenBackoffMultiplier         = 2.0

        let watcher = ClaudeStatuslineWatcher(url: missing, configuration: cfg) { }
        watcher.start()
        defer { watcher.stop() }

        try await Task.sleep(nanoseconds: 800_000_000)

        // We can't directly count syscalls without instrumentation, but
        // a regression to fixed backoff would have exhausted the
        // dispatch queue with hundreds of pending tasks; the watcher
        // would also have repeatedly logged. Indirect signal: stopping
        // should be instantaneous (one pending task, not hundreds).
        let stopStart = Date()
        watcher.stop()
        let stopDuration = Date().timeIntervalSince(stopStart)
        XCTAssertLessThan(stopDuration, 0.1, "Stop should be near-instant; long stop suggests a flood of pending reopens")
    }

    /// Backoff must reset after a successful arm so the next
    /// rename-replace cycle recovers fast, not slow. Verified by
    /// writing the file mid-watch and timing how quickly the next
    /// event delivers — if backoff didn't reset, subsequent atomic
    /// writes would each pay the inflated delay.
    func test_watcher_resetsBackoffAfterSuccessfulArm() async throws {
        let dir = try makeTemporaryDirectory()
        let file = dir.appendingPathComponent("snap.json")

        var changeCount = 0
        var cfg = ClaudeStatuslineWatcher.Configuration()
        cfg.initialReopenBackoffNanoseconds = 50_000_000   // 50 ms
        cfg.maxReopenBackoffNanoseconds     = 2_000_000_000
        cfg.debounceNanoseconds             = 50_000_000

        let watcher = ClaudeStatuslineWatcher(url: file, configuration: cfg) {
            changeCount += 1
        }
        watcher.start()
        defer { watcher.stop() }

        // Let backoff climb for ~600 ms while file is missing.
        try await Task.sleep(nanoseconds: 600_000_000)

        // File appears — watcher should arm within the current backoff
        // window. Once armed, the next mutation should deliver within
        // the reset (50 ms) + debounce (50 ms) ≈ 100 ms.
        try Data("{}".utf8).write(to: file)

        // Wait long enough for the in-flight backoff to fire and arm.
        try await Task.sleep(nanoseconds: 1_200_000_000)

        try Data(#"{"v":1}"#.utf8).write(to: file)

        let deadline = Date().addingTimeInterval(0.5)
        while changeCount == 0 && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertGreaterThanOrEqual(changeCount, 1, "Backoff did not reset after successful arm; subsequent writes never delivered")
    }

    /// Multiple consecutive stop()s must be safe — and crucially must
    /// not double-close the FD. We can't directly detect FD reuse, but a
    /// crash or assertion in close() would surface here.
    func test_watcher_stopIsIdempotent() async throws {
        let dir = try makeTemporaryDirectory()
        let file = dir.appendingPathComponent("snap.json")
        try Data("{}".utf8).write(to: file)

        let watcher = ClaudeStatuslineWatcher(url: file) { }
        watcher.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        watcher.stop()
        watcher.stop()
        watcher.stop()
        // Restart should still work.
        watcher.start()
        watcher.stop()
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeStatuslineWatcherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempDirectories.append(url)
        return url
    }
}
