import Foundation
import OpenBurnBarCore
import SQLite3
@testable import OpenBurnBarDaemon
import XCTest

final class BurnBarProjectCodeMemoryStoreTests: XCTestCase {
    func testIndexSearchSymbolsReferencesCallGraphAndStatus() throws {
        let fixture = try makeFixture()
        try write(
            """
            struct Runner {
                func start() {
                    helper()
                }
            }

            func helper() {}
            """,
            to: fixture.project.appendingPathComponent("Sources").appendingPathComponent("App.swift")
        )
        try write(
            #"let token = "sk-abcdefghijklmnopqrstuvwxyz123456""#,
            to: fixture.project.appendingPathComponent("Sources").appendingPathComponent("Secret.swift")
        )

        let store = try BurnBarProjectCodeMemoryStore(databasePath: fixture.database.path, logger: BurnBarDaemonLogger(category: "test"))
        let indexed = try store.indexProject(
            BurnBarProjectCodeIndexProjectRequest(projectPath: fixture.project.path, maxFiles: 20)
        )

        XCTAssertEqual(indexed.indexedFiles, 1)
        XCTAssertEqual(indexed.rejectedFiles.map(\.filePath), ["Sources/Secret.swift"])
        XCTAssertGreaterThanOrEqual(indexed.symbolCount, 2)

        let search = try store.searchCode(BurnBarProjectCodeSearchRequest(query: "helper", projectPath: fixture.project.path))
        XCTAssertTrue(search.hits.contains { $0.filePath == "Sources/App.swift" })

        let symbol = try store.getSymbol(BurnBarProjectCodeSymbolRequest(name: "helper", projectPath: fixture.project.path))
        XCTAssertEqual(symbol.symbols.first?.name, "helper")

        let references = try store.findReferences(BurnBarProjectCodeSymbolRequest(name: "helper", projectPath: fixture.project.path))
        XCTAssertTrue(references.references.contains { $0.fromFilePath == "Sources/App.swift" })

        let graph = try store.callGraph(BurnBarProjectCodeSymbolRequest(name: "helper", projectPath: fixture.project.path))
        XCTAssertTrue(graph.edges.contains { $0.callee.name == "helper" })

        let status = try store.indexStatus(BurnBarProjectCodeIndexStatusRequest(projectPath: fixture.project.path))
        XCTAssertEqual(status.artifactCount, 1)
        XCTAssertGreaterThanOrEqual(status.symbolCount, 2)
        XCTAssertEqual(status.rejectedCount, 1)
    }

    func testExploreWithQueryReturnsContextPackPayload() throws {
        let fixture = try makeFixture()
        try write(
            """
            func exploreTarget() {
                print("explore-context-token")
            }
            """,
            to: fixture.project.appendingPathComponent("Sources").appendingPathComponent("Explore.swift")
        )

        let store = try BurnBarProjectCodeMemoryStore(databasePath: fixture.database.path, logger: BurnBarDaemonLogger(category: "test"))
        let explored = try store.explore(
            BurnBarProjectCodeExploreRequest(
                projectPath: fixture.project.path,
                query: "explore-context-token",
                limit: 5,
                maxBytes: 2_000
            )
        )

        XCTAssertTrue(explored.files.contains { $0.filePath == "Sources/Explore.swift" })
        XCTAssertTrue(explored.context?.contains("explore-context-token") ?? false)
        XCTAssertTrue(explored.hits.contains { $0.filePath == "Sources/Explore.swift" })
        XCTAssertFalse(explored.truncated)
    }

    func testStaticTreeSitterTierWhenHelperIsAvailable() throws {
        try skipUnlessStaticParserHelperExists()
        let fixture = try makeFixture()
        try write(
            """
            struct TreeSitterTarget {
                func parsedByHelper() {}
            }
            """,
            to: fixture.project.appendingPathComponent("Sources").appendingPathComponent("Static.swift")
        )

        let store = try BurnBarProjectCodeMemoryStore(databasePath: fixture.database.path, logger: BurnBarDaemonLogger(category: "test"))
        _ = try store.indexProject(BurnBarProjectCodeIndexProjectRequest(projectPath: fixture.project.path, maxFiles: 20))

        let symbol = try store.getSymbol(BurnBarProjectCodeSymbolRequest(name: "TreeSitterTarget", projectPath: fixture.project.path))
            .symbols
            .first
        XCTAssertEqual(symbol?.confidenceTier, "static_tree_sitter")
        XCTAssertEqual(symbol?.tierEvidence?.parser, "tree-sitter")
        XCTAssertEqual(symbol?.tierEvidence?.shaMatch, true)
        XCTAssertEqual(symbol?.tierEvidence?.details["helper"], "project-code-static-parser")
    }

    func testRememberRecallForgetAndAuditTrail() throws {
        let fixture = try makeFixture()
        let store = try BurnBarProjectCodeMemoryStore(databasePath: fixture.database.path, logger: BurnBarDaemonLogger(category: "test"))

        let remembered = try store.remember(
            BurnBarProjectMemoryRememberRequest(
                text: "Use the project code memory store for lexical symbol fallback.",
                projectPath: fixture.project.path,
                tags: ["architecture"]
            )
        )
        XCTAssertTrue(remembered.memoryID.hasPrefix("mem_"))

        let recall = try store.recall(
            BurnBarProjectMemoryRecallRequest(query: "lexical symbol", projectPath: fixture.project.path)
        )
        XCTAssertEqual(recall.hits.first?.memoryID, remembered.memoryID)

        let forgotten = try store.forget(
            BurnBarProjectMemoryForgetRequest(memoryID: remembered.memoryID, projectPath: fixture.project.path, requireCloudDelete: true)
        )
        XCTAssertTrue(forgotten.localDeleted)
        XCTAssertTrue(forgotten.cloudDeletePending)

        let afterForget = try store.recall(
            BurnBarProjectMemoryRecallRequest(query: "lexical symbol", projectPath: fixture.project.path)
        )
        XCTAssertTrue(afterForget.hits.isEmpty)

        let audit = try store.auditTrail(BurnBarProjectMemoryAuditTrailRequest(projectPath: fixture.project.path))
        XCTAssertTrue(audit.events.contains { $0.action == "memory.remember" })
        XCTAssertTrue(audit.events.contains { $0.action == "memory.forget" && $0.labels.contains("cloud hard delete pending") })
    }

    func testRememberStoresBodyInProjectMemorySnapshotNotAgentIndex() throws {
        let fixture = try makeFixture()
        let store = try BurnBarProjectCodeMemoryStore(databasePath: fixture.database.path, logger: BurnBarDaemonLogger(category: "test"))
        let body = "Use snapshot canonical storage for the agent memory raw body boundary."

        let remembered = try store.remember(
            BurnBarProjectMemoryRememberRequest(text: body, projectPath: fixture.project.path, tags: ["boundary"])
        )

        let agentIndex = try sqliteStrings(database: fixture.database, sql: "SELECT body_redacted FROM agent_memories")
        XCTAssertEqual(agentIndex.count, 1)
        XCTAssertFalse(agentIndex.joined(separator: "\n").contains(body))
        XCTAssertTrue(agentIndex[0].contains(remembered.memoryID))

        let memoryFTS = try sqliteStrings(database: fixture.database, sql: "SELECT bodyText FROM agent_memories_fts")
        XCTAssertFalse(memoryFTS.joined(separator: "\n").contains(body))

        let snapshots = try sqliteStrings(database: fixture.database, sql: "SELECT snapshotJSON FROM project_memory_snapshots")
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertTrue(snapshots[0].contains(body))
        XCTAssertTrue(snapshots[0].contains(remembered.memoryID))

        let recall = try store.recall(BurnBarProjectMemoryRecallRequest(query: "raw body boundary", projectPath: fixture.project.path))
        XCTAssertEqual(recall.hits.first?.bodyRedacted, body)
    }

    func testRememberRejectsSecretsWithLabelOnlyAudit() throws {
        let fixture = try makeFixture()
        let store = try BurnBarProjectCodeMemoryStore(databasePath: fixture.database.path, logger: BurnBarDaemonLogger(category: "test"))

        XCTAssertThrowsError(
            try store.remember(
                BurnBarProjectMemoryRememberRequest(
                    text: "token sk-abcdefghijklmnopqrstuvwxyz123456",
                    projectPath: fixture.project.path
                )
            )
        )

        let audit = try store.auditTrail(BurnBarProjectMemoryAuditTrailRequest(projectPath: fixture.project.path))
        let rejection = audit.events.first { $0.action == "memory.secret_rejected" }
        XCTAssertNotNil(rejection)
        XCTAssertEqual(rejection?.labels, ["OpenAI API key detected"])
        XCTAssertFalse(rejection?.labels.joined(separator: " ").contains("sk-") ?? true)
    }

    func testProjectPartitionPreventsCodeAndMemoryBleedAcrossRepos() throws {
        let fixture = try makeFixture()
        let repoA = fixture.root.appendingPathComponent("RepoA", isDirectory: true)
        let repoB = fixture.root.appendingPathComponent("RepoB", isDirectory: true)
        try FileManager.default.createDirectory(at: repoA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoB, withIntermediateDirectories: true)
        try write("func alphaOnly() { print(\"alphauniqueterm\") }\n", to: repoA.appendingPathComponent("A.swift"))
        try write("func betaOnly() { print(\"betauniqueterm\") }\n", to: repoB.appendingPathComponent("B.swift"))

        let store = try BurnBarProjectCodeMemoryStore(databasePath: fixture.database.path, logger: BurnBarDaemonLogger(category: "test"))
        _ = try store.indexProject(BurnBarProjectCodeIndexProjectRequest(projectPath: repoA.path, maxFiles: 20))
        _ = try store.indexProject(BurnBarProjectCodeIndexProjectRequest(projectPath: repoB.path, maxFiles: 20))
        _ = try store.remember(BurnBarProjectMemoryRememberRequest(text: "alpha memory alphaonlymemoryterm.", projectPath: repoA.path))
        _ = try store.remember(BurnBarProjectMemoryRememberRequest(text: "beta memory betaonlymemoryterm.", projectPath: repoB.path))

        let codeBleed = try store.searchCode(BurnBarProjectCodeSearchRequest(query: "betauniqueterm", projectPath: repoA.path))
        XCTAssertTrue(codeBleed.hits.isEmpty)

        let memoryBleed = try store.recall(BurnBarProjectMemoryRecallRequest(query: "betaonlymemoryterm", projectPath: repoA.path))
        XCTAssertTrue(memoryBleed.hits.isEmpty)

        let explicitCrossProject = try store.recall(
            BurnBarProjectMemoryRecallRequest(query: "betaonlymemoryterm", projectPath: repoA.path, includeCrossProject: true)
        )
        XCTAssertFalse(explicitCrossProject.hits.isEmpty)
    }

    func testStaleCodeArtifactsAreSuppressedUntilReindexed() throws {
        let fixture = try makeFixture()
        let source = fixture.project.appendingPathComponent("Sources").appendingPathComponent("Stale.swift")
        try write(
            """
            func staleHelper() {
                print("stale-token")
            }
            """,
            to: source
        )

        let store = try BurnBarProjectCodeMemoryStore(databasePath: fixture.database.path, logger: BurnBarDaemonLogger(category: "test"))
        _ = try store.indexProject(BurnBarProjectCodeIndexProjectRequest(projectPath: fixture.project.path, maxFiles: 20))
        XCTAssertFalse(try store.searchCode(BurnBarProjectCodeSearchRequest(query: "stale-token", projectPath: fixture.project.path)).hits.isEmpty)
        XCTAssertFalse(try store.getSymbol(BurnBarProjectCodeSymbolRequest(name: "staleHelper", projectPath: fixture.project.path)).symbols.isEmpty)

        try write(
            """
            func freshHelper() {
                print("fresh-token")
            }
            """,
            to: source
        )

        XCTAssertTrue(try store.searchCode(BurnBarProjectCodeSearchRequest(query: "stale-token", projectPath: fixture.project.path)).hits.isEmpty)
        XCTAssertTrue(try store.getSymbol(BurnBarProjectCodeSymbolRequest(name: "staleHelper", projectPath: fixture.project.path)).symbols.isEmpty)

        _ = try store.indexProject(BurnBarProjectCodeIndexProjectRequest(projectPath: fixture.project.path, maxFiles: 20))
        XCTAssertFalse(try store.searchCode(BurnBarProjectCodeSearchRequest(query: "fresh-token", projectPath: fixture.project.path)).hits.isEmpty)
        XCTAssertFalse(try store.getSymbol(BurnBarProjectCodeSymbolRequest(name: "freshHelper", projectPath: fixture.project.path)).symbols.isEmpty)
    }

    func testIndexProjectHonorsGitignoreSymlinkEscapeAndMaxFilesCap() throws {
        let fixture = try makeFixture()
        try ".ignored/\n".write(to: fixture.project.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try write("func keptOne() {}\n", to: fixture.project.appendingPathComponent("Sources").appendingPathComponent("One.swift"))
        try write("func keptTwo() {}\n", to: fixture.project.appendingPathComponent("Sources").appendingPathComponent("Two.swift"))
        try write("func keptThree() {}\n", to: fixture.project.appendingPathComponent("Sources").appendingPathComponent("Three.swift"))
        try write("func ignoredSymbol() {}\n", to: fixture.project.appendingPathComponent(".ignored").appendingPathComponent("Ignored.swift"))

        let outside = fixture.root.appendingPathComponent("Outside.swift")
        try write("func outsideEscaped() {}\n", to: outside)
        let link = fixture.project.appendingPathComponent("Sources").appendingPathComponent("OutsideLink.swift")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let store = try BurnBarProjectCodeMemoryStore(databasePath: fixture.database.path, logger: BurnBarDaemonLogger(category: "test"))
        let indexed = try store.indexProject(BurnBarProjectCodeIndexProjectRequest(projectPath: fixture.project.path, maxFiles: 2))

        XCTAssertEqual(indexed.indexedFiles, 2)
        XCTAssertTrue(try store.getSymbol(BurnBarProjectCodeSymbolRequest(name: "ignoredSymbol", projectPath: fixture.project.path)).symbols.isEmpty)
        XCTAssertTrue(try store.getSymbol(BurnBarProjectCodeSymbolRequest(name: "outsideEscaped", projectPath: fixture.project.path)).symbols.isEmpty)
    }

    func testIndexProjectEnforcesStorageBudgetAndReportsVacuumMetadata() throws {
        let fixture = try makeFixture()
        try write("func smallBudgetKept() {}\n", to: fixture.project.appendingPathComponent("Sources").appendingPathComponent("Kept.swift"))
        try write(
            String(repeating: "func overBudget() {}\n", count: 20),
            to: fixture.project.appendingPathComponent("Sources").appendingPathComponent("OverBudget.swift")
        )

        let store = try BurnBarProjectCodeMemoryStore(databasePath: fixture.database.path, logger: BurnBarDaemonLogger(category: "test"))
        let indexed = try store.indexProject(
            BurnBarProjectCodeIndexProjectRequest(
                projectPath: fixture.project.path,
                maxFiles: 20,
                maxFileBytes: 10_000,
                storageBudgetBytes: 80
            )
        )

        XCTAssertEqual(indexed.indexedFiles, 1)
        XCTAssertEqual(indexed.rejectedFiles.first?.labels, ["Storage budget cap reached"])

        let status = try store.indexStatus(BurnBarProjectCodeIndexStatusRequest(projectPath: fixture.project.path))
        XCTAssertLessThanOrEqual(status.storageByteCount, status.storageBudgetBytes)
        XCTAssertEqual(status.storageBudgetBytes, 80)
        XCTAssertTrue(status.storageWithinBudget)
        XCTAssertNotNil(status.lastVacuumedAt)
    }

    func testWatchProjectReindexesWhenSourceChanges() throws {
        let fixture = try makeFixture()
        let source = fixture.project.appendingPathComponent("Sources").appendingPathComponent("Watched.swift")
        try write("func watchedOld() { print(\"old-watch-token\") }\n", to: source)

        let store = try BurnBarProjectCodeMemoryStore(databasePath: fixture.database.path, logger: BurnBarDaemonLogger(category: "test"))
        let watch = try store.watchProject(
            BurnBarProjectCodeWatchProjectRequest(
                projectPath: fixture.project.path,
                maxFiles: 20,
                maxFileBytes: 10_000,
                pollIntervalSeconds: 0.25
            )
        )
        XCTAssertTrue(watch.watching)
        XCTAssertEqual(watch.indexedFiles, 1)
        XCTAssertFalse(try store.searchCode(BurnBarProjectCodeSearchRequest(query: "old-watch-token", projectPath: fixture.project.path)).hits.isEmpty)

        try write("func watchedNew() { print(\"new-watch-token\") }\n", to: source)

        let deadline = Date().addingTimeInterval(4.0)
        var reindexed = false
        while Date() < deadline {
            let hits = try store.searchCode(BurnBarProjectCodeSearchRequest(query: "new-watch-token", projectPath: fixture.project.path))
            if hits.hits.isEmpty == false {
                reindexed = true
                break
            }
            Thread.sleep(forTimeInterval: 0.15)
        }

        XCTAssertTrue(reindexed)
        XCTAssertTrue(try store.getSymbol(BurnBarProjectCodeSymbolRequest(name: "watchedOld", projectPath: fixture.project.path)).symbols.isEmpty)
        XCTAssertFalse(try store.getSymbol(BurnBarProjectCodeSymbolRequest(name: "watchedNew", projectPath: fixture.project.path)).symbols.isEmpty)
    }

    func testSecretScannerCoversSharedCorpusWithLabelOnlyAudit() throws {
        let fixture = try makeFixture()
        let cases: [(String, String)] = [
            ("openai sk-abcdefghijklmnopqrstuvwxyz123456", "OpenAI API key detected"),
            ("anthropic sk-ant-abcdefghijklmnopqrstuvwxyz123456", "Anthropic API key detected"),
            ("stripe " + "sk_live_" + "abcdefghijklmnopqrstuvwxyz123456", "Stripe secret key detected"),
            ("github " + "ghp_" + "123456789012345678901234567890123456", "GitHub token detected"),
            ("google AIza12345678901234567890123456789012345", "Google API key detected"),
            ("slack " + "xoxb-" + "1234567890-abcdefghijklmnop", "Slack token detected"),
            ("xai xai-abcdefghijklmnopqrstuvwxyz123456", "xAI API key detected"),
            ("aws AKIA1234567890ABCDEF", "AWS access key detected"),
            ("pem -----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----", "Private key block detected"),
            ("db postgres://user:supersecretpassword@localhost/db", "Database URI credentials detected"),
            ("generic api_key=abcdefghijklmnopqrstuvwxyz123456", "Generic long secret assignment detected"),
            ("dotenv\nOPENBURNBAR_TOKEN=abcdefghijklmnopqrstuvwxyz123456", "Dotenv secret assignment detected"),
            ("jwt eyJabcdefghijk.eyJabcdefghijklmnop.abcdefghijklmnop", "JWT detected"),
            ("email person@example.com", "Email address detected"),
            ("ip 192.168.20.15", "IPv4 address detected"),
            ("card 4111 1111 1111 1111", "Credit card number detected"),
            ("ssn 123-45-6789", "US SSN detected"),
            ("phone 312-555-0199", "US phone number detected")
        ]
        let store = try BurnBarProjectCodeMemoryStore(databasePath: fixture.database.path, logger: BurnBarDaemonLogger(category: "test"))

        for (text, expectedLabel) in cases {
            XCTAssertThrowsError(
                try store.remember(BurnBarProjectMemoryRememberRequest(text: text, projectPath: fixture.project.path)),
                "Expected scanner rejection for \(expectedLabel)"
            )
        }

        let audit = try store.auditTrail(BurnBarProjectMemoryAuditTrailRequest(projectPath: fixture.project.path, limit: 200))
        let labels = Set(audit.events.flatMap(\.labels))
        for (_, expectedLabel) in cases {
            XCTAssertTrue(labels.contains(expectedLabel), "Missing scanner label \(expectedLabel)")
        }
        let serializedAudit = String(data: try JSONEncoder().encode(audit.events), encoding: .utf8) ?? ""
        XCTAssertFalse(serializedAudit.contains("ghp_"))
        let stripePrefix = "sk" + "_live_"
        XCTAssertFalse(serializedAudit.contains(stripePrefix))
        XCTAssertFalse(serializedAudit.contains("AKIA1234567890ABCDEF"))
    }

    private func makeFixture() throws -> (root: URL, project: URL, database: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectCodeMemoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("FixtureProject", isDirectory: true)
        let sources = project.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("openburnbar.sqlite", isDirectory: false)
        FileManager.default.createFile(atPath: database.path, contents: nil)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return (root, project, database)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func sqliteStrings(database: URL, sql: String) throws -> [String] {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        guard let db else { return [] }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK)
        guard let statement else { return [] }
        defer { sqlite3_finalize(statement) }

        var values: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) {
                values.append(String(cString: text))
            }
        }
        return values
    }

    private func skipUnlessStaticParserHelperExists() throws {
        let cwd = FileManager.default.currentDirectoryPath
        let candidates = [
            "\(cwd)/crates/project-code-static-parser/target/debug/project-code-static-parser",
            "\(cwd)/crates/project-code-static-parser/target/release/project-code-static-parser",
            "\(cwd)/../crates/project-code-static-parser/target/debug/project-code-static-parser",
            "\(cwd)/../crates/project-code-static-parser/target/release/project-code-static-parser"
        ]
        guard candidates.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("project-code-static-parser helper has not been built")
        }
    }
}
