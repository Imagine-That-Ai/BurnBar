import Foundation
import OpenBurnBarKernel
import OpenBurnBarParserSupport

public typealias AgentProviderIngestionCatalog = OpenBurnBarParserSupport.AgentProviderIngestionCatalog

/// Canonical provider log directory and file-pattern discovery for Linux and cross-platform ingestion.
///
/// macOS-specific VS Code globalStorage paths are mapped to `~/.config/Code/User/globalStorage/...` on Linux.
/// Session identity is derived from resolved absolute paths so symlink/rotation cases do not rewrite IDs silently.
public enum AgentProviderLogDiscovery {
    public struct ResolvedLogSource: Equatable, Sendable {
        public var provider: AgentProvider
        public var logicalPath: String
        public var resolvedPath: String
        public var filePattern: String
        public var sessionIdentityKey: String

        public init(
            provider: AgentProvider,
            logicalPath: String,
            resolvedPath: String,
            filePattern: String,
            sessionIdentityKey: String
        ) {
            self.provider = provider
            self.logicalPath = logicalPath
            self.resolvedPath = resolvedPath
            self.filePattern = filePattern
            self.sessionIdentityKey = sessionIdentityKey
        }
    }

    public static func logicalLogDirectory(for provider: AgentProvider) -> String {
        let entry = AgentProviderIngestionCatalog.entry(for: provider)
        #if os(Linux)
        return entry.linuxLogicalPath
        #else
        return entry.macOSLogicalPath
        #endif
    }

    public static func filePattern(for provider: AgentProvider) -> String {
        AgentProviderIngestionCatalog.entry(for: provider).filePattern
    }

    public static func resolveLogSource(
        for provider: AgentProvider,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ResolvedLogSource {
        let logical = logicalLogDirectory(for: provider)
        let homeDirectory = environment["HOME"]
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        let resolved = OpenBurnBarLinuxPaths.expandPath(
            logical,
            homeDirectory: homeDirectory,
            environment: environment
        )
        let pattern = filePattern(for: provider)
        let identity = sessionIdentityKey(provider: provider, resolvedPath: resolved)
        return ResolvedLogSource(
            provider: provider,
            logicalPath: logical,
            resolvedPath: resolved,
            filePattern: pattern,
            sessionIdentityKey: identity
        )
    }

    public static func sessionIdentityKey(provider: AgentProvider, resolvedPath: String) -> String {
        "\(provider.rawValue)|\(resolvedPath)"
    }

    // MARK: - Live session-log watch

    /// Whether this provider may own an FSEvents stream on the fleet panel.
    ///
    /// API-backed rows (`*-no-local-logs`) and model-filter piggybacks
    /// (MiniMax / Z.ai sharing Factory's session tree) have no file whose
    /// mtime is *their* activity. Watching those directories anyway is how
    /// the panel prints "wrote 12s ago" for an agent that has not written.
    public static func isLiveWatchCandidate(_ provider: AgentProvider) -> Bool {
        let entry = AgentProviderIngestionCatalog.entry(for: provider)
        guard entry.ingestion == .localParser else { return false }
        guard hasWatchableFilePattern(entry.filePattern) else { return false }
        if entry.coverageNote.localizedCaseInsensitiveContains("model-filter") {
            return false
        }
        return true
    }

    /// True when this provider is the canonical owner of its resolved log
    /// directory among every live-watch candidate. Shared trees (Factory vs
    /// MiniMax/Z.ai) arm exactly one stream.
    public static func shouldArmLiveWatch(
        for provider: AgentProvider,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard isLiveWatchCandidate(provider) else { return false }
        let mine = standardizedPath(
            resolveLogSource(for: provider, environment: environment).resolvedPath
        )
        for entry in AgentProviderIngestionCatalog.entries {
            guard isLiveWatchCandidate(entry.provider) else { continue }
            let other = standardizedPath(
                resolveLogSource(for: entry.provider, environment: environment).resolvedPath
            )
            guard other == mine else { continue }
            return entry.provider == provider
        }
        return false
    }

    /// A filesystem event counts as this provider writing only when the
    /// provider owns the tree and the filename matches the catalog glob.
    public static func admitsLiveWrite(
        provider: AgentProvider,
        path: String,
        isDirectory: Bool = false,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard isDirectory == false else { return false }
        guard shouldArmLiveWatch(for: provider, environment: environment) else { return false }
        return filePatternMatches(path, pattern: filePattern(for: provider))
    }

    /// Catalog glob against the last path component. Sentinel patterns
    /// (`openai-no-local-logs`) match nothing, which is the whole point of
    /// pinning them instead of a real glob.
    public static func filePatternMatches(_ path: String, pattern: String) -> Bool {
        guard hasWatchableFilePattern(pattern) else { return false }
        let name = URL(fileURLWithPath: path).lastPathComponent
        guard name.isEmpty == false, name != "/", name != "." else { return false }
        return globMatch(name, pattern: pattern)
    }

    private static func hasWatchableFilePattern(_ pattern: String) -> Bool {
        if pattern.isEmpty { return false }
        if pattern.contains("no-local-logs") { return false }
        return true
    }

    private static func standardizedPath(_ path: String) -> String {
        var result = path
        while result.count > 1, result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    private static func globMatch(_ name: String, pattern: String) -> Bool {
        var regex = "^"
        for character in pattern {
            switch character {
            case "*":
                regex += ".*"
            case "?":
                regex += "."
            case ".", "[", "]", "(", ")", "{", "}", "+", "^", "$", "|", "\\":
                regex += "\\" + String(character)
            default:
                regex += String(character)
            }
        }
        regex += "$"
        return name.range(of: regex, options: .regularExpression) != nil
    }
}
