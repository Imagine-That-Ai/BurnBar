import Foundation
@testable import OpenBurnBar

/// Testable wrapper for CodexParser that allows injecting test paths.
// AUDIT(@unchecked Sendable): FileManager is thread-safe but not formally Sendable.
final class TestableCodexParser: LogParser, @unchecked Sendable {
    let provider: AgentProvider = .codex
    private let fileManager: FileManager
    private let appPaths: OpenBurnBar.OpenBurnBarAppPaths
    private let homeDirectoryURL: URL

    init(fileManager: FileManager = .default, codexRoot: URL, appPaths: OpenBurnBar.OpenBurnBarAppPaths) {
        self.fileManager = fileManager
        self.appPaths = appPaths
        self.homeDirectoryURL = codexRoot.deletingLastPathComponent()
    }

    func parse() async throws -> ParseResult {
        try await parse(options: .default)
    }

    func parse(options: LogParseOptions) async throws -> ParseResult {
        let parser = CodexParser(
            fileManager: fileManager,
            appPaths: appPaths,
            homeDirectoryURL: homeDirectoryURL
        )
        return try await parser.parse(options: options)
    }
}
