import Foundation

// MARK: - Economy rules
//
// Cost, tokens, cache. The trap here is the metrics dump — "you spent $412 and
// used 91M tokens" tells a person nothing they can act on or feel. Every rule
// below frames its number against something: last month, their own average, or
// a record. A bare total only ships as part of the closing summary.

enum RecapEconomyRules {

    static let all: [@Sendable (RecapContext) -> RecapCandidate?] = [
        spendShift,
        spendRecord,
        cacheEfficiency,
        costPerSessionShift,
        thinkingShare,
        volumeMilestone
    ]

    // MARK: Spend

    @Sendable static func spendShift(_ ctx: RecapContext) -> RecapCandidate? {
        guard ctx.allowsAbsoluteClaims,
              let previous = ctx.previousMonth,
              previous.totalCostUSD > 1,
              ctx.facts.totalCostUSD > 1 else { return nil }

        let current = ctx.facts.totalCostUSD
        let prior = previous.totalCostUSD
        let delta = (current - prior) / prior
        guard abs(delta) >= 0.15 else { return nil }

        let previousLabel = previous.window.monthLabel(calendar: ctx.calendar)
        let up = delta > 0

        return RecapCandidate(
            id: "spend-shift:\(ctx.window.key)",
            ruleID: "spend-shift",
            family: "economy:spend",
            kind: .comparison,
            tone: up ? .matterOfFact : .celebratory,
            headline: up ? "You leaned in harder." : "You got more efficient.",
            body: "\(RecapRuleSupport.money(current)) this month, \(RecapRuleSupport.deltaPhrase(delta)) on \(previousLabel).",
            metrics: [
                RecapMetric("This month", current, .usd),
                RecapMetric(previousLabel, prior, .usd)
            ],
            comparison: RecapComparison(
                basis: .previousMonth,
                referenceLabel: previousLabel,
                currentValue: current,
                referenceValue: prior,
                unit: .usd
            ),
            visual: .sparkline,
            visualData: .dualSeries(current: ctx.facts.dailyCost, reference: previous.dailyCost),
            suggestedSize: .wide,
            novelty: 0.6,
            significance: RecapStatistics.significance(fromEffect: abs(delta), saturatingAt: 0.8),
            relevance: 0.85,
            confidence: ctx.confidence(sampleSize: ctx.facts.sessionCount)
        )
    }

    @Sendable static func spendRecord(_ ctx: RecapContext) -> RecapCandidate? {
        guard ctx.allowsAbsoluteClaims,
              ctx.monthsOfHistory >= 3,
              let best = ctx.allTimeBest(\.totalCostUSD),
              ctx.facts.totalCostUSD > best.value,
              best.value > 1 else { return nil }

        let margin = RecapStatistics.recordMargin(
            current: ctx.facts.totalCostUSD, previousBest: best.value
        )
        guard let margin, margin > 0.1 else { return nil }

        return RecapCandidate(
            id: "spend-record:\(ctx.window.key)",
            ruleID: "spend-record",
            family: "economy:spend",
            kind: .record,
            tone: .matterOfFact,
            headline: "Your biggest month yet.",
            body: "\(RecapRuleSupport.money(ctx.facts.totalCostUSD)) of agent work — past \(best.window.displayLabel(calendar: ctx.calendar)), your previous high.",
            metrics: [
                RecapMetric("This month", ctx.facts.totalCostUSD, .usd),
                RecapMetric("Previous best", best.value, .usd)
            ],
            comparison: RecapComparison(
                basis: .allTimeRecord,
                referenceLabel: best.window.monthLabel(calendar: ctx.calendar),
                currentValue: ctx.facts.totalCostUSD,
                referenceValue: best.value,
                unit: .usd
            ),
            visual: .bigNumber,
            visualData: .series(ctx.facts.dailyCost),
            suggestedSize: .hero,
            novelty: 0.9,
            significance: margin,
            relevance: 0.9,
            confidence: ctx.confidence(sampleSize: ctx.facts.sessionCount)
        )
    }

    // MARK: Cache

    /// Cache is the one efficiency lever a person can actually feel, so it gets
    /// framed as work avoided rather than as a hit-rate percentage.
    @Sendable static func cacheEfficiency(_ ctx: RecapContext) -> RecapCandidate? {
        let facts = ctx.facts
        guard facts.cacheReadTokens > 0, facts.sessionCount >= 10 else { return nil }
        let rate = facts.cacheHitRate
        guard rate >= 0.2 else { return nil }

        let average = ctx.average(\.cacheHitRate)
        let delta = average.map { rate - $0 }
        let improved = (delta ?? 0) > 0.05

        let body: String
        if let delta, abs(delta) >= 0.05, let average {
            body = improved
                ? "\(RecapRuleSupport.percent(rate)) of your prompt tokens came from cache — up from \(RecapRuleSupport.percent(average)) on your usual month."
                : "\(RecapRuleSupport.percent(rate)) of your prompt tokens came from cache, down from \(RecapRuleSupport.percent(average))."
        } else {
            body = "\(RecapRuleSupport.percent(rate)) of your prompt tokens were served from cache instead of being re-read."
        }

        return RecapCandidate(
            id: "cache-efficiency:\(ctx.window.key)",
            ruleID: "cache-efficiency",
            family: "economy:cache",
            kind: improved ? .trend : .personality,
            tone: improved ? .celebratory : .matterOfFact,
            headline: improved ? "Your context started paying rent." : "Cache did the heavy lifting.",
            body: body,
            metrics: [
                RecapMetric("Cache hit rate", rate, .percent),
                RecapMetric("Tokens from cache", Double(facts.cacheReadTokens), .tokens)
            ],
            comparison: average.map { value in
                RecapComparison(
                    basis: .personalAverage,
                    referenceLabel: "your usual month",
                    currentValue: rate,
                    referenceValue: value,
                    unit: .percent
                )
            },
            visual: .rings,
            visualData: .rings([
                RecapRingValue(
                    label: "Cache",
                    progress: rate,
                    caption: RecapRuleSupport.percent(rate)
                )
            ]),
            suggestedSize: .small,
            novelty: improved ? 0.8 : 0.45,
            significance: RecapStatistics.significance(
                fromEffect: max(rate - 0.2, abs(delta ?? 0) * 3), saturatingAt: 0.6
            ),
            relevance: 0.7,
            confidence: ctx.confidence(sampleSize: facts.sessionCount)
        )
    }

    // MARK: Unit economics

    @Sendable static func costPerSessionShift(_ ctx: RecapContext) -> RecapCandidate? {
        guard ctx.allowsAbsoluteClaims,
              let previous = ctx.previousMonth,
              ctx.facts.sessionCount >= 10,
              previous.sessionCount >= 10 else { return nil }

        let current = ctx.facts.totalCostUSD / Double(ctx.facts.sessionCount)
        let prior = previous.totalCostUSD / Double(previous.sessionCount)
        guard prior > 0.01, current > 0.01 else { return nil }
        let delta = (current - prior) / prior
        guard abs(delta) >= 0.25 else { return nil }

        let previousLabel = previous.window.monthLabel(calendar: ctx.calendar)
        let up = delta > 0

        return RecapCandidate(
            id: "cost-per-session:\(ctx.window.key)",
            ruleID: "cost-per-session",
            family: "economy:unit",
            kind: .trend,
            tone: .reflective,
            headline: up ? "Bigger asks." : "Cheaper per ask.",
            body: up
                ? "A typical session cost \(RecapRuleSupport.money(current)), \(RecapRuleSupport.deltaPhrase(delta)) on \(previousLabel) — you were handing over larger problems."
                : "A typical session cost \(RecapRuleSupport.money(current)), \(RecapRuleSupport.deltaPhrase(delta)) on \(previousLabel).",
            metrics: [
                RecapMetric("Per session", current, .usd),
                RecapMetric(previousLabel, prior, .usd)
            ],
            comparison: RecapComparison(
                basis: .previousMonth,
                referenceLabel: previousLabel,
                currentValue: current,
                referenceValue: prior,
                unit: .usd
            ),
            visual: .beforeAfter,
            visualData: .pair(before: prior, after: current),
            suggestedSize: .small,
            novelty: 0.7,
            significance: RecapStatistics.significance(fromEffect: abs(delta), saturatingAt: 1.0),
            relevance: 0.7,
            confidence: ctx.confidence(
                sampleSize: min(ctx.facts.sessionCount, previous.sessionCount)
            )
        )
    }

    /// How much of the month was models thinking rather than answering.
    @Sendable static func thinkingShare(_ ctx: RecapContext) -> RecapCandidate? {
        let facts = ctx.facts
        guard facts.totalTokens > 0, facts.reasoningTokens > 0 else { return nil }
        let share = Double(facts.reasoningTokens) / Double(facts.totalTokens)
        guard share >= 0.08 else { return nil }

        let average = ctx.average {
            $0.totalTokens > 0 ? Double($0.reasoningTokens) / Double($0.totalTokens) : 0
        }
        let delta = average.map { share - $0 } ?? 0

        return RecapCandidate(
            id: "thinking-share:\(ctx.window.key)",
            ruleID: "thinking-share",
            family: "economy:tokens",
            kind: delta > 0.04 ? .trend : .funFact,
            tone: .curious,
            headline: "A lot of it was thinking.",
            body: "\(RecapRuleSupport.percent(share)) of your tokens went to reasoning rather than output.",
            metrics: [
                RecapMetric("Reasoning share", share, .percent),
                RecapMetric("Reasoning tokens", Double(facts.reasoningTokens), .tokens)
            ],
            comparison: average.map { value in
                RecapComparison(
                    basis: .personalAverage,
                    referenceLabel: "your usual month",
                    currentValue: share,
                    referenceValue: value,
                    unit: .percent
                )
            },
            visual: .rings,
            visualData: .rings([
                RecapRingValue(
                    label: "Thinking",
                    progress: share,
                    caption: RecapRuleSupport.percent(share)
                )
            ]),
            suggestedSize: .small,
            novelty: 0.6,
            significance: RecapStatistics.significance(
                fromEffect: max(share, abs(delta) * 4), saturatingAt: 0.4
            ),
            relevance: 0.55,
            confidence: ctx.confidence(sampleSize: facts.sessionCount)
        )
    }

    /// A round-number milestone worth noticing, measured cumulatively.
    @Sendable static func volumeMilestone(_ ctx: RecapContext) -> RecapCandidate? {
        guard ctx.allowsLifetimeClaims, ctx.monthsOfHistory >= 2 else { return nil }

        let priorSessions = ctx.comparableHistory.reduce(0) { $0 + $1.sessionCount }
        let total = priorSessions + ctx.facts.sessionCount
        let thresholds = [100, 250, 500, 1_000, 2_500, 5_000, 10_000]
        // The milestone crossed *this month* — not one passed long ago.
        guard let crossed = thresholds.last(where: { $0 > priorSessions && $0 <= total }) else {
            return nil
        }

        return RecapCandidate(
            id: "volume-milestone:\(crossed)",
            ruleID: "volume-milestone",
            family: "milestone",
            kind: .milestone,
            tone: .celebratory,
            headline: "You passed \(crossed) sessions.",
            body: "Somewhere in \(ctx.window.monthLabel(calendar: ctx.calendar)), your \(crossed)th agent session went by without ceremony.",
            metrics: [
                RecapMetric("Sessions all time", Double(total), .count),
                RecapMetric("This month", Double(ctx.facts.sessionCount), .count)
            ],
            comparison: RecapComparison(
                basis: .allTimeRecord,
                referenceLabel: "before this month",
                currentValue: Double(total),
                referenceValue: Double(priorSessions),
                unit: .count
            ),
            visual: .bigNumber,
            suggestedSize: .medium,
            novelty: 0.95,
            significance: 0.8,
            relevance: 0.75,
            confidence: ctx.confidence(sampleSize: ctx.facts.sessionCount)
        )
    }
}
