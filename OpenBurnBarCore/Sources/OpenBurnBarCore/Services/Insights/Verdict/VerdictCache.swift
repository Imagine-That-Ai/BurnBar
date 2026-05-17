import Foundation

/// Thread-safe, two-tier cache for `InsightVerdict`.
///
/// Tier 1 is an in-memory dict for sub-16ms reads on every tab appear.
/// Tier 2 is a JSON-on-disk store keyed by (deviceID, window) so the
/// verdict survives launches. Reads always serve from memory; disk loads
/// happen lazily on first access for a key and are populated back into
/// memory.
///
/// The cache is opinionated about staleness: every read returns
/// `(verdict, isStale)` so the renderer can paint the cached entry
/// immediately while the composer kicks a background refresh.
public actor VerdictCache {

    public struct Read: Sendable {
        public let verdict: InsightVerdict
        public let isStale: Bool
        public let age: TimeInterval

        public init(verdict: InsightVerdict, isStale: Bool, age: TimeInterval) {
            self.verdict = verdict
            self.isStale = isStale
            self.age = age
        }
    }

    public enum Storage: Sendable {
        case memoryOnly
        case onDisk(directory: URL)

        public static func defaultUserCaches(subpath: String = "OpenBurnBar/Verdicts") -> Storage {
            let base = FileManager.default
                .urls(for: .cachesDirectory, in: .userDomainMask)
                .first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            return .onDisk(directory: base.appendingPathComponent(subpath, isDirectory: true))
        }
    }

    private let storage: Storage
    private let calendar: Calendar
    /// In-memory: deviceID -> Window -> dayBucketKey -> Verdict.
    private var memory: [String: [VerdictWindow: [String: InsightVerdict]]] = [:]
    /// Keys whose disk content has already been hydrated into memory.
    private var hydrated: Set<String> = []

    public init(storage: Storage = .defaultUserCaches(), calendar: Calendar = .current) {
        self.storage = storage
        self.calendar = calendar
        if case .onDisk(let directory) = storage {
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
    }

    // MARK: - Read / Write

    public func read(
        window: VerdictWindow,
        deviceID: String,
        now: Date = Date()
    ) -> Read? {
        hydrateIfNeeded(window: window, deviceID: deviceID)
        let bucket = window.dayBucketKey(for: now, calendar: calendar)
        guard let verdict = memory[deviceID]?[window]?[bucket] else { return nil }
        let age = now.timeIntervalSince(verdict.generatedAt)
        return Read(
            verdict: verdict,
            isStale: age >= window.cacheTTL,
            age: age
        )
    }

    /// Read the most recent entry for a window even when the user is past
    /// the bucket boundary — used by the renderer to avoid blanking the
    /// surface when the calendar rolls over mid-session.
    public func readMostRecent(
        window: VerdictWindow,
        deviceID: String,
        now: Date = Date()
    ) -> Read? {
        hydrateIfNeeded(window: window, deviceID: deviceID)
        guard let buckets = memory[deviceID]?[window] else { return nil }
        let verdict = buckets.values.max(by: { $0.generatedAt < $1.generatedAt })
        guard let verdict else { return nil }
        let age = now.timeIntervalSince(verdict.generatedAt)
        return Read(
            verdict: verdict,
            isStale: age >= window.cacheTTL,
            age: age
        )
    }

    public func write(
        _ verdict: InsightVerdict,
        deviceID: String,
        now: Date = Date()
    ) {
        let bucket = verdict.window.dayBucketKey(for: verdict.generatedAt, calendar: calendar)
        memory[deviceID, default: [:]][verdict.window, default: [:]][bucket] = verdict
        persist(window: verdict.window, deviceID: deviceID)
    }

    public func clear(deviceID: String? = nil) {
        if let deviceID {
            memory[deviceID] = nil
        } else {
            memory.removeAll()
            hydrated.removeAll()
        }
        if case .onDisk(let directory) = storage {
            if let deviceID {
                try? FileManager.default.removeItem(
                    at: directory.appendingPathComponent("\(safeName(deviceID))")
                )
            } else {
                try? FileManager.default.removeItem(at: directory)
                try? FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
            }
        }
    }

    /// Number of cached verdicts for a (deviceID, window). Used by tests
    /// and the audit log.
    public func count(deviceID: String, window: VerdictWindow) -> Int {
        hydrateIfNeeded(window: window, deviceID: deviceID)
        return memory[deviceID]?[window]?.count ?? 0
    }

    // MARK: - Persistence

    private func hydrateIfNeeded(window: VerdictWindow, deviceID: String) {
        let key = "\(deviceID)/\(window.rawValue)"
        guard !hydrated.contains(key) else { return }
        defer { hydrated.insert(key) }
        guard case .onDisk(let directory) = storage else { return }
        let url = fileURL(in: directory, deviceID: deviceID, window: window)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder.verdict.decode([String: InsightVerdict].self, from: data)
        else { return }
        memory[deviceID, default: [:]][window] = dict
    }

    private func persist(window: VerdictWindow, deviceID: String) {
        guard case .onDisk(let directory) = storage else { return }
        guard let dict = memory[deviceID]?[window] else { return }
        let url = fileURL(in: directory, deviceID: deviceID, window: window)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(dict) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    private func fileURL(in directory: URL, deviceID: String, window: VerdictWindow) -> URL {
        let safeID = safeName(deviceID)
        let dir = directory.appendingPathComponent(safeID, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(window.rawValue).json")
    }

    private func safeName(_ raw: String) -> String {
        raw.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }
            .reduce(into: "") { $0.append($1) }
    }
}

private extension JSONDecoder {
    static let verdict: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
