import Foundation

// MARK: - Rhythm rules
//
// When the work happened: which days, which hours, how long the sessions ran,
// how many days in a row. These are the cards that answer "how did I work?" and
// they are usually the ones a person has never seen stated out loud.

enum RecapRhythmRules {

    static let all: [@Sendable (RecapContext) -> RecapCandidate?] = [
        weekdayPersonality,
        lateNightHabit,
        peakHour,
        weekendHabit,
        longestStreak,
        busiestWeek,
        busiestDay,
        longestSession,
        sessionLengthTrend,
        showUpRate
    ]

    // MARK: Weekday

    /// "Apparently Tuesday is build day."
    ///
    /// Gated on Cramér's V rather than "the biggest bar wins": with seven
    /// weekdays and a handful of sessions, one of them always leads.
    @Sendable static func weekdayPersonality(_ ctx: RecapContext) -> RecapCandidate? {
        let facts = ctx.facts
        guard facts.sessionCount >= 20 else { return nil }
        guard let effect = RecapStatistics.uniformityEffect(counts: facts.weekdaySessions),
              effect >= 0.12 else { return nil }
        guard let peakIndex = facts.weekdaySessions.indices.max(by: {
            (facts.weekdaySessions[$0], $1) < (facts.weekdaySessions[$1], $0)
        }) else { return nil }

        let peakCount = facts.weekdaySessions[peakIndex]
        let share = Double(peakCount) / Double(facts.sessionCount)
        guard share >= 0.2 else { return nil }

        let dayName = RecapRuleSupport.weekdayName(peakIndex, calendar: ctx.calendar)
        let plural = RecapRuleSupport.weekdayPlural(peakIndex, calendar: ctx.calendar)

        return RecapCandidate(
            id: "weekday-personality:\(peakIndex)",
            ruleID: "weekday-personality",
            family: "rhythm:weekday",
            kind: .personality,
            tone: .playful,
            headline: "Apparently \(dayName) is build day.",
            body: "\(RecapRuleSupport.approximateFraction(share).capitalizedFirst) of your sessions this month landed on \(plural).",
            metrics: [
                RecapMetric("Share of sessions", share, .percent),
                RecapMetric("Sessions", Double(peakCount), .count)
            ],
            comparison: RecapComparison(
                basis: .uniform,
                referenceLabel: "an even week",
                currentValue: share,
                referenceValue: 1.0 / 7.0,
                unit: .percent
            ),
            visual: .bars,
            visualData: .ranked(weekdayEntries(facts, calendar: ctx.calendar)),
            suggestedSize: .wide,
            novelty: 0.8,
            significance: effect,
            relevance: 0.75,
            confidence: ctx.confidence(sampleSize: facts.sessionCount)
        )
    }

    // MARK: Hours

    /// "Late-night builder."
    @Sendable static func lateNightHabit(_ ctx: RecapContext) -> RecapCandidate? {
        let facts = ctx.facts
        guard facts.sessionCount >= 15, facts.lateNightCostShare >= 0.15 else { return nil }

        let historyAverage = ctx.average(\.lateNightCostShare)
        let comparison = historyAverage.map { average in
            RecapComparison(
                basis: .personalAverage,
                referenceLabel: "your usual month",
                currentValue: facts.lateNightCostShare,
                referenceValue: average,
                unit: .percent
            )
        }

        // Interesting either because it is high, or because it is unusually
        // high *for them*.
        let againstSelf = historyAverage.map { abs(facts.lateNightCostShare - $0) } ?? 0
        let significance = max(
            RecapStatistics.significance(fromEffect: facts.lateNightCostShare, saturatingAt: 0.45),
            RecapStatistics.significance(fromEffect: againstSelf, saturatingAt: 0.15)
        )

        let isRecord = historyAverage.map { facts.lateNightCostShare > $0 * 1.25 } ?? false
        let body = isRecord
            ? "\(RecapRuleSupport.percent(facts.lateNightCostShare)) of your work happened after midnight — more than your usual month."
            : "\(RecapRuleSupport.percent(facts.lateNightCostShare)) of your work happened between midnight and 6am."

        return RecapCandidate(
            id: "late-night:\(ctx.window.key)",
            ruleID: "late-night",
            family: "rhythm:hours",
            kind: isRecord ? .trend : .personality,
            tone: .playful,
            headline: "Late-night builder.",
            body: body,
            metrics: [RecapMetric("After midnight", facts.lateNightCostShare, .percent)],
            comparison: comparison,
            visual: .heatmap,
            visualData: .matrix(facts.hourWeekdayCost),
            suggestedSize: .wide,
            novelty: historyAverage == nil ? 0.6 : 0.85,
            significance: significance,
            relevance: 0.8,
            confidence: ctx.confidence(sampleSize: facts.sessionCount)
        )
    }

    @Sendable static func peakHour(_ ctx: RecapContext) -> RecapCandidate? {
        let facts = ctx.facts
        guard facts.sessionCount >= 20, let hour = facts.peakHour else { return nil }
        guard let effect = RecapStatistics.uniformityEffect(
            weights: facts.hourCost, effectiveSampleSize: facts.sessionCount
        ), effect >= 0.10 else { return nil }

        let total = facts.hourCost.reduce(0, +)
        guard total > 0 else { return nil }
        let share = facts.hourCost[hour] / total

        return RecapCandidate(
            id: "peak-hour:\(hour)",
            ruleID: "peak-hour",
            family: "rhythm:hours",
            kind: .funFact,
            tone: .curious,
            headline: "Your hour is \(RecapRuleSupport.hourName(hour, calendar: ctx.calendar)).",
            body: "More of your month happened in that one hour than any other.",
            metrics: [
                RecapMetric("Share of spend", share, .percent),
                RecapMetric("Hour", Double(hour), .ordinal)
            ],
            visual: .bars,
            visualData: .series(facts.hourCost),
            suggestedSize: .small,
            novelty: 0.7,
            significance: effect,
            relevance: 0.5,
            confidence: ctx.confidence(sampleSize: facts.sessionCount)
        )
    }

    @Sendable static func weekendHabit(_ ctx: RecapContext) -> RecapCandidate? {
        let facts = ctx.facts
        guard facts.sessionCount >= 20 else { return nil }
        let share = facts.weekendCostShare
        // Two ways to be interesting: you work weekends, or you conspicuously
        // do not. The uninteresting middle is skipped.
        let isHigh = share >= 0.3
        let isLow = share <= 0.04
        guard isHigh || isLow else { return nil }

        return RecapCandidate(
            id: "weekend-habit:\(ctx.window.key)",
            ruleID: "weekend-habit",
            family: "rhythm:weekend",
            kind: .personality,
            tone: isHigh ? .curious : .celebratory,
            headline: isHigh ? "Weekends counted." : "You kept your weekends.",
            body: isHigh
                ? "\(RecapRuleSupport.percent(share)) of your work happened on Saturdays and Sundays."
                : "Barely \(RecapRuleSupport.percent(share)) of your work touched a weekend.",
            metrics: [RecapMetric("Weekend share", share, .percent)],
            comparison: ctx.average(\.weekendCostShare).map { average in
                RecapComparison(
                    basis: .personalAverage,
                    referenceLabel: "your usual month",
                    currentValue: share,
                    referenceValue: average,
                    unit: .percent
                )
            },
            visual: .bigNumber,
            suggestedSize: .small,
            novelty: 0.65,
            significance: RecapStatistics.significance(
                fromEffect: abs(share - 2.0 / 7.0), saturatingAt: 0.22
            ),
            relevance: 0.7,
            confidence: ctx.confidence(sampleSize: facts.sessionCount)
        )
    }

    // MARK: Streaks and stretches

    @Sendable static func longestStreak(_ ctx: RecapContext) -> RecapCandidate? {
        let facts = ctx.facts
        guard facts.longestActiveStreak >= 4 else { return nil }

        let best = ctx.allTimeBest(\.longestActiveStreakValue)
        let isRecord = ctx.allowsAbsoluteClaims
            && (best.map { Double(facts.longestActiveStreak) > $0.value } ?? false)

        let activeFlags = (0..<facts.dayCount).map { index in
            facts.dailySessions.indices.contains(index) && facts.dailySessions[index] > 0
        }

        return RecapCandidate(
            id: "streak:\(ctx.window.key)",
            ruleID: "streak",
            family: "rhythm:streak",
            kind: isRecord ? .record : .milestone,
            tone: .celebratory,
            headline: isRecord ? "Your longest run yet." : "You kept showing up.",
            body: isRecord
                ? "\(facts.longestActiveStreak) days in a row — longer than any streak before it."
                : "You worked with an agent \(facts.longestActiveStreak) days in a row.",
            metrics: [RecapMetric("Streak", Double(facts.longestActiveStreak), .days)],
            comparison: best.map { previous in
                RecapComparison(
                    basis: .allTimeRecord,
                    referenceLabel: "your previous best",
                    currentValue: Double(facts.longestActiveStreak),
                    referenceValue: previous.value,
                    unit: .days
                )
            },
            visual: .streak,
            visualData: .streak(activeFlags),
            suggestedSize: isRecord ? .hero : .wide,
            novelty: isRecord ? 0.95 : 0.6,
            significance: isRecord
                ? (RecapStatistics.recordMargin(
                    current: Double(facts.longestActiveStreak),
                    previousBest: best?.value ?? 0
                  ) ?? 0.6)
                : RecapStatistics.significance(
                    fromEffect: Double(facts.longestActiveStreak), saturatingAt: 14
                  ),
            relevance: 0.85,
            confidence: ctx.confidence(sampleSize: facts.sessionCount)
        )
    }

    /// "You were on a roll." — the busiest seven-day stretch.
    @Sendable static func busiestWeek(_ ctx: RecapContext) -> RecapCandidate? {
        let facts = ctx.facts
        guard ctx.allowsAbsoluteClaims,
              facts.sessionCount >= 15,
              let week = facts.busiestWeek,
              week.costUSD > 0 else { return nil }

        // Only a story if that week genuinely outran the rest of the month.
        let monthlyAverageWeek = facts.totalCostUSD / Double(max(1, facts.dayCount)) * 7
        guard monthlyAverageWeek > 0 else { return nil }
        let lift = (week.costUSD - monthlyAverageWeek) / monthlyAverageWeek
        guard lift >= 0.25 else { return nil }

        let range = RecapRuleSupport.dayRange(
            from: week.startDate, to: week.endDate, calendar: ctx.calendar
        )
        let best = ctx.allTimeBest(\.busiestWeekCost)
        let isRecord = best.map { week.costUSD > $0.value } ?? false

        return RecapCandidate(
            id: "busiest-week:\(ctx.window.key)",
            ruleID: "busiest-week",
            family: "rhythm:peak",
            kind: isRecord ? .record : .milestone,
            tone: .celebratory,
            headline: "You were on a roll.",
            body: isRecord
                ? "\(range) was your busiest week ever — \(RecapRuleSupport.deltaPhrase(lift)) on your usual pace."
                : "\(range) was your busiest stretch of the month, \(RecapRuleSupport.deltaPhrase(lift)) on your usual pace.",
            metrics: [
                RecapMetric("That week", week.costUSD, .usd),
                RecapMetric("Sessions", Double(week.sessions), .count)
            ],
            comparison: best.map { previous in
                RecapComparison(
                    basis: .allTimeRecord,
                    referenceLabel: "your previous best week",
                    currentValue: week.costUSD,
                    referenceValue: previous.value,
                    unit: .usd
                )
            },
            visual: .timeline,
            visualData: .series(facts.dailyCost),
            suggestedSize: .hero,
            novelty: isRecord ? 0.95 : 0.7,
            significance: RecapStatistics.significance(fromEffect: lift, saturatingAt: 1.0),
            relevance: 0.9,
            confidence: ctx.confidence(sampleSize: week.sessions, full: 20)
        )
    }

    @Sendable static func busiestDay(_ ctx: RecapContext) -> RecapCandidate? {
        let facts = ctx.facts
        guard ctx.allowsAbsoluteClaims,
              facts.activeDayCount >= 5,
              let day = facts.busiestDay,
              day.costUSD > 0, day.sessions >= 2 else { return nil }

        let averageActiveDay = facts.totalCostUSD / Double(max(1, facts.activeDayCount))
        guard averageActiveDay > 0 else { return nil }
        let multiple = day.costUSD / averageActiveDay
        guard multiple >= 2 else { return nil }

        return RecapCandidate(
            id: "busiest-day:\(ctx.window.key)",
            ruleID: "busiest-day",
            family: "rhythm:peak",
            kind: .funFact,
            tone: .curious,
            headline: "One day did a lot of the lifting.",
            body: "\(RecapRuleSupport.dayLabel(day.date, calendar: ctx.calendar)) carried \(String(format: "%.1f", multiple))× your average day, across \(day.sessions) sessions.",
            metrics: [
                RecapMetric("That day", day.costUSD, .usd),
                RecapMetric("Sessions", Double(day.sessions), .count)
            ],
            visual: .sparkline,
            visualData: .series(facts.dailyCost),
            suggestedSize: .small,
            novelty: 0.6,
            significance: RecapStatistics.significance(fromEffect: multiple - 1, saturatingAt: 3),
            relevance: 0.55,
            confidence: ctx.confidence(sampleSize: facts.sessionCount)
        )
    }

    @Sendable static func longestSession(_ ctx: RecapContext) -> RecapCandidate? {
        let facts = ctx.facts
        guard ctx.allowsAbsoluteClaims,
              let session = facts.longestSession,
              session.durationSeconds >= 45 * 60 else { return nil }

        let best = ctx.allTimeBest(\.longestSessionSeconds)
        let isRecord = best.map { session.durationSeconds > $0.value } ?? false
        let where_ = session.projectName.map { " on \($0)" } ?? ""

        return RecapCandidate(
            id: "longest-session:\(ctx.window.key)",
            ruleID: "longest-session",
            family: "session:length",
            kind: isRecord ? .record : .milestone,
            tone: .celebratory,
            headline: isRecord ? "Your longest run ever." : "The long haul.",
            body: "One session ran \(RecapRuleSupport.duration(seconds: session.durationSeconds))\(where_), with \(session.model).",
            metrics: [
                RecapMetric("Duration", session.durationSeconds / 3600, .hours),
                RecapMetric("Cost", session.costUSD, .usd)
            ],
            comparison: best.map { previous in
                RecapComparison(
                    basis: .allTimeRecord,
                    referenceLabel: "your previous longest",
                    currentValue: session.durationSeconds / 3600,
                    referenceValue: previous.value / 3600,
                    unit: .hours
                )
            },
            visual: .bigNumber,
            suggestedSize: isRecord ? .wide : .small,
            novelty: isRecord ? 0.9 : 0.55,
            significance: isRecord
                ? (RecapStatistics.recordMargin(
                    current: session.durationSeconds, previousBest: best?.value ?? 0
                  ) ?? 0.6)
                : RecapStatistics.significance(
                    fromEffect: session.durationSeconds, saturatingAt: 4 * 3600
                  ),
            relevance: 0.7,
            confidence: ctx.confidence(sampleSize: facts.sessionCount)
        )
    }

    @Sendable static func sessionLengthTrend(_ ctx: RecapContext) -> RecapCandidate? {
        guard let previous = ctx.previousMonth,
              ctx.facts.sessionStats.count >= 10,
              previous.sessionStats.count >= 10 else { return nil }

        let current = ctx.facts.sessionStats.medianSeconds
        let prior = previous.sessionStats.medianSeconds
        guard prior > 0, current > 0 else { return nil }
        let delta = (current - prior) / prior
        guard abs(delta) >= 0.2 else { return nil }

        let longer = delta > 0
        let previousLabel = previous.window.monthLabel(calendar: ctx.calendar)

        return RecapCandidate(
            id: "session-length-trend:\(ctx.window.key)",
            ruleID: "session-length-trend",
            family: "session:length",
            kind: .trend,
            tone: .reflective,
            headline: longer ? "Your sessions got longer." : "Shorter, sharper sessions.",
            body: "A typical session ran \(RecapRuleSupport.duration(seconds: current)), \(RecapRuleSupport.deltaPhrase(delta)) on \(previousLabel).",
            metrics: [
                RecapMetric("Typical session", current / 60, .minutes),
                RecapMetric(previousLabel, prior / 60, .minutes)
            ],
            comparison: RecapComparison(
                basis: .previousMonth,
                referenceLabel: previousLabel,
                currentValue: current / 60,
                referenceValue: prior / 60,
                unit: .minutes
            ),
            visual: .beforeAfter,
            visualData: .pair(before: prior / 60, after: current / 60),
            suggestedSize: .wide,
            novelty: 0.75,
            significance: RecapStatistics.significance(fromEffect: abs(delta), saturatingAt: 0.6),
            relevance: 0.7,
            confidence: ctx.confidence(
                sampleSize: min(ctx.facts.sessionStats.count, previous.sessionStats.count)
            )
        )
    }

    @Sendable static func showUpRate(_ ctx: RecapContext) -> RecapCandidate? {
        let facts = ctx.facts
        guard ctx.allowsAbsoluteClaims, facts.activeDayCount >= 8 else { return nil }
        let rate = Double(facts.activeDayCount) / Double(max(1, facts.dayCount))
        guard rate >= 0.5 else { return nil }

        let best = ctx.allTimeBest(\.activeDayRate)
        let isRecord = best.map { rate > $0.value } ?? false

        return RecapCandidate(
            id: "show-up-rate:\(ctx.window.key)",
            ruleID: "show-up-rate",
            family: "rhythm:streak",
            kind: isRecord ? .record : .milestone,
            tone: .celebratory,
            headline: isRecord ? "Your most consistent month." : "You showed up.",
            body: "\(facts.activeDayCount) of \(facts.dayCount) days had agent work in them.",
            metrics: [
                RecapMetric("Active days", Double(facts.activeDayCount), .days),
                RecapMetric("Of the month", rate, .percent)
            ],
            comparison: best.map { previous in
                RecapComparison(
                    basis: .allTimeRecord,
                    referenceLabel: "your previous best",
                    currentValue: rate,
                    referenceValue: previous.value,
                    unit: .percent
                )
            },
            visual: .streak,
            visualData: .streak((0..<facts.dayCount).map {
                facts.dailySessions.indices.contains($0) && facts.dailySessions[$0] > 0
            }),
            suggestedSize: .wide,
            novelty: isRecord ? 0.9 : 0.5,
            significance: RecapStatistics.significance(fromEffect: rate, saturatingAt: 0.9),
            relevance: 0.8,
            confidence: ctx.confidence(sampleSize: facts.sessionCount)
        )
    }

    // MARK: - Helpers

    private static func weekdayEntries(_ facts: RecapFacts, calendar: Calendar) -> [RecapRankedEntry] {
        let maximum = Double(facts.weekdaySessions.max() ?? 0)
        guard maximum > 0 else { return [] }
        let names = RecapRuleSupport.weekdayNames(calendar: calendar)
        return facts.weekdaySessions.indices.map { index in
            RecapRankedEntry(
                key: "weekday-\(index)",
                label: names.indices.contains(index) ? names[index] : "that day",
                value: Double(facts.weekdaySessions[index]),
                fraction: Double(facts.weekdaySessions[index]) / maximum
            )
        }
    }
}

// MARK: - Metric key paths used for all-time records

extension RecapFacts {
    var longestActiveStreakValue: Double { Double(longestActiveStreak) }
    var busiestWeekCost: Double { busiestWeek?.costUSD ?? 0 }
    var longestSessionSeconds: Double { longestSession?.durationSeconds ?? 0 }
    var activeDayRate: Double { Double(activeDayCount) / Double(max(1, dayCount)) }
}

private extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return String(first).uppercased() + dropFirst()
    }
}
