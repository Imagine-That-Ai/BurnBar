import Foundation
import OpenBurnBarCore

// MARK: - Calendar Month Snapshot
//
// Everything the month grid needs to draw: per-day cost (drives the heatmap
// fill) and the day's top providers (drives the dots). Days are keyed by
// local start-of-day — sessions spanning midnight are attributed to the day
// their `startTime` lands in, never split and never UTC-truncated.

struct CalendarMonthSnapshot: Equatable, Sendable {

    /// The grid model this snapshot was built for (defines the fetch window).
    let monthStart: Date
    let gridRange: ClosedRange<Date>

    /// Total cost per local day. Only days with usage appear; cells treat a
    /// missing key as zero.
    let dayCosts: [Date: Double]

    /// Up to three providers per day, ranked by that day's cost.
    let dayProviders: [Date: [AgentProvider]]

    /// The month's busiest day cost — the denominator for heatmap intensity.
    let peakDayCost: Double

    /// Spend on days inside the calendar month itself (grid overflow days
    /// from neighboring months excluded), for the header subtitle.
    let monthTotalCost: Double

    /// The usages version the snapshot was built from.
    let usagesVersion: Int

    /// Pure builder — runs off the main actor via the service.
    static func build(
        rows: [TokenUsage],
        model: CalendarMonthGridModel,
        calendar: Calendar,
        usagesVersion: Int
    ) -> CalendarMonthSnapshot {
        var dayCosts: [Date: Double] = [:]
        var providerCosts: [Date: [AgentProvider: Double]] = [:]
        for row in rows {
            let day = calendar.startOfDay(for: row.startTime)
            guard model.gridRange.contains(day) else { continue }
            dayCosts[day, default: 0] += row.cost
            providerCosts[day, default: [:]][row.provider, default: 0] += row.cost
        }

        var dayProviders: [Date: [AgentProvider]] = [:]
        for (day, costs) in providerCosts {
            dayProviders[day] = costs
                .sorted { lhs, rhs in
                    lhs.value == rhs.value ? lhs.key.rawValue < rhs.key.rawValue : lhs.value > rhs.value
                }
                .prefix(3)
                .map(\.key)
        }

        let monthInterval = calendar.dateInterval(of: .month, for: model.monthStart)
        let monthTotal = dayCosts.reduce(0.0) { partial, entry in
            guard let monthInterval, monthInterval.contains(entry.key) else { return partial }
            return partial + entry.value
        }

        return CalendarMonthSnapshot(
            monthStart: model.monthStart,
            gridRange: model.gridRange,
            dayCosts: dayCosts,
            dayProviders: dayProviders,
            peakDayCost: dayCosts.values.max() ?? 0,
            monthTotalCost: monthTotal,
            usagesVersion: usagesVersion
        )
    }
}

// MARK: - Calendar Selection Snapshot
//
// Every analytics card's prepared data for the current day selection — the
// selection-driven twin of `ChartsSnapshot`. Built off the main actor; cards
// render with zero aggregation of their own.

struct CalendarSelectionSnapshot: Equatable, Sendable {

    struct ProviderShare: Equatable, Sendable {
        let provider: AgentProvider
        let cost: Double
    }

    struct ModelCost: Equatable, Sendable {
        /// Raw model key (feeds `ModelProviderLogoView`).
        let model: String
        /// Human label (`TokenExtractionUtility.displayNameForModel`).
        let displayName: String
        let cost: Double
    }

    struct ProjectCost: Equatable, Sendable {
        let name: String
        let cost: Double
    }

    /// Selected days, ascending, start-of-day normalized.
    let selectedDays: [Date]

    /// True when no usage rows land on any selected day.
    let isEmpty: Bool

    // MARK: KPI tiles

    let totalCost: Double
    let totalTokens: Int
    /// Distinct `sessionId` count across the selection (COUNT DISTINCT).
    let sessionCount: Int
    /// Selected days that carry at least one usage row.
    let activeDays: Int
    /// Total cost averaged over every selected day (silent days included).
    let averageCostPerDay: Double

    // MARK: burnOverSelection

    /// Per-day cost across the selection's span, gap-filled.
    let dailyBurn: [ChartBucketing.DateBucket]

    // MARK: providerMix / modelMix / projectFocus

    let providerShares: [ProviderShare]
    let topModels: [ModelCost]
    let projectShares: [ProjectCost]

    // MARK: hourOfDayHeatmap

    /// 7×24 cost matrix; row 0 = Sunday (Gregorian weekday order).
    let hourWeekdayCost: [[Double]]
    let peakWeekdayIndex: Int?
    let peakHour: Int?

    // MARK: cacheROI / reasoningShare

    let cacheHitRate: Double
    let cacheReadTokens: Int
    /// Same estimate as `ChartsSnapshot.cacheSavingsEstimate` — cache reads
    /// billed at ~10% of the blended per-token rate. Labeled "(est.)" in UI.
    let cacheSavingsEstimate: Double
    let reasoningShare: Double
    let reasoningTokens: Int

    /// Pure builder. `rows` = the loaded month rows (any superset of the
    /// selection window); only rows whose local start-of-day `startTime`
    /// falls on a selected day contribute.
    static func build(
        rows: [TokenUsage],
        selectedDays: Set<Date>,
        calendar: Calendar
    ) -> CalendarSelectionSnapshot {
        let sortedDays = selectedDays.sorted()
        let selected = rows.filter { selectedDays.contains(calendar.startOfDay(for: $0.startTime)) }

        let totalCost = selected.reduce(0) { $0 + $1.cost }
        let totalTokens = selected.reduce(0) { $0 + $1.totalTokens }
        let sessionCount = Set(selected.map(\.sessionId)).count
        let activeDays = Set(selected.map { calendar.startOfDay(for: $0.startTime) }).count

        // Per-day burn across the selection's span — gap-filled so silent
        // days draw as zero bars instead of collapsing.
        let dailyBurn: [ChartBucketing.DateBucket]
        if let first = sortedDays.first, let last = sortedDays.last,
           let dayAfter = calendar.date(byAdding: .day, value: 1, to: last) {
            dailyBurn = ChartBucketing.dateBuckets(
                events: selected.map { (date: $0.startTime, value: $0.cost) },
                range: first...dayAfter,
                component: .day,
                calendar: calendar
            )
        } else {
            dailyBurn = []
        }

        let providerShares = UsageStore.makeProviderSummaries(from: selected)
            .map { ProviderShare(provider: $0.provider, cost: $0.totalCost) }
        let topModels = UsageStore.makeModelSummaries(from: selected)
            .prefix(6)
            .map { ModelCost(model: $0.modelName, displayName: $0.displayName, cost: $0.totalCost) }
        let projectShares = UsageStore.makeProjectSpendSummaries(from: selected)
            .prefix(5)
            .map { ProjectCost(name: $0.projectName, cost: $0.totalCost) }

        let matrix = ChartBucketing.hourWeekdayMatrix(
            events: selected.map { (date: $0.startTime, value: $0.cost) },
            calendar: calendar
        )
        var peak: (weekday: Int, hour: Int)?
        var peakValue = 0.0
        for (weekday, hours) in matrix.enumerated() {
            for (hour, value) in hours.enumerated() where value > peakValue {
                peakValue = value
                peak = (weekday, hour)
            }
        }

        let cacheRead = selected.reduce(0) { $0 + $1.cacheReadTokens }
        let promptBasis = selected.reduce(0) { $0 + $1.inputTokens + $1.cacheCreationTokens + $1.cacheReadTokens }
        let cacheHitRate = promptBasis > 0 ? Double(cacheRead) / Double(promptBasis) : 0
        let blendedRate = totalTokens > 0 ? totalCost / Double(totalTokens) : 0
        let cacheSavings = 0.9 * Double(cacheRead) * blendedRate
        let reasoningTokens = selected.reduce(0) { $0 + $1.reasoningTokens }
        let reasoningShare = totalTokens > 0 ? Double(reasoningTokens) / Double(totalTokens) : 0

        return CalendarSelectionSnapshot(
            selectedDays: sortedDays,
            isEmpty: selected.isEmpty,
            totalCost: totalCost,
            totalTokens: totalTokens,
            sessionCount: sessionCount,
            activeDays: activeDays,
            averageCostPerDay: totalCost / Double(max(sortedDays.count, 1)),
            dailyBurn: dailyBurn,
            providerShares: providerShares,
            topModels: topModels,
            projectShares: projectShares,
            hourWeekdayCost: matrix,
            peakWeekdayIndex: peak?.weekday,
            peakHour: peak?.hour,
            cacheHitRate: cacheHitRate,
            cacheReadTokens: cacheRead,
            cacheSavingsEstimate: cacheSavings,
            reasoningShare: reasoningShare,
            reasoningTokens: reasoningTokens
        )
    }
}

// MARK: - Calendar Data Service
//
// Owns the Calendar surface's snapshots. Follows the `ChartsDataService`
// playbook: rows are fetched on the main actor from the data store, heavy
// aggregation runs in a detached task, and invalidation keys on the store's
// `usagesVersion` rather than the usage array itself.
//
// The month is fetched once per (month, usagesVersion); selection changes
// re-aggregate the already-loaded month rows, so clicking around the grid
// never hits the database.

@MainActor
@Observable
final class CalendarDataService {

    private(set) var monthSnapshot: CalendarMonthSnapshot?
    private(set) var selectionSnapshot: CalendarSelectionSnapshot?
    private(set) var isBuilding = false

    /// Identity of the month currently requested or displayed.
    private var currentKey: MonthKey?
    private var monthRows: [TokenUsage] = []
    private var lastSelectedDays: Set<Date> = []
    private var monthTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?

    struct MonthKey: Equatable {
        let usagesVersion: Int
        let monthStart: Date
    }

    /// Reloads the visible month when the data version or month moved, then
    /// rebuilds the selection aggregation from the fresh rows. Safe to call
    /// redundantly — identical keys are no-ops, so callers can drive this
    /// straight from `.task(id:)`.
    func refresh(
        dataStore: DataStore,
        model: CalendarMonthGridModel,
        selectedDays: Set<Date>,
        calendar: Calendar = .current
    ) {
        lastSelectedDays = selectedDays
        let key = MonthKey(usagesVersion: dataStore.usagesVersion, monthStart: model.monthStart)
        guard key != currentKey else { return }
        currentKey = key

        monthTask?.cancel()
        selectionTask?.cancel()
        isBuilding = monthSnapshot == nil
        monthTask = Task { [weak self] in
            let rows = (try? await dataStore.fetchUsage(in: model.gridRange, limit: Int.max)) ?? []
            guard !Task.isCancelled else { return }
            let monthBuilt = await Self.buildMonthDetached(
                rows: rows, model: model, calendar: calendar, usagesVersion: key.usagesVersion
            )
            guard !Task.isCancelled else { return }
            let days = self?.lastSelectedDays ?? []
            let selectionBuilt = await Self.buildSelectionDetached(
                rows: rows, selectedDays: days, calendar: calendar
            )
            guard !Task.isCancelled else { return }
            guard let self, self.currentKey == key else { return }
            self.monthRows = rows
            self.monthSnapshot = monthBuilt
            self.selectionSnapshot = selectionBuilt
            self.isBuilding = false
        }
    }

    /// Rebuilds the selection aggregation from the already-loaded month rows.
    /// Cheap and database-free — safe to call on every click.
    func refreshSelection(selectedDays: Set<Date>, calendar: Calendar = .current) {
        guard selectedDays != lastSelectedDays else { return }
        lastSelectedDays = selectedDays
        let rows = monthRows
        selectionTask?.cancel()
        selectionTask = Task { [weak self] in
            let built = await Self.buildSelectionDetached(
                rows: rows, selectedDays: selectedDays, calendar: calendar
            )
            guard !Task.isCancelled else { return }
            guard let self, self.lastSelectedDays == selectedDays else { return }
            self.selectionSnapshot = built
        }
    }

    private nonisolated static func buildMonthDetached(
        rows: [TokenUsage],
        model: CalendarMonthGridModel,
        calendar: Calendar,
        usagesVersion: Int
    ) async -> CalendarMonthSnapshot {
        await Task.detached(priority: .userInitiated) {
            CalendarMonthSnapshot.build(
                rows: rows, model: model, calendar: calendar, usagesVersion: usagesVersion
            )
        }.value
    }

    private nonisolated static func buildSelectionDetached(
        rows: [TokenUsage],
        selectedDays: Set<Date>,
        calendar: Calendar
    ) async -> CalendarSelectionSnapshot {
        await Task.detached(priority: .userInitiated) {
            CalendarSelectionSnapshot.build(rows: rows, selectedDays: selectedDays, calendar: calendar)
        }.value
    }
}
