import Foundation
import CryptoKit

/// Content-addressed cache for completed LLM investigations.
///
/// Key = sha256(digestContentHash + prompt + modelID + tier + instruction).
/// When a hit occurs the UI shows "Replayed — $0 saved".
public actor InsightCache {

    public struct CachedCanvas: Codable, Hashable, Sendable {
        public var key: String
        public var canvas: InsightCanvas
        public var storedAt: Date
        public var costSavedUSD: Double
        public init(key: String, canvas: InsightCanvas, storedAt: Date = Date(), costSavedUSD: Double = 0) {
            self.key = key; self.canvas = canvas; self.storedAt = storedAt; self.costSavedUSD = costSavedUSD
        }
    }

    public static let maxEntries: Int = 64

    private let directoryURL: URL
    private var index: [String: Date] = [:]    // key → storedAt

    public init(directoryURL: URL) throws {
        self.directoryURL = directoryURL
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        self.index = Self.buildInitialIndex(at: directoryURL)
    }

    /// Compute a stable key for the request.
    public static func key(digestContentHash: String,
                           prompt: String,
                           modelID: String,
                           tier: InsightCapabilityTier,
                           instruction: InsightInvestigateRequest.Instruction) -> String {
        let raw = [digestContentHash, prompt, modelID, tier.rawValue, instruction.rawValue].joined(separator: "|")
        let bytes = SHA256.hash(data: Data(raw.utf8))
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    public func lookup(key: String) -> CachedCanvas? {
        let url = url(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let cached = try? decoder.decode(CachedCanvas.self, from: data) else { return nil }
        return cached
    }

    public func store(_ cached: CachedCanvas) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(cached)
        try data.write(to: url(for: cached.key), options: [.atomic])
        index[cached.key] = cached.storedAt
        evictIfNeeded()
    }

    public func clear() throws {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directoryURL,
                                                                  includingPropertiesForKeys: nil)) ?? []
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
        index.removeAll()
    }

    private func evictIfNeeded() {
        guard index.count > Self.maxEntries else { return }
        let sorted = index.sorted { $0.value < $1.value }
        let toRemove = sorted.prefix(index.count - Self.maxEntries)
        for (key, _) in toRemove {
            try? FileManager.default.removeItem(at: url(for: key))
            index.removeValue(forKey: key)
        }
    }

    private func url(for key: String) -> URL {
        directoryURL.appendingPathComponent("\(key).json")
    }

    private static func buildInitialIndex(at directoryURL: URL) -> [String: Date] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        var out: [String: Date] = [:]
        for url in urls where url.pathExtension == "json" {
            let key = url.deletingPathExtension().lastPathComponent
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            out[key] = date
        }
        return out
    }
}
