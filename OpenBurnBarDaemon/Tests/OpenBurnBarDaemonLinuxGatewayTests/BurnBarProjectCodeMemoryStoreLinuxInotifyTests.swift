#if os(Linux)
import Foundation
@testable import OpenBurnBarDaemon
import XCTest

final class BurnBarProjectCodeMemoryStoreLinuxInotifyTests: XCTestCase {
    func testLinuxInotifyStreamDeliversEventsAndCancelClosesFileDescriptor() throws {
        let fixture = try makeFixture()
        let queue = DispatchQueue(label: "com.openburnbar.tests.linux-inotify")
        let event = DispatchSemaphore(value: 0)
        let baselineFileDescriptorCount = try openFileDescriptorCount()

        guard let stream = BurnBarProjectCodeMemoryStore._testOnlyMakeLinuxFileSystemEventStream(
            roots: [fixture.project],
            queue: queue,
            onEvent: {
                event.signal()
            }
        ) else {
            return XCTFail("expected Linux inotify stream to install at least one watch")
        }
        addTeardownBlock {
            BurnBarProjectCodeMemoryStore._testOnlyCancelLinuxFileSystemEventStream(stream)
        }

        let source = fixture.project.appendingPathComponent("Sources/Watched.swift", isDirectory: false)
        try write("func linuxInotifyNew() { print(\"new-linux-watch-token\") }\n", to: source)

        XCTAssertEqual(event.wait(timeout: .now() + 3.0), .success)

        BurnBarProjectCodeMemoryStore._testOnlyCancelLinuxFileSystemEventStream(stream)
        try waitForFileDescriptorCount(
            atMost: baselineFileDescriptorCount,
            timeout: 3.0
        )
    }

    func testLinuxInotifyStreamAddsWatchesForCreatedDirectories() throws {
        let fixture = try makeFixture()
        let queue = DispatchQueue(label: "com.openburnbar.tests.linux-inotify-created-dir")
        let events = DispatchSemaphore(value: 0)

        guard let stream = BurnBarProjectCodeMemoryStore._testOnlyMakeLinuxFileSystemEventStream(
            roots: [fixture.project],
            queue: queue,
            onEvent: {
                events.signal()
            }
        ) else {
            return XCTFail("expected Linux inotify stream to install at least one watch")
        }
        addTeardownBlock {
            BurnBarProjectCodeMemoryStore._testOnlyCancelLinuxFileSystemEventStream(stream)
        }

        let nested = fixture.project.appendingPathComponent("Sources/NewFeature", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        XCTAssertEqual(events.wait(timeout: .now() + 3.0), .success)

        let createdAfterDirectoryWatch = nested.appendingPathComponent("Fresh.swift", isDirectory: false)
        try write("func linuxInotifyNested() {}\n", to: createdAfterDirectoryWatch)
        XCTAssertEqual(events.wait(timeout: .now() + 3.0), .success)

        BurnBarProjectCodeMemoryStore._testOnlyCancelLinuxFileSystemEventStream(stream)
    }

    func testLinuxInotifyStreamRewatchDoesNotLeakFileDescriptors() throws {
        let fixture = try makeFixture()
        let queue = DispatchQueue(label: "com.openburnbar.tests.linux-inotify-fd")
        let baselineFileDescriptorCount = try openFileDescriptorCount()

        for _ in 0..<10 {
            guard let stream = BurnBarProjectCodeMemoryStore._testOnlyMakeLinuxFileSystemEventStream(
                roots: [fixture.project],
                queue: queue,
                onEvent: {}
            ) else {
                return XCTFail("expected Linux inotify stream to install at least one watch")
            }
            BurnBarProjectCodeMemoryStore._testOnlyCancelLinuxFileSystemEventStream(stream)
        }

        try waitForFileDescriptorCount(
            atMost: baselineFileDescriptorCount,
            timeout: 3.0
        )
    }

    func testLinuxInotifyStreamDeleteSelfRebuildsOnceAndContinuesWatching() throws {
        let fixture = try makeFixture()
        let queue = DispatchQueue(label: "com.openburnbar.tests.linux-inotify-delete-self")
        let events = LockedCounter()
        let rebuilds = LockedCounter()

        guard let stream = BurnBarProjectCodeMemoryStore._testOnlyMakeLinuxFileSystemEventStream(
            roots: [fixture.project],
            queue: queue,
            onEvent: {
                events.increment()
            },
            onRebuild: {
                rebuilds.increment()
            }
        ) else {
            return XCTFail("expected Linux inotify stream to install at least one watch")
        }
        addTeardownBlock {
            BurnBarProjectCodeMemoryStore._testOnlyCancelLinuxFileSystemEventStream(stream)
        }

        let watchedSubdirectory = fixture.project.appendingPathComponent("Sources/DeleteMe", isDirectory: true)
        try FileManager.default.createDirectory(at: watchedSubdirectory, withIntermediateDirectories: true)
        try waitUntil(timeout: 3.0) { events.value > 0 }

        let eventsBeforeDelete = events.value
        try FileManager.default.removeItem(at: watchedSubdirectory)
        try waitUntil(timeout: 3.0) { events.value > eventsBeforeDelete && rebuilds.value >= 1 }
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(rebuilds.value, 1)

        let eventsBeforeFollowUpCreate = events.value
        try write("func linuxInotifyAfterDeletedDirectory() {}\n", to: fixture.project.appendingPathComponent("Sources/AfterDelete.swift"))
        try waitUntil(timeout: 3.0) { events.value > eventsBeforeFollowUpCreate }
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(rebuilds.value, 1)

        BurnBarProjectCodeMemoryStore._testOnlyCancelLinuxFileSystemEventStream(stream)
    }

    func testLinuxInotifyStreamQueueOverflowRebuildsAndContinuesWatching() throws {
        let fixture = try makeFixture()
        let queue = DispatchQueue(label: "com.openburnbar.tests.linux-inotify-overflow")
        let events = LockedCounter()
        let rebuilds = LockedCounter()

        guard let stream = BurnBarProjectCodeMemoryStore._testOnlyMakeLinuxFileSystemEventStream(
            roots: [fixture.project],
            queue: queue,
            onEvent: {
                events.increment()
            },
            onRebuild: {
                rebuilds.increment()
            }
        ) else {
            return XCTFail("expected Linux inotify stream to install at least one watch")
        }
        addTeardownBlock {
            BurnBarProjectCodeMemoryStore._testOnlyCancelLinuxFileSystemEventStream(stream)
        }

        BurnBarProjectCodeMemoryStore._testOnlySimulateLinuxInotifyQueueOverflow(stream, queue: queue)
        XCTAssertEqual(rebuilds.value, 1)
        XCTAssertEqual(events.value, 1)

        let eventsBeforeCreate = events.value
        try write("func linuxInotifyAfterOverflow() {}\n", to: fixture.project.appendingPathComponent("Sources/AfterOverflow.swift"))
        try waitUntil(timeout: 3.0) { events.value > eventsBeforeCreate }
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(rebuilds.value, 1)

        BurnBarProjectCodeMemoryStore._testOnlyCancelLinuxFileSystemEventStream(stream)
    }

    private func makeFixture() throws -> (root: URL, project: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectCodeMemoryLinuxInotifyTests-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("FixtureProject", isDirectory: true)
        let sources = project.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return (root, project)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func openFileDescriptorCount() throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd").count
    }

    private func waitForFileDescriptorCount(atMost expectedCount: Int, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var currentCount = try openFileDescriptorCount()
        while Date() < deadline {
            currentCount = try openFileDescriptorCount()
            if currentCount <= expectedCount {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertLessThanOrEqual(currentCount, expectedCount)
    }

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(condition())
    }

    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }
    }
}
#endif
