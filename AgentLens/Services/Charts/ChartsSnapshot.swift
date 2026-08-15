import Foundation
import OpenBurnBarCore

// MARK: - Charts Snapshot
//
// An immutable, Sendable bundle of *prepared* chart data — every series is
// already bucketed, ranked, and reduced to plain values, so card views render
// cached Paths with zero per-frame computation. Built off the main thread by
// `ChartsSnapshot.build` (pure; unit-tested in ChartsDataServiceTests) and
// published by `ChartsDataService`.

struct ChartsSnapshot: Equatable, Sendable {

    // MARK: Component types

    struct ProviderShare: Equatable, Sendable {
        let provider: AgentProvider
        let cost: Double
    }

    struct LabeledValue: Equatable, Sendable {
        let label: String
        let value: Double
    }

    struct OutlierSession: Equatable, Sendable {
        let sessionId: String
        let projectName: String
        let model: String
        let provider: AgentProvider
        let cost: Double
    }

    struct ProjectDailySeries: Equatable, Sendable {
        let projectName: String
        /// Aligned with `projectDayStarts`.
        let dailyCosts: [Double]
    }

    struct Forecast: Equatable, Sendable {
        /// Daily costs, oldest → newest (the observation window).
        let dailyCosts: [Double]
        let dayStarts: [Date]
        /// Projected daily values continuing past the observation window.
        let projectedDaily: [Double]
        /// Month-to-date actual + projected remainder of the calendar month.
        let projectedMonthEndSpend: Double
    }

    // MARK: Identity

    /// The usages version + range this snapshot was built from; used by the
    /// service to skip redundant rebuilds and by the insight engine as a
    /// cache key.
    let usagesVersion: Int
    let timeRange: TimeRange
    let builtAt: Date

    /// True when the selected window contains no usage at all — the page
    /// shows a single editorial empty state instead of 12 empty cards.
    let isEmpty: Bool

    // MARK: Headline totals

    let totalCost: Double
    let totalTokens: Int
    let sessionCount: Int

    // MARK: burnOverTime

    let burnSeries: [ChartBucketing.DateBucket]
    /// Second-half vs first-half percent change of the burn series, or nil
    /// when the first half is silent.
    let burnTrendPercent: Double?

    // MARK: spendLens (billing provenance)

    /// Burn series restricted to real per-token API dollars.
    let apiBurnSeries: [ChartBucketing.DateBucket]
    /// Burn series restricted to plan-covered (subscription) imputed value.
    let subscriptionBurnSeries: [ChartBucketing.DateBucket]
    /// Burn series for spend that resisted classification.
    ///
    /// Carried as a series and not only a total so every lens mode can *draw*
    /// it. Split previously showed only API and Plan, which silently dropped
    /// this bucket from both the curves and the headline total.
    let unknownBurnSeries: [ChartBucketing.DateBucket]
    let apiCost: Double
    let subscriptionCost: Double
    /// Cost that resisted classification. Surfaced in copy when non-zero —
    /// never silently folded into either side.
    let unknownBillingCost: Double

    // MARK: providerMix / modelMix

    let providerShares: [ProviderShare]
    let modelCosts: [LabeledValue]

    // MARK: cacheROI

    let cacheHitRateSeries: [ChartBucketing.DateBucket]
    let cacheHitRate: Double
    let cacheReadTokens: Int
    /// Rough savings estimate assuming cache reads bill at ~10% of the
    /// window's blended per-token rate. Clearly labeled "(est.)" in UI.
    let cacheSavingsEstimate: Double

    // MARK: reasoningShare

    let reasoningShareSeries: [ChartBucketing.DateBucket]
    let reasoningShare: Double

    // MARK: hourOfDayHeatmap

    /// 7×24 cost matrix; row 0 = Sunday (Gregorian weekday order).
    let hourWeekdayCost: [[Double]]
    let peakWeekdayIndex: Int?
    let peakHour: Int?

    // MARK: weekOverWeekDelta (fixed window, independent of TimeRange)

    let thisWeekDaily: [Double]
    let lastWeekDaily: [Double]
    let weekOverWeekPercent: Double?

    // MARK: costPerSessionDistribution / sessionOutliers

    let sessionCostBins: [ChartBucketing.HistogramBin]
    let medianSessionCost: Double?
    let outlierSessions: [OutlierSession]

    // MARK: projectFocus

    let projectDayStarts: [Date]
    let projectSeries: [ProjectDailySeries]
    /// 0 = fully focused on one project, 1 = evenly spread.
    let projectEntropy: Double

    // MARK: burnForecast (fixed window, independent of TimeRange)

    let forecast: Forecast?

    // MARK: provenanceQuality

    /// Cost share per provenance confidence bucket, ranked.
    let provenanceShares: [LabeledValue]
    let exactShare: Double

    // MARK: modelConcentration / remoteVsLocal (hidden by default)

    /// Herfindahl–Hirschman index over model cost shares, 0…1.
    let modelConcentrationIndex: Double
    let remoteCost: Double
    let localCost: Double
}

// MARK: - Builder

extension ChartsSnapshot {

    /// Pure builder. `rows` = usage in the selected window; `recentRows` =
    /// usage over the trailing 30 days (feeds the fixed-window charts:
    /// week-vs-week and the forecast). TokenUsage input stays the oracle;
    /// production Charts uses `ChartFactRow` from the covering SQL scan.
    static func build(
        rows: [TokenUsage],
        recentRows: [TokenUsage],
        timeRange: TimeRange,
        usagesVersion: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ChartsSnapshot {
        build(
            rows: rows.map(ChartFactRow.init),
            recentRows: recentRows.map(ChartFactRow.init),
            timeRange: timeRange,
            usagesVersion: usagesVersion,
            now: now,
            calendar: calendar
        )
    }

    static func build(
        rows: [ChartFactRow],
        recentRows: [ChartFactRow],
        timeRange: TimeRange,
        usagesVersion: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ChartsSnapshot {
        let range = resolvedRange(for: timeRange, rows: rows, now: now, calendar: calendar)
        let bucketComponent: Calendar.Component = timeRange == .today ? .hour : .day

        let costEvents = rows.map {
            (date: attributionDate(for: $0.startTime, in: range), value: $0.cost)
        }
        let burnSeries = ChartBucketing.dateBuckets(
            events: costEvents, range: range, component: bucketComponent, calendar: calendar
        )

        // Spend lens: split the same window by billing provenance. Rows carry
        // a stamped kind from v60 onward; anything still unknown is classified
        // with the shared deterministic rule so the chart and the migration
        // backfill can never disagree.
        func effectiveBillingKind(_ row: ChartFactRow) -> BurnBarBillingKind {
            row.billingKind == .unknown
                ? BurnBarBillingProvenance.classify(provider: row.provider, usageSource: row.usageSource)
                : row.billingKind
        }
        var apiRows: [ChartFactRow] = []
        var subscriptionRows: [ChartFactRow] = []
        // Kept as rows, not just a running total, so Split can draw the
        // unclassified curve rather than only naming its total. A bucket the
        // lens cannot draw is a bucket the lens hides.
        var unknownRows: [ChartFactRow] = []
        for row in rows {
            switch effectiveBillingKind(row) {
            case .api: apiRows.append(row)
            case .subscription: subscriptionRows.append(row)
            case .unknown: unknownRows.append(row)
            }
        }
        let apiBurnSeries = ChartBucketing.dateBuckets(
            events: apiRows.map { (date: attributionDate(for: $0.startTime, in: range), value: $0.cost) },
            range: range, component: bucketComponent, calendar: calendar
        )
        let subscriptionBurnSeries = ChartBucketing.dateBuckets(
            events: subscriptionRows.map { (date: attributionDate(for: $0.startTime, in: range), value: $0.cost) },
            range: range, component: bucketComponent, calendar: calendar
        )
        let unknownBurnSeries = ChartBucketing.dateBuckets(
            events: unknownRows.map { (date: attributionDate(for: $0.startTime, in: range), value: $0.cost) },
            range: range, component: bucketComponent, calendar: calendar
        )
        let apiCost = apiRows.reduce(0) { $0 + $1.cost }
        let subscriptionCost = subscriptionRows.reduce(0) { $0 + $1.cost }
        let unknownBillingCost = unknownRows.reduce(0) { $0 + $1.cost }

        let totalCost = rows.reduce(0) { $0 + $1.cost }
        let totalTokens = rows.reduce(0) { $0 + $1.totalTokens }
        let sessionIDs = Set(rows.map(\.sessionId))

        // Provider / model mixes
        var providerCosts: [AgentProvider: Double] = [:]
        var modelCosts: [String: Double] = [:]
        for row in rows {
            providerCosts[row.provider, default: 0] += row.cost
            modelCosts[row.model, default: 0] += row.cost
        }
        let providerShares = providerCosts
            .map { ProviderShare(provider: $0.key, cost: $0.value) }
            .sorted { $0.cost > $1.cost }
        let rankedModels = modelCosts
            .map { LabeledValue(label: $0.key, value: $0.value) }
            .sorted { $0.value > $1.value }
            .prefix(8)

        // Cache
        let cacheSeries = ratioSeries(
            rows: rows, range: range, component: bucketComponent, calendar: calendar,
            numerator: { Double($0.cacheReadTokens) },
            denominator: { Double($0.inputTokens + $0.cacheCreationTokens + $0.cacheReadTokens) }
        )
        let cacheRead = rows.reduce(0) { $0 + $1.cacheReadTokens }
        let promptBasis = rows.reduce(0) { $0 + $1.inputTokens + $1.cacheCreationTokens + $1.cacheReadTokens }
        let cacheHitRate = promptBasis > 0 ? Double(cacheRead) / Double(promptBasis) : 0
        let blendedRate = totalTokens > 0 ? totalCost / Double(totalTokens) : 0
        let cacheSavings = 0.9 * Double(cacheRead) * blendedRate

        // Reasoning
        let reasoningSeries = ratioSeries(
            rows: rows, range: range, component: bucketComponent, calendar: calendar,
            numerator: { Double($0.reasoningTokens) },
            denominator: { Double($0.totalTokens) }
        )
        let reasoningTotal = rows.reduce(0) { $0 + $1.reasoningTokens }
        let reasoningShare = totalTokens > 0 ? Double(reasoningTotal) / Double(totalTokens) : 0

        // Heatmap / outliers / entropy share one fold so the SQL narrow-scan
        // path can match `ChartsSnapshot.build` bit-identically.
        let sessionAnalytics = ChartSessionAnalytics.from(rows: rows, range: range, calendar: calendar)
        let matrix = sessionAnalytics.hourWeekdayCost
        let peak = peakCell(in: matrix)

        // Week vs week (trailing fixed windows anchored at start of today)
        let (thisWeek, lastWeek) = weekPair(rows: recentRows, now: now, calendar: calendar)
        let lastWeekTotal = lastWeek.reduce(0, +)
        let thisWeekTotal = thisWeek.reduce(0, +)
        let wowPercent: Double? = lastWeekTotal > 0
            ? ((thisWeekTotal - lastWeekTotal) / lastWeekTotal) * 100
            : nil

        // Sessions
        var sessionCosts: [String: Double] = [:]
        for row in rows {
            sessionCosts[row.sessionId, default: 0] += row.cost
        }
        let costsPerSession = Array(sessionCosts.values)

        // Project focus
        var projectCosts: [String: Double] = [:]
        for row in rows {
            let name = row.projectName.isEmpty ? "Unassigned" : row.projectName
            projectCosts[name, default: 0] += row.cost
        }
        let topProjects = projectCosts.sorted { $0.value > $1.value }.prefix(5).map(\.key)
        let dayStarts = burnSeries.map(\.start)
        let projectSeries: [ProjectDailySeries] = topProjects.map { project in
            let events = rows
                .filter { ($0.projectName.isEmpty ? "Unassigned" : $0.projectName) == project }
                .map { (date: attributionDate(for: $0.startTime, in: range), value: $0.cost) }
            let buckets = ChartBucketing.dateBuckets(
                events: events, range: range, component: bucketComponent, calendar: calendar
            )
            return ProjectDailySeries(projectName: project, dailyCosts: buckets.map(\.value))
        }

        // Forecast (trailing 30 days observation, project to month end)
        let forecast = buildForecast(rows: recentRows, now: now, calendar: calendar)

        // Provenance
        var provenanceCosts: [String: Double] = [:]
        var exactCost: Double = 0
        for row in rows {
            let label = provenanceLabel(row.provenanceConfidence)
            provenanceCosts[label, default: 0] += row.cost
            if row.provenanceConfidence == .exact || row.provenanceConfidence == .derivedExact {
                exactCost += row.cost
            }
        }
        let provenanceShares = provenanceCosts
            .map { LabeledValue(label: $0.key, value: $0.value) }
            .sorted { $0.value > $1.value }
        let exactShare = totalCost > 0 ? exactCost / totalCost : 0

        // Concentration + remote/local
        let hhi: Double = totalCost > 0
            ? modelCosts.values.reduce(0) { $0 + pow($1 / totalCost, 2) }
            : 0
        let remoteCost = rows.filter(\.isRemote).reduce(0) { $0 + $1.cost }

        return ChartsSnapshot(
            usagesVersion: usagesVersion,
            timeRange: timeRange,
            builtAt: now,
            isEmpty: rows.isEmpty,
            totalCost: totalCost,
            totalTokens: totalTokens,
            sessionCount: sessionIDs.count,
            burnSeries: burnSeries,
            burnTrendPercent: halfOverHalfPercent(burnSeries.map(\.value)),
            apiBurnSeries: apiBurnSeries,
            subscriptionBurnSeries: subscriptionBurnSeries,
            unknownBurnSeries: unknownBurnSeries,
            apiCost: apiCost,
            subscriptionCost: subscriptionCost,
            unknownBillingCost: unknownBillingCost,
            providerShares: providerShares,
            modelCosts: Array(rankedModels),
            cacheHitRateSeries: cacheSeries,
            cacheHitRate: cacheHitRate,
            cacheReadTokens: cacheRead,
            cacheSavingsEstimate: cacheSavings,
            reasoningShareSeries: reasoningSeries,
            reasoningShare: reasoningShare,
            hourWeekdayCost: matrix,
            peakWeekdayIndex: peak?.weekday,
            peakHour: peak?.hour,
            thisWeekDaily: thisWeek,
            lastWeekDaily: lastWeek,
            weekOverWeekPercent: wowPercent,
            sessionCostBins: ChartBucketing.histogramLogBuckets(values: costsPerSession),
            medianSessionCost: ChartBucketing.median(costsPerSession.filter { $0 > 0 }),
            outlierSessions: sessionAnalytics.outlierSessions,
            projectDayStarts: dayStarts,
            projectSeries: projectSeries,
            projectEntropy: sessionAnalytics.projectEntropy,
            forecast: forecast,
            provenanceShares: provenanceShares,
            exactShare: exactShare,
            modelConcentrationIndex: hhi,
            remoteCost: remoteCost,
            localCost: totalCost - remoteCost
        )
    }

    // MARK: Helpers

    static func attributionDate(
        for startTime: Date,
        in range: ClosedRange<Date>
    ) -> Date {
        min(max(startTime, range.lowerBound), range.upperBound)
    }

    static func attributionDate(
        for row: TokenUsage,
        in range: ClosedRange<Date>
    ) -> Date {
        attributionDate(for: row.startTime, in: range)
    }

    static func resolvedRange(
        for timeRange: TimeRange,
        earliestStart: Date?,
        now: Date,
        calendar: Calendar
    ) -> ClosedRange<Date> {
        if let range = timeRange.dateRange(now: now) {
            return range.lowerBound...max(range.lowerBound, min(range.upperBound, now))
        }
        let earliest = earliestStart
            ?? calendar.date(byAdding: .day, value: -30, to: now)
            ?? now.addingTimeInterval(-30 * 86_400)
        let lower = min(earliest, now.addingTimeInterval(-1))
        return lower...now
    }

    static func resolvedRange(
        for timeRange: TimeRange,
        rows: [TokenUsage],
        now: Date,
        calendar: Calendar
    ) -> ClosedRange<Date> {
        resolvedRange(
            for: timeRange,
            earliestStart: rows.map(\.startTime).min(),
            now: now,
            calendar: calendar
        )
    }

    static func resolvedRange(
        for timeRange: TimeRange,
        rows: [ChartFactRow],
        now: Date,
        calendar: Calendar
    ) -> ClosedRange<Date> {
        resolvedRange(
            for: timeRange,
            earliestStart: rows.map(\.startTime).min(),
            now: now,
            calendar: calendar
        )
    }

    /// Per-bucket ratio of two summed row projections (e.g. cache reads over
    /// prompt basis). Buckets with a zero denominator carry 0.
    private static func ratioSeries(
        rows: [ChartFactRow],
        range: ClosedRange<Date>,
        component: Calendar.Component,
        calendar: Calendar,
        numerator: (ChartFactRow) -> Double,
        denominator: (ChartFactRow) -> Double
    ) -> [ChartBucketing.DateBucket] {
        let num = ChartBucketing.dateBuckets(
            events: rows.map { (date: attributionDate(for: $0.startTime, in: range), value: numerator($0)) },
            range: range, component: component, calendar: calendar
        )
        let den = ChartBucketing.dateBuckets(
            events: rows.map { (date: attributionDate(for: $0.startTime, in: range), value: denominator($0)) },
            range: range, component: component, calendar: calendar
        )
        return zip(num, den).map { top, bottom in
            ChartBucketing.DateBucket(
                start: top.start,
                value: bottom.value > 0 ? top.value / bottom.value : 0
            )
        }
    }

    private static func halfOverHalfPercent(_ values: [Double]) -> Double? {
        guard values.count >= 4 else { return nil }
        let mid = values.count / 2
        let firstHalf = values[..<mid].reduce(0, +)
        let secondHalf = values[mid...].reduce(0, +)
        guard firstHalf > 0 else { return nil }
        return ((secondHalf - firstHalf) / firstHalf) * 100
    }

    private static func peakCell(in matrix: [[Double]]) -> (weekday: Int, hour: Int)? {
        var best: (weekday: Int, hour: Int, value: Double)?
        for (weekday, hours) in matrix.enumerated() {
            for (hour, value) in hours.enumerated() where value > (best?.value ?? 0) {
                best = (weekday, hour, value)
            }
        }
        return best.map { ($0.weekday, $0.hour) }
    }

    private static func weekPair(
        rows: [ChartFactRow],
        now: Date,
        calendar: Calendar
    ) -> (thisWeek: [Double], lastWeek: [Double]) {
        let todayStart = calendar.startOfDay(for: now)
        guard let thisWeekStart = calendar.date(byAdding: .day, value: -6, to: todayStart),
              let lastWeekStart = calendar.date(byAdding: .day, value: -13, to: todayStart),
              let thisWeekEnd = calendar.date(byAdding: .day, value: 1, to: todayStart) else {
            return ([], [])
        }
        let events = rows.map { (date: $0.startTime, value: $0.cost) }
        let thisWeek = ChartBucketing.dateBuckets(
            events: events, range: thisWeekStart...thisWeekEnd, component: .day, calendar: calendar
        ).map(\.value)
        let lastWeek = ChartBucketing.dateBuckets(
            events: events, range: lastWeekStart...thisWeekStart, component: .day, calendar: calendar
        ).map(\.value)
        return (Array(thisWeek.prefix(7)), Array(lastWeek.prefix(7)))
    }

    private static func buildForecast(
        rows: [ChartFactRow],
        now: Date,
        calendar: Calendar
    ) -> Forecast? {
        let todayStart = calendar.startOfDay(for: now)
        guard let observationStart = calendar.date(byAdding: .day, value: -13, to: todayStart),
              let todayEnd = calendar.date(byAdding: .day, value: 1, to: todayStart) else { return nil }
        let events = rows.map { (date: $0.startTime, value: $0.cost) }
        let daily = ChartBucketing.dateBuckets(
            events: events, range: observationStart...todayEnd, component: .day, calendar: calendar
        )
        let values = daily.map(\.value)
        guard values.contains(where: { $0 > 0 }), let fit = ChartBucketing.linearFit(values: values) else {
            return nil
        }

        // Project each remaining day of the calendar month (today excluded —
        // it's still accruing and already inside the observation window).
        guard let monthInterval = calendar.dateInterval(of: .month, for: now) else { return nil }
        var projectedDaily: [Double] = []
        var cursor = todayEnd
        var x = Double(values.count)
        while cursor < monthInterval.end, projectedDaily.count < 62 {
            projectedDaily.append(max(0, fit.projected(at: x)))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
            x += 1
        }

        let monthToDate = rows
            .filter { $0.startTime >= monthInterval.start && $0.startTime <= now }
            .reduce(0) { $0 + $1.cost }
        let projectedMonthEnd = monthToDate + projectedDaily.reduce(0, +)

        return Forecast(
            dailyCosts: values,
            dayStarts: daily.map(\.start),
            projectedDaily: projectedDaily,
            projectedMonthEndSpend: projectedMonthEnd
        )
    }

    private static func provenanceLabel(_ confidence: UsageProvenanceConfidence) -> String {
        switch confidence {
        case .exact: return "Exact"
        case .derivedExact: return "Derived exact"
        case .highConfidenceEstimate: return "High-confidence est."
        case .lowConfidenceEstimate: return "Low-confidence est."
        case .unknown: return "Unknown"
        }
    }
}
