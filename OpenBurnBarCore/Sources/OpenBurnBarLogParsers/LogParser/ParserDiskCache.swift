import Foundation
import OpenBurnBarKernel

// AUDIT(@unchecked Sendable): `UserDefaults` is thread-safe for value
// access/mutation, and this module additionally funnels high-volume settings writes
// through `SettingsPersistenceCoordinator`.
// The `FileManager: @retroactive @unchecked Sendable` shim was moved DOWN to the
// `OpenBurnBarPlatformSupport/PlatformSupport.swift` by the P-12 follow-up so Core's
// `ProviderQuotaAdapterContext` and the future `OpenBurnBarQuota` target can see it
// without depending on this leaf; this file inherits it via `import OpenBurnBarKernel`.
extension UserDefaults: @retroactive @unchecked Sendable {} // sendable-allowlist: foundation-sdk-shim
extension NSDictionary: @retroactive @unchecked Sendable {} // sendable-allowlist: foundation-sdk-shim
extension KeyPath: @retroactive @unchecked Sendable {} // sendable-allowlist: foundation-sdk-shim

public struct FileSignature: Codable, Equatable, Sendable {
    public let modifiedAt: TimeInterval
    public let sizeBytes: Int64

    public init(modifiedAt: TimeInterval, sizeBytes: Int64) {
        self.modifiedAt = modifiedAt
        self.sizeBytes = sizeBytes
    }

    public init?(for url: URL, using fileManager: FileManager = .default) {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
        guard let values else { return nil }
        self.init(resourceValues: values)
    }

    public init?(resourceValues values: URLResourceValues) {
        guard values.isRegularFile == true else { return nil }
        self.modifiedAt = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        self.sizeBytes = Int64(values.fileSize ?? 0)
    }

    /// Prefetch these on `contentsOfDirectory` / `enumerator` so a later
    /// `FileSignature(for:)` / `resourceValues(forKeys:)` hits the URL cache
    /// instead of issuing a second `stat`.
    public static let directoryListingPrefetchKeys: [URLResourceKey] = [
        .fileSizeKey,
        .contentModificationDateKey,
        .isRegularFileKey
    ]
}

public struct NamedFileSignature: Codable, Equatable, Sendable {
    public let name: String
    public let signature: FileSignature

    public init(name: String, signature: FileSignature) {
        self.name = name
        self.signature = signature
    }
}

public struct FileSetSignature: Codable, Equatable, Sendable {
    public let files: [NamedFileSignature]

    public init(files: [NamedFileSignature]) {
        self.files = files.sorted { $0.name < $1.name }
    }

    public init?(urls: [URL], using fileManager: FileManager = .default) {
        var collected: [NamedFileSignature] = []
        collected.reserveCapacity(urls.count)
        for url in urls {
            guard let signature = FileSignature(for: url, using: fileManager) else { return nil }
            collected.append(NamedFileSignature(name: url.lastPathComponent, signature: signature))
        }
        self.files = collected.sorted { $0.name < $1.name }
    }

    /// SQLite appends land in `-wal`. Signing only the main db file is a false
    /// hit while the WAL grows, so the WAL participates when present.
    /// `-shm` is a shared-memory index: a read-only open creates or rewrites it
    /// without changing session totals, so it must not participate.
    public init?(databaseURL: URL, using fileManager: FileManager = .default) {
        var urls = [databaseURL]
        let wal = URL(fileURLWithPath: databaseURL.path + "-wal")
        if fileManager.fileExists(atPath: wal.path) {
            urls.append(wal)
        }
        self.init(urls: urls, using: fileManager)
    }

    /// Build a signature from URLs whose size/mtime/`isRegularFile` values
    /// were already prefetched by a directory listing. A second
    /// `FileSignature(for:)` stat is not performed.
    public init?(prefetchedURLs urls: [URL]) {
        var collected: [NamedFileSignature] = []
        collected.reserveCapacity(urls.count)
        for url in urls {
            let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey,
                .fileSizeKey,
                .contentModificationDateKey
            ])
            guard let values, let signature = FileSignature(resourceValues: values) else {
                return nil
            }
            collected.append(NamedFileSignature(name: url.lastPathComponent, signature: signature))
        }
        self.init(files: collected)
    }
}

/// Persist-visible usage totals for idle ticks. Never includes conversation bodies.
public struct CachedUsageTotals: Codable, Equatable, Sendable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationTokens: Int
    public let cacheReadTokens: Int
    public let reasoningTokens: Int
    public let model: String
    public let projectName: String
    public let startTime: Date
    public let endTime: Date
    public let costUSD: Double
    public let provenanceMethod: UsageProvenanceMethod
    public let provenanceConfidence: UsageProvenanceConfidence
    public let estimatorVersion: String

    public init(usage: TokenUsage) {
        self.inputTokens = usage.inputTokens
        self.outputTokens = usage.outputTokens
        self.cacheCreationTokens = usage.cacheCreationTokens
        self.cacheReadTokens = usage.cacheReadTokens
        self.reasoningTokens = usage.reasoningTokens
        self.model = usage.model
        self.projectName = usage.projectName
        self.startTime = usage.startTime
        self.endTime = usage.endTime
        self.costUSD = usage.costUSD
        self.provenanceMethod = usage.provenanceMethod
        self.provenanceConfidence = usage.provenanceConfidence
        self.estimatorVersion = usage.estimatorVersion
    }

    public func makeUsage(provider: AgentProvider, sessionId: String) -> TokenUsage {
        TokenUsage(
            provider: provider,
            sessionId: sessionId,
            projectName: projectName,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            reasoningTokens: reasoningTokens,
            costUSD: costUSD,
            startTime: startTime,
            endTime: endTime,
            provenanceMethod: provenanceMethod,
            provenanceConfidence: provenanceConfidence,
            estimatorVersion: estimatorVersion
        )
    }
}

public struct CachedUsageEntry<Signature: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public let signature: Signature
    public let totals: CachedUsageTotals

    public init(signature: Signature, usage: TokenUsage) {
        self.signature = signature
        self.totals = CachedUsageTotals(usage: usage)
    }
}

/// One persist-visible usage row inside a multi-session file (Goose `sessions.db`).
public struct CachedNamedUsage: Codable, Equatable, Sendable {
    public let sessionId: String
    public let totals: CachedUsageTotals

    public init(sessionId: String, usage: TokenUsage) {
        self.sessionId = sessionId
        self.totals = CachedUsageTotals(usage: usage)
    }

    public func makeUsage(provider: AgentProvider) -> TokenUsage {
        totals.makeUsage(provider: provider, sessionId: sessionId)
    }
}

/// Disk cache entry for a file that yields many usage rows (Goose SQLite, or a
/// JSONL session stored as a one-element bundle).
public struct CachedUsageBundleEntry<Signature: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public let signature: Signature
    public let sessions: [CachedNamedUsage]

    public init(signature: Signature, usages: [TokenUsage]) {
        self.signature = signature
        self.sessions = usages.map { CachedNamedUsage(sessionId: $0.sessionId, usage: $0) }
    }
}

public struct CompositeFileSignature<Signature: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public let primary: Signature
    public let settings: Signature?
    public let metadata: Signature?

    public init(primary: Signature, settings: Signature? = nil, metadata: Signature? = nil) {
        self.primary = primary
        self.settings = settings
        self.metadata = metadata
    }
}

public struct ParserDiskCache<Entry: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var fileEntries: [String: Entry]
    public var lastUpdatedAt: Date?

    public init(schemaVersion: Int, fileEntries: [String: Entry], lastUpdatedAt: Date? = nil) {
        self.schemaVersion = schemaVersion
        self.fileEntries = fileEntries
        self.lastUpdatedAt = lastUpdatedAt
    }

    public static func empty(schemaVersion: Int) -> Self {
        Self(schemaVersion: schemaVersion, fileEntries: [:], lastUpdatedAt: nil)
    }

    public mutating func prune(staleKeys: [String]) {
        for key in staleKeys {
            fileEntries.removeValue(forKey: key)
        }
    }
}

public struct ParserDiskCacheStore<Entry: Codable & Equatable & Sendable>: Sendable {
    public let cacheURL: URL
    public let fileManager: FileManager
    public let schemaVersion: Int
    public let logLabel: String

    public init(
        cacheURL: URL,
        fileManager: FileManager = .default,
        schemaVersion: Int,
        logLabel: String
    ) {
        self.cacheURL = cacheURL
        self.fileManager = fileManager
        self.schemaVersion = schemaVersion
        self.logLabel = logLabel
    }

    public func load() -> ParserDiskCache<Entry> {
        guard fileManager.fileExists(atPath: cacheURL.path) else {
            return .empty(schemaVersion: schemaVersion)
        }
        do {
            let data = try Data(contentsOf: cacheURL)
            let cache = try Self.decode(cache: data)
            guard cache.schemaVersion == schemaVersion else {
                return .empty(schemaVersion: schemaVersion)
            }
            return cache
        } catch {
            return .empty(schemaVersion: schemaVersion)
        }
    }

    public func persist(_ cache: ParserDiskCache<Entry>) {
        do {
            let supportDir = cacheURL.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: supportDir.path) {
                try fileManager.createDirectory(at: supportDir, withIntermediateDirectories: true)
            }
            var persisted = cache
            persisted.lastUpdatedAt = Date()
            // Binary plist is the SOTA on-disk shape for this cache: encode is
            // ~3-5× faster than pretty-printed JSON, the file is ~2-3× smaller,
            // and `PropertyListEncoder` preserves `Date` fidelity natively (no
            // ISO-8601 string round-trip). The dual-read in `decode(cache:)`
            // upgrades any pre-existing JSON cache in place on the next persist.
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(persisted)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            ParserDiagnostics.silentFailure("\(logLabel): Failed to persist parser cache", error: error)
        }
    }

    /// Dual-format decoder: binary plist first (current format), JSON fallback
    /// (legacy caches written before the round-4 perf sweep). Both paths
    /// produce the same `ParserDiskCache` value; the fallback is removed once
    /// every cache has been re-persisted as a binary plist.
    static func decode(cache data: Data) throws -> ParserDiskCache<Entry> {
        if let plist = try? PropertyListDecoder().decode(ParserDiskCache<Entry>.self, from: data) {
            return plist
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ParserDiskCache<Entry>.self, from: data)
    }
}
