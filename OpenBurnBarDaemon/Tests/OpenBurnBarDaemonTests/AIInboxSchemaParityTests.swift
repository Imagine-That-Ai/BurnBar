import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

/// The AI Inbox tables are created in two places against ONE database file:
/// the daemon store and the one GRDB migrator (`v58_ai_inbox` /
/// `v59_founder_lens` in `OpenBurnBarData`). Wave 2.2 deleted the AgentLens
/// mirror of those migrations, so the app runs this same registry — there is
/// no second text to drift.
///
/// This suite pins the daemon's statements against the migrator's and asserts
/// the deleted mirror stays deleted, so a change that is not in the one
/// registry fails the build rather than a user's database.
final class AIInboxSchemaParityTests: XCTestCase {
    private static let dataMigrationPath =
        "OpenBurnBarCore/Sources/OpenBurnBarData/OpenBurnBarDatabase+DataMigrationV58.swift"
    private static let deletedAppMigrationPath =
        "AgentLens/Services/DataStore/OpenBurnBarDatabase+MigrationV58.swift"
    private static let dataFounderLensMigrationPath =
        "OpenBurnBarCore/Sources/OpenBurnBarData/OpenBurnBarDatabase+DataMigrationV59.swift"
    private static let deletedAppFounderLensMigrationPath =
        "AgentLens/Services/DataStore/OpenBurnBarDatabase+MigrationV59.swift"

    /// Walks up from this file to the repository root so the test works from any
    /// working directory (`swift test`, Xcode, CI).
    private static func repositoryRoot() -> URL? {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<8 {
            url = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("AGENTS.md").path) {
                return url
            }
        }
        return nil
    }

    private static func source(at relativePath: String) throws -> String? {
        guard let root = repositoryRoot() else { return nil }
        let url = root.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("Missing migration file: \(relativePath)")
            return nil
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func statementsBlock(from source: String, marker: String) -> String? {
        guard let start = source.range(of: marker) else {
            return nil
        }
        let remainder = source[start.upperBound...]
        guard let end = remainder.range(of: "\n    ]") else { return nil }
        return String(remainder[..<end.lowerBound])
    }

    /// The v58 / v59 DDL lives in exactly one file each now.
    func test_agentLensMirrorStaysDeleted() throws {
        guard let root = Self.repositoryRoot() else {
            throw XCTSkip("Repository sources are not reachable from this test environment.")
        }
        for relativePath in [Self.deletedAppMigrationPath, Self.deletedAppFounderLensMigrationPath] {
            try MemorySchemaSource.assertAgentLensMirrorDeleted(relativePath, under: root)
        }
    }

    func test_singleMigratorRegistersTheExpectedIdentifier() throws {
        guard let dataSource = try Self.source(at: Self.dataMigrationPath) else {
            throw XCTSkip("Repository sources are not reachable from this test environment.")
        }
        XCTAssertTrue(
            dataSource.contains("migrator.registerMigration(\"v58_ai_inbox\")"),
            "The single migrator must register the v58 migration identifier"
        )
    }

    /// The daemon creates these tables itself (so a pre-migration profile still
    /// works). Its DDL must therefore describe the same tables and columns the
    /// migrations do.
    func test_daemonDDLMatchesMigrationDDL() throws {
        guard let dataSource = try Self.source(at: Self.dataMigrationPath) else {
            throw XCTSkip("Repository sources are not reachable from this test environment.")
        }

        for statement in BurnBarAIInboxSchema.statements {
            let normalized = Self.normalize(statement)
            let migrationContainsIt = Self.normalize(dataSource).contains(normalized)
            XCTAssertTrue(
                migrationContainsIt,
                """
                The daemon creates a table/index the v58 migration does not:

                \(statement)

                Add it to the single migrator.
                """
            )
        }
    }

    /// Collapses whitespace so indentation differences between a Swift multiline
    /// string in the daemon and one in a migration do not read as drift.
    private static func normalize(_ sql: String) -> String {
        sql
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - v59 Founder Lens parity

    /// The v59 DDL block must still exist in the single migrator (and only
    /// there — the mirror-gone test above covers the deleted path).
    func test_founderLensDDLBlockExistsInSingleMigrator() throws {
        guard let dataSource = try Self.source(at: Self.dataFounderLensMigrationPath) else {
            throw XCTSkip("Repository sources are not reachable from this test environment.")
        }
        let marker = "static let founderLensSchemaStatements: [String] = ["
        XCTAssertNotNil(
            Self.statementsBlock(from: dataSource, marker: marker),
            "Could not find the DDL block in \(Self.dataFounderLensMigrationPath)"
        )
    }

    func test_founderLensMigratorRegistersTheExpectedIdentifier() throws {
        guard let dataSource = try Self.source(at: Self.dataFounderLensMigrationPath) else {
            throw XCTSkip("Repository sources are not reachable from this test environment.")
        }
        XCTAssertTrue(
            dataSource.contains("migrator.registerMigration(\"v59_founder_lens\")"),
            "The single migrator must register the v59 migration identifier"
        )
    }

    func test_daemonFounderLensDDLMatchesMigrationDDL() throws {
        guard let dataSource = try Self.source(at: Self.dataFounderLensMigrationPath) else {
            throw XCTSkip("Repository sources are not reachable from this test environment.")
        }
        for statement in BurnBarAIInboxSchema.founderLensStatements {
            let normalized = Self.normalize(statement)
            XCTAssertTrue(
                Self.normalize(dataSource).contains(normalized),
                """
                The daemon creates a Founder Lens table/index the v59 migration does not:

                \(statement)

                Add it to the single migrator.
                """
            )
        }
    }

    // MARK: - Live schema shape

    /// Guards the invariants the rest of the feature depends on, verified against
    /// a real database rather than the source text.
    func test_liveSchemaHasTheDedupeInvariant() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-inbox-schema-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try BurnBarAIInboxStore(
            databasePath: url.path,
            logger: BurnBarDaemonLogger(category: "test")
        )

        let indexes = try store.queryRows(
            "SELECT name, sql FROM sqlite_master WHERE type = 'index' AND name LIKE 'ai_inbox%'",
            []
        ).map { ($0.string(0), $0.optionalString(1) ?? "") }

        let uniqueIndex = try XCTUnwrap(
            indexes.first { $0.0 == "ai_inbox_items_open_fingerprint_idx" },
            "The open-fingerprint unique index must exist — it IS the dedupe rule"
        )
        XCTAssertTrue(
            uniqueIndex.1.contains("UNIQUE"),
            "The index must be UNIQUE or duplicates can be written"
        )
        XCTAssertTrue(
            uniqueIndex.1.contains("WHERE state IN ('new', 'updated')"),
            "The index must be PARTIAL so resolved history is retained"
        )
    }

    func testCanonicalSharedDatabaseDoesNotSelfHealSchema() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar.sqlite")
        try? FileManager.default.removeItem(at: url)
        defer { try? FileManager.default.removeItem(at: url) }
        FileManager.default.createFile(atPath: url.path, contents: nil)

        XCTAssertThrowsError(
            try BurnBarAIInboxStore(
                databasePath: url.path,
                logger: BurnBarDaemonLogger(category: "test")
            )
        ) { error in
            let text = String(describing: error)
            XCTAssertTrue(
                text.contains("app migrator") || text.contains("missing") || text.contains("Failed to open"),
                "canonical openburnbar.sqlite must not CREATE inbox tables; got \(text)"
            )
        }

        let bytes = (try? Data(contentsOf: url)) ?? Data()
        let ascii = String(data: bytes, encoding: .ascii) ?? ""
        XCTAssertFalse(
            ascii.contains("ai_inbox_items"),
            "fail-closed open must not write inbox DDL into canonical openburnbar.sqlite"
        )
    }
}
