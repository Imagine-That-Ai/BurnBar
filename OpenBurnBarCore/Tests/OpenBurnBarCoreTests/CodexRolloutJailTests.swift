import GRDB
import XCTest
@testable import OpenBurnBarLogParsers

/// Wave 2.7: `rollout_path` values come from Codex's own SQLite database —
/// attacker-influenced input (a compromised or malicious Codex install writes
/// arbitrary paths there). Both consumers (the subagent probe, which OPENS
/// the file, and the session scanner, which stats/reads it) must only ever
/// see paths jailed under `~/.codex`. Anything else resolves to nil and the
/// thread is parsed from its database row alone.
///
/// Red-before/green-after: against the unjailed expansion these assertions
/// fail (escapes pass through as ordinary paths); with the jail they pass.
final class CodexRolloutJailTests: XCTestCase {
    private func makeThreadsDB() throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-jail-\(UUID().uuidString).sqlite").path
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        let db = try DatabaseQueue(path: path)
        try db.write { conn in
            try conn.execute(sql: """
                CREATE TABLE threads (
                    id TEXT PRIMARY KEY, title TEXT, model TEXT,
                    model_provider TEXT, tokens_used INTEGER,
                    created_at INTEGER, updated_at INTEGER,
                    cwd TEXT, rollout_path TEXT, archived INTEGER NOT NULL DEFAULT 0
                )
                """)
            let now = Int64(Date().timeIntervalSince1970)
            let rows: [(String, String)] = [
                ("ok", "~/.codex/sessions/2026-09-24/rollout-ok.jsonl"),
                ("traversal", "~/.codex/../../.ssh/id_rsa"),
                ("absolute", "/etc/passwd"),
                ("sibling", "~/.codex-evil/rollout.jsonl"),
                ("nested", "~/.codex/sessions/../../../../tmp/x.jsonl"),
            ]
            for (id, rollout) in rows {
                try conn.execute(
                    sql: """
                        INSERT INTO threads (id, title, model, model_provider, tokens_used,
                            created_at, updated_at, cwd, rollout_path, archived)
                        VALUES (?, 't', 'm', 'codex', 0, ?, ?, '/tmp', ?, 0)
                        """,
                    arguments: [id, now, now, rollout]
                )
            }
        }
        return path
    }

    func test_threadRowsJailRolloutPathsUnderCodexHome() throws {
        let parser = CodexParser()
        let fetched = try parser.fetchThreadRows(dbPath: makeThreadsDB(), governor: nil)
        let byID = Dictionary(uniqueKeysWithValues: fetched.rows.map { ($0.threadId, $0) })
        XCTAssertEqual(byID.count, 5)

        // The legitimate rollout survives, contained (exact home mapping is
        // covered by `test_jailContract`).
        let ok = try XCTUnwrap(byID["ok"]?.expandedRolloutPath)
        XCTAssertTrue(ok.hasSuffix("/.codex/sessions/2026-09-24/rollout-ok.jsonl"), ok)

        // Every escape resolves to nil: the thread still parses (from its
        // database row) but no file outside the jail is ever touched.
        XCTAssertNil(byID["traversal"]?.expandedRolloutPath)
        XCTAssertNil(byID["absolute"]?.expandedRolloutPath)
        XCTAssertNil(byID["sibling"]?.expandedRolloutPath)
        XCTAssertNil(byID["nested"]?.expandedRolloutPath)
    }

    func test_jailRejectsSymlinkEscapes() throws {
        // A symlink INSIDE the jail pointing OUTSIDE must not smuggle reads out.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-jail-link-\(UUID().uuidString)", isDirectory: true)
        let codex = root.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("secret.txt")
        try Data("x".utf8).write(to: outside)
        let link = codex.appendingPathComponent("evil.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        XCTAssertNil(CodexRolloutJail.containedPath(link.path, homeDirectoryURL: root))
        // …while a real file inside stays readable.
        let inner = codex.appendingPathComponent("ok.jsonl")
        try Data("{}".utf8).write(to: inner)
        XCTAssertEqual(
            CodexRolloutJail.containedPath(inner.path, homeDirectoryURL: root),
            inner.standardizedFileURL.path
        )
    }

    func test_jailContract() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        XCTAssertEqual(
            CodexRolloutJail.containedPath("~/.codex/sessions/a.jsonl", homeDirectoryURL: home),
            "/Users/test/.codex/sessions/a.jsonl"
        )
        XCTAssertNil(CodexRolloutJail.containedPath("~/.codex/../x", homeDirectoryURL: home))
        XCTAssertNil(CodexRolloutJail.containedPath("/etc/passwd", homeDirectoryURL: home))
        XCTAssertNil(CodexRolloutJail.containedPath("~/.codex-evil/x", homeDirectoryURL: home))
        XCTAssertNil(CodexRolloutJail.containedPath("~/.codex", homeDirectoryURL: home))
        XCTAssertNil(CodexRolloutJail.containedPath("~", homeDirectoryURL: home))
        XCTAssertNil(CodexRolloutJail.containedPath("sessions/a.jsonl", homeDirectoryURL: home))
        XCTAssertNil(CodexRolloutJail.containedPath("", homeDirectoryURL: home))
    }

    func test_windowsContainmentCore() {
        // The pure string core of the Windows branch (which itself only
        // compiles on Windows): drive-letter + UNC absolute, backslashes,
        // case-insensitive, trailing-slash prefix blocks siblings and root.
        let jail = #"C:\Users\test\.codex"#
        XCTAssertTrue(CodexRolloutJail.windowsPathIsContained(
            candidate: #"C:\Users\test\.codex\sessions\a.jsonl"#, jailRoot: jail))
        XCTAssertTrue(CodexRolloutJail.windowsPathIsContained(
            candidate: "C:/Users/test/.codex/sessions/a.jsonl", jailRoot: jail))
        XCTAssertTrue(CodexRolloutJail.windowsPathIsContained(
            candidate: #"c:\users\TEST\.CODEX\a.jsonl"#, jailRoot: jail))
        XCTAssertTrue(CodexRolloutJail.windowsPathIsContained(
            candidate: #"\\server\share\.codex\a.jsonl"#,
            jailRoot: #"\\server\share\.codex"#))
        XCTAssertFalse(CodexRolloutJail.windowsPathIsContained(
            candidate: #"C:\Users\test\.codex-evil\a.jsonl"#, jailRoot: jail))
        XCTAssertFalse(CodexRolloutJail.windowsPathIsContained(
            candidate: #"C:\Users\test\.codex"#, jailRoot: jail))
        XCTAssertFalse(CodexRolloutJail.windowsPathIsContained(
            candidate: #"D:\.codex\a.jsonl"#, jailRoot: jail))
        XCTAssertFalse(CodexRolloutJail.windowsPathIsContained(
            candidate: #"C:codex\a.jsonl"#, jailRoot: jail))
        XCTAssertFalse(CodexRolloutJail.windowsPathIsContained(
            candidate: #"~\.codex\a.jsonl"#, jailRoot: jail))
        XCTAssertFalse(CodexRolloutJail.windowsPathIsContained(
            candidate: "sessions/a.jsonl", jailRoot: jail))
        XCTAssertFalse(CodexRolloutJail.windowsPathIsContained(candidate: "", jailRoot: jail))
    }

    func test_jailResolvesSymlinkedHome() throws {
        // A symlinked home (or a symlinked ~/.codex) must still jail
        // correctly: both sides of the prefix check resolve symlinks before
        // comparing, so an in-jail file stays accepted and an outside file
        // stays refused when home is reached through a link.
        let real = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-jail-real-\(UUID().uuidString)", isDirectory: true)
        let codex = real.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: real) }
        let inner = codex.appendingPathComponent("ok.jsonl")
        try Data("{}".utf8).write(to: inner)
        let viaLink = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-jail-home-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: viaLink, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: viaLink) }

        XCTAssertEqual(
            CodexRolloutJail.containedPath(
                viaLink.appendingPathComponent(".codex/ok.jsonl").path,
                homeDirectoryURL: viaLink
            ),
            inner.standardizedFileURL.resolvingSymlinksInPath().path
        )
        XCTAssertNil(
            CodexRolloutJail.containedPath("/etc/passwd", homeDirectoryURL: viaLink)
        )
    }
}
