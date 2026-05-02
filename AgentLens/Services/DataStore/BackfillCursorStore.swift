import Foundation
import GRDB
import OpenBurnBarCore

// MARK: - Backfill Cursor Record

/// A database record representing historical backfill cursor state.
/// Used for tracking backfill progress and enabling monotonic progression
/// across scheduled historical backfill runs.
///
/// VAL-PERSIST-007: Backfill cursor progresses monotonically.
/// Across repeated runs, backfill cursor/window must advance monotonically
/// and cover history without regressions or overlaps that cause duplication.
struct BackfillCursorRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "backfill_cursors"

    /// The provider this cursor tracks.
    let provider: String

    /// The upper bound of the last processed 7-day window (exclusive).
    /// Processing proceeds from earliest available data up to this cursor.
    /// A null value means no backfill has been performed yet.
    var lastProcessedWindowUpperBound: Date?

    /// The earliest date that exists in the source data for this provider.
    /// Used to determine the starting point of backfill.
    var earliestSourceDate: Date?

    /// The timestamp when this cursor was last updated.
    var updatedAt: Date

    /// Version number for optimistic concurrency control.
    var version: Int

    enum CodingKeys: String, CodingKey {
        case provider
        case lastProcessedWindowUpperBound
        case earliestSourceDate
        case updatedAt
        case version
    }
}

// MARK: - Backfill Cursor Store

/// Stores historical backfill cursor/high-watermark state for safe monotonic
/// progression across scheduled backfill runs.
///
/// Backfill cursor advancement semantics:
/// - Cursor advances ONLY after successful backfill batch commit (VAL-PERSIST-004 analog)
/// - Cursor progresses monotonically - never moves backward (VAL-PERSIST-007)
/// - 7-day windows are strictly bounded - each run processes at most 7 days (VAL-PERSIST-006)
final class BackfillCursorStore: Sendable {
    private let dbQueue: any DatabaseWriter

    /// The maximum duration of a single backfill window in seconds (7 days).
    static let backfillWindowSeconds: TimeInterval = 7 * 24 * 60 * 60

    /// Storage precision for datetime values: milliseconds.
    /// SQLite/GRDB stores datetime as TEXT in ISO8601-like format with millisecond precision
    /// (yyyy-MM-dd HH:mm:ss.SSS). When a Date is stored and retrieved, it may be
    /// truncated/rounded to this precision. This constant defines the normalization
    /// granularity used to ensure equal timestamps survive persistence round-trips.
    static let storagePrecisionSeconds: TimeInterval = 0.001

    init(dbQueue: any DatabaseWriter) {
        self.dbQueue = dbQueue
    }

    // MARK: - Storage Precision Normalization

    /// Normalizes a Date to storage precision (milliseconds) for comparison purposes.
    ///
    /// When a Date is stored in SQLite/GRDB and retrieved, it may be rounded/truncated
    /// to millisecond precision. Normalizing both dates before comparison ensures that
    /// equal logical timestamps survive persistence round-trips without epsilon tolerance.
    ///
    /// - Parameter date: The date to normalize.
    /// - Returns: A Date normalized to millisecond precision.
    static func normalizeToStoragePrecision(_ date: Date) -> Date {
        let timeInterval = date.timeIntervalSince1970
        let normalized = (timeInterval / Self.storagePrecisionSeconds).rounded()
            * Self.storagePrecisionSeconds
        return Date(timeIntervalSince1970: normalized)
    }

    // MARK: - Read

    /// Fetches the current backfill cursor for a provider.
    func fetchCursor(for provider: AgentProvider) throws -> BackfillCursorRecord? {
        try dbQueue.read { db in
            try BackfillCursorRecord.fetchOne(db, sql: """
                SELECT * FROM backfill_cursors WHERE provider = ?
                """, arguments: [provider.rawValue])
        }
    }

    /// Fetches all backfill cursors for all providers.
    func fetchAllCursors() throws -> [BackfillCursorRecord] {
        try dbQueue.read { db in
            try BackfillCursorRecord.fetchAll(db, sql: "SELECT * FROM backfill_cursors")
        }
    }

    // MARK: - Write

    /// Advances the backfill cursor for a provider after successful 7-day window commit.
    /// This MUST be called only after the backfill batch has been committed.
    ///
    /// VAL-PERSIST-006: Backfill run is bounded to 7-day window.
    /// VAL-PERSIST-007: Backfill cursor progresses monotonically.
    ///
    /// - Parameters:
    ///   - provider: The provider whose cursor to advance.
    ///   - newUpperBound: The new upper bound (exclusive) after processing a 7-day window.
    ///   - earliestSourceDate: The earliest source date if discovered during backfill.
    ///
    /// - Note: newUpperBound must be greater than or equal to the current cursor value.
    ///   Equal timestamp advances are accepted as idempotent (handled by upsert semantics).
    ///   Any backward movement is strictly rejected regardless of magnitude.
    func advanceCursor(
        for provider: AgentProvider,
        newUpperBound: Date,
        earliestSourceDate: Date? = nil
    ) throws {
        try dbQueue.write { db in
            let now = Date()

            // Fetch current cursor to validate monotonicity
            let current = try BackfillCursorRecord.fetchOne(db, sql: """
                SELECT * FROM backfill_cursors WHERE provider = ?
                """, arguments: [provider.rawValue])

            // VAL-PERSIST-007: Enforce strict monotonic progression at normalized precision.
            // Equal timestamp advances are accepted as idempotent (upsert version bump handles retries).
            // Any backward movement is strictly rejected at normalized precision.
            //
            // Storage-precision normalization: SQLite/GRDB stores datetime with millisecond precision.
            // When the same timestamp is stored and retrieved, floating-point arithmetic and precision
            // conversions can produce tiny differences. Normalizing both dates to storage precision
            // before comparison bridges this gap without needing epsilon tolerance.
            // Forward movement (diff > 0) and equal timestamps (diff == 0) pass.
            // Any true backward movement (diff < 0) is rejected.
            if let current = current, let currentBound = current.lastProcessedWindowUpperBound {
                let normalizedCurrent = Self.normalizeToStoragePrecision(currentBound)
                let normalizedNew = Self.normalizeToStoragePrecision(newUpperBound)
                let diff = normalizedNew.timeIntervalSince(normalizedCurrent)
                guard diff >= 0 else {
                    throw BackfillCursorError.nonMonotonicAdvance(
                        provider: provider,
                        currentBound: currentBound,
                        attemptedBound: newUpperBound
                    )
                }
            }

            // Calculate the window duration to enforce 7-day bound
            let windowDuration = current?.lastProcessedWindowUpperBound.map {
                newUpperBound.timeIntervalSince($0)
            } ?? newUpperBound.timeIntervalSince(earliestSourceDate ?? newUpperBound)

            // VAL-PERSIST-006: Enforce 7-day window bound with tolerance for floating-point precision
            let windowEpsilon: TimeInterval = 0.001 // 1 millisecond tolerance
            guard windowDuration <= Self.backfillWindowSeconds + windowEpsilon || current == nil else {
                throw BackfillCursorError.windowExceedsBound(
                    provider: provider,
                    windowDuration: windowDuration,
                    maxAllowed: Self.backfillWindowSeconds
                )
            }

            // Update or insert the cursor
            try db.execute(sql: """
                INSERT INTO backfill_cursors (provider, lastProcessedWindowUpperBound, earliestSourceDate, updatedAt, version)
                VALUES (?, ?, ?, ?, 1)
                ON CONFLICT(provider) DO UPDATE SET
                    lastProcessedWindowUpperBound = excluded.lastProcessedWindowUpperBound,
                    earliestSourceDate = COALESCE(excluded.earliestSourceDate, backfill_cursors.earliestSourceDate),
                    updatedAt = excluded.updatedAt,
                    version = version + 1
                """, arguments: [
                    provider.rawValue,
                    newUpperBound,
                    earliestSourceDate,
                    now
                ])
        }
    }

    /// Resets the backfill cursor for a provider, forcing a full backfill on next run.
    /// Used when cache corruption or data loss is detected.
    func resetCursor(for provider: AgentProvider) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                DELETE FROM backfill_cursors WHERE provider = ?
                """, arguments: [provider.rawValue])
        }
    }

    /// Resets all backfill cursors (e.g., for a full reset).
    func resetAllCursors() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM backfill_cursors")
        }
    }

    /// Computes the next backfill window for a provider.
    /// Returns a half-open interval [start, end) representing the next window to process.
    ///
    /// - Returns: A closed range from the cursor position to 7 days later,
    ///   or nil if backfill is complete (cursor has reached or passed current date).
    func nextBackfillWindow(for provider: AgentProvider, currentDate: Date = Date()) throws -> ClosedRange<Date>? {
        let cursor = try fetchCursor(for: provider)

        // If no cursor exists, backfill has never run - start from earliest source date or 7 days ago
        let windowStart: Date
        if let cursorBound = cursor?.lastProcessedWindowUpperBound {
            windowStart = cursorBound
        } else if let earliest = cursor?.earliestSourceDate {
            windowStart = earliest
        } else {
            // Default: start 7 days before current date for initial backfill
            windowStart = currentDate.addingTimeInterval(-Self.backfillWindowSeconds)
        }

        let windowEnd = windowStart.addingTimeInterval(Self.backfillWindowSeconds)

        // If window start is at or after current date, backfill is complete
        guard windowStart < currentDate else {
            return nil
        }

        // Clamp the window end to current date if it would exceed it
        let clampedEnd = min(windowEnd, currentDate)

        return windowStart...clampedEnd
    }
}

// MARK: - Backfill Cursor Errors

enum BackfillCursorError: Error, CustomStringConvertible {
    case nonMonotonicAdvance(provider: AgentProvider, currentBound: Date, attemptedBound: Date)
    case windowExceedsBound(provider: AgentProvider, windowDuration: TimeInterval, maxAllowed: TimeInterval)

    var description: String {
        switch self {
        case .nonMonotonicAdvance(let provider, let currentBound, let attemptedBound):
            return "Backfill cursor for \(provider.rawValue) cannot advance backward: current=\(currentBound), attempted=\(attemptedBound)"
        case .windowExceedsBound(let provider, let windowDuration, let maxAllowed):
            return "Backfill window for \(provider.rawValue) exceeds 7-day bound: duration=\(windowDuration)s, max=\(maxAllowed)s"
        }
    }
}
