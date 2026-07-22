import Foundation
@testable import OpenBurnBar

/// Testable wrapper for FactoryDroidParser that allows injecting test paths.
final class TestableFactoryDroidParser: LogParser, Sendable {
    let provider: AgentProvider = .factory
    private let parser: FactoryDroidParser

    init(fileManager: FileManager = .default, testSessionsPath: URL) {
        parser = FactoryDroidParser(
            fileManager: fileManager,
            appPaths: OpenBurnBarAppPaths(
                applicationSupportRoot: testSessionsPath.deletingLastPathComponent()
            ),
            sessionsDirectoryOverride: testSessionsPath
        )
    }

    func parse(options: LogParseOptions) async throws -> ParseResult {
        try await parser.parse(options: options)
    }
}
