import Foundation

/// The rows one calendar month's recap is folded from.
///
/// Reuses `InsightUsageRow` / `InsightSessionRow` rather than inventing parallel
/// projections — they already carry exactly the dimensions the recap needs.
public struct RecapRowBatch: Sendable {

    public let window: RecapWindow
    public let usages: [InsightUsageRow]
    public let sessions: [InsightSessionRow]

    /// True when the source could not read the whole month (for example a
    /// paging budget ran out before the cursor did).
    ///
    /// A partial month may still be summarised, but it must never claim a
    /// total, a record, or a "most ever" — see `RecapCandidateGenerator`.
    public let isPartial: Bool

    /// Whether this source can supply conversation-level rows *at all*.
    ///
    /// Distinct from `sessions.isEmpty`: a month with genuinely no sessions and
    /// a platform that simply cannot see sessions are different facts, and
    /// conflating them would let the recap claim "you used no tools" when the
    /// truth is "we cannot see your tools from here."
    public let hasSessionData: Bool

    /// Share of cost carried by rows whose provenance is exact or
    /// derived-exact, 0…1. Damps confidence on months built from estimates.
    public let exactShare: Double

    public init(
        window: RecapWindow,
        usages: [InsightUsageRow],
        sessions: [InsightSessionRow] = [],
        isPartial: Bool = false,
        hasSessionData: Bool = false,
        exactShare: Double = 1
    ) {
        self.window = window
        self.usages = usages
        self.sessions = sessions
        self.isPartial = isPartial
        self.hasSessionData = hasSessionData
        self.exactShare = min(max(exactShare, 0), 1)
    }

    public var isEmpty: Bool { usages.isEmpty }

    /// An honest empty batch — no data, and not pretending the month was quiet.
    public static func empty(_ window: RecapWindow, hasSessionData: Bool = false) -> RecapRowBatch {
        RecapRowBatch(window: window, usages: [], sessions: [], hasSessionData: hasSessionData)
    }
}

// MARK: - Source

/// Supplies month-scoped rows to the recap engine.
///
/// Deliberately separate from `InsightDataSource`, whose two shipped
/// implementations are both unfit here: the macOS one filters the bounded warm
/// in-memory cache rather than the database (so history silently truncates),
/// and the mobile one derives rows from *rolling* rollups keyed by window
/// duration (so every calendar month collides on `.thirtyDays`). Retrofitting
/// either would change behaviour for the existing Insights verdict surface;
/// a purpose-built source keeps the blast radius at zero.
public protocol RecapSource: Sendable {

    /// Rows for a single month.
    func rows(for window: RecapWindow) async throws -> RecapRowBatch

    /// Rows for several months at once.
    ///
    /// The default implementation loops. Sources backed by a local database
    /// should override it with **one covering scan** over the whole span,
    /// bucketed by month — a per-month loop over an unindexed table is N full
    /// scans, and history backfill asks for twelve of them at once.
    func rows(for windows: [RecapWindow]) async throws -> [RecapWindow: RecapRowBatch]
}

public extension RecapSource {
    func rows(for windows: [RecapWindow]) async throws -> [RecapWindow: RecapRowBatch] {
        var result: [RecapWindow: RecapRowBatch] = [:]
        for window in windows {
            try Task.checkCancellation()
            result[window] = try await rows(for: window)
        }
        return result
    }
}
