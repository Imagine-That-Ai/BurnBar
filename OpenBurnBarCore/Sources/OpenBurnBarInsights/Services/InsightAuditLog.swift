import Foundation

/// Append-only JSONL audit trail for every LLM investigation.
///
/// Surfaced in Settings → Insights → "Audit log" so the user can see
/// exactly which data left their device, when, and at what cost. Each
/// entry mirrors the spec in `docs/INSIGHTS.md`.
public actor InsightAuditLog {

    public struct Entry: Codable, Hashable, Sendable, Identifiable {
        public var id: UUID
        public var canvasID: UUID?
        public var prompt: String
        public var modelTag: InsightModelTag
        public var egressTier: InsightEgressTier
        public var digestBytes: Int
        public var digestContentHash: String
        public var instruction: String
        public var tokenUsage: InsightTokenUsage?
        public var startedAt: Date
        public var completedAt: Date?
        public var status: Status
        public var errorDescription: String?

        public init(id: UUID = UUID(), canvasID: UUID?, prompt: String, modelTag: InsightModelTag,
                    egressTier: InsightEgressTier, digestBytes: Int, digestContentHash: String,
                    instruction: String, tokenUsage: InsightTokenUsage? = nil,
                    startedAt: Date = Date(), completedAt: Date? = nil,
                    status: Status, errorDescription: String? = nil) {
            self.id = id; self.canvasID = canvasID; self.prompt = prompt
            self.modelTag = modelTag; self.egressTier = egressTier
            self.digestBytes = digestBytes; self.digestContentHash = digestContentHash
            self.instruction = instruction; self.tokenUsage = tokenUsage
            self.startedAt = startedAt; self.completedAt = completedAt
            self.status = status; self.errorDescription = errorDescription
        }

        public enum Status: String, Codable, Hashable, Sendable {
            case started, succeeded, cancelled, failed
        }
    }

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        self.encoder = {
            let e = JSONEncoder()
            e.dateEncodingStrategy = .iso8601
            return e
        }()
        self.decoder = {
            let d = JSONDecoder()
            d.dateDecodingStrategy = .iso8601
            return d
        }()
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                               withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
    }

    /// Append an entry.
    public func append(_ entry: Entry) throws {
        var data = try encoder.encode(entry)
        data.append(0x0A)   // newline
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
    }

    /// Read entries (newest first). Useful for the Settings UI.
    public func readAll(limit: Int = 500) throws -> [Entry] {
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { return [] }
        var entries: [Entry] = []
        var startIndex = data.startIndex
        for idx in data.indices where data[idx] == 0x0A {
            let line = data[startIndex..<idx]
            startIndex = data.index(after: idx)
            if line.isEmpty { continue }
            if let entry = try? decoder.decode(Entry.self, from: line) {
                entries.append(entry)
            }
        }
        // Handle the case where the last line lacks a trailing newline.
        if startIndex < data.endIndex {
            let line = data[startIndex..<data.endIndex]
            if let entry = try? decoder.decode(Entry.self, from: line) {
                entries.append(entry)
            }
        }
        return Array(entries.reversed().prefix(limit))
    }

    /// Clear the entire audit log (re-creates an empty file).
    public func clear() throws {
        try FileManager.default.removeItem(at: fileURL)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
    }
}
