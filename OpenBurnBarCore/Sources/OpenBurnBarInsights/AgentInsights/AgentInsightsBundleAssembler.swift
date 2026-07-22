import Foundation

/// Pure, deterministic conversion of (snapshot + analysis + canvases + audit)
/// into `AgentInsightsBundle`.
///
/// No I/O, no platform code, no side effects. Each platform shell plugs its
/// own data source into a `AgentInsightsBundleProducer` that ultimately
/// hands those inputs to `assemble`. That keeps the visible Insights surface
/// identical across iOS, iPad, macOS, and Android.
public enum AgentInsightsBundleAssembler {

    public static func assemble(
        scope: AgentInsightsScope,
        snapshot: InsightDataSnapshot,
        previousWindowSnapshot: InsightDataSnapshot? = nil,
        canvases: [InsightCanvas] = [],
        analysis: InsightAnalysisResult? = nil,
        auditEntries: [InsightAnalysisAuditEntry] = [],
        now: Date = Date()
    ) -> AgentInsightsBundle {
        let scopedUsages = snapshot.usages.filter { scope.matches(providerToken: $0.provider) }
        let scopedSessions = snapshot.sessions.filter { scope.matches(providerToken: $0.provider) }
        let scopedPrevUsages = previousWindowSnapshot?.usages.filter {
            scope.matches(providerToken: $0.provider)
        }

        let header = makeHeader(
            scope: scope,
            usages: scopedUsages,
            sessions: scopedSessions,
            now: now
        )
        let kpis = makeKPIStrip(
            current: scopedUsages,
            previous: scopedPrevUsages,
            analysis: analysis
        )
        return AgentInsightsBundle(
            scope: scope,
            header: header,
            kpis: kpis,
            brief: analysis,
            canvases: filterCanvases(canvases, scope: scope),
            missions: rankMissions(analysis?.missionCandidates ?? []),
            auditTrail: trimAuditEntries(auditEntries),
            generatedAt: now
        )
    }

    // MARK: - Header

    static func makeHeader(
        scope: AgentInsightsScope,
        usages: [InsightUsageRow],
        sessions: [InsightSessionRow],
        now: Date
    ) -> AgentInsightsHeader {
        let lastSeen = mostRecent(usages: usages, sessions: sessions)
        let status = status(for: lastSeen, now: now)
        let lineup = modelLineup(from: usages)
        let subtitle = lineup.first.map { "Top model: \($0)" } ?? subtitleFallback(status)

        if let provider = scope.provider {
            return AgentInsightsHeader(
                provider: provider,
                title: provider.displayName,
                subtitle: subtitle,
                symbolName: provider.iconName,
                status: status,
                lastSeen: lastSeen,
                modelLineup: lineup
            )
        }
        return AgentInsightsHeader(
            provider: nil,
            title: "All agents",
            subtitle: subtitle,
            symbolName: "rectangle.stack.fill",
            status: status,
            lastSeen: lastSeen,
            modelLineup: lineup
        )
    }

    static func status(for lastSeen: Date?, now: Date) -> AgentInsightsHeader.Status {
        guard let lastSeen else { return .unconfigured }
        let interval = now.timeIntervalSince(lastSeen)
        if interval < 86_400 { return .active }
        if interval < 7 * 86_400 { return .idle }
        return .dormant
    }

    private static func subtitleFallback(_ status: AgentInsightsHeader.Status) -> String {
        switch status {
        case .active: return "Active in the last 24 hours"
        case .idle: return "Quiet but active this week"
        case .dormant: return "No signal in over a week"
        case .unconfigured: return "Not connected yet"
        }
    }

    private static func mostRecent(
        usages: [InsightUsageRow],
        sessions: [InsightSessionRow]
    ) -> Date? {
        let usageMax = usages.map(\.endTime).max()
        let sessionMax = sessions.map(\.endTime).max()
        switch (usageMax, sessionMax) {
        case let (u?, s?): return max(u, s)
        case let (u?, nil): return u
        case let (nil, s?): return s
        default: return nil
        }
    }

    static func modelLineup(from usages: [InsightUsageRow]) -> [String] {
        var byModel: [String: Int] = [:]
        for row in usages {
            let key = row.model.isEmpty ? "—" : row.model
            byModel[key, default: 0] += max(0, row.totalTokens)
        }
        return byModel
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .prefix(3)
            .map(\.key)
    }

    // MARK: - KPIs

    static func makeKPIStrip(
        current: [InsightUsageRow],
        previous: [InsightUsageRow]?,
        analysis: InsightAnalysisResult?
    ) -> AgentInsightsKPIStrip {
        let curSpend = current.reduce(0.0) { $0 + $1.costUSD }
        let curTokens = current.reduce(0) { $0 + $1.totalTokens }
        let curSessions = Set(current.map(\.sessionID)).count

        let prevSpend = previous?.reduce(0.0) { $0 + $1.costUSD } ?? 0
        let prevTokens = previous?.reduce(0) { $0 + $1.totalTokens } ?? 0
        let prevSessions = Set(previous?.map(\.sessionID) ?? []).count

        let anomalyRaw = (analysis?.anomalies.map(\.score).max()) ?? 0

        return AgentInsightsKPIStrip(
            spend: makeKPI(
                id: "spend",
                label: "Spend",
                valueText: formatUSD(curSpend),
                comparable: previous == nil ? nil : (curSpend, prevSpend),
                raw: curSpend,
                symbolName: "dollarsign.circle"
            ),
            tokens: makeKPI(
                id: "tokens",
                label: "Tokens",
                valueText: formatCompact(Double(curTokens)),
                comparable: previous == nil ? nil : (Double(curTokens), Double(prevTokens)),
                raw: Double(curTokens),
                symbolName: "sum"
            ),
            sessions: makeKPI(
                id: "sessions",
                label: "Sessions",
                valueText: formatCompact(Double(curSessions)),
                comparable: previous == nil ? nil : (Double(curSessions), Double(prevSessions)),
                raw: Double(curSessions),
                symbolName: "person.2.wave.2"
            ),
            anomalyScore: makeKPI(
                id: "anomaly",
                label: "Anomaly",
                valueText: formatAnomaly(anomalyRaw),
                comparable: nil,
                raw: anomalyRaw,
                symbolName: "exclamationmark.triangle"
            )
        )
    }

    private static func makeKPI(
        id: String,
        label: String,
        valueText: String,
        comparable: (current: Double, previous: Double)?,
        raw: Double,
        symbolName: String
    ) -> AgentInsightsKPIStrip.KPI {
        let trend = comparable.map(trend(current:previous:)) ?? (nil, .flat)
        return AgentInsightsKPIStrip.KPI(
            id: id,
            label: label,
            valueText: valueText,
            trendText: trend.0,
            trendDirection: trend.1,
            raw: raw,
            symbolName: symbolName
        )
    }

    private static func trend(
        current: Double,
        previous: Double
    ) -> (String?, AgentInsightsKPIStrip.KPI.TrendDirection) {
        guard previous > 0 else {
            return (current > 0 ? "New activity" : nil, .flat)
        }
        let pct = ((current - previous) / previous) * 100
        if abs(pct) < 1 { return ("Flat", .flat) }
        let sign = pct > 0 ? "+" : ""
        return (String(format: "%@%.0f%% vs prior", sign, pct), pct > 0 ? .up : .down)
    }

    static func formatUSD(_ value: Double) -> String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .currency
        fmt.currencyCode = "USD"
        fmt.maximumFractionDigits = value < 10 ? 2 : 0
        return fmt.string(from: NSNumber(value: value)) ?? "$\(value)"
    }

    static func formatCompact(_ value: Double) -> String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        fmt.maximumFractionDigits = 1
        if value >= 1_000_000_000 {
            return (fmt.string(from: NSNumber(value: value / 1_000_000_000)) ?? "0") + "B"
        }
        if value >= 1_000_000 {
            return (fmt.string(from: NSNumber(value: value / 1_000_000)) ?? "0") + "M"
        }
        if value >= 1_000 {
            return (fmt.string(from: NSNumber(value: value / 1_000)) ?? "0") + "K"
        }
        fmt.maximumFractionDigits = 0
        return fmt.string(from: NSNumber(value: value)) ?? "0"
    }

    static func formatAnomaly(_ value: Double) -> String {
        if value <= 0 { return "None" }
        let clamped = min(max(value, 0), 1)
        return String(format: "%.0f / 100", clamped * 100)
    }

    // MARK: - Canvas / mission / audit filtering

    static func filterCanvases(
        _ canvases: [InsightCanvas],
        scope: AgentInsightsScope
    ) -> [InsightCanvas] {
        let sorted: (InsightCanvas, InsightCanvas) -> Bool = { lhs, rhs in
            if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
            return lhs.updatedAt > rhs.updatedAt
        }
        guard let provider = scope.provider else {
            return canvases.sorted(by: sorted)
        }
        let token = provider.rawValue
        let scoped = canvases.filter { $0.filter.providers.contains(token) }
        if !scoped.isEmpty {
            return scoped.sorted(by: sorted)
        }
        // Fallback: surface unscoped (shared) canvases so every agent
        // surface still has something to render.
        return canvases
            .filter { $0.filter.providers.isEmpty }
            .sorted(by: sorted)
    }

    static func rankMissions(
        _ missions: [InsightMissionCandidate]
    ) -> [InsightMissionCandidate] {
        missions.sorted { lhs, rhs in
            priorityRank(lhs.priority) > priorityRank(rhs.priority)
        }
    }

    private static func priorityRank(_ priority: InsightMissionCandidate.Priority) -> Int {
        switch priority {
        case .critical: return 4
        case .high: return 3
        case .medium: return 2
        case .low: return 1
        }
    }

    static func trimAuditEntries(
        _ entries: [InsightAnalysisAuditEntry]
    ) -> [InsightAnalysisAuditEntry] {
        Array(entries.sorted { $0.ranAt > $1.ranAt }.prefix(50))
    }
}
