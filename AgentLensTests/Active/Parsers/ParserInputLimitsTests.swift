import XCTest
@testable import OpenBurnBar

/// Covers the DoS-hardening guard shared by the local log parsers
/// (`ParserInputLimits`): a pre-flight file-size cap and a JSON
/// recursion-depth cap (finding V-37).
final class ParserInputLimitsTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-parser-limits-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        try super.tearDownWithError()
    }

    private func writeFile(named name: String, bytes: Int) throws -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        let data = Data(count: bytes)
        try data.write(to: url)
        return url
    }

    // MARK: - Size cap

    func test_guardedContents_readsFileWithinLimit() throws {
        let url = try writeFile(named: "ok.json", bytes: 1_024)

        let data = try ParserInputLimits.guardedContents(ofFile: url.path)

        XCTAssertEqual(data.count, 1_024)
    }

    func test_guardedContents_throwsFileTooLargeAboveLimit() throws {
        // One byte over the cap must be rejected by the pre-flight stat,
        // never allocated into memory.
        let overLimitURL = tempDirectory.appendingPathComponent("huge.json")
        let size = Int(ParserInputLimits.maxFileSizeBytes) + 1
        // Sparse write keeps the test cheap while still reporting the true size.
        let handle = FileManager.default
        XCTAssertTrue(handle.createFile(atPath: overLimitURL.path, contents: nil))
        let fileHandle = try FileHandle(forWritingTo: overLimitURL)
        defer { try? fileHandle.close() }
        try fileHandle.truncate(atOffset: UInt64(size))

        XCTAssertThrowsError(try ParserInputLimits.guardedContents(ofFile: overLimitURL.path)) { error in
            guard let tooLarge = error as? ParserInputLimits.FileTooLarge else {
                return XCTFail("Expected FileTooLarge, got \(error)")
            }
            XCTAssertEqual(tooLarge.limitBytes, ParserInputLimits.maxFileSizeBytes)
            XCTAssertGreaterThan(tooLarge.sizeBytes, ParserInputLimits.maxFileSizeBytes)
            XCTAssertEqual(tooLarge.path, overLimitURL.path)
        }
    }

    func test_boundedContents_returnsDataWithinLimit() throws {
        let url = try writeFile(named: "small.json", bytes: 16)

        let data = ParserInputLimits.boundedContents(of: url)

        XCTAssertEqual(data?.count, 16)
    }

    func test_boundedContents_returnsNilAboveLimit() throws {
        let overLimitURL = tempDirectory.appendingPathComponent("huge2.json")
        XCTAssertTrue(FileManager.default.createFile(atPath: overLimitURL.path, contents: nil))
        let fileHandle = try FileHandle(forWritingTo: overLimitURL)
        defer { try? fileHandle.close() }
        try fileHandle.truncate(atOffset: ParserInputLimits.maxFileSizeBytes + 1)

        XCTAssertNil(ParserInputLimits.boundedContents(of: overLimitURL))
    }

    func test_boundedContents_returnsNilForMissingFile() {
        let missing = tempDirectory.appendingPathComponent("does-not-exist.json")

        XCTAssertNil(ParserInputLimits.boundedContents(of: missing))
    }

    // MARK: - Depth cap

    func test_depthWithinLimit_boundary() {
        XCTAssertTrue(ParserInputLimits.depthWithinLimit(0))
        XCTAssertTrue(ParserInputLimits.depthWithinLimit(ParserInputLimits.maxJSONDepth - 1))
        XCTAssertFalse(ParserInputLimits.depthWithinLimit(ParserInputLimits.maxJSONDepth))
        XCTAssertFalse(ParserInputLimits.depthWithinLimit(ParserInputLimits.maxJSONDepth + 1))
    }

    /// A deeply-nested OpenClaw session JSON must parse without crashing: the
    /// flatten walk is bounded by `maxJSONDepth`, so an adversarial document
    /// returns rather than recursing until the stack is exhausted.
    func test_openClawParser_boundedDepth_doesNotCrashOnDeepNesting() async throws {
        let sessionsDir = tempDirectory.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        // Build JSON nested far deeper than the cap under an "items" key, which
        // the flatten walk descends. A top-level array makes the per-line JSONL
        // decode fail (it is not a `[String: Any]`), so the parser falls through
        // to the whole-file `flattenSessionObjects` recursion under test.
        let depth = ParserInputLimits.maxJSONDepth + 50
        var json = "{\"role\":\"user\",\"content\":\"hi\"}"
        for _ in 0..<depth {
            json = "{\"items\":[\(json)]}"
        }
        json = "[\(json)]"
        let file = sessionsDir.appendingPathComponent("deep.json")
        try json.data(using: .utf8)!.write(to: file)

        let parser = OpenClawParser(sessionsDirectory: sessionsDir)
        // The load-bearing assertion is that parse() returns at all: an
        // unbounded recursive flatten would exhaust the stack on this input.
        // Because the walk stops at maxJSONDepth (emitting the wrapper dict as a
        // leaf rather than the innermost turn), no usable turns are recovered and
        // the oversized session simply yields no conversation — which is the
        // intended fail-safe behaviour.
        let result = try await parser.parse()
        XCTAssertTrue(result.conversations.isEmpty)
        XCTAssertTrue(result.usages.isEmpty)
    }
}
