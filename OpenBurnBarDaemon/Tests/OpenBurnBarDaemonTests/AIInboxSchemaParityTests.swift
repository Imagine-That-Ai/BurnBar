import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

/// The AI Inbox tables are created in three places against ONE database file:
/// the daemon store, the `OpenBurnBarData` migration, and the AgentLens mirror
/// of that migration. Drift between them is the classic silent-corruption bug in
/// this repo's two-tree migration setup.
///
/// This suite reads the two migration files from source and asserts they are
/// byte-identical to each other and structurally identical to the daemon DDL, so
/// a change to one that is not mirrored fails the build rather than a user's
/// database.
final class AIInboxSchemaParityTests: XCTestCase {
    private static let dataMigrationPath =
        "OpenBurnBarCore/Sources/OpenBurnBarData/OpenBurnBarDatabase+DataMigrationV58.swift"
    private static let appMigrationPath =
        "AgentLens/Services/DataStore/OpenBurnBarDatabase+MigrationV58.swift"
    private static let dataFounderLensMigrationPath =
        "OpenBurnBarCore/Sources/OpenBurnBarData/OpenBurnBarDatabase+DataMigrationV59.swift"
    private static let appFounderLensMigrationPath =
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

    /// Extracts the `aiInboxSchemaStatements` array literal.
    private static func statementsBlock(from source: String) -> String? {
        statementsBlock(from: source, marker: "static let aiInboxSchemaStatements: [String] = [")
    }

    private static func statementsBlock(from source: String, marker: String) -> String? {
        guard let start = source.range(of: marker) else {
            return nil
        }
        let remainder = source[start.upperBound...]
        guard let end = remainder.range(of: "\n    ]") else { return nil }
        return String(remainder[..<end.lowerBound])
    }

    func test_bothMigrationTreesDeclareIdenticalDDL() throws {
        guard let dataSource = try Self.source(at: Self.dataMigrationPath),
              let appSource = try Self.source(at: Self.appMigrationPath) else {
            throw XCTSkip("Repository sources are not reachable from this test environment.")
        }

        let dataBlock = try XCTUnwrap(
            Self.statementsBlock(from: dataSource),
            "Could not find the DDL block in \(Self.dataMigrationPath)"
        )
        let appBlock = try XCTUnwrap(
            Self.statementsBlock(from: appSource),
            "Could not find the DDL block in \(Self.appMigrationPath)"
        )

        XCTAssertEqual(
            dataBlock,
            appBlock,
            """
            The v58 AI Inbox DDL has drifted between the two migration trees. \
            Both files must declare byte-identical statements — update them in the same commit.
            """
        )
    }

    func test_bothMigrationTreesRegisterTheSameMigrationIdentifier() throws {
        guard let dataSource = try Self.source(at: Self.dataMigrationPath),
              let appSource = try Self.source(at: Self.appMigrationPath) else {
            throw XCTSkip("Repository sources are not reachable from this test environment.")
        }
        for source in [dataSource, appSource] {
            XCTAssertTrue(
                source.contains("migrator.registerMigration(\"v58_ai_inbox\")"),
                "Both trees must register the identical migration identifier"
            )
        }
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

                Add it to both migration trees in the same commit.
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

    func test_founderLensMigrationTreesDeclareIdenticalDDL() throws {
        guard let dataSource = try Self.source(at: Self.dataFounderLensMigrationPath),
              let appSource = try Self.source(at: Self.appFounderLensMigrationPath) else {
            throw XCTSkip("Repository sources are not reachable from this test environment.")
        }
        let marker = "static let founderLensSchemaStatements: [String] = ["
        let dataBlock = try XCTUnwrap(
            Self.statementsBlock(from: dataSource, marker: marker),
            "Could not find the DDL block in \(Self.dataFounderLensMigrationPath)"
        )
        let appBlock = try XCTUnwrap(
            Self.statementsBlock(from: appSource, marker: marker),
            "Could not find the DDL block in \(Self.appFounderLensMigrationPath)"
        )
        XCTAssertEqual(
            dataBlock,
            appBlock,
            """
            The v59 Founder Lens DDL has drifted between the two migration trees. \
            Both files must declare byte-identical statements — update them in the same commit.
            """
        )
    }

    func test_founderLensMigrationTreesRegisterTheSameIdentifier() throws {
        guard let dataSource = try Self.source(at: Self.dataFounderLensMigrationPath),
              let appSource = try Self.source(at: Self.appFounderLensMigrationPath) else {
            throw XCTSkip("Repository sources are not reachable from this test environment.")
        }
        for source in [dataSource, appSource] {
            XCTAssertTrue(
                source.contains("migrator.registerMigration(\"v59_founder_lens\")"),
                "Both trees must register the identical v59 migration identifier"
            )
        }
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

                Add it to both migration trees in the same commit.
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

        let tables = Set(
            try store.queryRows(
                "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'ai_inbox%'",
                []
            ).map { $0.string(0) }
        )
        XCTAssertEqual(
            tables,
            [
                // v58
                "ai_inbox_items", "ai_inbox_runs", "ai_inbox_state", "ai_inbox_item_state",
                // v59 Founder Lens
                "ai_inbox_threads", "ai_inbox_thread_messages",
                "ai_inbox_plans", "ai_inbox_plan_steps", "ai_inbox_plan_events",
                "ai_inbox_memory_export"
            ]
        )
    }
}
