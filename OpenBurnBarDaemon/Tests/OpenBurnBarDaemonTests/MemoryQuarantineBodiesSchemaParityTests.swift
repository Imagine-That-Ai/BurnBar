// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
@testable import OpenBurnBarDaemon
import OpenBurnBarEngine
import SQLite3
import XCTest

/// `memory_quarantine_bodies` is created in three places against ONE database
/// file: the daemon's `bootstrapSchema`, the `OpenBurnBarData` GRDB migration
/// (`v65_memory_quarantine_bodies`), and the AgentLens mirror of that migration.
/// Whichever process opens a fresh profile first wins the race, and both writers
/// say `IF NOT EXISTS` — so the loser is a no-op, but only for as long as the
/// three texts agree. If a column were added on one side only, the loser would
/// silently keep the other's shape and the mismatch would surface as a runtime
/// SQL error in a member's database, not here.
///
/// The table matters more since the agent lane started landing in review
/// (D-0005): a quarantined mirrored memory keeps its body HERE and nowhere else,
/// and the macOS review inbox now reads it to show a member what a coding agent
/// asked BurnBar to remember. That read needs the table to exist and to have the
/// shape the reader expects no matter which process bootstrapped the profile.
///
/// So this suite reads all three statements from source — applying Swift's own
/// multiline-literal rule, so what it compares is the string each compiler
/// builds, not the indentation each file happens to use — and then proves the
/// app's statement really is a no-op on a store the daemon bootstrapped.
final class MemoryQuarantineBodiesSchemaParityTests: XCTestCase {

    private static let daemonBootstrapPath =
        "OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ProjectCodeMemory/BurnBarProjectCodeMemoryStore+Database.swift"
    private static let dataMigrationPath =
        "OpenBurnBarCore/Sources/OpenBurnBarData/OpenBurnBarDatabase+CommandBoardIndexMigration.swift"
    private static let appMigrationPath =
        "AgentLens/Services/DataStore/OpenBurnBarDatabase+CommandBoardIndexMigration.swift"

    private static let tableMarker = "CREATE TABLE IF NOT EXISTS memory_quarantine_bodies ("
    private static let indexMarker = "CREATE INDEX IF NOT EXISTS memory_quarantine_bodies_project_idx"

    // MARK: - Source parity

    /// The two migration trees are hand-mirrored copies of one file. They must be
    /// byte-identical, the way the v58/v59 pairs are.
    func testBothMigrationTreesDeclareTheSameQuarantineBodiesDDL() throws {
        let dataTable = try tableStatement(inFileAt: Self.dataMigrationPath)
        let appTable = try tableStatement(inFileAt: Self.appMigrationPath)
        XCTAssertEqual(
            dataTable,
            appTable,
            """
            The v65 quarantine-bodies DDL has drifted between the two migration \
            trees. Both files must declare byte-identical statements — update \
            them in the same commit.
            """
        )
    }

    /// The whole point of the suite: the app's migration and the daemon's
    /// bootstrap create the same table, character for character.
    func testTheAppMigrationDDLIsByteEqualToTheDaemonBootstrapDDL() throws {
        let daemonTable = try tableStatement(inFileAt: Self.daemonBootstrapPath)
        let appTable = try tableStatement(inFileAt: Self.appMigrationPath)
        XCTAssertEqual(
            daemonTable,
            appTable,
            """
            `memory_quarantine_bodies` is created by both the daemon bootstrap \
            and the app's GRDB migrator against one database file. The two \
            statements have drifted, so whichever process opens a fresh profile \
            second will silently keep the other's shape.
            """
        )
        XCTAssertTrue(
            daemonTable.contains("IF NOT EXISTS"),
            "both writers must be idempotent — the second one to run is a no-op by design"
        )
    }

    /// The companion index. The two files differ in ONE respect — the app wraps
    /// the statement across two lines and the daemon keeps it on one — so this
    /// asserts the SQL, not the line breaks. A column or a name changing on one
    /// side still fails it.
    func testTheAppIndexDDLMatchesTheDaemonBootstrapIndex() throws {
        let daemonIndex = try indexStatement(inFileAt: Self.daemonBootstrapPath)
        let appIndex = try indexStatement(inFileAt: Self.appMigrationPath)
        XCTAssertEqual(
            Self.collapsingWhitespace(daemonIndex),
            Self.collapsingWhitespace(appIndex),
            "the quarantine-bodies project index differs between the daemon bootstrap and the app migration"
        )
    }

    // MARK: - Behaviour on a real store

    /// Source equality would still let the app's statement fail against a store
    /// the daemon created, so run it there: bootstrap a real store, park a real
    /// quarantined agent-lane body in it, then execute the app's migration text
    /// twice. One table, one index, no error, and the parked body untouched.
    func testTheAppMigrationIsANoOpOnADaemonBootstrappedStore() throws {
        let appTable = try tableStatement(inFileAt: Self.appMigrationPath)
        let appIndex = try indexStatement(inFileAt: Self.appMigrationPath)

        let fixture = try makeFixture()
        let store = try BurnBarProjectCodeMemoryStore(
            databasePath: fixture.database.path,
            logger: BurnBarDaemonLogger(category: "quarantine-bodies-parity-test")
        )
        // The row the app's review inbox exists to show: the JSON the Memory MCP
        // engine's mirror sends, which carries no `reviewStatus` and therefore
        // lands quarantined (D-0005).
        let body = "The staging deploy runs from the release branch."
        let request = try JSONDecoder().decode(
            BurnBarProjectMemoryRememberRequest.self,
            from: Data("""
            {"text": "\(body)",
             "projectPath": "\(fixture.project.path)",
             "kind": "fact",
             "scope": "project",
             "engineMemoryID": "mem_00112233445566778899aabbccddeeff"}
            """.utf8)
        )
        XCTAssertEqual(request.reviewStatus, .quarantined)
        let written = try store.remember(request)

        // Twice: a migrator runs once per profile, but a no-op that is only a
        // no-op the first time is not one.
        try execute(sql: appTable, on: fixture.database)
        try execute(sql: appIndex, on: fixture.database)
        try execute(sql: appTable, on: fixture.database)
        try execute(sql: appIndex, on: fixture.database)

        XCTAssertEqual(
            try queryStrings(
                sql: """
                SELECT type || ':' || name FROM sqlite_master \
                WHERE name IN ('memory_quarantine_bodies', 'memory_quarantine_bodies_project_idx') \
                ORDER BY name
                """,
                on: fixture.database
            ),
            ["table:memory_quarantine_bodies", "index:memory_quarantine_bodies_project_idx"],
            "the app's DDL must find the daemon's objects, not create second ones"
        )
        XCTAssertEqual(
            try queryStrings(
                sql: "SELECT name FROM pragma_table_info('memory_quarantine_bodies') ORDER BY cid",
                on: fixture.database
            ),
            ["memory_id", "project_id", "body", "created_at", "updated_at"],
            "the surviving table is the shape both statements describe"
        )
        XCTAssertEqual(
            try queryStrings(
                sql: "SELECT body FROM memory_quarantine_bodies WHERE memory_id = '\(written.memoryID)'",
                on: fixture.database
            ),
            [body],
            "and the quarantined body the review inbox reads survived the app's migration"
        )
    }

    // MARK: - Source reading

    /// Walks up from this file to the repository root. Deliberately fails rather
    /// than skipping when it cannot find one: a parity test that goes green
    /// because its reference tree is missing is worse than no parity test.
    private func repositoryRoot(file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<8 {
            url = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("AGENTS.md").path) {
                return url
            }
        }
        XCTFail("Could not locate the repository root from \(#filePath)", file: file, line: line)
        throw CocoaError(.fileNoSuchFile)
    }

    private func source(at relativePath: String) throws -> String {
        let url = try repositoryRoot().appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("Missing source file: \(relativePath)")
            throw CocoaError(.fileNoSuchFile)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func tableStatement(inFileAt relativePath: String) throws -> String {
        let text = try source(at: relativePath)
        return try XCTUnwrap(
            Self.multilineLiteral(containing: Self.tableMarker, in: text),
            "Could not find the CREATE TABLE literal in \(relativePath)"
        )
    }

    /// The index is a one-line literal in the daemon and a multiline one in the
    /// app migration, so try both shapes — the one-line form first, because a
    /// multiline scan started from a line that is not inside a multiline literal
    /// happily walks to the nearest unrelated delimiters and returns nonsense.
    private func indexStatement(inFileAt relativePath: String) throws -> String {
        let text = try source(at: relativePath)
        if let literal = Self.singleLineLiteral(containing: Self.indexMarker, in: text) {
            return literal
        }
        return try XCTUnwrap(
            Self.multilineLiteral(containing: Self.indexMarker, in: text),
            "Could not find the CREATE INDEX literal in \(relativePath)"
        )
    }

    /// Reproduces Swift's multiline-string rule on a literal read from source:
    /// take the lines between the delimiters and strip the CLOSING delimiter's
    /// indentation from each. What comes back is the string the compiler builds,
    /// so two files that indent their literals differently still compare equal —
    /// and two files whose SQL differs still compare unequal.
    static func multilineLiteral(containing marker: String, in source: String) -> String? {
        let lines = source.components(separatedBy: "\n")
        guard let markerIndex = lines.firstIndex(where: { $0.contains(marker) }) else { return nil }
        guard let openIndex = (0..<markerIndex).reversed().first(where: {
            lines[$0].trimmingCharacters(in: .whitespaces).hasSuffix("\"\"\"")
        }) else { return nil }
        guard let closeIndex = (markerIndex..<lines.count).first(where: {
            let trimmed = lines[$0].trimmingCharacters(in: .whitespaces)
            return trimmed == "\"\"\"" || trimmed == "\"\"\","
        }) else { return nil }
        guard openIndex + 1 <= closeIndex - 1 else { return nil }

        let indent = lines[closeIndex].prefix { $0 == " " }.count
        let body = lines[(openIndex + 1)...(closeIndex - 1)].map { line -> String in
            String(line.dropFirst(min(indent, line.prefix { $0 == " " }.count)))
        }
        return body.joined(separator: "\n")
    }

    /// The `"…"` form: everything between the quotes on the marker's own line.
    /// Nil when the marker's line carries no quoted string of its own, which is
    /// how a multiline literal's opening line is told apart from this one.
    static func singleLineLiteral(containing marker: String, in source: String) -> String? {
        guard let line = source.components(separatedBy: "\n").first(where: { $0.contains(marker) }),
              let open = line.firstIndex(of: "\""),
              let close = line.lastIndex(of: "\""),
              open < close else {
            return nil
        }
        let literal = String(line[line.index(after: open)..<close])
        return literal.contains(marker) ? literal : nil
    }

    private static func collapsingWhitespace(_ sql: String) -> String {
        sql.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // MARK: - SQLite

    private func makeFixture() throws -> (root: URL, project: URL, database: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuarantineBodiesParityTests-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("FixtureProject", isDirectory: true)
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent("Sources", isDirectory: true),
            withIntermediateDirectories: true
        )
        let database = root.appendingPathComponent("openburnbar.sqlite", isDirectory: false)
        FileManager.default.createFile(atPath: database.path, contents: nil)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, project, database)
    }

    /// Opens the fixture the way the daemon wrote it — through SQLCipher when a
    /// codec and a provisioned key are both present, which is any real dev Mac.
    private func openDatabase(_ url: URL, flags: Int32) throws -> OpaquePointer {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &handle, flags, nil), SQLITE_OK)
        let unwrapped = try XCTUnwrap(handle)
        try BurnBarDaemonDatabaseCipher.applyKeyIfAvailable(to: unwrapped)
        return unwrapped
    }

    private func execute(sql: String, on database: URL) throws {
        let handle = try openDatabase(database, flags: SQLITE_OPEN_READWRITE)
        defer { sqlite3_close(handle) }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        let message = errorMessage.map { String(cString: $0) } ?? ""
        if let errorMessage { sqlite3_free(errorMessage) }
        XCTAssertEqual(status, SQLITE_OK, "executing the app's DDL failed: \(message)")
    }

    private func queryStrings(sql: String, on database: URL) throws -> [String] {
        let handle = try openDatabase(database, flags: SQLITE_OPEN_READONLY)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(handle, sql, -1, &statement, nil), SQLITE_OK)
        let unwrapped = try XCTUnwrap(statement)
        defer { sqlite3_finalize(unwrapped) }
        var values: [String] = []
        while sqlite3_step(unwrapped) == SQLITE_ROW {
            if let text = sqlite3_column_text(unwrapped, 0) {
                values.append(String(cString: text))
            }
        }
        return values
    }
}
