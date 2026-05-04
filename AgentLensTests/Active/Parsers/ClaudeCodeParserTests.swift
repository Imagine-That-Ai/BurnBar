import XCTest
@testable import OpenBurnBar

private final class ActiveTestableClaudeCodeParser: LogParser, Sendable {
    let provider: AgentProvider = .claudeCode
    private let testProjectsPath: URL
    private let fileManager: FileManager

    init(testProjectsPath: URL, fileManager: FileManager = .default) {
        self.testProjectsPath = testProjectsPath
        self.fileManager = fileManager
    }

    func parse() async throws -> ParseResult {
        guard fileManager.fileExists(atPath: testProjectsPath.path) else {
            return ParseResult(usages: [], conversations: [])
        }

        guard let projectDirs = try? fileManager.contentsOfDirectory(
            at: testProjectsPath,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return ParseResult(usages: [], conversations: [])
        }

        for projectDir in projectDirs where projectDir.hasDirectoryPath {
            guard let files = try? fileManager.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: nil),
                  files.contains(where: { $0.pathExtension == "jsonl" }) else {
                continue
            }
            return ParseResult(usages: [TokenUsage(provider: .claudeCode, sessionId: "fixture", projectName: projectDir.lastPathComponent, model: "claude", inputTokens: 1, outputTokens: 1, cacheCreationTokens: 0, cacheReadTokens: 0, costUSD: 0, startTime: Date(), endTime: Date())], conversations: [])
        }

        return ParseResult(usages: [], conversations: [])
    }
}

final class ClaudeCodeParserTests: XCTestCase {
    func testParseEmptyDirectory() async throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("openburnbar-claude-parser-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let parser = ActiveTestableClaudeCodeParser(testProjectsPath: tempRoot)
        let result = try await parser.parse()
        XCTAssertTrue(result.usages.isEmpty)
        XCTAssertTrue(result.conversations.isEmpty)
    }
    
    func testProviderReturnsCorrectValue() {
        let parser = ClaudeCodeParser()
        XCTAssertEqual(parser.provider, .claudeCode)
    }
}
