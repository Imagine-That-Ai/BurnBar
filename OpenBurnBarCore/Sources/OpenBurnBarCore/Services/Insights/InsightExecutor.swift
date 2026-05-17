import Foundation

/// Turns an `InsightDataBinding` into concrete `InsightWidgetData`.
///
/// Pure function over `(binding, filter, snapshot)`. Every widget kind
/// supported by the catalog has a matching evaluation branch here.
public struct InsightExecutor: Sendable {
    public var calendar: Calendar
    public var taxonomy: InsightTaxonomy

    public init(calendar: Calendar = .current, taxonomy: InsightTaxonomy = .default) {
        self.calendar = calendar
        self.taxonomy = taxonomy
    }

    /// Evaluate `binding` against `snapshot` under `filter`.
    public func evaluate(binding: InsightDataBinding,
                         filter: InsightFilter,
                         snapshot: InsightDataSnapshot) -> InsightWidgetData {
        let usages = filterUsages(snapshot.usages, filter: filter)
        let sessions = filterSessions(snapshot.sessions, filter: filter)

        switch binding {
        case .kpi(let metric, _):
            return .kpi(makeKPI(metric: metric, usages: usages, sessions: sessions,
                                snapshot: snapshot, filter: filter))

        case .timeSeries(let metric, let dimension, _):
            return .timeSeries(makeTimeSeries(metric: metric, dimension: dimension,
                                              usages: usages, snapshot: snapshot))

        case .ranking(let metric, let dimension, let limit, _):
            return .ranking(makeRanking(metric: metric, dimension: dimension,
                                        limit: limit, usages: usages, sessions: sessions))

        case .distribution(let metric, let dimension, _):
            return .distribution(makeDistribution(metric: metric, dimension: dimension,
                                                  usages: usages))

        case .heatmap(let metric, _):
            return .heatmap(makeHeatmap(metric: metric, usages: usages))

        case .scatter(let xMetric, let yMetric, let dimension, _):
            return .scatter(makeScatter(xMetric: xMetric, yMetric: yMetric,
                                        dimension: dimension, usages: usages))

        case .sankey(let source, let mid, let target, _):
            return .sankey(makeSankey(source: source, mid: mid, target: target,
                                      usages: usages))

        case .radar(let target, _):
            return .radar(makeRadar(target: target, sessions: sessions, usages: usages))

        case .cohort:
            return .cohort(makeCohort(sessions: sessions))

        case .funnel(let stages, _):
            return .funnel(makeFunnel(stages: stages, snapshot: snapshot))

        case .quota(let providerKey):
            return .quota(makeQuota(providerKey: providerKey, snapshot: snapshot))

        case .forecast(let metric, let horizon):
            return .forecast(makeForecast(metric: metric, horizonDays: horizon,
                                          usages: usages, snapshot: snapshot))

        case .anomaly:
            return .anomaly(makeAnomalyTable(usages: usages))

        case .useCaseClusters:
            return .useCaseCluster(makeUseCaseCluster(sessions: sessions, usages: usages))

        case .agentFocusMatrix:
            return .focusMatrix(makeAgentFocusMatrix(sessions: sessions))

        case .modelFocusMatrix:
            return .focusMatrix(makeModelFocusMatrix(sessions: sessions, usages: usages))

        case .drilldown(let limit):
            return .drilldown(makeDrilldown(limit: limit, sessions: sessions, usages: usages))

        case .narrative(let body):
            return .narrative(body)

        case .recommendation(let r):
            return .recommendation(r)

        case .mermaid(let source):
            return .mermaid(source)

        case .ascii(let card):
            return .ascii(card)

        case .composed(let children):
            return .composed(children.map { evaluate(binding: $0, filter: filter, snapshot: snapshot) })
        }
    }

    // MARK: - Filtering

    private func filterUsages(_ usages: [InsightUsageRow], filter: InsightFilter) -> [InsightUsageRow] {
        usages.filter { row in
            if !filter.providers.isEmpty, !filter.providers.contains(row.provider) { return false }
            if !filter.models.isEmpty, !filter.models.contains(row.model) { return false }
            if !filter.projects.isEmpty {
                guard let p = row.projectName, filter.projects.contains(p) else { return false }
            }
            if let minC = filter.minCostUSD, row.costUSD < minC { return false }
            if let maxC = filter.maxCostUSD, row.costUSD > maxC { return false }
            return true
        }
    }

    private func filterSessions(_ sessions: [InsightSessionRow], filter: InsightFilter) -> [InsightSessionRow] {
        sessions.filter { row in
            if !filter.providers.isEmpty, !filter.providers.contains(row.provider) { return false }
            if !filter.projects.isEmpty {
                guard let p = row.projectName, filter.projects.contains(p) else { return false }
            }
            return true
        }
    }

    // MARK: - KPI

    private func makeKPI(metric: InsightDataBinding.KPIMetric,
                         usages: [InsightUsageRow],
                         sessions: [InsightSessionRow],
                         snapshot: InsightDataSnapshot,
                         filter: InsightFilter) -> InsightWidgetData.KPI {
        let label: String
        let format: ValueFormat
        let value: Double
        var spark: [Double] = []
        var context: String? = nil
        switch metric {
        case .totalCost:
            label = "Cost"
            format = .currency
            value = usages.reduce(0) { $0 + $1.costUSD }
            spark = daily(values: usages, by: { $0.costUSD })
        case .totalTokens:
            label = "Tokens"
            format = .tokens
            value = Double(usages.reduce(0) { $0 + $1.totalTokens })
            spark = daily(values: usages, by: { Double($0.totalTokens) })
        case .totalSessions:
            label = "Sessions"
            format = .count
            value = Double(Set(usages.map { "\($0.provider)|\($0.sessionID)" }).count)
            spark = dailySessionCounts(usages: usages)
        case .cacheHitRate:
            label = "Cache hit"
            format = .percent
            let cache = usages.reduce(0) { $0 + $1.cacheReadTokens }
            let total = usages.reduce(0) { $0 + $1.totalTokens }
            value = total > 0 ? Double(cache) / Double(total) : 0
            spark = dailyCacheHitRate(usages: usages)
        case .inputTokens:
            label = "Input tokens"
            format = .tokens
            value = Double(usages.reduce(0) { $0 + $1.inputTokens })
        case .outputTokens:
            label = "Output tokens"
            format = .tokens
            value = Double(usages.reduce(0) { $0 + $1.outputTokens })
        case .reasoningTokens:
            label = "Reasoning"
            format = .tokens
            value = Double(usages.reduce(0) { $0 + $1.reasoningTokens })
        case .avgCostPerSession:
            label = "Avg per session"
            format = .currency
            let sessionCount = max(1, Set(usages.map { "\($0.provider)|\($0.sessionID)" }).count)
            value = usages.reduce(0) { $0 + $1.costUSD } / Double(sessionCount)
        case .avgTokensPerSession:
            label = "Avg tokens / session"
            format = .tokens
            let sessionCount = max(1, Set(usages.map { "\($0.provider)|\($0.sessionID)" }).count)
            value = Double(usages.reduce(0) { $0 + $1.totalTokens }) / Double(sessionCount)
        case .providerCount:
            label = "Providers"
            format = .count
            value = Double(Set(usages.map(\.provider)).count)
        case .modelCount:
            label = "Models"
            format = .count
            value = Double(Set(usages.map(\.model)).count)
        case .projectCount:
            label = "Projects"
            format = .count
            value = Double(Set(usages.compactMap(\.projectName)).count)
        case .quotaHeadroom:
            label = "Quota headroom"
            format = .percent
            value = computeQuotaHeadroom(snapshot.quotaBuckets)
            context = "weighted across providers"
        }

        let (delta, deltaIsPct) = computeDelta(metric: metric,
                                               usages: usages,
                                               filter: filter,
                                               snapshot: snapshot)
        return InsightWidgetData.KPI(
            metricLabel: label,
            value: value,
            valueFormat: format,
            delta: delta,
            deltaIsPercent: deltaIsPct,
            sparkline: spark,
            contextLabel: context
        )
    }

    private func computeQuotaHeadroom(_ buckets: [InsightQuotaBucket]) -> Double {
        let withLimits = buckets.filter { ($0.limit ?? 0) > 0 }
        guard !withLimits.isEmpty else { return 0 }
        let avg = withLimits.reduce(0.0) { acc, b in
            guard let l = b.limit, l > 0 else { return acc }
            return acc + max(0, 1 - b.used / l)
        }
        return avg / Double(withLimits.count)
    }

    private func computeDelta(metric: InsightDataBinding.KPIMetric,
                              usages: [InsightUsageRow],
                              filter: InsightFilter,
                              snapshot: InsightDataSnapshot) -> (Double?, Bool) {
        // Compare current window's total vs. equally sized preceding window.
        let now = snapshot.generatedAt
        let interval = filter.window.interval(now: now, calendar: calendar)
        let length = interval.end.timeIntervalSince(interval.start)
        let priorEnd = interval.start
        let priorStart = priorEnd.addingTimeInterval(-length)
        let priorInterval = DateInterval(start: priorStart, end: priorEnd)
        let priorUsages = snapshot.usages.filter { priorInterval.contains($0.startTime) }
        func sum(_ rows: [InsightUsageRow], _ pick: (InsightUsageRow) -> Double) -> Double {
            rows.reduce(0) { $0 + pick($1) }
        }
        switch metric {
        case .totalCost:
            return percentDelta(current: sum(usages, { $0.costUSD }),
                                prior: sum(priorUsages, { $0.costUSD }))
        case .totalTokens:
            return percentDelta(current: sum(usages, { Double($0.totalTokens) }),
                                prior: sum(priorUsages, { Double($0.totalTokens) }))
        case .totalSessions:
            return percentDelta(current: Double(Set(usages.map { "\($0.provider)|\($0.sessionID)" }).count),
                                prior: Double(Set(priorUsages.map { "\($0.provider)|\($0.sessionID)" }).count))
        default:
            return (nil, true)
        }
    }

    private func percentDelta(current: Double, prior: Double) -> (Double?, Bool) {
        guard prior > 0 else { return (nil, true) }
        return ((current - prior) / prior, true)
    }

    private func daily(values usages: [InsightUsageRow],
                       by pick: (InsightUsageRow) -> Double) -> [Double] {
        let grouped = Dictionary(grouping: usages) { calendar.startOfDay(for: $0.startTime) }
        return grouped.keys.sorted().map { day in
            grouped[day, default: []].reduce(0) { $0 + pick($1) }
        }
    }

    private func dailySessionCounts(usages: [InsightUsageRow]) -> [Double] {
        let grouped = Dictionary(grouping: usages) { calendar.startOfDay(for: $0.startTime) }
        return grouped.keys.sorted().map { day in
            Double(Set(grouped[day, default: []].map { "\($0.provider)|\($0.sessionID)" }).count)
        }
    }

    private func dailyCacheHitRate(usages: [InsightUsageRow]) -> [Double] {
        let grouped = Dictionary(grouping: usages) { calendar.startOfDay(for: $0.startTime) }
        return grouped.keys.sorted().map { day in
            let rows = grouped[day, default: []]
            let cache = rows.reduce(0) { $0 + $1.cacheReadTokens }
            let total = rows.reduce(0) { $0 + $1.totalTokens }
            return total > 0 ? Double(cache) / Double(total) : 0
        }
    }

    // MARK: - Time series

    private func makeTimeSeries(metric: InsightDataBinding.TimeSeriesMetric,
                                dimension: InsightDataBinding.Dimension?,
                                usages: [InsightUsageRow],
                                snapshot: InsightDataSnapshot) -> InsightWidgetData.TimeSeries {
        let (yLabel, format) = timeSeriesLabel(metric)
        let xLabel = "Date"
        let series: [InsightWidgetData.TimeSeries.Series]

        if let dim = dimension {
            series = buildSeries(metric: metric, usages: usages, dimension: dim)
        } else {
            let dailyMap = Dictionary(grouping: usages) { calendar.startOfDay(for: $0.startTime) }
            let points = dailyMap.keys.sorted().map { day in
                InsightWidgetData.TimeSeries.Point(date: day, value: aggregate(metric: metric,
                                                                                rows: dailyMap[day, default: []]))
            }
            series = [.init(id: "all", name: yLabel, points: points)]
        }
        return InsightWidgetData.TimeSeries(series: series, xAxisLabel: xLabel,
                                            yAxisLabel: yLabel, yFormat: format)
    }

    private func timeSeriesLabel(_ metric: InsightDataBinding.TimeSeriesMetric) -> (String, ValueFormat) {
        switch metric {
        case .cost: return ("Cost (USD)", .currency)
        case .tokens: return ("Tokens", .tokens)
        case .sessions: return ("Sessions", .count)
        case .cacheRate: return ("Cache hit %", .percent)
        case .reasoningShare: return ("Reasoning share", .percent)
        }
    }

    private func aggregate(metric: InsightDataBinding.TimeSeriesMetric,
                           rows: [InsightUsageRow]) -> Double {
        switch metric {
        case .cost: return rows.reduce(0) { $0 + $1.costUSD }
        case .tokens: return Double(rows.reduce(0) { $0 + $1.totalTokens })
        case .sessions: return Double(Set(rows.map { "\($0.provider)|\($0.sessionID)" }).count)
        case .cacheRate:
            let cache = rows.reduce(0) { $0 + $1.cacheReadTokens }
            let total = rows.reduce(0) { $0 + $1.totalTokens }
            return total > 0 ? Double(cache) / Double(total) : 0
        case .reasoningShare:
            let reasoning = rows.reduce(0) { $0 + $1.reasoningTokens }
            let total = rows.reduce(0) { $0 + $1.totalTokens }
            return total > 0 ? Double(reasoning) / Double(total) : 0
        }
    }

    private func buildSeries(metric: InsightDataBinding.TimeSeriesMetric,
                             usages: [InsightUsageRow],
                             dimension: InsightDataBinding.Dimension) -> [InsightWidgetData.TimeSeries.Series] {
        let key: (InsightUsageRow) -> String = dimensionKey(for: dimension)
        let grouped = Dictionary(grouping: usages, by: key)
        // Take top 5 series by sum.
        let topDimensions = grouped.keys
            .map { ($0, aggregate(metric: metric, rows: grouped[$0, default: []])) }
            .sorted { $0.1 > $1.1 }
            .prefix(5)
            .map(\.0)
        return topDimensions.map { dim in
            let rows = grouped[dim, default: []]
            let perDay = Dictionary(grouping: rows) { calendar.startOfDay(for: $0.startTime) }
            let points = perDay.keys.sorted().map { day in
                InsightWidgetData.TimeSeries.Point(date: day, value: aggregate(metric: metric, rows: perDay[day, default: []]))
            }
            return .init(id: dim, name: dim, points: points)
        }
    }

    private func dimensionKey(for dimension: InsightDataBinding.Dimension) -> (InsightUsageRow) -> String {
        switch dimension {
        case .provider: return { $0.provider }
        case .model:    return { $0.model }
        case .project:  return { $0.projectName ?? "—" }
        case .device:   return { $0.deviceID ?? "local" }
        case .session:  return { $0.sessionID }
        case .file:     return { $0.projectName ?? "—" }     // best-available proxy at this layer
        case .day:      return { ISO8601DateFormatter().string(from: $0.startTime) }
        case .hourOfDay: return {
            let cal = Calendar.current
            return String(cal.component(.hour, from: $0.startTime))
        }
        case .dayOfWeek: return {
            let cal = Calendar.current
            return String(cal.component(.weekday, from: $0.startTime))
        }
        case .focus, .useCase: return { $0.provider }       // require session-side join elsewhere
        }
    }

    // MARK: - Ranking

    private func makeRanking(metric: InsightDataBinding.RankingMetric,
                             dimension: InsightDataBinding.Dimension,
                             limit: Int,
                             usages: [InsightUsageRow],
                             sessions: [InsightSessionRow]) -> InsightWidgetData.Ranking {
        let key = dimensionKey(for: dimension)
        let grouped = Dictionary(grouping: usages, by: key)
        let format: ValueFormat
        let valuePicker: ([InsightUsageRow]) -> Double
        switch metric {
        case .cost: format = .currency; valuePicker = { $0.reduce(0) { $0 + $1.costUSD } }
        case .tokens: format = .tokens; valuePicker = { Double($0.reduce(0) { $0 + $1.totalTokens }) }
        case .sessions: format = .count; valuePicker = { Double(Set($0.map { "\($0.provider)|\($0.sessionID)" }).count) }
        case .costPerSession: format = .currency; valuePicker = { rows in
            let sessions = Set(rows.map { "\($0.provider)|\($0.sessionID)" }).count
            return rows.reduce(0) { $0 + $1.costUSD } / Double(max(1, sessions))
        }
        case .cacheHitRate: format = .percent; valuePicker = { rows in
            let cache = rows.reduce(0) { $0 + $1.cacheReadTokens }
            let total = rows.reduce(0) { $0 + $1.totalTokens }
            return total > 0 ? Double(cache) / Double(total) : 0
        }
        }
        let rows = grouped
            .map { ($0.key, valuePicker($0.value)) }
            .sorted { $0.1 > $1.1 }
            .prefix(max(1, limit))
            .map { key, value in
                InsightWidgetData.Ranking.Row(id: key, label: key, value: value, secondaryLabel: nil, colorHex: nil)
            }
        return InsightWidgetData.Ranking(rows: Array(rows), valueFormat: format,
                                         dimensionLabel: dimensionLabel(dimension))
    }

    private func dimensionLabel(_ d: InsightDataBinding.Dimension) -> String {
        switch d {
        case .provider: return "Provider"
        case .model: return "Model"
        case .project: return "Project"
        case .device: return "Device"
        case .session: return "Session"
        case .file: return "File"
        case .day: return "Day"
        case .hourOfDay: return "Hour"
        case .dayOfWeek: return "Day of week"
        case .focus: return "Focus"
        case .useCase: return "Use case"
        }
    }

    // MARK: - Distribution

    private func makeDistribution(metric: InsightDataBinding.DistributionMetric,
                                  dimension: InsightDataBinding.Dimension,
                                  usages: [InsightUsageRow]) -> InsightWidgetData.Distribution {
        let key = dimensionKey(for: dimension)
        let grouped = Dictionary(grouping: usages, by: key)
        let format: ValueFormat
        let valuePicker: ([InsightUsageRow]) -> Double
        switch metric {
        case .cost: format = .currency; valuePicker = { $0.reduce(0) { $0 + $1.costUSD } }
        case .tokens: format = .tokens; valuePicker = { Double($0.reduce(0) { $0 + $1.totalTokens }) }
        case .sessions: format = .count; valuePicker = { Double(Set($0.map { "\($0.provider)|\($0.sessionID)" }).count) }
        }
        let slices = grouped
            .map { ($0.key, valuePicker($0.value)) }
            .sorted { $0.1 > $1.1 }
            .prefix(6)
            .map { key, value in
                InsightWidgetData.Distribution.Slice(id: key, label: key, value: value, colorHex: nil)
            }
        let total = slices.reduce(0) { $0 + $1.value }
        return .init(slices: Array(slices), valueFormat: format, total: total)
    }

    // MARK: - Heatmap

    private func makeHeatmap(metric: InsightDataBinding.HeatmapMetric,
                             usages: [InsightUsageRow]) -> InsightWidgetData.Heatmap {
        let dowLabels = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let hourLabels = (0..<24).map { String($0) }
        var cells = Array(repeating: Array(repeating: 0.0, count: 24), count: 7)
        for u in usages {
            let dow = max(1, min(7, calendar.component(.weekday, from: u.startTime))) - 1
            let hour = max(0, min(23, calendar.component(.hour, from: u.startTime)))
            switch metric {
            case .sessions: cells[dow][hour] += 1
            case .cost: cells[dow][hour] += u.costUSD
            case .tokens: cells[dow][hour] += Double(u.totalTokens)
            }
        }
        let format: ValueFormat = (metric == .cost ? .currency : (metric == .tokens ? .tokens : .count))
        return .init(rowLabels: dowLabels, columnLabels: hourLabels, cells: cells, valueFormat: format)
    }

    // MARK: - Scatter

    private func makeScatter(xMetric: InsightDataBinding.ScatterMetric,
                             yMetric: InsightDataBinding.ScatterMetric,
                             dimension: InsightDataBinding.Dimension,
                             usages: [InsightUsageRow]) -> InsightWidgetData.Scatter {
        let key = dimensionKey(for: dimension)
        let grouped = Dictionary(grouping: usages, by: key)
        func value(metric: InsightDataBinding.ScatterMetric, rows: [InsightUsageRow]) -> Double {
            switch metric {
            case .cost: return rows.reduce(0) { $0 + $1.costUSD }
            case .tokens: return Double(rows.reduce(0) { $0 + $1.totalTokens })
            case .sessions: return Double(Set(rows.map { "\($0.provider)|\($0.sessionID)" }).count)
            case .costPerMtoken:
                let cost = rows.reduce(0) { $0 + $1.costUSD }
                let tok = Double(rows.reduce(0) { $0 + $1.totalTokens })
                return tok > 0 ? cost * 1_000_000 / tok : 0
            case .cacheRate:
                let cache = rows.reduce(0) { $0 + $1.cacheReadTokens }
                let total = rows.reduce(0) { $0 + $1.totalTokens }
                return total > 0 ? Double(cache) / Double(total) : 0
            case .avgDurationSeconds:
                let durations = rows.map { $0.endTime.timeIntervalSince($0.startTime) }
                return durations.isEmpty ? 0 : (durations.reduce(0, +) / Double(durations.count))
            }
        }
        let points = grouped.map { key, rows in
            InsightWidgetData.Scatter.Point(
                id: key,
                label: key,
                x: value(metric: xMetric, rows: rows),
                y: value(metric: yMetric, rows: rows),
                size: Double(rows.count)
            )
        }
        let xFormat = scatterFormat(xMetric)
        let yFormat = scatterFormat(yMetric)
        return .init(points: points, xAxisLabel: scatterLabel(xMetric),
                     yAxisLabel: scatterLabel(yMetric), xFormat: xFormat, yFormat: yFormat)
    }

    private func scatterFormat(_ m: InsightDataBinding.ScatterMetric) -> ValueFormat {
        switch m {
        case .cost, .costPerMtoken: return .currency
        case .tokens: return .tokens
        case .sessions: return .count
        case .cacheRate: return .percent
        case .avgDurationSeconds: return .duration
        }
    }

    private func scatterLabel(_ m: InsightDataBinding.ScatterMetric) -> String {
        switch m {
        case .cost: return "Cost (USD)"
        case .tokens: return "Tokens"
        case .sessions: return "Sessions"
        case .costPerMtoken: return "$/Mtoken"
        case .cacheRate: return "Cache hit rate"
        case .avgDurationSeconds: return "Avg duration (s)"
        }
    }

    // MARK: - Sankey

    private func makeSankey(source: InsightDataBinding.Dimension,
                            mid: InsightDataBinding.Dimension?,
                            target: InsightDataBinding.Dimension,
                            usages: [InsightUsageRow]) -> InsightWidgetData.Sankey {
        let sKey = dimensionKey(for: source)
        let tKey = dimensionKey(for: target)

        var nodeIDs: Set<String> = []
        var linkMap: [String: Double] = [:]

        if let mid {
            let mKey = dimensionKey(for: mid)
            for u in usages {
                let a = sKey(u); let b = mKey(u); let c = tKey(u)
                nodeIDs.insert(a); nodeIDs.insert(b); nodeIDs.insert(c)
                linkMap["\(a)|\(b)", default: 0] += u.costUSD
                linkMap["\(b)|\(c)", default: 0] += u.costUSD
            }
        } else {
            for u in usages {
                let a = sKey(u); let b = tKey(u)
                nodeIDs.insert(a); nodeIDs.insert(b)
                linkMap["\(a)|\(b)", default: 0] += u.costUSD
            }
        }

        let nodes = nodeIDs.sorted().map { InsightWidgetData.Sankey.Node(id: $0, label: $0) }
        let links = linkMap
            .sorted { $0.value > $1.value }
            .prefix(48)
            .map { key, value -> InsightWidgetData.Sankey.Link in
                let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
                let s = parts.count == 2 ? parts[0] : ""
                let t = parts.count == 2 ? parts[1] : ""
                return .init(source: s, target: t, value: value)
            }
        return .init(nodes: nodes, links: Array(links))
    }

    // MARK: - Radar

    private func makeRadar(target: InsightDataBinding.RadarTarget,
                           sessions: [InsightSessionRow],
                           usages: [InsightUsageRow]) -> InsightWidgetData.Radar {
        let axes = taxonomy.focuses
        let entries: [(name: String, sessions: [InsightSessionRow])]
        switch target {
        case .agent(let agent):
            entries = [(agent, sessions.filter { $0.provider == agent })]
        case .model(let modelID):
            let sessionByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.sessionID, $0) })
            let modelSessions = usages
                .filter { $0.model == modelID }
                .compactMap { sessionByID[$0.sessionID] }
            entries = [(modelID, modelSessions)]
        case .allAgents:
            let grouped = Dictionary(grouping: sessions, by: \.provider)
            let topAgents = grouped.keys.sorted { (grouped[$0]?.count ?? 0) > (grouped[$1]?.count ?? 0) }
                .prefix(4)
            entries = topAgents.map { ($0, grouped[$0] ?? []) }
        case .allModels:
            let sessionByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.sessionID, $0) })
            let perModel = Dictionary(grouping: usages, by: \.model)
            let topModels = perModel.keys.sorted { (perModel[$0]?.count ?? 0) > (perModel[$1]?.count ?? 0) }
                .prefix(4)
            entries = topModels.map { modelID in
                (modelID, perModel[modelID, default: []].compactMap { sessionByID[$0.sessionID] })
            }
        }
        let series = entries.map { entry in
            let counts = axes.map { axis in
                Double(entry.sessions.filter { InsightDigestBuilder.inferFocus(session: $0, taxonomy: taxonomy) == axis }.count)
            }
            let total = max(1, counts.reduce(0, +))
            let normalized = counts.map { $0 / total }
            return InsightWidgetData.Radar.Series(id: entry.name, name: entry.name, values: normalized)
        }
        return .init(axes: axes, series: series)
    }

    // MARK: - Cohort

    private func makeCohort(sessions: [InsightSessionRow]) -> InsightWidgetData.Cohort {
        // Cohort = week of first appearance per provider. Periods = subsequent weeks.
        let cal = calendar
        let providerEntries = Dictionary(grouping: sessions, by: \.provider)
        let cohortLabels = providerEntries.keys.sorted()
        // Find earliest session per provider for cohort row name.
        let firstSeen = providerEntries.mapValues { rows -> Date in
            rows.map(\.startTime).min() ?? Date()
        }
        // Period labels: 0…N weeks since cohort first-seen, capped at 8.
        let maxPeriods = 8
        let periodLabels = (0..<maxPeriods).map { "W+\($0)" }
        var cells: [[Double?]] = Array(repeating: Array(repeating: nil, count: maxPeriods), count: cohortLabels.count)
        for (rIdx, provider) in cohortLabels.enumerated() {
            let rows = providerEntries[provider] ?? []
            guard let baseline = firstSeen[provider] else { continue }
            let total = max(1, Set(rows.map(\.sessionID)).count)
            for p in 0..<maxPeriods {
                guard let weekStart = cal.date(byAdding: .day, value: 7 * p, to: baseline),
                      let weekEnd = cal.date(byAdding: .day, value: 7, to: weekStart) else { continue }
                let active = rows.filter { $0.startTime >= weekStart && $0.startTime < weekEnd }
                cells[rIdx][p] = Double(Set(active.map(\.sessionID)).count) / Double(total)
            }
        }
        return .init(cohortLabels: cohortLabels, periodLabels: periodLabels, cells: cells)
    }

    // MARK: - Funnel

    private func makeFunnel(stages: [String],
                            snapshot: InsightDataSnapshot) -> InsightWidgetData.Funnel {
        guard !stages.isEmpty else { return .init(steps: []) }
        var stageCounts: [Double] = []
        for stage in stages {
            let count = snapshot.operatingActions.filter { $0.actionKind == stage }.count
            stageCounts.append(Double(count))
        }
        let steps = zip(stages, stageCounts).map { name, count in
            InsightWidgetData.Funnel.Step(id: name, label: name, count: count)
        }
        return .init(steps: steps)
    }

    // MARK: - Quota

    private func makeQuota(providerKey: String?,
                           snapshot: InsightDataSnapshot) -> InsightWidgetData.QuotaState {
        let filtered = providerKey.map { key in
            snapshot.quotaBuckets.filter { $0.providerKey == key }
        } ?? snapshot.quotaBuckets
        let buckets = filtered.map { bucket -> InsightWidgetData.QuotaState.Bucket in
            .init(
                id: bucket.id,
                providerLabel: bucket.providerDisplayName,
                bucketName: bucket.bucketName,
                used: bucket.used,
                limit: bucket.limit,
                resetsAt: bucket.resetsAt,
                symbolName: symbolName(for: bucket),
                colorHex: nil
            )
        }
        return .init(buckets: buckets)
    }

    private func symbolName(for bucket: InsightQuotaBucket) -> String {
        guard let limit = bucket.limit, limit > 0 else { return "gauge.with.dots.needle.0percent" }
        let pct = bucket.used / limit
        switch pct {
        case ..<0.34: return "gauge.with.dots.needle.33percent"
        case ..<0.67: return "gauge.with.dots.needle.50percent"
        case ..<0.9: return "gauge.with.dots.needle.67percent"
        default: return "gauge.with.dots.needle.100percent"
        }
    }

    // MARK: - Forecast

    private func makeForecast(metric: InsightDataBinding.TimeSeriesMetric,
                              horizonDays: Int,
                              usages: [InsightUsageRow],
                              snapshot: InsightDataSnapshot) -> InsightWidgetData.Forecast {
        let dailyMap = Dictionary(grouping: usages) { calendar.startOfDay(for: $0.startTime) }
        let days = dailyMap.keys.sorted()
        let actualPoints = days.map { day in
            InsightWidgetData.TimeSeries.Point(date: day, value: aggregate(metric: metric, rows: dailyMap[day, default: []]))
        }
        let yLabel: String
        let format: ValueFormat
        (yLabel, format) = timeSeriesLabel(metric)

        // Simple Holt linear forecast.
        guard actualPoints.count >= 7 else {
            return .init(actual: actualPoints, forecast: [], lowerBound: [], upperBound: [],
                         xAxisLabel: "Date", yAxisLabel: yLabel, yFormat: format,
                         summary: "Need at least 7 days for a forecast.")
        }
        let values = actualPoints.map(\.value)
        let (level, trend) = Self.holtLinearParameters(values)
        let residuals = Self.residuals(values, level: level, trend: trend)
        let stddev = Self.stddev(residuals)

        let lastDay = actualPoints.last?.date ?? Date()
        var forecast: [InsightWidgetData.TimeSeries.Point] = []
        var lower: [InsightWidgetData.TimeSeries.Point] = []
        var upper: [InsightWidgetData.TimeSeries.Point] = []
        for i in 1...max(1, horizonDays) {
            let day = calendar.date(byAdding: .day, value: i, to: lastDay) ?? lastDay
            let forecastValue = max(0, level + Double(i) * trend)
            let width = 1.96 * stddev * sqrt(Double(i))
            forecast.append(.init(date: day, value: forecastValue))
            lower.append(.init(date: day, value: max(0, forecastValue - width)))
            upper.append(.init(date: day, value: forecastValue + width))
        }
        let summary = String(format: "Trend %@ %.2f / day", trend >= 0 ? "+" : "−", abs(trend))
        return .init(actual: actualPoints, forecast: forecast,
                     lowerBound: lower, upperBound: upper,
                     xAxisLabel: "Date", yAxisLabel: yLabel, yFormat: format,
                     summary: summary)
    }

    private static func holtLinearParameters(_ values: [Double], alpha: Double = 0.4, beta: Double = 0.2) -> (Double, Double) {
        guard values.count >= 2 else { return (values.last ?? 0, 0) }
        var level = values[0]
        var trend = values[1] - values[0]
        for v in values.dropFirst() {
            let prevLevel = level
            level = alpha * v + (1 - alpha) * (level + trend)
            trend = beta * (level - prevLevel) + (1 - beta) * trend
        }
        return (level, trend)
    }

    private static func residuals(_ values: [Double], level: Double, trend: Double) -> [Double] {
        var fitted: [Double] = []
        guard !values.isEmpty else { return [] }
        var l = values[0]
        var t = trend
        for i in 1..<values.count {
            let pred = l + t
            fitted.append(values[i] - pred)
            let prevL = l
            l = 0.4 * values[i] + 0.6 * (l + t)
            t = 0.2 * (l - prevL) + 0.8 * t
        }
        return fitted
    }

    private static func stddev(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count - 1)
        return sqrt(variance)
    }

    // MARK: - Anomaly table

    /// Day-of-week-normalized robust z-score anomaly detection.
    ///
    /// Plan §4.5 — `Robust z-score on day-of-week–normalized daily cost;
    /// surface only z>=2; cap at 12; include drill-down citations`.
    ///
    /// Each weekday is rolled up independently so a Tuesday spike is
    /// scored against Tuesday history, not weekend history. This catches
    /// the "Thursday cache hit dropped" class of anomaly that a plain
    /// median completely misses.
    ///
    /// Each surfaced row carries up to 3 session-id citations from that
    /// day so the renderer can offer "open the session that drove the
    /// anomaly" as a drill-through.
    private func makeAnomalyTable(usages: [InsightUsageRow]) -> InsightWidgetData.AnomalyTable {
        let dailyMap = Dictionary(grouping: usages) { calendar.startOfDay(for: $0.startTime) }
        let days = dailyMap.keys.sorted()
        guard days.count >= Self.anomalyMinimumDays else { return .init(rows: []) }

        // Pair each day with its weekday + cost so the leave-one-out
        // baseline computation below can skip the candidate cleanly.
        let dayCosts: [(day: Date, weekday: Int, cost: Double)] = days.map { day in
            let weekday = calendar.component(.weekday, from: day)
            let cost = dailyMap[day, default: []].reduce(0) { $0 + $1.costUSD }
            return (day, weekday, cost)
        }

        var rows: [InsightWidgetData.AnomalyTable.Row] = []
        for entry in dayCosts {
            // Leave-one-out so the candidate day doesn't warp its own
            // baseline. Try the weekday-normalized baseline first; fall
            // back to the global baseline when the weekday has too few
            // data points to be stable. Both are O(n) per candidate; the
            // overall scan is O(n²) but n is small (≤90 days).
            let weekdayBaseline = dayCosts
                .filter { $0.weekday == entry.weekday && $0.day != entry.day }
                .map(\.cost)
            let baseline: [Double]
            let baselineLabel: String
            let weekdayName = Self.weekdayName(entry.weekday, calendar: calendar)
            if weekdayBaseline.count >= Self.anomalyMinimumPerWeekday {
                baseline = weekdayBaseline
                baselineLabel = weekdayName
            } else {
                baseline = dayCosts.filter { $0.day != entry.day }.map(\.cost)
                baselineLabel = "global"
            }
            guard baseline.count >= Self.anomalyMinimumDays else { continue }
            let med = Self.median(baseline)
            let mad = max(Self.anomalyFloorMAD,
                          Self.median(baseline.map { abs($0 - med) }))
            let z = 0.6745 * (entry.cost - med) / mad
            guard abs(z) >= Self.anomalyZThreshold else { continue }

            let day = entry.day

            let label = z > 0 ? "\(weekdayName) spike" : "\(weekdayName) dip"
            let dayISO = Self.dayOnlyFormatter.string(from: day)
            // Surface up to 3 sessions for drill-through. Rank by cost
            // contribution so the largest contributor to the anomaly is
            // always cited first — that's the session the user wants to
            // open when they tap the anomaly.
            let costBySession = Dictionary(grouping: dailyMap[day, default: []],
                                           by: \.sessionID)
                .mapValues { rows in rows.reduce(0) { $0 + $1.costUSD } }
            let topSessionIDs = costBySession
                .sorted { lhs, rhs in lhs.value > rhs.value }
                .prefix(3)
                .map(\.key)
            var citations: [InsightCitation] = [
                .init(kind: .day(date: dayISO), label: dayLabel(day))
            ]
            for sid in topSessionIDs {
                citations.append(.init(kind: .session(id: sid, provider: nil),
                                       label: "session \(sid.prefix(8))"))
            }

            rows.append(.init(
                id: dayISO,
                occurredAt: day,
                label: label,
                detail: String(
                    format: "%.2f z vs %@ baseline ($%.2f median).",
                    z, baselineLabel, med
                ),
                score: abs(z),
                citations: citations
            ))
        }
        return .init(rows: Array(rows.sorted { $0.score > $1.score }.prefix(Self.anomalyMaxRows)))
    }

    static let anomalyZThreshold: Double = 2.0
    static let anomalyMaxRows: Int = 12
    static let anomalyMinimumDays: Int = 5
    static let anomalyMinimumPerWeekday: Int = 2
    static let anomalyFloorMAD: Double = 0.0001

    private static let dayOnlyFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()

    private static func weekdayName(_ weekday: Int, calendar: Calendar) -> String {
        // Calendar.weekday is 1-indexed with 1 == Sunday in the Gregorian
        // calendar. Use the calendar's `standaloneWeekdaySymbols` so the
        // label respects the user's locale.
        let symbols = calendar.standaloneWeekdaySymbols
        let idx = max(0, min(symbols.count - 1, weekday - 1))
        return symbols[idx]
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    private func dayLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }

    // MARK: - Use-case clusters

    private func makeUseCaseCluster(sessions: [InsightSessionRow],
                                    usages: [InsightUsageRow]) -> InsightWidgetData.UseCaseCluster {
        let counts = Dictionary(grouping: sessions, by: { InsightDigestBuilder.inferUseCase(session: $0, taxonomy: taxonomy) })
            .mapValues { $0 }
        let clusters = counts.map { (label, sessions) in
            InsightWidgetData.UseCaseCluster.Cluster(
                id: label,
                label: label,
                size: sessions.count,
                exampleSessionIDs: Array(sessions.prefix(3).map(\.sessionID)),
                colorHex: nil
            )
        }
        .sorted { $0.size > $1.size }
        return .init(clusters: clusters)
    }

    // MARK: - Focus matrices

    private func makeAgentFocusMatrix(sessions: [InsightSessionRow]) -> InsightWidgetData.FocusMatrix {
        let agents = Array(Set(sessions.map(\.provider))).sorted()
        let focuses = taxonomy.focuses
        var cells = Array(repeating: Array(repeating: 0.0, count: focuses.count), count: agents.count)
        for (rIdx, agent) in agents.enumerated() {
            let agentSessions = sessions.filter { $0.provider == agent }
            let total = max(1, agentSessions.count)
            for (cIdx, focus) in focuses.enumerated() {
                let count = agentSessions.filter { InsightDigestBuilder.inferFocus(session: $0, taxonomy: taxonomy) == focus }.count
                cells[rIdx][cIdx] = Double(count) / Double(total)
            }
        }
        return .init(rowLabels: agents, columnLabels: focuses, cells: cells)
    }

    private func makeModelFocusMatrix(sessions: [InsightSessionRow],
                                      usages: [InsightUsageRow]) -> InsightWidgetData.FocusMatrix {
        let sessionByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.sessionID, $0) })
        let models = Array(Set(usages.map(\.model))).sorted()
        let focuses = taxonomy.focuses
        var cells = Array(repeating: Array(repeating: 0.0, count: focuses.count), count: models.count)
        for (rIdx, model) in models.enumerated() {
            let modelUsages = usages.filter { $0.model == model }
            let modelSessions = modelUsages.compactMap { sessionByID[$0.sessionID] }
            let total = max(1, modelSessions.count)
            for (cIdx, focus) in focuses.enumerated() {
                let count = modelSessions.filter { InsightDigestBuilder.inferFocus(session: $0, taxonomy: taxonomy) == focus }.count
                cells[rIdx][cIdx] = Double(count) / Double(total)
            }
        }
        return .init(rowLabels: models, columnLabels: focuses, cells: cells)
    }

    // MARK: - Drilldown

    private func makeDrilldown(limit: Int,
                               sessions: [InsightSessionRow],
                               usages: [InsightUsageRow]) -> InsightWidgetData.Drilldown {
        let costBySession = Dictionary(grouping: usages, by: { "\($0.provider)|\($0.sessionID)" })
            .mapValues { $0.reduce(0) { $0 + $1.costUSD } }
        let tokensBySession = Dictionary(grouping: usages, by: { "\($0.provider)|\($0.sessionID)" })
            .mapValues { $0.reduce(0) { $0 + $1.totalTokens } }
        let sortedSessions = sessions.sorted { (lhs, rhs) -> Bool in
            let lk = "\(lhs.provider)|\(lhs.sessionID)"
            let rk = "\(rhs.provider)|\(rhs.sessionID)"
            return (costBySession[lk] ?? 0) > (costBySession[rk] ?? 0)
        }
        let rows = sortedSessions.prefix(max(1, limit)).map { s -> InsightWidgetData.Drilldown.Row in
            let key = "\(s.provider)|\(s.sessionID)"
            return .init(
                id: key,
                title: s.inferredTaskTitle ?? "Session \(s.sessionID.prefix(8))",
                subtitle: s.provider,
                occurredAt: s.startTime,
                costUSD: costBySession[key],
                tokens: tokensBySession[key],
                citation: .init(kind: .session(id: s.sessionID, provider: s.provider),
                                label: s.inferredTaskTitle ?? s.sessionID)
            )
        }
        return .init(rows: Array(rows))
    }
}
