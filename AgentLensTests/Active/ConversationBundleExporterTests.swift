import XCTest
@testable import OpenBurnBar
import OpenBurnBarCore

/// Verifies the Mac "Export all conversations" bundle: folder layout, JSON
/// manifest round-trip, per-conversation Markdown, README index, the
/// `bodyProvider` seam, and filename collision handling.
final class ConversationBundleExporterTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    private func makeRecord(
        provider: AgentProvider = .claudeCode,
        sessionId: String,
        title: String,
        project: String = "demo-project",
        messages: Int = 2,
        fullText: String = "user turn\n\nassistant turn"
    ) -> ConversationRecord {
        ConversationRecord(
            id: ConversationRecord.stableId(provider: provider, sessionId: sessionId),
            provider: provider,
            sessionId: sessionId,
            projectName: project,
            startTime: Date(timeIntervalSince1970: 1_716_200_000),
            endTime: Date(timeIntervalSince1970: 1_716_200_600),
            messageCount: messages,
            userWordCount: 4,
            assistantWordCount: 6,
            keyFiles: ["src/main.swift"],
            keyCommands: ["swift build"],
            keyTools: ["Edit"],
            inferredTaskTitle: title,
            lastAssistantMessage: "assistant turn",
            fullText: fullText,
            fileModifiedAt: nil
        )
    }

    func testExportProducesFolderJsonAndMarkdownFiles() async throws {
        let records = [
            makeRecord(sessionId: "s1", title: "Refactor the parser"),
            makeRecord(provider: .codex, sessionId: "s2", title: "Fix the crash")
        ]

        let result = try await ConversationBundleExporter.exportBundle(records: records, to: workDir)

        XCTAssertEqual(result.conversationCount, 2)
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: result.folderURL.path))
        XCTAssertTrue(fm.fileExists(atPath: result.jsonURL.path))
        XCTAssertTrue(fm.fileExists(atPath: result.folderURL.appendingPathComponent("README.md").path))

        let markdownDir = result.folderURL.appendingPathComponent("markdown")
        let markdownFiles = try fm.contentsOfDirectory(atPath: markdownDir.path)
            .filter { $0.hasSuffix(".md") }
        XCTAssertEqual(markdownFiles.count, 2, "Each conversation should write exactly one Markdown file")
    }

    func testJsonManifestRoundTripsRecordMetadata() async throws {
        let record = makeRecord(sessionId: "round-trip", title: "Round trip metadata")
        let result = try await ConversationBundleExporter.exportBundle(records: [record], to: workDir)

        let data = try Data(contentsOf: result.jsonURL)
        let manifest = try JSONDecoder().decode(ConversationBundleExporter.ExportManifest.self, from: data)

        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.app, "OpenBurnBar")
        XCTAssertEqual(manifest.conversationCount, 1)
        let exported = try XCTUnwrap(manifest.conversations.first)
        XCTAssertEqual(exported.id, record.id)
        XCTAssertEqual(exported.provider, record.provider.rawValue)
        XCTAssertEqual(exported.sessionId, "round-trip")
        XCTAssertEqual(exported.title, "Round trip metadata")
        XCTAssertEqual(exported.messageCount, record.messageCount)
        XCTAssertEqual(exported.keyFiles, record.keyFiles)
        XCTAssertEqual(exported.transcript, record.fullText)
        XCTAssertNotNil(exported.startTime)
        XCTAssertNotNil(exported.endTime)
    }

    func testBodyProviderResolvesTranscriptLazily() async throws {
        // A record with an empty fullText whose body is supplied by the closure
        // (mirrors cloud/iCloud body resolution on the Mac).
        let record = makeRecord(sessionId: "lazy-body", title: "Lazy body", fullText: "")
        let resolved = "## Resolved transcript\n\nFetched from the cloud."

        let result = try await ConversationBundleExporter.exportBundle(records: [record], to: workDir) { rec in
            XCTAssertEqual(rec.sessionId, "lazy-body")
            return resolved
        }

        let manifest = try JSONDecoder().decode(
            ConversationBundleExporter.ExportManifest.self,
            from: Data(contentsOf: result.jsonURL)
        )
        XCTAssertEqual(manifest.conversations.first?.transcript, resolved)

        let markdownDir = result.folderURL.appendingPathComponent("markdown")
        let mdFile = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(atPath: markdownDir.path).first { $0.hasSuffix(".md") }
        )
        let markdown = try String(contentsOf: markdownDir.appendingPathComponent(mdFile), encoding: .utf8)
        XCTAssertTrue(markdown.contains("Resolved transcript"), "Markdown transcript should use the resolved body")
        XCTAssertTrue(markdown.contains("# Lazy body"), "Markdown should be titled with the conversation title")
    }

    func testDuplicateTitlesProduceUniqueFilenames() async throws {
        let records = [
            makeRecord(sessionId: "dup-a", title: "Same Title"),
            makeRecord(sessionId: "dup-b", title: "Same Title"),
            makeRecord(sessionId: "dup-c", title: "Same Title")
        ]
        let result = try await ConversationBundleExporter.exportBundle(records: records, to: workDir)

        let markdownDir = result.folderURL.appendingPathComponent("markdown")
        let files = try FileManager.default.contentsOfDirectory(atPath: markdownDir.path)
            .filter { $0.hasSuffix(".md") }
        XCTAssertEqual(files.count, 3)
        XCTAssertEqual(Set(files).count, 3, "Colliding titles must still yield unique Markdown filenames")
    }

    func testEmptyTranscriptFallsBackToPlaceholder() async throws {
        let record = makeRecord(sessionId: "empty", title: "Empty body", fullText: "")
        let result = try await ConversationBundleExporter.exportBundle(records: [record], to: workDir)

        let markdownDir = result.folderURL.appendingPathComponent("markdown")
        let mdFile = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(atPath: markdownDir.path).first { $0.hasSuffix(".md") }
        )
        let markdown = try String(contentsOf: markdownDir.appendingPathComponent(mdFile), encoding: .utf8)
        XCTAssertTrue(markdown.contains("No transcript body was available"))
    }
}
