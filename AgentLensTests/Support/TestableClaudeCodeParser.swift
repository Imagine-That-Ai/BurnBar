import Foundation
@testable import OpenBurnBar

final class TestableClaudeCodeParser: LogParser, Sendable {
    let provider: AgentProvider = .claudeCode
    private let parser: ClaudeCodeParser

    init(fileManager: FileManager = .default, testProjectsPath: URL) {
        parser = ClaudeCodeParser(
            fileManager: fileManager,
            appPaths: OpenBurnBarAppPaths(
                applicationSupportRoot: testProjectsPath.deletingLastPathComponent()
            ),
            projectsDirectoryOverride: testProjectsPath
        )
    }

    func parse(options: LogParseOptions) async throws -> ParseResult {
        try await parser.parse(options: options)
    }
}
