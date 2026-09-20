import Foundation

/// Per-month `RecapFacts`, persisted so comparisons are cheap.
///
/// This is what makes month-over-month and all-time claims affordable: comparing
/// August to a year of history is comparing thirteen small structs, not
/// re-reading a year of raw usage rows on every open.
public actor RecapHistoryStore {

    public struct Snapshot: Codable, Sendable {
        public var schemaVersion: Int
        public var months: [String: RecapFacts]
        public var completeThroughKey: String?

        public init(
            schemaVersion: Int = RecapFacts.currentSchemaVersion,
            months: [String: RecapFacts] = [:],
            completeThroughKey: String? = nil
        ) {
            self.schemaVersion = schemaVersion
            self.months = months
            self.completeThroughKey = completeThroughKey
        }
    }

    private let fileURL: URL
    private var snapshot: Snapshot
    private let encoder: JSONEncoder

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        encoder = RecapSnapshotFile.makeEncoder()
        snapshot = try RecapSnapshotFile.load(
            Snapshot.self,
            from: fileURL,
            decoder: RecapSnapshotFile.makeDecoder(),
            fallback: { Snapshot() }
        )

        // Drop months folded by an older version of the fold. A missing month
        // narrows comparisons — which every rule already tolerates through its
        // history floor — whereas a stale month would silently mis-compare.
        let loadedSchemaVersion = snapshot.schemaVersion
        let hadStaleMonths = snapshot.months.contains {
            $0.value.schemaVersion != RecapFacts.currentSchemaVersion
        }
        snapshot.months = snapshot.months.filter {
            $0.value.schemaVersion == RecapFacts.currentSchemaVersion
        }
        if loadedSchemaVersion != RecapFacts.currentSchemaVersion || hadStaleMonths {
            snapshot.completeThroughKey = nil
        }
        snapshot.schemaVersion = RecapFacts.currentSchemaVersion
    }

    // MARK: - Reads

    public func facts(for window: RecapWindow) -> RecapFacts? {
        snapshot.months[window.key]
    }

    /// All stored months, newest first.
    public func allFacts() -> [RecapFacts] {
        snapshot.months.values.sorted { $0.window > $1.window }
    }

    /// Every month we hold before `window`, newest first.
    ///
    /// Deliberately uncapped (Codex P1). `RecapContext` derives all-time records
    /// and lifetime totals from exactly what it is handed, so truncating here turns
    /// "your biggest month yet" into "your biggest month out of the last N" while
    /// the deck goes on saying the former. How far back a *backfill* reaches is a
    /// separate, fetch-cost decision owned by the caller that pays for the scan.
    public func history(before window: RecapWindow) -> [RecapFacts] {
        allFacts().filter { $0.window < window }
    }

    /// Whether a source has authoritatively scanned all of its history through
    /// `window`. Stored months alone cannot prove this: a fresh install may
    /// have only the bounded backfill while older usage still exists.
    public func hasCompleteHistory(through window: RecapWindow) -> Bool {
        guard let key = snapshot.completeThroughKey,
              let completeThrough = RecapWindow(key: key) else { return false }
        return completeThrough >= window
    }

    /// How long a partially-read month is left alone before a backfill retries it.
    ///
    /// A partial month must stay eligible — `RecapContext` drops partial months from
    /// every comparison, so calling one done strands it outside records and trends
    /// forever, even once the connection that truncated it is back. But it cannot be
    /// eligible on *every* open: `isPartial` does not record *why*, and a month
    /// truncated by the mobile paging budget (24 pages x 300 rows) is
    /// deterministically partial on every retry. Re-paginating it each time costs
    /// thousands of billed reads to reach the same answer.
    ///
    /// A day is the compromise: a recovered connection repairs the month by the next
    /// day, and a permanently-truncated one costs one re-read a day, not one per open.
    public static let partialRetryInterval: TimeInterval = 24 * 60 * 60

    /// Months in the requested span that are missing, stale, or due a retry after
    /// being only partially read — oldest first, exactly what a backfill fetches.
    public func monthsNeedingBackfill(
        endingAt window: RecapWindow,
        monthsBack: Int,
        now: Date = Date()
    ) -> [RecapWindow] {
        guard monthsBack > 0 else { return [] }
        return window.priorMonths(monthsBack)
            .filter { month in
                guard let stored = snapshot.months[month.key] else { return true }
                guard stored.isPartial else { return false }
                return now.timeIntervalSince(stored.builtAt) >= Self.partialRetryInterval
            }
            .sorted()
    }

    // MARK: - Writes

    public func upsert(_ facts: RecapFacts) throws {
        try upsert([facts])
    }

    /// A partial read must never overwrite a full one; that is how one
    /// truncated month would poison every later comparison.
    public func upsert(_ batch: [RecapFacts]) throws {
        for facts in batch {
            if let existing = snapshot.months[facts.window.key],
               !existing.isPartial, facts.isPartial {
                continue
            }
            snapshot.months[facts.window.key] = facts
        }
        try persist()
    }

    /// Replaces the authoritative portion of history after a complete source
    /// scan. Removing absent months matters: deleted local usage must not linger
    /// in lifetime totals simply because an older snapshot once contained it.
    public func replaceCompleteHistory(
        with batch: [RecapFacts],
        through window: RecapWindow
    ) throws {
        snapshot.months = snapshot.months.filter { key, _ in
            guard let storedWindow = RecapWindow(key: key) else { return false }
            return storedWindow > window
        }
        for facts in batch where facts.window <= window {
            snapshot.months[facts.window.key] = facts
        }

        if let key = snapshot.completeThroughKey,
           let existing = RecapWindow(key: key),
           existing > window {
            snapshot.completeThroughKey = existing.key
        } else {
            snapshot.completeThroughKey = window.key
        }
        try persist()
    }

    private func persist() throws {
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }
}
