#if os(Linux)
import Foundation
import OpenBurnBarCore

public enum PensieveSourceKind: String, Codable, Sendable {
    case repoDocs = "repo_docs"
    case notes
    case chatMemory = "chat_memory"
}

extension BurnBarDaemonPaths {
    public static var defaultPensieveQueueDirectoryURL: URL {
        if let override = ProcessInfo.processInfo.environment["OPENBURNBAR_PENSIEVE_QUEUE_DIR"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".openburnbar/pensieve-queue", isDirectory: true)
    }

    public static var defaultClaudeProjectsDirectoryURL: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }
}

public struct PensieveWatchRoot: Sendable {
    public let url: URL
    public let sourceKind: PensieveSourceKind
    public let includedExtensions: Set<String>

    public init(url: URL, sourceKind: PensieveSourceKind, includedExtensions: Set<String> = []) {
        self.url = url
        self.sourceKind = sourceKind
        self.includedExtensions = includedExtensions
    }
}

public final class PensieveKnowledgeWatcher: Sendable {
    public var lastEnqueueDate: Date? { nil }
    public var lastEnqueuedCount: Int { 0 }
    public var lastError: String? { "Pensieve filesystem watching is unavailable on Linux." }

    public init(
        roots: [PensieveWatchRoot],
        queueDirectoryURL: URL = BurnBarDaemonPaths.defaultPensieveQueueDirectoryURL,
        vaultKeyProvider: @escaping @Sendable () -> Data?,
        debounceInterval: TimeInterval = 2.0,
        backstopInterval: TimeInterval = 15 * 60,
        fileSystem: any SendableFileSystem = DefaultSendableFileSystem()
    ) {}

    public static func standardRoots(
        repoDocsURL: URL? = nil,
        notesURL: URL? = nil,
        claudeProjectsURL: URL = BurnBarDaemonPaths.defaultClaudeProjectsDirectoryURL
    ) -> [PensieveWatchRoot] {
        var roots: [PensieveWatchRoot] = []
        if let repoDocsURL {
            roots.append(PensieveWatchRoot(url: repoDocsURL, sourceKind: .repoDocs, includedExtensions: ["md", "mdx", "txt", "rst"]))
        }
        if let notesURL {
            roots.append(PensieveWatchRoot(url: notesURL, sourceKind: .notes, includedExtensions: ["md", "txt"]))
        }
        roots.append(PensieveWatchRoot(url: claudeProjectsURL, sourceKind: .chatMemory, includedExtensions: ["jsonl"]))
        return roots
    }

    public func start() {}
    public func stop() {}
}
#endif
