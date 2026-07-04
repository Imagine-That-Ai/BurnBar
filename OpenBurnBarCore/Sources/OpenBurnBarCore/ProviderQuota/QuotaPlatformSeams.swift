import Foundation

// MARK: - Platform seams (WS-C2 quota lift)
//
// macOS AgentLens injects KeychainStore, Process, and AppLogger; Windows PAL
// injects DPAPI/CNG secret store, ConPTY process runner, and its own logger.
// SEAM adapters stay in AgentLens until these protocols are wired end-to-end.

/// Reads credentials and other quota-related secrets (replaces KeychainStore).
public protocol SecretStore: Sendable {
    func string(for account: String, service: String) -> String?
}

/// Runs local CLI tools for quota probes (replaces Foundation.Process).
public protocol CLIExecutor: Sendable {
    func run(executable: String, arguments: [String], environment: [String: String]) throws -> Data
}

/// Logging for quota fetch paths (replaces AppLogger / os.Logger).
public protocol QuotaLogger: Sendable {
    func log(_ message: String)
}

public struct NoOpQuotaLogger: QuotaLogger {
    public init() {}
    public func log(_ message: String) {}
}

/// Persisted quota snapshots and scratch keys (AgentLens `ProviderQuotaSnapshotStore`).
public protocol ProviderQuotaSnapshotPersisting: Sendable {}

/// Claude statusline bridge install/status (AgentLens `ClaudeQuotaBridgeManager`).
public protocol ClaudeQuotaBridgeManaging: Sendable {}