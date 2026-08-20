import Foundation
import OpenBurnBarInsights
import OpenBurnBarKernel

/// Per-month `RecapFacts`, persisted so comparisons are cheap.
///
/// This is what makes month-over-month and all-time claims affordable: comparing
/// August to a year of history is comparing thirteen small structs, not
/// re-reading a year of raw usage rows on every open.
public actor RecapHistoryStore {

    public struct Snapshot: Codable, Sendable {
        public var schemaVersion: Int
        public var months: [String: RecapFacts]

        public init(schemaVersion: Int = RecapFacts.currentSchemaVersion, months: [String: RecapFacts] = [:]) {
            self.schemaVersion = schemaVersion
            self.months = months
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
        snapshot.months = snapshot.months.filter {
            $0.value.schemaVersion == RecapFacts.currentSchemaVersion
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

    /// The `limit` months immediately before `window` that we hold.
    public func history(before window: RecapWindow, limit: Int = 12) -> [RecapFacts] {
        Array(
            allFacts()
                .filter { $0.window < window }
                .prefix(limit)
        )
    }

    /// Months in the requested span that are missing or stale, oldest first —
    /// exactly the set a backfill needs to fetch.
    public func monthsNeedingBackfill(
        endingAt window: RecapWindow,
        monthsBack: Int
    ) -> [RecapWindow] {
        guard monthsBack > 0 else { return [] }
        return window.priorMonths(monthsBack)
            .filter { snapshot.months[$0.key] == nil }
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

    private func persist() throws {
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }
}
