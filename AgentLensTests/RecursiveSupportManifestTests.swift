import Foundation
import XCTest

final class RecursiveSupportManifestTests: XCTestCase {
    func test_manifestIncludesNestedEntriesAndDetectsSameSizeContentChanges() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("recursive-support-manifest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let nestedFile = root
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("cache.json")
        try FileManager.default.createDirectory(
            at: nestedFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("one".utf8).write(to: nestedFile)
        let before = RecursiveSupportManifest.make(for: root)

        try Data("two".utf8).write(to: nestedFile)
        let after = RecursiveSupportManifest.make(for: root)

        let relativePath = "nested/cache.json"
        XCTAssertNotNil(before[relativePath], "nested files must be included")
        XCTAssertEqual(before[relativePath]?.size, after[relativePath]?.size, "fixture keeps size stable")
        XCTAssertNotEqual(
            before[relativePath]?.contentHash,
            after[relativePath]?.contentHash,
            "content-only writes must be detected by the hash"
        )
        XCTAssertNotEqual(before, after)
    }
}
