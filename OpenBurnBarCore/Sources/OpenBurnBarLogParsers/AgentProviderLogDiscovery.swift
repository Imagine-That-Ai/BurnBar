import Foundation
import OpenBurnBarKernel
import OpenBurnBarParserSupport

public typealias AgentProviderIngestionCatalog = OpenBurnBarParserSupport.AgentProviderIngestionCatalog

/// Canonical provider log directory and file-pattern discovery for Linux and cross-platform ingestion.
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
}

public extension AgentProvider {
    /// Filesystem directory where the provider writes session logs the file
    /// watcher can scrape, resolved for the current host. Windows remaps the
    /// macOS logical form through ``LogPathPlatform``.
    var logDirectory: String {
        LogPathPlatform.resolveLogDirectory(AgentProviderLogDiscovery.logicalLogDirectory(for: self))
    }
}
