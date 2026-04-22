import Foundation
@testable import OpenBurnBar

/// Testable wrapper for CodexParser that allows injecting test paths.
final class TestableCodexParser: LogParser, @unchecked Sendable {
    let provider: AgentProvider = .codex
    private let fileManager: FileManager
    private let appPaths: OpenBurnBarAppPaths
    private let homeDirectoryURL: URL

    init(fileManager: FileManager = .default, codexRoot: URL, appPaths: OpenBurnBarAppPaths) {
        self.fileManager = fileManager
        self.appPaths = appPaths
        self.homeDirectoryURL = codexRoot.deletingLastPathComponent()
    }

    func parse() async throws -> ParseResult {
        let parser = CodexParser(
            fileManager: fileManager,
            appPaths: appPaths,
            homeDirectoryURL: homeDirectoryURL
        )
        return try await parser.parse()
    }
}
