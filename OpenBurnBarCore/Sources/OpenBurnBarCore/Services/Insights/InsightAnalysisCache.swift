import CryptoKit
import Foundation

/// Content-addressed cache for `InsightAnalysisResult`.
///
/// Sibling to `InsightCache` (which caches canvas-investigation runs). Keyed
/// by the inputs that uniquely determine an analysis: prompt + digest content
/// hash + model id + capability tier + instruction. LRU eviction at 64 entries.
public actor InsightAnalysisCache {
    public struct CachedResult: Codable, Hashable, Sendable {
        public let key: String
        public let result: InsightAnalysisResult
        public let storedAt: Date
        public let estimatedCostSavedUSD: Double

        public init(
            key: String,
            result: InsightAnalysisResult,
            storedAt: Date = Date(),
            estimatedCostSavedUSD: Double = 0
        ) {
            self.key = key
            self.result = result
            self.storedAt = storedAt
            self.estimatedCostSavedUSD = estimatedCostSavedUSD
        }
    }

    private let directoryURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let maxEntries: Int

    public init(directoryURL: URL, maxEntries: Int = 64) {
        self.directoryURL = directoryURL
        self.maxEntries = maxEntries
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// Schema version baked into every cache key. Bump whenever the
    /// engine produces a meaningfully different result for the same
    /// inputs (e.g., when widget data synthesis lands and previously
    /// cached entries would render empty charts).
    ///
    /// v3 — 2026-05-14: analysis results now include mission candidates
    /// generated from the same evidence as findings/recommendations.
    /// Pre-v3 cached remote results may have an empty mission board.
    ///
    /// v2 — 2026-05-13: rule-based engine now synthesizes widget data
    /// for `barRanking`, `timeSeriesLine`, and `quotaPulse` straight
    /// from the digest. Pre-fix cached entries have `data = nil` and
    /// must be invalidated so the brief paints real charts.
    public static let schemaVersion = "v3-insight-mission-candidates"

    public static func key(
        prompt: String,
        digestContentHash: String,
        modelID: String,
        instruction: InsightAnalysisRequest.Instruction
    ) -> String {
        let payload = "\(schemaVersion)\u{1F}\(prompt)\u{1F}\(digestContentHash)\u{1F}\(modelID)\u{1F}\(instruction.rawValue)"
        return SHA256.hash(data: Data(payload.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public func lookup(key: String) -> CachedResult? {
        let url = fileURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let cached = try? decoder.decode(CachedResult.self, from: data)
        else { return nil }
        return cached
    }

    public func store(_ cached: CachedResult) throws {
        try ensureDirectoryExists()
        let data = try encoder.encode(cached)
        try data.write(to: fileURL(for: cached.key), options: .atomic)
        try evictIfNeeded()
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return }
        try FileManager.default.removeItem(at: directoryURL)
    }

    public func entryCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path).count) ?? 0
    }

    private func fileURL(for key: String) -> URL {
        directoryURL.appendingPathComponent("\(key).json", isDirectory: false)
    }

    private func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private func evictIfNeeded() throws {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        guard urls.count > maxEntries else { return }
        let sorted = urls.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return lhsDate < rhsDate
        }
        let toRemove = sorted.prefix(sorted.count - maxEntries)
        for url in toRemove {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
