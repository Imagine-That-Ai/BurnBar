import Foundation
import OpenBurnBarInsights
import OpenBurnBarKernel

/// Everything a rule is allowed to look at: the month in question, and whatever
/// history the device has accumulated.
///
/// Rules never reach past this. That is what makes each one independently
/// testable and what makes the "data floor" discipline enforceable — a rule
/// asks the context how much history exists and declines to fire when the
/// answer is "not enough".
public struct RecapContext: Sendable {

    /// The month being recapped.
    public let facts: RecapFacts
    /// Prior months, newest first. May be sparse — a device that was offline
    /// for a month simply has a gap, and every rule tolerates that.
    public let history: [RecapFacts]
    public let calendar: Calendar

    public init(facts: RecapFacts, history: [RecapFacts], calendar: Calendar = .current) {
        self.facts = facts
        self.history = history
            .filter { $0.window < facts.window }
            .sorted { $0.window > $1.window }
        self.calendar = calendar
    }

    public var window: RecapWindow { facts.window }

    /// History with partial months removed.
    ///
    /// A month the source could only half-read would understate every total,
    /// which would then manufacture fake records and fake growth in the month
    /// being recapped. Comparisons use only months we actually saw in full.
    public var comparableHistory: [RecapFacts] {
        history.filter { !$0.isPartial }
    }

    /// The immediately preceding calendar month, when we have it in full.
    /// Nil for a gap — "vs last month" is then simply not said.
    public var previousMonth: RecapFacts? {
        let target = facts.window.previous
        return comparableHistory.first { $0.window == target }
    }

    public var monthsOfHistory: Int { comparableHistory.count }
    public var isFirstMonthEver: Bool { comparableHistory.isEmpty }

    /// Whether absolute claims — totals, records, "most ever" — are permitted.
    ///
    /// False for a partially-read month. This is the single guard that keeps a
    /// truncated read from being presented as a headline number.
    public var allowsAbsoluteClaims: Bool { !facts.isPartial }

    /// Whether conversation-derived claims (tools, task titles) are possible at
    /// all on this platform. Distinct from "there were no tools".
    public var allowsSessionClaims: Bool { facts.hasSessionData }

    // MARK: - History aggregates

    public func historyValues(_ metric: (RecapFacts) -> Double) -> [Double] {
        comparableHistory.map(metric)
    }

    /// Mean across history, or nil when there is none.
    public func average(_ metric: (RecapFacts) -> Double) -> Double? {
        let values = historyValues(metric)
        guard !values.isEmpty else { return nil }
        return RecapStatistics.mean(values)
    }

    /// Best (highest) prior value and the month it happened in.
    public func allTimeBest(_ metric: (RecapFacts) -> Double) -> (value: Double, window: RecapWindow)? {
        var best: (value: Double, window: RecapWindow)?
        for month in comparableHistory {
            let value = metric(month)
            if best == nil || value > best!.value {
                best = (value, month.window)
            }
        }
        return best
    }

    // MARK: - Identity across time

    public func hasSeenModel(_ key: String) -> Bool {
        comparableHistory.contains { $0.modelKeys.contains(key) }
    }

    public func hasSeenProject(_ key: String) -> Bool {
        comparableHistory.contains { $0.projectKeys.contains(key) }
    }

    public func hasSeenTool(_ name: String) -> Bool {
        comparableHistory.contains { $0.toolKeys.contains(name) }
    }

    /// Models used this month that have never appeared before.
    /// Empty on a first-ever month by design — everything being new is not news.
    public func newModels() -> [RecapShare] {
        guard !isFirstMonthEver else { return [] }
        return facts.models.filter { !hasSeenModel($0.key) }
    }

    public func newProjects() -> [RecapShare] {
        guard !isFirstMonthEver else { return [] }
        return facts.projects.filter { !hasSeenProject($0.key) }
    }

    public func newTools() -> [RecapCount] {
        guard !isFirstMonthEver, allowsSessionClaims else { return [] }
        return facts.tools.filter { !hasSeenTool($0.name) }
    }

    // MARK: - Share lookups

    /// A dimension entry's share in the previous month, for month-over-month
    /// movement. `dimension` picks the ranked list to look in.
    public func previousShare(
        key: String,
        in dimension: (RecapFacts) -> [RecapShare]
    ) -> RecapShare? {
        previousMonth.flatMap { month in dimension(month).first { $0.key == key } }
    }

    // MARK: - Confidence

    /// Confidence for a claim resting on `n` observations.
    public func confidence(sampleSize n: Int, full: Int = 40) -> Double {
        RecapStatistics.clamp(
            (RecapStatistics.clamp(facts.exactShare) * 0.5)
            + (RecapStatistics.sampleConfidence(n, full: full) * 0.5)
        )
    }

    /// Novelty for a claim about `key` that may or may not be a repeat of what
    /// the user already knows.
    ///
    /// Something true every month is not news however large it is; the first
    /// time it is true is the interesting month. This is the mechanism behind
    /// "prefer insights that tell the user something they didn't already know".
    public func novelty(repeatedInPriorMonths repeats: Int) -> Double {
        guard monthsOfHistory > 0 else { return 0.55 }
        let repetition = Double(repeats) / Double(monthsOfHistory)
        return RecapStatistics.clamp(1 - repetition)
    }

    /// How many prior months had `key` at the top of `dimension` — the input to
    /// `novelty(repeatedInPriorMonths:)` for "favourite X" claims.
    public func monthsWhereTop(
        key: String,
        in dimension: (RecapFacts) -> [RecapShare]
    ) -> Int {
        comparableHistory.filter { dimension($0).first?.key == key }.count
    }
}
