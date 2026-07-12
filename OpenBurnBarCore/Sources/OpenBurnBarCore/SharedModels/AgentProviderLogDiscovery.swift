import Foundation

/// Canonical provider log discovery backed by the generated provider capability manifest.
public enum AgentProviderLogDiscovery {
    public struct ResolvedLogSource: Equatable, Sendable {
        public var provider: AgentProvider
        public var logicalPath: String
        public var resolvedPath: String
        public var filePattern: String
        public var parserSource: String
        public var sessionIdentityKey: String

        public init(
            provider: AgentProvider,
            logicalPath: String,
            resolvedPath: String,
            filePattern: String,
            parserSource: String? = nil,
            sessionIdentityKey: String
        ) {
            self.provider = provider
            self.logicalPath = logicalPath
            self.resolvedPath = resolvedPath
            self.filePattern = filePattern
            self.parserSource = parserSource ?? provider.capabilityRecord.parserSource ?? ""
            self.sessionIdentityKey = sessionIdentityKey
        }
    }

    public static func logicalLogDirectory(for provider: AgentProvider) -> String? {
        provider.capabilityRecord.logicalPath
    }

    public static func filePattern(for provider: AgentProvider) -> String? {
        provider.capabilityRecord.filePattern
    }

    /// Returns nil for API-only providers and paths without a registered transcript parser.
    public static func resolveLogSource(
        for provider: AgentProvider,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ResolvedLogSource? {
        let capability = provider.capabilityRecord
        guard let logical = capability.logicalPath,
              let pattern = capability.filePattern,
              let parserSource = capability.parserSource else {
            return nil
        }
        let resolved = URL(
            fileURLWithPath: OpenBurnBarLinuxPaths.expandPath(
                logical,
                homeDirectory: providerHomeDirectory(environment: environment),
                environment: environment
            ),
            isDirectory: true
        ).standardizedFileURL.path
        return ResolvedLogSource(
            provider: provider,
            logicalPath: logical,
            resolvedPath: resolved,
            filePattern: pattern,
            parserSource: parserSource,
            sessionIdentityKey: sessionIdentityKey(provider: provider, resolvedPath: resolved)
        )
    }

    /// Identity follows the standardized logical path, not a symlink target.
    public static func sessionIdentityKey(provider: AgentProvider, resolvedPath: String) -> String {
        let standardized = URL(fileURLWithPath: resolvedPath, isDirectory: true).standardizedFileURL.path
        return "\(provider.rawValue)|\(standardized)"
    }

    private static func providerHomeDirectory(environment: [String: String]) -> URL? {
        for key in ["OPENBURNBAR_PROVIDER_HOME", "SNAP_REAL_HOME", "HOME"] {
            if let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                return URL(fileURLWithPath: raw, isDirectory: true)
            }
        }
        return nil
    }
}
