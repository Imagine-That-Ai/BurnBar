import Foundation

public struct FileSignature: Codable, Equatable, Sendable {
    public let modifiedAt: TimeInterval
    public let sizeBytes: Int64

    public init(modifiedAt: TimeInterval, sizeBytes: Int64) {
        self.modifiedAt = modifiedAt
        self.sizeBytes = sizeBytes
    }

    public init?(for url: URL, using fileManager: FileManager = .default) {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true else { return nil }
        self.modifiedAt = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        self.sizeBytes = Int64(values?.fileSize ?? 0)
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
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let cache = try decoder.decode(ParserDiskCache<Entry>.self, from: data)
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
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(persisted)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            AppLogger.parser.silentFailure("\(logLabel): Failed to persist parser cache", error: error)
        }
    }
}
