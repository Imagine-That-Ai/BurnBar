import Foundation

// MARK: - The fold
//
// One pure function from rows to facts. No `Date()`, no `UUID()`, no I/O, so
// the same rows always produce the same facts — which is what lets the deck be
// snapshot-tested and lets a stored month be trusted months later.

public extension RecapFacts {

    /// Folds one month of rows into the month's facts.
    ///
    /// Bucketing is calendar-local: SQLite's `strftime` is UTC, so anything
    /// that folds by day or hour has to go through `Calendar`, not string math.
    static func build(
        batch: RecapRowBatch,
        builtAt: Date,
        calendar: Calendar = .current
    ) -> RecapFacts {
        let window = batch.window
        let dayCount = window.dayCount(calendar: calendar)
        // Hoisted once: `contains`/`dayIndex` each rebuild the month from
        // `DateComponents`, and this loop runs per usage row — tens of
        // thousands of times during a history backfill.
        let (monthStart, monthEnd) = window.bounds(calendar: calendar)

        var dailyCost = [Double](repeating: 0, count: dayCount)
        var dailyTokens = [Int](repeating: 0, count: dayCount)
        var dailySessions = [Int](repeating: 0, count: dayCount)
        var hourWeekdayCost = [[Double]](repeating: [Double](repeating: 0, count: 24), count: 7)
        var hourCost = [Double](repeating: 0, count: 24)
        var weekdayCost = [Double](repeating: 0, count: 7)
        var weekdaySessions = [Int](repeating: 0, count: 7)

        var totalCost = 0.0
        var totalTokens = 0
        var inputTokens = 0
        var outputTokens = 0
        var reasoningTokens = 0
        var cacheReadTokens = 0
        var cacheCreationTokens = 0

        var modelAcc: [String: DimensionAccumulator] = [:]
        var providerAcc: [String: DimensionAccumulator] = [:]
        var projectAcc: [String: DimensionAccumulator] = [:]
        var pairingAcc: [String: DimensionAccumulator] = [:]
        var sessionAcc: [String: SessionAccumulator] = [:]

        for row in batch.usages {
            guard row.startTime >= monthStart, row.startTime < monthEnd else { continue }
            // One `dateComponents` call rather than three separate `component`
            // lookups — the same three fields, a fraction of the work.
            let parts = calendar.dateComponents([.day, .weekday, .hour], from: row.startTime)
            let dayIndex = (parts.day ?? 1) - 1
            guard dayIndex >= 0, dayIndex < dayCount else { continue }

            let cost = row.costUSD.isFinite ? max(0, row.costUSD) : 0
            let tokens = max(0, row.totalTokens)
            let weekdayIndex = max(0, min(6, (parts.weekday ?? 1) - 1))
            let hour = max(0, min(23, parts.hour ?? 0))

            dailyCost[dayIndex] += cost
            dailyTokens[dayIndex] += tokens
            hourWeekdayCost[weekdayIndex][hour] += cost
            hourCost[hour] += cost
            weekdayCost[weekdayIndex] += cost

            totalCost += cost
            totalTokens += tokens
            inputTokens += max(0, row.inputTokens)
            outputTokens += max(0, row.outputTokens)
            reasoningTokens += max(0, row.reasoningTokens)
            cacheReadTokens += max(0, row.cacheReadTokens)
            cacheCreationTokens += max(0, row.cacheCreationTokens)

            let sessionKey = "\(row.provider)|\(row.sessionID)"
            let modelKey = normalizedKey(row.model)
            let providerKey = normalizedKey(row.provider)
            let projectKey = row.projectName.flatMap { $0.isEmpty ? nil : $0 }

            modelAcc[modelKey, default: .init(label: row.model)].add(
                cost: cost, tokens: tokens, sessionKey: sessionKey
            )
            providerAcc[providerKey, default: .init(label: row.provider)].add(
                cost: cost, tokens: tokens, sessionKey: sessionKey
            )
            if let projectKey {
                projectAcc[projectKey, default: .init(label: projectKey)].add(
                    cost: cost, tokens: tokens, sessionKey: sessionKey
                )
            }
            let pairKey = "\(modelKey)\(Self.pairingSeparator)\(providerKey)"
            pairingAcc[pairKey, default: .init(label: "\(row.model) on \(row.provider)")].add(
                cost: cost, tokens: tokens, sessionKey: sessionKey
            )

            sessionAcc[sessionKey, default: .init(
                sessionID: row.sessionID, providerKey: row.provider
            )].add(row: row, cost: cost, tokens: tokens)
        }

        // Sessions land on the day they started, so a session that runs past
        // midnight is counted once — on the day the person started working.
        for session in sessionAcc.values {
            guard session.startTime >= monthStart, session.startTime < monthEnd else { continue }
            let parts = calendar.dateComponents([.day, .weekday], from: session.startTime)
            let dayIndex = (parts.day ?? 1) - 1
            guard dayIndex >= 0, dayIndex < dayCount else { continue }
            dailySessions[dayIndex] += 1
            weekdaySessions[max(0, min(6, (parts.weekday ?? 1) - 1))] += 1
        }

        let sessionCount = sessionAcc.count
        let activeFlags = (0..<dayCount).map {
            dailyCost[$0] > 0 || dailyTokens[$0] > 0 || dailySessions[$0] > 0
        }
        let activeDayCount = activeFlags.filter { $0 }.count

        // Ranked dimensions
        let models = rank(modelAcc, totalCost: totalCost, totalSessions: sessionCount)
        let providers = rank(providerAcc, totalCost: totalCost, totalSessions: sessionCount)
        let projects = rank(projectAcc, totalCost: totalCost, totalSessions: sessionCount)
        let pairings = rank(pairingAcc, totalCost: totalCost, totalSessions: sessionCount)

        // Tools: how many sessions mentioned each tool. Only meaningful when the
        // platform can actually see conversations.
        let tools = rankTools(batch.sessions)

        // Session shape
        let durations = sessionAcc.values.map(\.durationSeconds).sorted()
        let costs = sessionAcc.values.map(\.costUSD).sorted()
        let sessionStats = RecapSessionStats(
            count: sessionCount,
            medianSeconds: percentile(durations, 0.5),
            p90Seconds: percentile(durations, 0.9),
            meanSeconds: durations.isEmpty ? 0 : durations.reduce(0, +) / Double(durations.count),
            totalSeconds: durations.reduce(0, +),
            medianCostUSD: percentile(costs, 0.5)
        )

        let longestSession = sessionAcc.values
            .max { lhs, rhs in
                (lhs.durationSeconds, lhs.sessionID) < (rhs.durationSeconds, rhs.sessionID)
            }
            .map { $0.highlight() }
        let busiestDay = busiestDayHighlight(
            dailyCost: dailyCost,
            dailyTokens: dailyTokens,
            dailySessions: dailySessions,
            monthStart: monthStart,
            calendar: calendar
        )
        let busiestWeek = busiestWeekHighlight(
            dailyCost: dailyCost,
            dailySessions: dailySessions,
            monthStart: monthStart,
            calendar: calendar
        )

        let peakHour = hourCost.contains { $0 > 0 } ? indexOfMax(hourCost) : nil
        let peakWeekday = weekdayCost.contains { $0 > 0 } ? indexOfMax(weekdayCost) : nil

        // Ratios
        let promptBasis = inputTokens + cacheCreationTokens + cacheReadTokens
        let cacheHitRate = promptBasis > 0 ? Double(cacheReadTokens) / Double(promptBasis) : 0
        let modelConcentration = models.reduce(0) { $0 + ($1.costShare * $1.costShare) }
        let weekendCost = weekdayCost[0] + weekdayCost[6]
        let weekendCostShare = totalCost > 0 ? weekendCost / totalCost : 0

        func hourBandShare(_ range: Range<Int>) -> Double {
            guard totalCost > 0 else { return 0 }
            return range.reduce(0.0) { $0 + hourCost[$1] } / totalCost
        }

        return RecapFacts(
            window: window,
            builtAt: builtAt,
            isPartial: batch.isPartial,
            hasSessionData: batch.hasSessionData,
            exactShare: batch.exactShare,
            totalCostUSD: totalCost,
            totalTokens: totalTokens,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            reasoningTokens: reasoningTokens,
            cacheReadTokens: cacheReadTokens,
            cacheCreationTokens: cacheCreationTokens,
            sessionCount: sessionCount,
            activeDayCount: activeDayCount,
            dayCount: dayCount,
            dailyCost: dailyCost,
            dailyTokens: dailyTokens,
            dailySessions: dailySessions,
            hourWeekdayCost: hourWeekdayCost,
            hourCost: hourCost,
            weekdayCost: weekdayCost,
            weekdaySessions: weekdaySessions,
            models: models,
            providers: providers,
            projects: projects,
            pairings: pairings,
            tools: tools,
            sessionStats: sessionStats,
            longestSession: longestSession,
            busiestDay: busiestDay,
            busiestWeek: busiestWeek,
            peakHour: peakHour,
            peakWeekday: peakWeekday,
            longestActiveStreak: longestStreak(activeFlags),
            modelKeys: modelAcc.keys.sorted(),
            providerKeys: providerAcc.keys.sorted(),
            projectKeys: projectAcc.keys.sorted(),
            toolKeys: tools.map(\.name).sorted(),
            cacheHitRate: cacheHitRate,
            modelConcentration: modelConcentration,
            weekendCostShare: weekendCostShare,
            lateNightCostShare: hourBandShare(0..<6),
            morningCostShare: hourBandShare(6..<12),
            eveningCostShare: hourBandShare(18..<24)
        )
    }

    /// Separator between the model and harness halves of a pairing key.
    static var pairingSeparator: String { " ⨯ " }

    /// Splits a pairing key back into its two halves.
    static func splitPairingKey(_ key: String) -> (model: String, provider: String)? {
        let parts = key.components(separatedBy: pairingSeparator)
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }
}

// MARK: - Accumulators

private struct DimensionAccumulator {
    let label: String
    var cost: Double = 0
    var tokens: Int = 0
    var sessionKeys: Set<String> = []

    mutating func add(cost: Double, tokens: Int, sessionKey: String) {
        self.cost += cost
        self.tokens += tokens
        sessionKeys.insert(sessionKey)
    }
}

private struct SessionAccumulator {
    let sessionID: String
    let providerKey: String
    var startTime: Date = .distantFuture
    var endTime: Date = .distantPast
    var costUSD: Double = 0
    var tokens: Int = 0
    var projectName: String?
    /// Cost per model, so the session's headline model is the one that did the
    /// work rather than whichever row happened to be first.
    var costByModel: [String: Double] = [:]

    mutating func add(row: InsightUsageRow, cost: Double, tokens: Int) {
        startTime = min(startTime, row.startTime)
        endTime = max(endTime, max(row.startTime, row.endTime))
        costUSD += cost
        self.tokens += tokens
        costByModel[row.model, default: 0] += cost
        if projectName == nil, let name = row.projectName, !name.isEmpty {
            projectName = name
        }
    }

    var durationSeconds: Double {
        guard endTime > startTime else { return 0 }
        return endTime.timeIntervalSince(startTime)
    }

    var dominantModel: String {
        costByModel.max { lhs, rhs in (lhs.value, lhs.key) < (rhs.value, rhs.key) }?.key ?? ""
    }

    func highlight() -> RecapSessionHighlight {
        RecapSessionHighlight(
            sessionID: sessionID,
            projectName: projectName,
            model: dominantModel,
            providerKey: providerKey,
            startTime: startTime,
            durationSeconds: durationSeconds,
            costUSD: costUSD,
            tokens: tokens
        )
    }
}

// MARK: - Helpers

private func normalizedKey(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

private func rank(
    _ accumulators: [String: DimensionAccumulator],
    totalCost: Double,
    totalSessions: Int
) -> [RecapShare] {
    accumulators
        .map { key, acc in
            RecapShare(
                key: key,
                label: acc.label,
                costUSD: acc.cost,
                tokens: acc.tokens,
                sessions: acc.sessionKeys.count,
                costShare: totalCost > 0 ? acc.cost / totalCost : 0,
                sessionShare: totalSessions > 0
                    ? Double(acc.sessionKeys.count) / Double(totalSessions)
                    : 0
            )
        }
        // Cost descending, then key ascending — a total order, so equal-cost
        // entries can never reorder between runs.
        .sorted { lhs, rhs in
            lhs.costUSD == rhs.costUSD ? lhs.key < rhs.key : lhs.costUSD > rhs.costUSD
        }
}

private func rankTools(_ sessions: [InsightSessionRow]) -> [RecapCount] {
    guard !sessions.isEmpty else { return [] }
    var counts: [String: Int] = [:]
    for session in sessions {
        // Distinct per session: a session that called `grep` forty times counts
        // once, so the ranking reflects reach rather than chattiness.
        for tool in Set(session.keyTools) where !tool.isEmpty {
            counts[tool, default: 0] += 1
        }
    }
    let denominator = Double(sessions.count)
    return counts
        .map { RecapCount(name: $0.key, count: $0.value, share: Double($0.value) / denominator) }
        .sorted { lhs, rhs in
            lhs.count == rhs.count ? lhs.name < rhs.name : lhs.count > rhs.count
        }
}

/// Linear-interpolated percentile over a pre-sorted array.
private func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    guard sorted.count > 1 else { return sorted[0] }
    let position = fraction * Double(sorted.count - 1)
    let lower = Int(position.rounded(.down))
    let upper = min(lower + 1, sorted.count - 1)
    let weight = position - Double(lower)
    return sorted[lower] + (sorted[upper] - sorted[lower]) * weight
}

private func indexOfMax(_ values: [Double]) -> Int? {
    guard !values.isEmpty else { return nil }
    var best = 0
    for index in values.indices where values[index] > values[best] { best = index }
    return values[best] > 0 ? best : nil
}

private func longestStreak(_ flags: [Bool]) -> Int {
    var best = 0
    var run = 0
    for flag in flags {
        run = flag ? run + 1 : 0
        best = max(best, run)
    }
    return best
}

private func busiestDayHighlight(
    dailyCost: [Double],
    dailyTokens: [Int],
    dailySessions: [Int],
    monthStart: Date,
    calendar: Calendar
) -> RecapDayHighlight? {
    guard let index = indexOfMax(dailyCost),
          let date = calendar.date(byAdding: .day, value: index, to: monthStart) else { return nil }
    return RecapDayHighlight(
        dayIndex: index,
        date: date,
        costUSD: dailyCost[index],
        tokens: dailyTokens[index],
        sessions: dailySessions[index]
    )
}

/// Sliding seven-day window, not a calendar week — "August 8–14" is how a
/// person describes their busiest stretch, and calendar weeks would clip it at
/// an arbitrary Sunday.
private func busiestWeekHighlight(
    dailyCost: [Double],
    dailySessions: [Int],
    monthStart: Date,
    calendar: Calendar
) -> RecapWeekHighlight? {
    let dayCount = dailyCost.count
    guard dayCount >= 7 else { return nil }

    var windowSum = dailyCost.prefix(7).reduce(0, +)
    var bestSum = windowSum
    var bestStart = 0
    for start in 1...(dayCount - 7) {
        windowSum += dailyCost[start + 6] - dailyCost[start - 1]
        if windowSum > bestSum {
            bestSum = windowSum
            bestStart = start
        }
    }
    guard bestSum > 0 else { return nil }

    let endIndex = bestStart + 6
    guard let startDate = calendar.date(byAdding: .day, value: bestStart, to: monthStart),
          let endDate = calendar.date(byAdding: .day, value: endIndex, to: monthStart) else { return nil }

    return RecapWeekHighlight(
        startDayIndex: bestStart,
        endDayIndex: endIndex,
        startDate: startDate,
        endDate: endDate,
        costUSD: bestSum,
        sessions: dailySessions[bestStart...endIndex].reduce(0, +)
    )
}
