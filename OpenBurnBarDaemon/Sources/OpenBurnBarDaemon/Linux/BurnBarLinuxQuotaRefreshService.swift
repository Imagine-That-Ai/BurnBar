#if os(Linux)

import Foundation
import OpenBurnBarEngine
import OpenBurnBarKernel
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class BurnBarLinuxQuotaOutputBuffer: Sendable {
    private struct State: Sendable {
        var data = Data()
        var didExceedLimit = false
    }

    private let state = Locked(State())

    func append(_ chunk: Data, limit: Int) {
        state.withLock { state in
            guard !state.didExceedLimit else { return }
            guard state.data.count + chunk.count <= limit else {
                state.didExceedLimit = true
                return
            }
            state.data.append(chunk)
        }
    }

    func snapshot() -> (data: Data, didExceedLimit: Bool) {
        state.withLock { ($0.data, $0.didExceedLimit) }
    }
}

/// Synchronous adapter-backed secret lookup used only while constructing a
/// daemon-owned quota refresh context. Values are copied from the resolved
/// credential slots and never cross the daemon RPC boundary.
private struct BurnBarLinuxQuotaSecretStore: SecretStore {
    let values: [String: String]

    func string(for account: String, service: String) -> String? {
        values[account]
            ?? values["\(service):\(account)"]
            ?? values[account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
    }
}

private struct BurnBarLinuxQuotaClaudeCredentialsReader: ClaudeCredentialsReading {
    func load() -> ClaudeOAuthCredentials? { nil }
}

private struct BurnBarLinuxQuotaBridgeManager: ClaudeQuotaBridgeManaging {
    func installClaudeQuotaBridge() throws {}

    func refreshClaudeBridgeStatus() -> ClaudeQuotaBridgeStatus {
        ClaudeQuotaBridgeStatus(
            state: .notInstalled,
            wrapperPath: "",
            detailText: "Claude Code statusline bridge is not installed in the Linux daemon context.",
            lastPayloadAt: nil
        )
    }
}

/// Runs only the fixed, first-party provider CLI names used by quota adapters.
/// The adapter contract does not accept arbitrary renderer-provided commands.
struct BurnBarLinuxQuotaCLIExecutor: CLIExecutor {
    private static let maxOutputBytes = 1_048_576
    private let timeout: TimeInterval
    private static let allowedNames: Set<String> = [
        "aider", "claude", "codex", "cursor", "factory", "goose", "junie",
        "kimi", "ollama", "opencode", "omp", "pi", "warp", "zai"
    ]

    init(timeout: TimeInterval = 8) {
        self.timeout = timeout
    }

    func run(executable: String, arguments: [String], environment: [String: String]) throws -> Data {
        let name = URL(fileURLWithPath: executable).lastPathComponent
        guard Self.allowedNames.contains(name) else {
            throw QuotaServiceError.invalidResponse("Linux quota CLI is not allowlisted.")
        }

        let path = executable.hasPrefix("/")
            ? executable
            : (environment["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? "")
                .split(separator: ":")
                .map(String.init)
                .map { URL(fileURLWithPath: $0).appendingPathComponent(name).path }
                .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        guard let path else {
            throw QuotaServiceError.invalidResponse("Linux quota CLI is unavailable.")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()

        let outputBuffer = BurnBarLinuxQuotaOutputBuffer()
        let errorBuffer = BurnBarLinuxQuotaOutputBuffer()
        let outputDrain = DispatchWorkItem {
            Self.drain(outputPipe.fileHandleForReading, into: outputBuffer)
        }
        let errorDrain = DispatchWorkItem {
            Self.drain(errorPipe.fileHandleForReading, into: errorBuffer)
        }
        DispatchQueue.global(qos: .utility).async(execute: outputDrain)
        DispatchQueue.global(qos: .utility).async(execute: errorDrain)

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        let timedOut = process.isRunning
        if timedOut {
            process.terminate()
        }
        process.waitUntilExit()
        outputDrain.wait()
        errorDrain.wait()

        if timedOut {
            throw QuotaServiceError.invalidResponse("Linux quota CLI timed out.")
        }
        let stdout = outputBuffer.snapshot()
        let stderr = errorBuffer.snapshot()
        guard !stdout.didExceedLimit, !stderr.didExceedLimit else {
            throw QuotaServiceError.invalidResponse("Linux quota CLI output exceeded the safety bound.")
        }
        guard process.terminationStatus == 0 else {
            throw QuotaServiceError.invalidResponse(
                "Linux quota CLI exited with status \(process.terminationStatus)."
            )
        }
        return stdout.data
    }

    private static func drain(_ handle: FileHandle, into buffer: BurnBarLinuxQuotaOutputBuffer) {
        while true {
            do {
                guard let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty else {
                    return
                }
                buffer.append(chunk, limit: maxOutputBytes)
            } catch {
                return
            }
        }
    }
}

final class BurnBarLinuxQuotaSnapshotCache: Sendable, ProviderQuotaSnapshotPersisting {
    private struct DiskPayload: Codable {
        let schemaVersion: Int
        let snapshots: [ProviderQuotaSnapshot]
    }

    private struct State: Sendable {
        var snapshotsByProvider: [String: ProviderQuotaSnapshot] = [:]
        var scratch: [String: String] = [:]
    }

    private let fileURL: URL
    private let logger: BurnBarDaemonLogger
    private let state: Locked<State>

    init(
        fileURL: URL = OpenBurnBarAppPaths.live().providerQuotaSnapshotsURL,
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "linux-quota-cache")
    ) {
        self.fileURL = fileURL
        self.logger = logger
        self.state = Locked(Self.loadInitialState(fileURL: fileURL))
    }

    func snapshots() -> [ProviderQuotaSnapshot] {
        state.withLock {
            $0.snapshotsByProvider.values.sorted { $0.providerID.rawValue < $1.providerID.rawValue }
        }
    }

    func replace(_ snapshots: [ProviderQuotaSnapshot]) {
        let normalized = Dictionary(
            uniqueKeysWithValues: snapshots.map { ($0.providerID.rawValue, $0) }
        )
        state.withLock { state in
            state.snapshotsByProvider = normalized
            persist(snapshotsByProvider: normalized)
        }
    }

    func loadScratchString(forKey key: String) -> String? {
        state.withLock { $0.scratch[key] }
    }

    func saveScratchString(_ value: String, forKey key: String) {
        state.withLock {
            $0.scratch[key] = value
        }
    }

    func readJSONObject(from url: URL) throws -> [String: Any]? {
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func loadInitialState(fileURL: URL) -> State {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(DiskPayload.self, from: data) else {
            return State()
        }
        return State(snapshotsByProvider: Dictionary(
            uniqueKeysWithValues: payload.snapshots.map { ($0.providerID.rawValue, $0) }
        ))
    }

    /// Called only from within `state.withLock`, so disk writes stay serialized
    /// behind the same lock that guards the in-memory snapshots.
    private func persist(snapshotsByProvider: [String: ProviderQuotaSnapshot]) {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            let payload = DiskPayload(schemaVersion: 1, snapshots: snapshotsByProvider.values.sorted {
                $0.providerID.rawValue < $1.providerID.rawValue
            })
            let data = try JSONEncoder().encode(payload)
            try data.write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            // Quota cache loss must never make provider routing or the daemon
            // unavailable; the next refresh can rebuild it from the adapters.
            logger.silentFailure("linux_quota_snapshot_persist", error: error)
        }
    }
}

/// Linux's daemon-owned quota transport. It resolves the preferred credential
/// slot inside the daemon, invokes the shared cross-platform adapter registry,
/// validates every result, and persists only redacted quota snapshots.
public actor BurnBarLinuxQuotaRefreshService {
    private enum RefreshError: Error {
        case timeout
    }

    private static let adapterTimeoutNanoseconds: UInt64 = 8_000_000_000
    private let configStore: BurnBarConfigStore
    private let cache: BurnBarLinuxQuotaSnapshotCache
    private let registry: ProviderQuotaAdapterRegistry
    private let logger: BurnBarDaemonLogger
    private var lastRefreshAt: Date?
    private var refreshInFlight = false

    public init(
        configStore: BurnBarConfigStore,
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "linux-quota-refresh")
    ) {
        self.configStore = configStore
        self.cache = BurnBarLinuxQuotaSnapshotCache()
        self.registry = .standard
        self.logger = logger
    }

    init(
        configStore: BurnBarConfigStore,
        registry: ProviderQuotaAdapterRegistry,
        cache: BurnBarLinuxQuotaSnapshotCache,
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "linux-quota-refresh")
    ) {
        self.configStore = configStore
        self.cache = cache
        self.registry = registry
        self.logger = logger
    }

    public func snapshots() -> [ProviderQuotaSnapshot] {
        cache.snapshots()
    }

    /// Refreshes at most once per five minutes unless explicitly forced. A
    /// concurrent request receives the last durable cache rather than issuing
    /// duplicate provider calls or blocking the daemon indefinitely.
    public func refreshIfNeeded(
        now: Date = Date(),
        force: Bool = false
    ) async -> [ProviderQuotaSnapshot] {
        if !force,
           let lastRefreshAt,
           now.timeIntervalSince(lastRefreshAt) < 5 * 60 {
            return cache.snapshots()
        }
        guard !refreshInFlight else { return cache.snapshots() }
        refreshInFlight = true
        defer { refreshInFlight = false }
        let refreshed = await refreshAll(now: now)
        lastRefreshAt = now
        return refreshed
    }

    private func refreshAll(now: Date) async -> [ProviderQuotaSnapshot] {
        let configurations: [BurnBarResolvedProviderConfiguration]
        do {
            configurations = try await configStore.resolvedConfigurations()
        } catch {
            logger.silentFailure("linux_quota_config_resolution", error: error)
            return cache.snapshots()
        }

        let context = makeContext(configurations: configurations)
        let entries = AgentProvider.quotaSignalProviders.compactMap { provider in
            registry.entry(for: provider).map { (provider, $0) }
        }
        let snapshots = await fetchSnapshots(
            entries: entries,
            context: context,
            configurations: configurations,
            now: now
        )

        cache.replace(snapshots)
        return cache.snapshots()
    }

    private func fetchSnapshots(
        entries: [(AgentProvider, ProviderQuotaAdapterRegistry.Entry)],
        context: ProviderQuotaAdapterContext,
        configurations: [BurnBarResolvedProviderConfiguration],
        now: Date
    ) async -> [ProviderQuotaSnapshot] {
        var snapshots: [ProviderQuotaSnapshot] = []
        snapshots.reserveCapacity(entries.count)
        var iterator = entries.makeIterator()
        await withTaskGroup(of: ProviderQuotaSnapshot.self) { group in
            for _ in 0..<min(4, entries.count) {
                guard let next = iterator.next() else { break }
                group.addTask {
                    await self.fetchOne(
                        provider: next.0,
                        entry: next.1,
                        context: context,
                        configurations: configurations,
                        now: now
                    )
                }
            }
            for await snapshot in group {
                snapshots.append(snapshot)
                guard let next = iterator.next() else { continue }
                group.addTask {
                    await self.fetchOne(
                        provider: next.0,
                        entry: next.1,
                        context: context,
                        configurations: configurations,
                        now: now
                    )
                }
            }
        }
        return snapshots.sorted { $0.providerID.rawValue < $1.providerID.rawValue }
    }

    private func fetchOne(
        provider: AgentProvider,
        entry: ProviderQuotaAdapterRegistry.Entry,
        context: ProviderQuotaAdapterContext,
        configurations: [BurnBarResolvedProviderConfiguration],
        now: Date
    ) async -> ProviderQuotaSnapshot {
        do {
            let snapshot = try await fetch(entry: entry, context: context)
            guard let accepted = ProviderQuotaSnapshotValidator.accepted(
                snapshot,
                expectedProvider: provider.providerID,
                now: now
            ) else {
                return unavailableSnapshot(
                    provider: provider,
                    message: "Provider returned an invalid quota snapshot."
                )
            }
            return enriched(accepted, configuration: configurations.first {
                AgentProvider.fromCatalogProviderID($0.provider.id) == provider
            })
        } catch {
            logger.silentFailure("linux_quota_adapter_\(provider.persistedToken)", error: error)
            return unavailableSnapshot(
                provider: provider,
                message: "Quota refresh failed without exposing provider credentials."
            )
        }
    }

    private func fetch(
        entry: ProviderQuotaAdapterRegistry.Entry,
        context: ProviderQuotaAdapterContext
    ) async throws -> ProviderQuotaSnapshot {
        try await withThrowingTaskGroup(of: ProviderQuotaSnapshot.self) { group in
            group.addTask {
                try await entry.adapter.fetch(context: context)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: Self.adapterTimeoutNanoseconds)
                throw RefreshError.timeout
            }
            defer { group.cancelAll() }
            guard let snapshot = try await group.next() else {
                throw RefreshError.timeout
            }
            return snapshot
        }
    }

    private func makeContext(
        configurations: [BurnBarResolvedProviderConfiguration]
    ) -> ProviderQuotaAdapterContext {
        var resolvedKeys: [String: String?] = [:]
        var plainValues: [String: String] = [:]
        for configuration in configurations {
            guard let key = configuration.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !key.isEmpty else { continue }
            let provider = configuration.provider.id
            for identifier in identifiers(for: provider) {
                resolvedKeys[identifier] = key
                plainValues[identifier] = key
            }
        }
        let paths = OpenBurnBarAppPaths.live()
        let environment = ProcessInfo.processInfo.environment
        return ProviderQuotaAdapterContext(
            appPaths: paths,
            fileManager: .default,
            session: .shared,
            environment: environment,
            homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser,
            snapshotStore: cache,
            bridgeManager: BurnBarLinuxQuotaBridgeManager(),
            miniMaxMode: .tokenPlan,
            factoryPlan: .unknown,
            xaiPlan: .unknown,
            mimoTokenPlanRegion: .global,
            mimoTokenPlanTier: .standard,
            mimoTokenPlanBillingCycle: .monthly,
            codexRolloutScanCache: .empty,
            updateCodexRolloutScanCache: { _, _ in },
            claudeCredentialsReader: BurnBarLinuxQuotaClaudeCredentialsReader(),
            resolvedAPIKeys: resolvedKeys,
            secretStore: BurnBarLinuxQuotaSecretStore(values: plainValues),
            cliExecutor: BurnBarLinuxQuotaCLIExecutor(),
            quotaLogger: NoOpQuotaLogger()
        )
    }

    private func identifiers(for providerID: String) -> [String] {
        let normalized = providerID.lowercased()
        switch normalized {
        case "anthropic", "claude-code", "claude": return ["anthropic", "claude", "claude_code"]
        case "deepseek": return ["deepseek", "deep_seek"]
        case "moonshot", "kimi": return ["kimi", "kimi_auth_token", "moonshot"]
        case "minimax": return ["minimax"]
        case "zai": return ["zai", "z_ai"]
        case "xai": return ["xai", "x_ai", "xai_management_key"]
        case "opencode": return ["opencode", "open_code"]
        case "cursor": return ["cursor", "cursor_cookie"]
        case "factory": return ["factory", "factory_cookie", "factory_cookie_header"]
        case "ollama", "ollama-local": return ["ollama", "ollama_cookie", "ollama_cookie_header"]
        case "mimo": return ["mimo"]
        case "openai", "codex": return ["openai", "codex"]
        default: return [normalized]
        }
    }

    private func enriched(
        _ snapshot: ProviderQuotaSnapshot,
        configuration: BurnBarResolvedProviderConfiguration?
    ) -> ProviderQuotaSnapshot {
        guard let configuration else { return snapshot }
        let selectedSlot = configuration.credentialSlots.first {
            $0.slot.slotID == configuration.settings.preferredCredentialSlotID
        } ?? configuration.credentialSlots.first(where: { $0.slot.isEnabled })
        return ProviderQuotaSnapshot(
            id: snapshot.id,
            provider: snapshot.provider,
            providerID: snapshot.providerID,
            accountID: selectedSlot?.slot.slotID ?? snapshot.accountID,
            accountLabel: selectedSlot?.slot.label ?? snapshot.accountLabel,
            accountStorageScope: snapshot.accountStorageScope,
            sourceKind: snapshot.sourceKind,
            sourceId: snapshot.sourceId,
            fetchedAt: snapshot.fetchedAt,
            source: snapshot.source,
            confidence: snapshot.confidence,
            managementURL: snapshot.managementURL,
            statusMessage: snapshot.statusMessage,
            buckets: snapshot.buckets,
            schemaVersion: snapshot.schemaVersion,
            updatedAt: snapshot.updatedAt
        )
    }

    private func unavailableSnapshot(provider: AgentProvider, message: String) -> ProviderQuotaSnapshot {
        ProviderQuotaSnapshot(
            provider: provider,
            fetchedAt: Date(),
            source: .unavailable,
            confidence: .stale,
            managementURL: nil,
            statusMessage: message,
            buckets: []
        )
    }
}

#endif
