import Foundation

/// File-backed high-water-mark store for phone-control authority counters.
///
/// The validator accepts only strictly increasing counters per peer. Persisting
/// those high-water marks closes the restart replay window for a captured,
/// still-fresh authority envelope. Writes merge by max so concurrent validator
/// instances cannot roll the file back to an older counter.
public final class PhoneControlReplayCounterStore: Sendable {
    private struct SnapshotFile: Codable {
        var version: Int
        var counters: [String: UInt64]
        var updatedAt: Date
    }

    private static let currentVersion = 1

    private let fileURL: URL
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "com.openburnbar.phoneControl.replayCounterStore")
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        fileURL: URL = PhoneControlReplayCounterStore.defaultFileURL(),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public static func defaultStore() -> PhoneControlReplayCounterStore {
        PhoneControlReplayCounterStore()
    }

    /// Result of restoring persisted high-water marks.
    ///
    /// SECURITY (F6): callers MUST distinguish "the file is genuinely absent"
    /// (a legitimate first run → an empty baseline is safe) from "the file exists
    /// but could not be read/decoded" (corruption, truncation, or a hostile delete
    /// of the contents). In the latter case returning an empty map silently resets
    /// every per-peer counter to 0, which re-opens the restart replay window for a
    /// captured, still-fresh authority envelope. `unreadable` lets the validator
    /// fail CLOSED instead of trusting a zeroed baseline.
    public enum LoadOutcome: Sendable {
        case absent
        case loaded([String: UInt64])
        case unreadable(any Error)
    }

    public func loadOutcome() -> LoadOutcome {
        queue.sync {
            guard fileManager.fileExists(atPath: fileURL.path) else { return .absent }
            do {
                let data = try Data(contentsOf: fileURL)
                let snapshot = try decoder.decode(SnapshotFile.self, from: data)
                return .loaded(snapshot.counters.filter { $0.key.isEmpty == false })
            } catch {
                return .unreadable(error)
            }
        }
    }

    public func load() -> [String: UInt64] {
        switch loadOutcome() {
        case .absent, .unreadable:
            return [:]
        case .loaded(let counters):
            return counters
        }
    }

    public func persist(_ counters: [String: UInt64]) throws {
        try queue.sync {
            var merged = try readUnlocked()
            for (peerNodeId, counter) in counters where peerNodeId.isEmpty == false {
                merged[peerNodeId] = max(merged[peerNodeId] ?? 0, counter)
            }
            try writeUnlocked(merged)
        }
    }

    private func readUnlocked() throws -> [String: UInt64] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [:] }
        let data = try Data(contentsOf: fileURL)
        let snapshot = try decoder.decode(SnapshotFile.self, from: data)
        return snapshot.counters.filter { $0.key.isEmpty == false }
    }

    private func writeUnlocked(_ counters: [String: UInt64]) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let snapshot = SnapshotFile(
            version: Self.currentVersion,
            counters: counters.filter { $0.key.isEmpty == false },
            updatedAt: Date()
        )
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: [.atomic])
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    public static func defaultFileURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("com.openburnbar.AgentLens", isDirectory: true)
            .appendingPathComponent("phone-control-replay-counters.json", isDirectory: false)
    }
}
