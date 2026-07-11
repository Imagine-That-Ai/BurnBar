import Foundation
import XCTest
@testable import OpenBurnBarCore

final class OBBCAbiUsageScanExportTests: XCTestCase {
    func test_scanReadsClaudeAndCursorFixturesWithStableRuntimeRows() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("obb-cabi-usage-scan-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let home = root.appendingPathComponent("home", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let claude = home.appendingPathComponent(
            ".claude/projects/-Users-test-Documents-ParserContract",
            isDirectory: true
        )
        let cursor = home.appendingPathComponent(".cursor-agent/sessions", isDirectory: true)
        try fileManager.createDirectory(at: claude, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: cursor, withIntermediateDirectories: true)

        try fileManager.copyItem(
            at: fixture("pc-claude-basic-session.jsonl"),
            to: claude.appendingPathComponent("claude-basic-session.jsonl")
        )
        let cursorFixture = """
        {"role":"user","content":"Inspect the Windows usage runtime","timestamp":"2026-07-10T12:00:00Z"}
        {"role":"assistant","content":"I found the parser boundary.","thinking":"Check the native bridge.","timestamp":"2026-07-10T12:00:01Z"}
        {"role":"tool","content":"File Path: `file:///C:/src/OpenBurnBar/App.xaml.cs`","timestamp":"2026-07-10T12:00:02Z"}
        """
        try Data(cursorFixture.utf8).write(
            to: cursor.appendingPathComponent("cursor-basic.jsonl"),
            options: .atomic
        )

        let request = OBBCAbiUsageScanRequest(
            supportDirectory: support.path,
            homeDirectory: home.path,
            claudeProjectsDirectory: home.appendingPathComponent(".claude/projects").path,
            codexHomeDirectory: home.path,
            cursorSessionsDirectory: cursor.path,
            factorySessionsDirectory: home.appendingPathComponent(".factory/sessions").path,
            hermesHomeDirectory: home.appendingPathComponent(".hermes").path,
            includeConversationBodies: true
        )
        let requestData = try JSONEncoder().encode(request)

        let first = try OBBCAbiUsageScanExport.run(requestData: requestData)
        let second = try OBBCAbiUsageScanExport.run(requestData: requestData)

        XCTAssertTrue(first.ok)
        XCTAssertNil(first.error)
        XCTAssertEqual(
            first.providers.first(where: { $0.provider == AgentProvider.claudeCode.rawValue })?.status,
            .succeeded
        )
        XCTAssertEqual(
            first.providers.first(where: { $0.provider == AgentProvider.cursorAgent.rawValue })?.status,
            .succeeded
        )
        XCTAssertEqual(
            first.providers.first(where: { $0.provider == AgentProvider.codex.rawValue })?.status,
            .missing
        )
        XCTAssertTrue(first.usages.contains(where: { $0.provider == AgentProvider.claudeCode.rawValue }))
        XCTAssertTrue(first.usages.contains(where: { $0.provider == AgentProvider.cursorAgent.rawValue }))
        XCTAssertFalse(first.conversations.isEmpty)
        XCTAssertEqual(first.usages.map(\.id), second.usages.map(\.id))
    }

    func test_scanRejectsIncompleteRequest() throws {
        let invalid = Data(#"{"supportDirectory":""}"#.utf8)
        XCTAssertThrowsError(try OBBCAbiUsageScanExport.run(requestData: invalid)) { error in
            XCTAssertEqual(error as? OBBCAbiUsageScanError, .invalidRequest)
        }
    }

    private func fixture(_ name: String) -> URL {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repositoryRoot
            .appendingPathComponent("AgentLensTests/Fixtures/ParserContract", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
    }
}
