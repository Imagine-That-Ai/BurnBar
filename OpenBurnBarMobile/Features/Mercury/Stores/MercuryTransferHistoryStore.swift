import Foundation
import Combine

/// Persists a rolling list of Mercury file transfers (sent + received)
/// per connectionID. Persistence is a single JSON file in Application
/// Support so the user's history survives app restarts. Writes are
/// debounced (250ms) so a burst of transfers doesn't thrash disk.
@MainActor
final class MercuryTransferHistoryStore: ObservableObject {
    static let shared = MercuryTransferHistoryStore()

    /// Global cap across all connectionIDs. Older entries are trimmed.
    /// The UI shows the last 5 for a given connectionID by default.
    static let globalCap = 50

    @Published private(set) var entries: [MercuryTransferHistoryEntry] = []

    private let fileURL: URL
    private let writeQueue = DispatchQueue(label: "com.openburnbar.mobile.transferHistory")
    private var pendingWrite: DispatchWorkItem?

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = Self.defaultFileURL()
        }
        self.entries = Self.load(from: self.fileURL)
    }

    // MARK: - Mutation

    func append(_ entry: MercuryTransferHistoryEntry) {
        // De-dupe by id — `sendFile` and `handleAdvertise` paths shouldn't
        // emit twice, but defend against a future retry path that does.
        if let existingIndex = entries.firstIndex(where: { $0.id == entry.id }) {
            entries.remove(at: existingIndex)
        }
        entries.insert(entry, at: 0)
        if entries.count > Self.globalCap {
            entries.removeLast(entries.count - Self.globalCap)
        }
        schedulePersist()
    }

    func remove(id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries.remove(at: index)
        schedulePersist()
    }

    func clear(connectionID: String) {
        entries.removeAll { $0.connectionID == connectionID }
        schedulePersist()
    }

    // MARK: - Query

    /// Last `limit` entries for the given connectionID, newest first.
    func recent(for connectionID: String, limit: Int = 5) -> [MercuryTransferHistoryEntry] {
        Array(entries.filter { $0.connectionID == connectionID }.prefix(limit))
    }

    /// Total count for a connectionID — used to decide whether to show
    /// a "View all" chevron.
    func totalCount(for connectionID: String) -> Int {
        entries.lazy.filter { $0.connectionID == connectionID }.count
    }

    // MARK: - Persistence

    private func schedulePersist() {
        pendingWrite?.cancel()
        let snapshot = entries
        let url = fileURL
        let work = DispatchWorkItem {
            Self.write(snapshot, to: url)
        }
        pendingWrite = work
        writeQueue.asyncAfter(deadline: .now() + .milliseconds(250), execute: work)
    }

    /// Forces a synchronous flush — used during tests so assertions can
    /// read the persisted file.
    func flush() {
        pendingWrite?.cancel()
        pendingWrite = nil
        Self.write(entries, to: fileURL)
    }

    private static func write(_ entries: [MercuryTransferHistoryEntry], to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(entries)
            try data.write(to: url, options: .atomic)
        } catch {
            // Best-effort — losing one debounced write is preferable to
            // crashing the app.
        }
    }

    private static func load(from url: URL) -> [MercuryTransferHistoryEntry] {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([MercuryTransferHistoryEntry].self, from: data)) ?? []
    }

    private static func defaultFileURL() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("OpenBurnBarMobile", isDirectory: true)
            .appendingPathComponent("mercury-transfers.json")
    }
}
