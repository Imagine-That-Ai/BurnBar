import CoreServices
import XCTest
@testable import OpenBurnBar

/// Regression for the 1.0.40 (81) fleet-watch SIGSEGV.
///
/// Thread 30 (`ai.burnbar.fleet.watch`) died in
/// `Array._conditionallyBridgeFromObjectiveC` because `fileTreeEventCallback`
/// bitcast FSEvents `eventPaths` to `NSArray` without `UseCFTypes`. The kernel
/// then handed over a `char **`, and objc_msgSend walked path bytes
/// (`0x656e756ec694`).
final class FileTreeEventStreamTests: XCTestCase {

    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    /// The 1.0.40 (81) crash is this flag being off. A live FSEvents test can
    /// still pass if someone restores the NSArray bridge *and* keeps the flag;
    /// removing the flag is the defect that turns path bytes into an isa.
    func test_creationFlags_includeUseCFTypesAndFileEvents() {
        let flags = FileTreeEventStream.creationFlags
        XCTAssertNotEqual(
            flags & FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes),
            0,
            "UseCFTypes must stay set: without it eventPaths is char** and the callback SIGSEGVs"
        )
        XCTAssertNotEqual(
            flags & FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents),
            0,
            "FileEvents is what names the written session file on the fleet row"
        )
    }

    func test_decoder_copiesCFArrayOfPaths() {
        let expected = [
            "/Users/dewclaw/.claude/projects/BurnBar/session.jsonl",
            "/Users/dewclaw/.codex/sessions/rollout.jsonl"
        ]
        let cfArray = expected as CFArray
        let pointer = Unmanaged.passUnretained(cfArray).toOpaque()
        XCTAssertEqual(
            FileTreeEventPathDecoder.collect(from: pointer, count: expected.count),
            expected
        )
    }

    func test_decoder_ignoresCountWhenZero() {
        let cfArray = ["/tmp/session.jsonl"] as CFArray
        let pointer = Unmanaged.passUnretained(cfArray).toOpaque()
        XCTAssertEqual(FileTreeEventPathDecoder.collect(from: pointer, count: 0), [])
    }

    func test_decoder_capsToArrayLengthAndSkipsNonStrings() {
        let mixed: NSMutableArray = [NSNumber(value: 7), "/tmp/session.jsonl", NSNumber(value: 9)]
        let pointer = Unmanaged.passUnretained(mixed).toOpaque()
        XCTAssertEqual(
            FileTreeEventPathDecoder.collect(from: pointer, count: 99),
            ["/tmp/session.jsonl"]
        )
    }

    func test_start_returnsFalseWhenRootIsMissing() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("filetree-missing-\(UUID().uuidString)", isDirectory: true)
        let stream = FileTreeEventStream(
            root: missing,
            queue: DispatchQueue(label: "test.filetree.missing"),
            latency: 0.05
        ) { _ in }
        XCTAssertFalse(stream.start())
    }

    /// End-to-end: a real FSEvents callback must deliver the written file, not
    /// crash the way build 81 did when the first session log landed.
    func test_stream_deliversWrittenFilePath() async throws {
        let dir = try makeTemporaryDirectory()
        let lock = NSLock()
        var received: [String] = []
        let stream = FileTreeEventStream(
            root: dir,
            queue: DispatchQueue(label: "test.filetree.watch"),
            latency: 0.05
        ) { paths in
            lock.lock()
            received.append(contentsOf: paths)
            lock.unlock()
        }
        XCTAssertTrue(stream.start())
        defer { stream.stop() }

        let file = dir.appendingPathComponent("session.jsonl")
        try Data("write\n".utf8).write(to: file)

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            lock.lock()
            let snapshot = received
            lock.unlock()
            if snapshot.contains(where: { $0.hasSuffix("session.jsonl") }) {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        lock.lock()
        let snapshot = received
        lock.unlock()
        XCTFail("FSEvents never delivered session.jsonl; got \(snapshot)")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("filetree-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirectories.append(dir)
        return dir
    }
}
