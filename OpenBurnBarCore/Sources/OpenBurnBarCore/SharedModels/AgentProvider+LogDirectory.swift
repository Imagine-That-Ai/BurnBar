import Foundation

public extension AgentProvider {
    /// Host-resolved conventional log directory. API-only identities keep the
    /// historical Codex-root compatibility value for generic settings callers;
    /// `AgentProviderLogDiscovery` excludes them from local ingestion.
    var logDirectory: String {
        LogPathPlatform.resolveLogDirectory(capabilityRecord.logicalPath ?? "~/.codex")
    }
}
