import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import FirebaseFunctions
import Foundation
import OpenBurnBarKernel
import os.log

// MARK: - Cloud Transcript Cache

struct CloudTranscriptCacheSettings: Sendable {
    static let defaultMaxMegabytes = 250
    static let maximumMegabytes = 2_048
    static let bytesPerMegabyte: Int64 = 1_024 * 1_024
    static let shared = CloudTranscriptCacheSettings()

    private static let maxMegabytesKey = "streams.transcriptCache.maxMegabytes.v1"
    private let defaultsSuiteName: String?

    init(defaultsSuiteName: String? = nil) {
        self.defaultsSuiteName = defaultsSuiteName
    }

    var maxMegabytes: Int {
        get {
            let stored = defaults.object(forKey: Self.maxMegabytesKey) as? NSNumber
            return Self.clampedMegabytes(stored?.intValue ?? Self.defaultMaxMegabytes)
        }
        nonmutating set {
            defaults.set(Self.clampedMegabytes(newValue), forKey: Self.maxMegabytesKey)
        }
    }

    var maxBytes: Int64 {
        get { Int64(maxMegabytes) * Self.bytesPerMegabyte }
        nonmutating set {
            maxMegabytes = Int(newValue / Self.bytesPerMegabyte)
        }
    }

    private var defaults: UserDefaults {
        if let defaultsSuiteName, let suite = UserDefaults(suiteName: defaultsSuiteName) {
            return suite
        }
        return .standard
    }

    static func clampedMegabytes(_ value: Int) -> Int {
        min(max(0, value), maximumMegabytes)
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesActualByteCount = false
        return formatter.string(fromByteCount: max(0, bytes))
    }
}

struct CloudTranscriptCacheSnapshot: Equatable, Sendable {
    let usageBytes: Int64
    let maxBytes: Int64

    var isDisabled: Bool { maxBytes <= 0 }
    var isFull: Bool { !isDisabled && usageBytes >= maxBytes }
}

struct CloudTranscriptCacheWarmupResult: Equatable, Sendable {
    var available = 0
    var skipped = 0
    var failed = 0
    var limitReached = false
}

actor CloudTranscriptCache {
    static let shared = CloudTranscriptCache()

    private struct CacheIndex: Codable, Sendable {
        var entries: [String: CacheEntry] = [:]
    }

    private struct CacheEntry: Codable, Sendable {
        let key: String
        let storagePath: String
        let bodyHash: String
        let bodyHashVersion: Int?
        var byteCount: Int64
        let cachedAt: Date
        var lastAccessedAt: Date
    }

    private let directory: URL
    private let settings: CloudTranscriptCacheSettings

    init(
        directory: URL? = nil,
        settings: CloudTranscriptCacheSettings = .shared
    ) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenBurnBarCloudTranscripts", isDirectory: true)
        self.settings = settings
    }

    func cachedTranscript(
        storagePath: String,
        bodyHash: String,
        bodyHashVersion: Int,
        vaultKey: Data,
        aadContext: CloudVaultAADContext
    ) -> String? {
        guard settings.maxBytes > 0 else { return nil }
        let key = Self.cacheKey(storagePath: storagePath, bodyHash: bodyHash, bodyHashVersion: bodyHashVersion)
        do {
            var index = try loadIndex()
            guard var entry = index.entries[key],
                  entry.storagePath == storagePath,
                  entry.bodyHash == bodyHash,
                  (entry.bodyHashVersion ?? 0) == bodyHashVersion else {
                return nil
            }
            let data = try Data(contentsOf: blobURL(for: key))
            let envelope = try JSONDecoder().decode(CloudVaultBlobEnvelope.self, from: data)
            let plaintext = try CloudVaultCrypto.openBlob(envelope, keyData: vaultKey, aadContext: aadContext)
            guard try CloudVaultCrypto.expectedSessionBodyHash(
                plaintext,
                keyData: vaultKey,
                bodyHashVersion: bodyHashVersion
            ) == bodyHash,
                  let transcript = String(data: plaintext, encoding: .utf8) else {
                try removeEntry(key, from: &index)
                try writeIndex(index)
                return nil
            }
            entry.byteCount = Int64(data.count)
            entry.lastAccessedAt = Date()
            index.entries[key] = entry
            try writeIndex(index)
            return transcript
        } catch {
            // Deliberate self-healing: a corrupt/undecryptable cache entry is
            // evicted so the next read falls back to a fresh cloud download.
            try? removeCachedKey(key)
            return nil
        }
    }

    func storeTranscript(
        _ transcript: String,
        storagePath: String,
        bodyHash: String,
        bodyHashVersion: Int,
        vaultKey: Data,
        aadContext: CloudVaultAADContext
    ) throws {
        let maxBytes = settings.maxBytes
        guard maxBytes > 0 else {
            try? clear()
            return
        }

        let plaintext = Data(transcript.utf8)
        let envelope = try CloudVaultCrypto.sealBlob(plaintext, keyData: vaultKey, aadContext: aadContext)
        guard try CloudVaultCrypto.expectedSessionBodyHash(
            plaintext,
            keyData: vaultKey,
            bodyHashVersion: bodyHashVersion
        ) == bodyHash else {
            throw CloudConversationSearchError.bodyHashMismatch
        }
        let encoded = try JSONEncoder().encode(envelope)
        guard Int64(encoded.count) <= maxBytes else { return }

        try ensureDirectory()
        let key = Self.cacheKey(storagePath: storagePath, bodyHash: bodyHash, bodyHashVersion: bodyHashVersion)
        try encoded.write(to: blobURL(for: key), options: .atomic)

        var index = try loadIndex()
        let now = Date()
        index.entries[key] = CacheEntry(
            key: key,
            storagePath: storagePath,
            bodyHash: bodyHash,
            bodyHashVersion: bodyHashVersion,
            byteCount: Int64(encoded.count),
            cachedAt: now,
            lastAccessedAt: now
        )
        try trim(&index, maxBytes: maxBytes)
        try writeIndex(index)
    }

    func snapshot() -> CloudTranscriptCacheSnapshot {
        let usage = (try? currentUsageBytes()) ?? 0
        return CloudTranscriptCacheSnapshot(usageBytes: usage, maxBytes: settings.maxBytes)
    }

    func trimToLimit() {
        do {
            var index = try loadIndex()
            try trim(&index, maxBytes: settings.maxBytes)
            try writeIndex(index)
        } catch {
            // Cache trimming is opportunistic; transcript loading should not fail because
            // the local cache index is temporarily unavailable.
        }
    }

    func clear() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try ensureDirectory()
        try writeIndex(CacheIndex())
    }

    private static func cacheKey(storagePath: String, bodyHash: String, bodyHashVersion: Int) -> String {
        CloudVaultCrypto.sha256Hex("\(storagePath)\n\(bodyHash)\n\(bodyHashVersion)")
    }

    private var indexURL: URL {
        directory.appendingPathComponent("index.json", isDirectory: false)
    }

    private func blobURL(for key: String) -> URL {
        directory.appendingPathComponent("\(key).json", isDirectory: false)
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func loadIndex() throws -> CacheIndex {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return CacheIndex() }
        let data = try Data(contentsOf: indexURL)
        return try JSONDecoder().decode(CacheIndex.self, from: data)
    }

    private func writeIndex(_ index: CacheIndex) throws {
        try ensureDirectory()
        let data = try JSONEncoder().encode(index)
        try data.write(to: indexURL, options: .atomic)
    }

    private func currentUsageBytes() throws -> Int64 {
        var index = try loadIndex()
        var total: Int64 = 0
        for (key, entry) in index.entries {
            let url = blobURL(for: key)
            guard FileManager.default.fileExists(atPath: url.path) else {
                index.entries.removeValue(forKey: key)
                continue
            }
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let byteCount = (attributes?[.size] as? NSNumber)?.int64Value ?? entry.byteCount
            var updated = entry
            updated.byteCount = byteCount
            index.entries[key] = updated
            total += byteCount
        }
        try writeIndex(index)
        return total
    }

    private func trim(_ index: inout CacheIndex, maxBytes: Int64) throws {
        guard maxBytes > 0 else {
            for key in Array(index.entries.keys) {
                try? FileManager.default.removeItem(at: blobURL(for: key))
            }
            index.entries = [:]
            return
        }

        var total: Int64 = 0
        for (key, entry) in index.entries {
            let url = blobURL(for: key)
            guard FileManager.default.fileExists(atPath: url.path) else {
                index.entries.removeValue(forKey: key)
                continue
            }
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let byteCount = (attributes?[.size] as? NSNumber)?.int64Value ?? entry.byteCount
            var updated = entry
            updated.byteCount = byteCount
            index.entries[key] = updated
            total += byteCount
        }

        let oldestFirst = index.entries.values.sorted { lhs, rhs in
            lhs.lastAccessedAt < rhs.lastAccessedAt
        }
        for entry in oldestFirst where total > maxBytes {
            try? FileManager.default.removeItem(at: blobURL(for: entry.key))
            index.entries.removeValue(forKey: entry.key)
            total -= entry.byteCount
        }
    }

    private func removeEntry(_ key: String, from index: inout CacheIndex) throws {
        try? FileManager.default.removeItem(at: blobURL(for: key))
        index.entries.removeValue(forKey: key)
    }

    private func removeCachedKey(_ key: String) throws {
        var index = try loadIndex()
        try removeEntry(key, from: &index)
        try writeIndex(index)
    }
}
