import Foundation

// MARK: - Platform seams (WS-C2 quota lift)
//
// macOS AgentLens injects KeychainStore, Process, and AppLogger; Windows PAL
// injects DPAPI/CNG secret store, ConPTY process runner, and its own logger.
// SEAM quota adapters compile in OpenBurnBarCore; macOS AgentLens injects concrete stores via ProviderQuotaMacPlatform.

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
    func recordDomainCoreShadowComparison(_ comparison: DomainCoreQuotaShadowComparison)
}

public extension QuotaLogger {
    func recordDomainCoreShadowComparison(_ comparison: DomainCoreQuotaShadowComparison) {}
}

public struct NoOpQuotaLogger: QuotaLogger {
    public init() {}
    public func log(_ message: String) {}
}

public enum DomainCoreQuotaShadowOutcome: String, Codable, Sendable {
    case match
    case mismatch
}

public enum DomainCoreQuotaShadowMismatchCategory: String, Codable, Sendable {
    case resultMismatch = "result_mismatch"
    case nativeUnavailable = "native_unavailable"
    case nativeError = "native_error"
    case invalidResult = "invalid_result"
}

/// Privacy-safe receipt for one complete legacy/Rust quota comparison.
/// Payloads, parsed values, credentials, user identifiers, and hashes are
/// deliberately absent. Platform adapters add consumer/channel/sample identity
/// before durably spooling this receipt.
public struct DomainCoreQuotaShadowComparison: Equatable, Sendable {
    public let operation: String
    public let coreVersion: String
    public let observedAt: Date
    public let outcome: DomainCoreQuotaShadowOutcome
    public let mismatchCategory: DomainCoreQuotaShadowMismatchCategory?
    public let legacyMicros: UInt64
    public let rustMicros: UInt64

    public init(
        operation: String,
        coreVersion: String,
        observedAt: Date,
        outcome: DomainCoreQuotaShadowOutcome,
        mismatchCategory: DomainCoreQuotaShadowMismatchCategory? = nil,
        legacyMicros: UInt64,
        rustMicros: UInt64
    ) {
        self.operation = operation
        self.coreVersion = coreVersion
        self.observedAt = observedAt
        self.outcome = outcome
        self.mismatchCategory = mismatchCategory
        self.legacyMicros = legacyMicros
        self.rustMicros = rustMicros
    }
}

/// Persisted quota snapshots and scratch keys (AgentLens `ProviderQuotaSnapshotStore`).
public protocol ProviderQuotaSnapshotPersisting: Sendable {
    func loadScratchString(forKey key: String) -> String?
    func saveScratchString(_ value: String, forKey key: String)
    func readJSONObject(from url: URL) throws -> [String: Any]?
}

/// Claude statusline bridge install/status (AgentLens `ClaudeQuotaBridgeManager`).
public protocol ClaudeQuotaBridgeManaging: Sendable {
    func installClaudeQuotaBridge() throws
    func refreshClaudeBridgeStatus() -> ClaudeQuotaBridgeStatus
}
