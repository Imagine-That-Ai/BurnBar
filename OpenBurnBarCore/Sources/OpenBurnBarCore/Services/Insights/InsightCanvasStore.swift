import Foundation

/// Thread-safe, file-backed canvas persistence.
///
/// Canvases live in a single JSON file under Application Support so the
/// store can be opened, mutated, exported, and synced atomically. Cap at
/// 200 canvases with LRU eviction based on `updatedAt`.
public actor InsightCanvasStore {

    public struct Snapshot: Codable, Hashable, Sendable {
        public var schemaVersion: Int
        public var canvases: [InsightCanvas]
        public init(schemaVersion: Int = 1, canvases: [InsightCanvas] = []) {
            self.schemaVersion = schemaVersion
            self.canvases = canvases
        }
    }

    public static let maxCanvases: Int = 200

    private let fileURL: URL
    private var snapshot: Snapshot
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        self.encoder = {
            let e = JSONEncoder()
            e.dateEncodingStrategy = .iso8601
            e.outputFormatting = [.prettyPrinted, .sortedKeys]
            return e
        }()
        self.decoder = {
            let d = JSONDecoder()
            d.dateDecodingStrategy = .iso8601
            return d
        }()
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            if data.isEmpty {
                snapshot = Snapshot()
            } else {
                snapshot = (try? decoder.decode(Snapshot.self, from: data)) ?? Snapshot()
            }
        } else {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                   withIntermediateDirectories: true)
            snapshot = Snapshot()
        }
    }

    /// All canvases sorted by `sortIndex`, then by most-recently-updated.
    public func allCanvases() -> [InsightCanvas] {
        snapshot.canvases.sorted { lhs, rhs in
            if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    /// Look up by id.
    public func canvas(id: UUID) -> InsightCanvas? {
        snapshot.canvases.first { $0.id == id }
    }

    /// Insert or update; bumps `updatedAt`, then trims LRU and persists.
    public func upsert(_ canvas: InsightCanvas) async throws {
        var working = canvas
        working.updatedAt = Date()
        if let idx = snapshot.canvases.firstIndex(where: { $0.id == working.id }) {
            snapshot.canvases[idx] = working
        } else {
            snapshot.canvases.append(working)
        }
        evictIfNeeded()
        try await persist()
    }

    /// Remove a canvas by id.
    public func remove(id: UUID) async throws {
        snapshot.canvases.removeAll { $0.id == id }
        try await persist()
    }

    /// Replace the entire canvas list (used when importing).
    public func replaceAll(_ canvases: [InsightCanvas]) async throws {
        snapshot.canvases = canvases
        evictIfNeeded()
        try await persist()
    }

    /// Move a canvas to a different position by sortIndex.
    public func reorder(_ orderedIDs: [UUID]) async throws {
        let lookup = Dictionary(uniqueKeysWithValues: snapshot.canvases.map { ($0.id, $0) })
        var reordered: [InsightCanvas] = []
        for (idx, id) in orderedIDs.enumerated() {
            if var c = lookup[id] {
                c.sortIndex = idx
                reordered.append(c)
            }
        }
        // Append any canvases that weren't in the order list.
        for c in snapshot.canvases where !orderedIDs.contains(c.id) {
            var copy = c
            copy.sortIndex = reordered.count
            reordered.append(copy)
        }
        snapshot.canvases = reordered
        try await persist()
    }

    // MARK: - Eviction

    private func evictIfNeeded() {
        guard snapshot.canvases.count > Self.maxCanvases else { return }
        let sorted = snapshot.canvases.sorted { $0.updatedAt > $1.updatedAt }
        snapshot.canvases = Array(sorted.prefix(Self.maxCanvases))
    }

    // MARK: - Persistence

    private func persist() async throws {
        let data = try encoder.encode(snapshot)
        // Atomic write through a temp file in the same directory.
        let tmp = fileURL.appendingPathExtension("tmp-\(UUID().uuidString.prefix(8))")
        try data.write(to: tmp, options: [.atomic])
        let manager = FileManager.default
        if manager.fileExists(atPath: fileURL.path) {
            _ = try manager.replaceItemAt(fileURL, withItemAt: tmp)
        } else {
            try manager.moveItem(at: tmp, to: fileURL)
        }
    }
}
