// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
@testable import OpenBurnBarDaemon
import OpenBurnBarEngine
import SQLite3
import XCTest

/// Reads a schema statement back out of the checkout, so a parity test compares
/// what a file actually declares rather than what a test author retyped. Shared
/// with `MemoryQuarantineBodiesSchemaParityTests`, which pins the
/// quarantine-bodies table the same way.
enum MemorySchemaSource {

    /// Walks up from this file to the repository root. Deliberately fails rather
    /// than skipping when it cannot find one: a parity test that goes green
    /// because its reference tree is missing is worse than no parity test.
    static func repositoryRoot(file: StaticString = #filePath, line: UInt = #line) throws -> URL {
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

    static func text(at relativePath: String) throws -> String {
        let url = try repositoryRoot().appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("Missing source file: \(relativePath)")
            throw CocoaError(.fileNoSuchFile)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

/// `agent_memories.review_status` is where a memory waits, and its column DEFAULT
/// is the last thing that decides where a write lands when nothing else says.
///
/// D-0005 made the wire fail closed — an absent `reviewStatus` on
/// `daemon.memory.remember` decodes as `quarantined` — but one layer below it the
/// daemon's own bootstrap DDL still declared `DEFAULT 'approved'`, the same
/// fail-open default in the storage layer, while the canonical GRDB migrator had
/// said `quarantined` since v51. Every writer in the tree names the column
/// explicitly, so the drift changed no row; it was a loaded gun pointed at the
/// next writer who forgot. I-57 closes it, and this suite is what keeps it shut:
/// the default is part of the pinned DDL text now, in all three trees, and the
/// last test proves the text is what SQLite actually applies.
final class MemoryReviewStatusDefaultParityTests: XCTestCase {

    private static let daemonBootstrapPath =
        "OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ProjectCodeMemory/BurnBarProjectCodeMemoryStore+Database.swift"
    private static let dataMigrationPath =
        "OpenBurnBarCore/Sources/OpenBurnBarData/OpenBurnBarDatabase+MemoryMigrations.swift"
    private static let appMigrationPath =
        "AgentLens/Services/DataStore/OpenBurnBarDatabase+MemoryMigrations.swift"

    /// The pinned text. Both statements in the daemon's bootstrap — the column in
    /// `CREATE TABLE agent_memories` and the `ensureColumn` definition that adds
    /// it to a database that predates the review lifecycle — declare the same
    /// default, because they govern the same future INSERT.
    private static let daemonColumn = "review_status TEXT NOT NULL DEFAULT 'quarantined'"
    private static let daemonEnsureColumn =
        #"ensureColumn(table: "agent_memories", column: "review_status", definition: "TEXT NOT NULL DEFAULT 'quarantined'")"#
    /// The GRDB spelling of the same default, in both hand-mirrored trees.
    private static let migratorColumn =
        #"t.add(column: "review_status", .text).notNull().defaults(to: "quarantined")"#

    // MARK: - Source parity

    func testTheDaemonBootstrapDefaultsReviewStatusToQuarantined() throws {
        let bootstrap = try MemorySchemaSource.text(at: Self.daemonBootstrapPath)
        XCTAssertTrue(
            bootstrap.contains(Self.daemonColumn),
            """
            The daemon's `CREATE TABLE agent_memories` must declare \
            `\(Self.daemonColumn)`. A write that names no review status is a write \
            nobody vouched for, and it belongs in review (D-0005 / I-57).
            """
        )
        XCTAssertTrue(
            bootstrap.contains(Self.daemonEnsureColumn),
            "the ALTER that adds the column to a pre-review database must agree with the CREATE TABLE"
        )
        XCTAssertFalse(
            bootstrap.contains("review_status TEXT NOT NULL DEFAULT 'approved'"),
            "the fail-open default is gone, not merely shadowed by a second statement"
        )
    }

    /// The two hand-mirrored migration trees, which have said `quarantined` since
    /// v51 and are the reason the bootstrap was the drifted one.
    func testBothMigrationTreesDeclareTheSameReviewStatusDefault() throws {
        for path in [Self.dataMigrationPath, Self.appMigrationPath] {
            let migration = try MemorySchemaSource.text(at: path)
            XCTAssertTrue(
                migration.contains(Self.migratorColumn),
                "the v51 migration in \(path) must add `review_status` fail-closed"
            )
        }
    }

    // MARK: - Behaviour on a real store

    /// Source equality is not the property; what SQLite applies is. So bootstrap a
    /// real store and INSERT a row that names no `review_status` at all — the
    /// forgetful future writer this default exists for — and read back where it
    /// landed.
    func testARowWrittenWithoutAReviewStatusLandsInReview() throws {
        let fixture = try makeFixture()
        _ = try BurnBarProjectCodeMemoryStore(
            databasePath: fixture.database.path,
            logger: BurnBarDaemonLogger(category: "review-status-default-test")
        )

        try execute(
            sql: """
            INSERT INTO agent_memories
                (id, project_id, kind, scope, confidence, body_ref, body_redacted, tags_json,
                 valid_from, created_at, updated_at)
            VALUES ('mem_forgetful', 'prj_fixture', 'fact', 'project', 0.5, '', '', '[]',
                    '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')
            """,
            on: fixture.database
        )

        XCTAssertEqual(
            try queryStrings(
                sql: "SELECT review_status FROM agent_memories WHERE id = 'mem_forgetful'",
                on: fixture.database
            ),
            ["quarantined"],
            """
            a write that named no review status landed approved before I-57 — \
            the storage layer's own version of the default D-0005 closed on the wire
            """
        )
    }

    /// And the other half of the migration note: a row that says `approved`
    /// stays approved. Nothing about this change re-reviews a memory a member
    /// already has — every writer names the column, so the default is only ever
    /// reached by a writer that does not.
    func testAnExplicitlyApprovedRowIsUntouchedByTheDefault() throws {
        let fixture = try makeFixture()
        let store = try BurnBarProjectCodeMemoryStore(
            databasePath: fixture.database.path,
            logger: BurnBarDaemonLogger(category: "review-status-default-approved-test")
        )
        let written = try store.remember(
            BurnBarProjectMemoryRememberRequest(
                text: "Repository knowledge the daemon has always recalled.",
                projectPath: fixture.project.path,
                kind: "fact",
                scope: "project",
                reviewStatus: .approved
            )
        )

        XCTAssertEqual(
            try queryStrings(
                sql: "SELECT review_status FROM agent_memories WHERE id = '\(written.memoryID)'",
                on: fixture.database
            ),
            ["approved"],
            "an explicit verdict is still believed — the default is a floor, not a ceiling"
        )
        XCTAssertFalse(
            try store.recall(
                BurnBarProjectMemoryRecallRequest(query: "repository knowledge", projectPath: fixture.project.path)
            ).hits.isEmpty,
            "and it is still recallable, which is what 'no existing row changes' means to a member"
        )
    }

    // MARK: - SQLite

    private func makeFixture() throws -> (root: URL, project: URL, database: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewStatusDefaultTests-\(UUID().uuidString)", isDirectory: true)
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
        XCTAssertEqual(status, SQLITE_OK, "executing the fixture write failed: \(message)")
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
