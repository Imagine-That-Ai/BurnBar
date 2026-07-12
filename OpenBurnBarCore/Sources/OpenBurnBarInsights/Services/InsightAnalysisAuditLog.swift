import Foundation

/// Append-only JSONL trail of every analysis run.
///
/// Separate from `InsightAuditLog` (which records the canvas-investigation
/// pipeline) so the analysis-layer audit can grow its own shape without
/// breaking the investigation audit's wire format.
///
/// File layout: one `InsightAnalysisAuditEntry` per line (JSON-encoded, no
/// pretty-printing). Newest-last on disk; `readAll(limit:)` returns the
/// newest-first slice the UI needs.
public actor InsightAnalysisAuditLog {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL) {
        self.fileURL = fileURL
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func append(_ entry: InsightAnalysisAuditEntry) throws {
        try ensureDirectoryExists()
        var data = try encoder.encode(entry)
        data.append(0x0A)  // newline
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: fileURL, options: .atomic)
        }
    }

    /// Replace the latest entry for `requestID` (preserves history but lets the
    /// orchestrator mark a started entry as succeeded/failed without writing
    /// two rows). Implemented as append-then-rewrite to keep the on-disk format
    /// simple — the file is small (one line per run).
    public func upsertLatest(_ entry: InsightAnalysisAuditEntry) throws {
        var rows = try readAll(limit: .max)
        if let idx = rows.firstIndex(where: { $0.requestID == entry.requestID }) {
            rows[idx] = entry
        } else {
            rows.append(entry)
        }
        try rewrite(rows)
    }

    public func readAll(limit: Int = 500) throws -> [InsightAnalysisAuditEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        let lines = data.split(separator: 0x0A)
        var out: [InsightAnalysisAuditEntry] = []
        out.reserveCapacity(min(lines.count, limit))
        for line in lines {
            guard !line.isEmpty else { continue }
            if let entry = try? decoder.decode(InsightAnalysisAuditEntry.self, from: Data(line)) {
                out.append(entry)
            }
        }
        return Array(out.suffix(limit).reversed())
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    private func rewrite(_ entries: [InsightAnalysisAuditEntry]) throws {
        try ensureDirectoryExists()
        var data = Data()
        for entry in entries {
            var encoded = try encoder.encode(entry)
            encoded.append(0x0A)
            data.append(encoded)
        }
        try data.write(to: fileURL, options: .atomic)
    }

    private func ensureDirectoryExists() throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}
