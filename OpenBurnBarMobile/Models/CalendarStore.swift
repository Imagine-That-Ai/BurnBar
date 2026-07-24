import Foundation
import OpenBurnBarCore
import FirebaseFirestore
import os.log

// MARK: - Calendar Month Snapshot
//
// Everything the month grid needs to draw: per-day cost (drives the heatmap
// fill) and the day's top providers (drives the dots). Days are keyed by
// local start-of-day — sessions spanning midnight are attributed to the day
// their `startTime` lands in, never split and never UTC-truncated.
//
// Why raw events and not rollup `dailyPoints`: the current Firestore rollup
// schema (v3 counters, `functions/src/rollupCompute.ts`) writes `dailyPoints`
// as per-day **token** counts keyed by UTC day — not per-day cost. Feeding
// those into a cost heatmap would silently mix units, so the month heat is
// bucketed from the same raw `TokenUsage` rows that drive the provider dots
// and the selection breakdowns. One fetch per visible month covers all three.

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

    /// Pure builder — runs synchronously off the loaded rows (≤ a few
    /// thousand rows; sub-millisecond aggregation).
    static func build(
        rows: [TokenUsage],
        model: CalendarMonthGridModel,
        calendar: Calendar
    ) -> CalendarMonthSnapshot {
        var dayCosts: [Date: Double] = [:]
        var providerCosts: [Date: [AgentProvider: Double]] = [:]
        for row in rows {
            let day = calendar.startOfDay(for: row.startTime)
            guard model.gridRange.contains(day) else { continue }
            dayCosts[day, default: 0] += row.costUSD
            providerCosts[day, default: [:]][row.provider, default: 0] += row.costUSD
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
            monthTotalCost: monthTotal
        )
    }
}

// MARK: - Calendar Selection Snapshot
//
// Every analytics card's prepared data for the current day selection. Built
// synchronously from the loaded month rows; cards render with zero
// aggregation of their own. Mirrors the macOS `CalendarSelectionSnapshot`
// field-for-field so the two surfaces tell the same story.

struct CalendarSelectionSnapshot: Equatable, Sendable {

    struct ProviderShare: Equatable, Sendable {
        let provider: AgentProvider
        let cost: Double
    }

    struct ModelCost: Equatable, Sendable {
        /// Raw model key.
        let model: String
        /// Human label (`FriendlyModelName`).
        let displayName: String
        /// The provider that accounted for the most cost on this model —
        /// drives the row's brand logo (real data, no string inference).
        let provider: AgentProvider
        let cost: Double
    }

    struct ProjectCost: Equatable, Sendable {
        let name: String
        let cost: Double
    }

    struct DayCost: Equatable, Sendable, Identifiable {
        let day: Date
        let cost: Double
        var id: Date { day }
    }

    /// Selected days, ascending, start-of-day normalized.
    let selectedDays: [Date]

    /// True when no usage rows land on any selected day.
    let isEmpty: Bool

    // MARK: KPI tiles

    let totalCost: Double
    let totalTokens: Int
    /// Distinct `sessionId` count across the selection.
    let sessionCount: Int
    /// Selected days that carry at least one usage row.
    let activeDays: Int
    /// Total cost averaged over every selected day (silent days included).
    let averageCostPerDay: Double

    // MARK: burnOverSelection

    /// Per-day cost across the selection's span, gap-filled so silent days
    /// draw as zero bars instead of collapsing.
    let dailyBurn: [DayCost]

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
    /// Cache reads billed at ~10% of the blended per-token rate — the same
    /// estimate the macOS card shows. Labeled "(est.)" in UI.
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
        let sortedDays = selectedDays.map { calendar.startOfDay(for: $0) }.sorted()
        let daySet = Set(sortedDays)
        let selected = rows.filter { daySet.contains(calendar.startOfDay(for: $0.startTime)) }

        let totalCost = selected.reduce(0) { $0 + $1.costUSD }
        let totalTokens = selected.reduce(0) { $0 + $1.totalTokens }
        let sessionCount = Set(selected.map(\.sessionId)).count
        let activeDays = Set(selected.map { calendar.startOfDay(for: $0.startTime) }).count

        // Per-day burn across the selection's span — gap-filled.
        var dailyBurn: [DayCost] = []
        if let first = sortedDays.first, let last = sortedDays.last {
            var costs: [Date: Double] = [:]
            for row in selected {
                costs[calendar.startOfDay(for: row.startTime), default: 0] += row.costUSD
            }
            var cursor = first
            var steps = 0
            while cursor <= last, steps < 372 {
                dailyBurn.append(DayCost(day: cursor, cost: costs[cursor] ?? 0))
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = calendar.startOfDay(for: next)
                steps += 1
            }
        }

        // Provider mix.
        var providerCosts: [AgentProvider: Double] = [:]
        for row in selected {
            providerCosts[row.provider, default: 0] += row.costUSD
        }
        // Each stage is a separately-annotated statement. Chained
        // map/sorted/prefix with ternaries inside the comparator pushes this
        // function past the Swift type-checker's budget.
        let providerRows: [ProviderShare] = providerCosts.map { entry in
            ProviderShare(provider: entry.key, cost: entry.value)
        }
        let providerShares: [ProviderShare] = providerRows.sorted { lhs, rhs in
            if lhs.cost == rhs.cost { return lhs.provider.rawValue < rhs.provider.rawValue }
            return lhs.cost > rhs.cost
        }

        // Model mix (top 6) with the dominant provider per model for logos.
        // Group on the normalized key so Cursor's `custom:` / `vibeproxy:`
        // prefixes and casing variants collapse into one row, exactly as
        // UsageStore.makeModelSummaries does on macOS.
        var modelCosts: [String: Double] = [:]
        var modelProviderCosts: [String: [AgentProvider: Double]] = [:]
        for row in selected {
            // Bound to a typed local first: the nested `default:` subscripts
            // otherwise push this past the type-checker's budget.
            let key: String = OpenBurnBarCore.TokenExtractionUtility.normalizeModelKey(row.model)
            let cost: Double = row.costUSD
            modelCosts[key, default: 0] += cost
            var perProvider: [AgentProvider: Double] = modelProviderCosts[key] ?? [:]
            perProvider[row.provider, default: 0] += cost
            modelProviderCosts[key] = perProvider
        }
        var modelRows: [ModelCost] = []
        modelRows.reserveCapacity(modelCosts.count)
        for (model, cost) in modelCosts {
            let perProvider: [AgentProvider: Double] = modelProviderCosts[model] ?? [:]
            let rankedProviders: [AgentProvider] = perProvider
                .sorted { lhs, rhs in
                    if lhs.value == rhs.value { return lhs.key.rawValue < rhs.key.rawValue }
                    return lhs.value > rhs.value
                }
                .map { entry in entry.key }
            let dominant: AgentProvider = rankedProviders.first ?? .openBurnBar
            modelRows.append(
                ModelCost(
                    model: model,
                    displayName: FriendlyModelName.format(model),
                    provider: dominant,
                    cost: cost
                )
            )
        }
        let sortedModels: [ModelCost] = modelRows.sorted { lhs, rhs in
            if lhs.cost == rhs.cost { return lhs.model < rhs.model }
            return lhs.cost > rhs.cost
        }
        let topModels: [ModelCost] = Array(sortedModels.prefix(6))

        // Project focus (top 5). Unnamed rows bucket as "Unattributed" rather
        // than vanishing — that bucket is often the largest, so dropping it
        // would silently understate the card (UsageStore+Summaries.swift:256).
        var projectCosts: [String: Double] = [:]
        for row in selected {
            let key = row.projectName.isEmpty ? "Unattributed" : row.projectName
            projectCosts[key, default: 0] += row.costUSD
        }
        let projectRows: [ProjectCost] = projectCosts.map { entry in
            ProjectCost(name: entry.key, cost: entry.value)
        }
        let sortedProjects: [ProjectCost] = projectRows.sorted { lhs, rhs in
            if lhs.cost == rhs.cost { return lhs.name < rhs.name }
            return lhs.cost > rhs.cost
        }
        let projectShares: [ProjectCost] = Array(sortedProjects.prefix(5))

        // Hour × weekday matrix (row 0 = Sunday).
        var matrix = [[Double]](repeating: [Double](repeating: 0, count: 24), count: 7)
        for row in selected {
            let comps = calendar.dateComponents([.weekday, .hour], from: row.startTime)
            guard let weekday = comps.weekday, let hour = comps.hour,
                  (1...7).contains(weekday), (0..<24).contains(hour) else { continue }
            matrix[weekday - 1][hour] += row.costUSD
        }
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

// MARK: - Calendar Store
//
// Owns the Calendar surface's data. Follows the hoisted-store precedent
// (`DashboardStore`): the tab root owns the instance, `CalendarView` drives
// loads from `.task(id:)` and selection changes from `.onChange`.
//
// Fetch strategy: one raw-event read per visible month (see the note on
// `CalendarMonthSnapshot` for why rollups can't back a cost heatmap). The
// current month uses the prescribed `fetchUsageSince` live read, with a
// truncation guard that falls back to a bounded paged read when the
// 2,000-document cap can't reach the grid start. Past months go straight to
// the bounded paged read — fetching "everything since" an old month would
// pull months of unrelated events. Selection changes never hit the network:
// they re-aggregate the loaded month rows.

@Observable
@MainActor
final class CalendarStore {
    private static let log = Logger(subsystem: "com.openburnbar.app", category: "CalendarStore")

    private let firestore: FirestoreRepository

    private(set) var monthSnapshot: CalendarMonthSnapshot?
    private(set) var selectionSnapshot: CalendarSelectionSnapshot?
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var hasLoadedOnce = false

    /// Rows backing the current snapshots (the visible month's grid window).
    private var monthRows: [TokenUsage] = []
    /// The month currently displayed, start-of-day. Guards redundant loads.
    private var loadedMonthStart: Date?
    /// Small per-month row cache so ‹ › navigation doesn't refetch months
    /// already visited this session. The month containing `now` is never
    /// served from cache — it must stay live.
    private var rowsByMonth: [Date: [TokenUsage]] = [:]

    init(firestore: FirestoreRepository = FirestoreRepository()) {
        self.firestore = firestore
    }

    /// Loads the visible month's rows and rebuilds both snapshots. Safe to
    /// call redundantly — revisiting the already-loaded month is a no-op.
    func load(
        gridModel: CalendarMonthGridModel,
        selectedDays: Set<Date>,
        calendar: Calendar = .current
    ) async {
        guard gridModel.monthStart != loadedMonthStart else { return }

        if AppStoreScreenshotMode.isEnabled {
            monthRows = AppStoreScreenshotData.recentUsage
            apply(rows: monthRows, model: gridModel, selectedDays: selectedDays, calendar: calendar)
            loadedMonthStart = gridModel.monthStart
            error = nil
            hasLoadedOnce = true
            return
        }

        // Past months visited this session are stable — reuse their rows.
        let isCurrentMonth = gridModel.gridRange.upperBound >= Date()
        if !isCurrentMonth, let cached = rowsByMonth[gridModel.monthStart] {
            monthRows = cached
            apply(rows: cached, model: gridModel, selectedDays: selectedDays, calendar: calendar)
            loadedMonthStart = gridModel.monthStart
            error = nil
            hasLoadedOnce = true
            return
        }

        isLoading = monthSnapshot == nil
        error = nil
        defer { isLoading = false }
        do {
            let rows = try await fetchMonthRows(gridModel: gridModel)
            guard !Task.isCancelled else { return }
            monthRows = rows
            rowsByMonth[gridModel.monthStart] = rows
            apply(rows: rows, model: gridModel, selectedDays: selectedDays, calendar: calendar)
            loadedMonthStart = gridModel.monthStart
            hasLoadedOnce = true
        } catch {
            guard !Task.isCancelled else { return }
            Self.log.error("Calendar month load failed: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    /// Rebuilds the selection aggregation from the already-loaded month
    /// rows. Cheap and network-free — safe to call on every tap/drag frame.
    func refreshSelection(selectedDays: Set<Date>, calendar: Calendar = .current) {
        selectionSnapshot = CalendarSelectionSnapshot.build(
            rows: monthRows,
            selectedDays: selectedDays,
            calendar: calendar
        )
    }

    /// Recomputes both snapshots from a row set. Internal so tests can drive
    /// the store with fixture events (no Firestore).
    func apply(
        rows: [TokenUsage],
        model: CalendarMonthGridModel,
        selectedDays: Set<Date>,
        calendar: Calendar
    ) {
        // Retain the rows: `refreshSelection` re-aggregates from `monthRows`,
        // so applying a row set without storing it left every later selection
        // change reading an empty array. The production callers already assign
        // `monthRows` before calling in, so this is idempotent for them.
        monthRows = rows
        monthSnapshot = CalendarMonthSnapshot.build(rows: rows, model: model, calendar: calendar)
        selectionSnapshot = CalendarSelectionSnapshot.build(rows: rows, selectedDays: selectedDays, calendar: calendar)
    }

    // MARK: - Fetching

    private func fetchMonthRows(gridModel: CalendarMonthGridModel) async throws -> [TokenUsage] {
        let now = Date()
        guard gridModel.gridRange.upperBound >= now else {
            // Past month — bounded paged read of exactly the grid window.
            return try await fetchUsageWindow(
                start: gridModel.gridRange.lowerBound,
                end: gridModel.gridRange.upperBound
            )
        }
        // Current month — the live-usage read shared with Pulse. When the
        // document cap truncates the window before the grid start, fall back
        // to the bounded paged read so old-grid days don't silently zero out.
        let rows = try await firestore.fetchUsageSince(gridModel.gridStart)
        let oldest = rows.map(\.endTime).min() ?? now
        let truncated = rows.count >= FirestoreRepository.liveUsageDocumentLimit
            && oldest > gridModel.gridStart
        if truncated {
            return try await fetchUsageWindow(
                start: gridModel.gridRange.lowerBound,
                end: gridModel.gridRange.upperBound
            )
        }
        return rows
    }

    /// Paged `startTime`-bounded read of a closed window — the same query
    /// shape `ActivityStore` uses for its date filters. Bounded at 12 pages
    /// (6,000 rows) so a pathological month can never run away.
    private func fetchUsageWindow(start: Date, end: Date) async throws -> [TokenUsage] {
        var all: [TokenUsage] = []
        var cursor: DocumentSnapshot?
        for _ in 0..<12 {
            let (page, last) = try await firestore.fetchUsagePage(
                pageSize: 500,
                after: cursor,
                provider: nil,
                model: nil,
                device: nil,
                startDate: start,
                endDate: end
            )
            all.append(contentsOf: page)
            guard let last, page.count == 500 else { break }
            cursor = last
        }
        return all
    }
}
