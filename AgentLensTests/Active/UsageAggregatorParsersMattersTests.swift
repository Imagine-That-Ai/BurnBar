import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

/// Behavioral coverage for the formerly-silent `try?` error-swallows in
/// `UsageAggregatorParsers.swift`.
///
/// The disk-cache-backed parsers (`CodexParser`, `ModelFilterParser`) warm up the
/// OpenBurnBar support directory in their initializers. That call used to be
/// `_ = try? OpenBurnBarMigration.prepareSupportDirectory(...)`, which discarded
/// every failure totally silently. It is now routed through
/// `ParserSupportDirectoryWarmUp.prepare(...)`, which:
///   * succeeds and returns `true` when the directory can be created,
///   * logs (`AppLogger.parser.error`) and returns `false` when preparation fails,
///   * never throws / crashes — a parser stays constructible even when its scratch
///     directory is unavailable, degrading gracefully by re-parsing.
///
/// These tests assert the observable success/failure outcome (so the catch path is
/// proven to run, not skipped) and that both parsers remain constructible and
/// runnable when the support directory cannot be prepared.
final class UsageAggregatorParsersMattersTests: XCTestCase {

    private var scratchRoots: [URL] = []

    override func tearDownWithError() throws {
        let fm = FileManager.default
        for root in scratchRoots where fm.fileExists(atPath: root.path) {
            try? fm.removeItem(at: root)
        }
        scratchRoots.removeAll()
        try super.tearDownWithError()
    }

    /// A unique temp URL registered for cleanup. Not created on disk.
    private func uniqueTempURL(suffix: String = "") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-parsers-matters-\(UUID().uuidString)\(suffix)", isDirectory: true)
        scratchRoots.append(url)
        return url
    }

    // MARK: - ParserSupportDirectoryWarmUp.prepare

    func testWarmUpSucceedsForWritableSupportRoot() throws {
        let root = uniqueTempURL()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = OpenBurnBarAppPaths(applicationSupportRoot: root)

        let prepared = ParserSupportDirectoryWarmUp.prepare(
            fileManager: .default,
            appPaths: paths
        )

        XCTAssertTrue(prepared, "Warm-up must report success for a writable support root.")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: paths.supportDirectory.path),
            "Warm-up must actually create the support directory on success."
        )
    }

    /// Drives the catch path: when the support root is occupied by a *regular file*,
    /// creating the `OpenBurnBar` subdirectory under it throws. The previous `try?`
    /// form swallowed this silently; the fix surfaces it as `false` (and logs).
    func testWarmUpFailsClosedToFalseAndDoesNotThrowWhenRootIsAFile() throws {
        // Place a regular file exactly where the support *root* directory is expected.
        let fileRoot = uniqueTempURL()
        try Data("not a directory".utf8).write(to: fileRoot, options: .atomic)
        let paths = OpenBurnBarAppPaths(applicationSupportRoot: fileRoot)

        // Must not throw / crash even though preparation fails.
        let prepared = ParserSupportDirectoryWarmUp.prepare(
            fileManager: .default,
            appPaths: paths
        )

        XCTAssertFalse(
            prepared,
            "Warm-up must observably report failure (formerly swallowed by try?) when the support directory cannot be created."
        )
        // The root stays a file — we never silently converted it into a directory.
        var isDirectory = ObjCBool(false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileRoot.path, isDirectory: &isDirectory))
        XCTAssertFalse(isDirectory.boolValue, "Warm-up must not clobber a pre-existing regular file at the root path.")
    }

    // MARK: - Graceful degradation of the parsers themselves

    /// `CodexParser` must remain constructible and runnable even when its support
    /// directory cannot be prepared. Pointing at a missing Codex DB keeps the run
    /// hermetic; the assertion is that construction + `parse()` do not crash and
    /// return an empty (degraded) result rather than failing closed.
    func testCodexParserConstructsAndDegradesWhenSupportDirUnavailable() async throws {
        let fileRoot = uniqueTempURL()
        try Data("not a directory".utf8).write(to: fileRoot, options: .atomic)
        let paths = OpenBurnBarAppPaths(applicationSupportRoot: fileRoot)

        // Home directory with no `.codex/state_5.sqlite` -> parse returns empty.
        let home = uniqueTempURL(suffix: "-home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let parser = CodexParser(
            fileManager: .default,
            appPaths: paths,
            homeDirectoryURL: home
        )

        let result = try await parser.parse()
        XCTAssertTrue(result.usages.isEmpty)
        XCTAssertTrue(result.conversations.isEmpty)
    }

    /// `ModelFilterParser` (used for Zai / MiniMax) must likewise stay constructible
    /// and degrade gracefully when the support directory cannot be prepared.
    func testModelFilterParserConstructsWhenSupportDirUnavailable() throws {
        let fileRoot = uniqueTempURL()
        try Data("not a directory".utf8).write(to: fileRoot, options: .atomic)
        let paths = OpenBurnBarAppPaths(applicationSupportRoot: fileRoot)

        // Construction triggers the warm-up; it must not throw / crash.
        let parser = ModelFilterParser(
            modelPattern: "zai",
            provider: .zai,
            fileManager: .default,
            appPaths: paths
        )
        XCTAssertEqual(parser.provider, .zai)
    }
}
