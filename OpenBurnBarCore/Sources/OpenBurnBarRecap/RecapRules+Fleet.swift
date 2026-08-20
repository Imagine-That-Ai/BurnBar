import Foundation

// MARK: - Fleet rules
//
// Which models and harnesses did the work, how that changed, and what got tried
// for the first time. Every rule returns nil rather than firing on thin data —
// the floors are what keep a first month or a quiet month from filling up with
// "0% change" cards.

enum RecapFleetRules {

    static let all: [@Sendable (RecapContext) -> RecapCandidate?] = [
        favouriteModel,
        biggestModelGain,
        biggestModelDecline,
        favouritePairing,
        fleetConcentration,
        newModelsTried,
        focusShift,
        oneHitWonder
    ]

    // MARK: Favourite model

    @Sendable static func favouriteModel(_ ctx: RecapContext) -> RecapCandidate? {
        let facts = ctx.facts
        guard facts.sessionCount >= 5, let top = facts.topModel, top.sessions > 0 else { return nil }

        // How lopsided is the field? A "favourite" among two near-equal models
        // is not a favourite.
        let sessionCounts = facts.models.map(\.sessions)
        let effect = RecapStatistics.uniformityEffect(counts: sessionCounts)
            ?? RecapStatistics.clamp(top.sessionShare - 0.4)
        guard effect > 0.05 else { return nil }

        let priorTopMonths = ctx.monthsWhereTop(key: top.key, in: \.models)
        let comparison = ctx.previousShare(key: top.key, in: \.models).map { previous in
            RecapComparison(
                basis: .previousMonth,
                referenceLabel: ctx.facts.window.previous.monthLabel(calendar: ctx.calendar),
                currentValue: top.sessionShare,
                referenceValue: previous.sessionShare,
                unit: .percent
            )
        }

        let headline: String
        if priorTopMonths == 0, ctx.monthsOfHistory > 0 {
            headline = "You found a favorite."
        } else if priorTopMonths == ctx.monthsOfHistory, ctx.monthsOfHistory >= 3 {
            headline = "Still your first choice."
        } else {
            headline = "Your most-used model."
        }

        let body = "\(top.label) handled \(RecapRuleSupport.percent(top.sessionShare)) of your sessions."

        return RecapCandidate(
            id: "favourite-model:\(top.key)",
            ruleID: "favourite-model",
            family: "model:\(top.key)",
            kind: priorTopMonths == 0 && ctx.monthsOfHistory > 0 ? .trend : .personality,
            tone: .celebratory,
            headline: headline,
            body: body,
            metrics: [
                RecapMetric("Share of sessions", top.sessionShare, .percent),
                RecapMetric("Sessions", Double(top.sessions), .count)
            ],
            comparison: comparison,
            visual: .spotlight,
            visualData: .ranked(RecapRuleSupport.ranked(facts.models, value: { Double($0.sessions) })),
            suggestedSize: .medium,
            novelty: ctx.novelty(repeatedInPriorMonths: priorTopMonths),
            significance: effect,
            relevance: RecapStatistics.clamp(0.5 + top.sessionShare / 2),
            confidence: ctx.confidence(sampleSize: top.sessions)
        )
    }

    // MARK: Movers

    @Sendable static func biggestModelGain(_ ctx: RecapContext) -> RecapCandidate? {
        shareMover(ctx, rising: true)
    }

    @Sendable static func biggestModelDecline(_ ctx: RecapContext) -> RecapCandidate? {
        shareMover(ctx, rising: false)
    }

    /// "Grok went from 18% of your sessions last month to 41% this month."
    ///
    /// Uses a two-proportion z-test, so a jump from 1-of-3 to 2-of-4 sessions —
    /// which is a 17-point "swing" and means nothing — cannot fire.
    private static func shareMover(_ ctx: RecapContext, rising: Bool) -> RecapCandidate? {
        guard let previous = ctx.previousMonth,
              ctx.facts.sessionCount >= 10,
              previous.sessionCount >= 10 else { return nil }

        var best: (share: RecapShare, priorShare: Double, priorSessions: Int, z: Double)?
        for model in ctx.facts.models {
            let prior = previous.models.first { $0.key == model.key }
            let priorSessions = prior?.sessions ?? 0
            guard let z = RecapStatistics.twoProportionZ(
                successes1: model.sessions, trials1: ctx.facts.sessionCount,
                successes2: priorSessions, trials2: previous.sessionCount
            ) else { continue }
            guard rising ? z > 0 : z < 0 else { continue }
            if let current = best, abs(z) <= abs(current.z) { continue }
            best = (model, prior?.sessionShare ?? 0, priorSessions, z)
        }

        // A decline is only worth a card if the model was meaningful before.
        guard let winner = best else { return nil }
        if !rising, winner.priorShare < 0.15 { return nil }

        let significance = RecapStatistics.significance(fromZ: winner.z)
        guard significance > 0.15 else { return nil }

        let previousLabel = previous.window.monthLabel(calendar: ctx.calendar)
        let headline = rising ? "A new go-to." : "Quietly stepped back."
        let body = rising
            ? "\(winner.share.label) went from \(RecapRuleSupport.percent(winner.priorShare)) of your sessions in \(previousLabel) to \(RecapRuleSupport.percent(winner.share.sessionShare))."
            : "\(winner.share.label) fell from \(RecapRuleSupport.percent(winner.priorShare)) of your sessions in \(previousLabel) to \(RecapRuleSupport.percent(winner.share.sessionShare))."

        return RecapCandidate(
            id: "model-\(rising ? "gain" : "decline"):\(winner.share.key)",
            ruleID: rising ? "model-gain" : "model-decline",
            family: "model:\(winner.share.key)",
            kind: .trend,
            tone: rising ? .celebratory : .reflective,
            headline: headline,
            body: body,
            metrics: [
                RecapMetric("This month", winner.share.sessionShare, .percent),
                RecapMetric(previousLabel, winner.priorShare, .percent)
            ],
            comparison: RecapComparison(
                basis: .previousMonth,
                referenceLabel: previousLabel,
                currentValue: winner.share.sessionShare,
                referenceValue: winner.priorShare,
                unit: .percent
            ),
            visual: .beforeAfter,
            visualData: .pair(before: winner.priorShare, after: winner.share.sessionShare),
            suggestedSize: .wide,
            novelty: 0.8,
            significance: significance,
            relevance: RecapStatistics.clamp(0.4 + max(winner.share.sessionShare, winner.priorShare)),
            confidence: ctx.confidence(sampleSize: winner.share.sessions + winner.priorSessions)
        )
    }

    // MARK: Pairing

    /// The combination — model *and* harness — that actually did the work.
    @Sendable static func favouritePairing(_ ctx: RecapContext) -> RecapCandidate? {
        let facts = ctx.facts
        guard facts.pairings.count >= 2,
              facts.sessionCount >= 8,
              let top = facts.pairings.first,
              top.sessionShare >= 0.25 else { return nil }

        let priorTopMonths = ctx.monthsWhereTop(key: top.key, in: \.pairings)
        let parts = RecapFacts.splitPairingKey(top.key)
        let body: String
        if let parts, let provider = facts.provider(key: parts.provider) {
            body = "\(top.label) ran \(RecapRuleSupport.approximateFraction(top.sessionShare)) of your sessions — more than any other pairing, and more than \(provider.label) managed with anything else."
        } else {
            body = "\(top.label) ran \(RecapRuleSupport.approximateFraction(top.sessionShare)) of your sessions — more than any other pairing."
        }

        return RecapCandidate(
            id: "favourite-pairing:\(top.key)",
            ruleID: "favourite-pairing",
            family: "pairing",
            kind: priorTopMonths == 0 && ctx.monthsOfHistory > 0 ? .trend : .personality,
            tone: .reflective,
            headline: "Your default setup.",
            body: body,
            metrics: [
                RecapMetric("Share of sessions", top.sessionShare, .percent),
                RecapMetric("Sessions", Double(top.sessions), .count)
            ],
            comparison: ctx.previousShare(key: top.key, in: \.pairings).map { previous in
                RecapComparison(
                    basis: .previousMonth,
                    referenceLabel: ctx.facts.window.previous.monthLabel(calendar: ctx.calendar),
                    currentValue: top.sessionShare,
                    referenceValue: previous.sessionShare,
                    unit: .percent
                )
            },
            visual: .ranking,
            visualData: .ranked(RecapRuleSupport.ranked(facts.pairings, value: { Double($0.sessions) })),
            suggestedSize: .wide,
            novelty: ctx.novelty(repeatedInPriorMonths: priorTopMonths),
            significance: RecapStatistics.significance(fromEffect: top.sessionShare, saturatingAt: 0.6),
            relevance: 0.9,
            confidence: ctx.confidence(sampleSize: top.sessions)
        )
    }

    // MARK: Fleet shape

    /// "You used 9 model + harness combinations, but three handled 78% of it."
    @Sendable static func fleetConcentration(_ ctx: RecapContext) -> RecapCandidate? {
        let facts = ctx.facts
        let pairings = facts.pairings
        guard pairings.count >= 4, facts.sessionCount >= 10 else { return nil }

        let topThree = pairings.prefix(3)
        let topThreeShare = topThree.reduce(0.0) { $0 + $1.sessionShare }
        guard topThreeShare >= 0.5 else { return nil }

        return RecapCandidate(
            id: "fleet-concentration:\(pairings.count)",
            ruleID: "fleet-concentration",
            family: "fleet-shape",
            kind: .personality,
            tone: .curious,
            headline: "A big bench, a short rotation.",
            body: "You used \(pairings.count) model and harness combinations this month. Three of them did \(RecapRuleSupport.percent(topThreeShare)) of the work.",
            metrics: [
                RecapMetric("Combinations used", Double(pairings.count), .count),
                RecapMetric("Handled by the top three", topThreeShare, .percent)
            ],
            comparison: ctx.previousMonth.map { previous in
                RecapComparison(
                    basis: .previousMonth,
                    referenceLabel: previous.window.monthLabel(calendar: ctx.calendar),
                    currentValue: Double(pairings.count),
                    referenceValue: Double(previous.pairings.count),
                    unit: .count
                )
            },
            visual: .donut,
            visualData: .ranked(RecapRuleSupport.ranked(pairings, limit: 6, value: { Double($0.sessions) })),
            suggestedSize: .wide,
            novelty: 0.6,
            significance: RecapStatistics.significance(fromEffect: topThreeShare, saturatingAt: 0.85),
            relevance: 0.8,
            confidence: ctx.confidence(sampleSize: facts.sessionCount)
        )
    }

    /// Did the month get more focused or more scattered?
    @Sendable static func focusShift(_ ctx: RecapContext) -> RecapCandidate? {
        guard let previous = ctx.previousMonth,
              ctx.facts.sessionCount >= 10,
              previous.sessionCount >= 10 else { return nil }

        let current = ctx.facts.modelConcentration
        let prior = previous.modelConcentration
        let delta = current - prior
        guard abs(delta) >= 0.08 else { return nil }

        let tightened = delta > 0
        let previousLabel = previous.window.monthLabel(calendar: ctx.calendar)

        return RecapCandidate(
            id: "focus-shift:\(ctx.window.key)",
            ruleID: "focus-shift",
            family: "fleet-shape",
            kind: .trend,
            tone: .reflective,
            headline: tightened ? "You stopped shopping around." : "You cast a wider net.",
            body: tightened
                ? "Your work concentrated into fewer models than in \(previousLabel) — less switching, more settling in."
                : "You spread work across more models than in \(previousLabel), rather than leaning on one.",
            metrics: [
                RecapMetric("Models used", Double(ctx.facts.models.count), .count),
                RecapMetric("Top model's share", ctx.facts.topModel?.sessionShare ?? 0, .percent)
            ],
            comparison: RecapComparison(
                basis: .previousMonth,
                referenceLabel: previousLabel,
                currentValue: current,
                referenceValue: prior,
                unit: .percent
            ),
            visual: .beforeAfter,
            visualData: .pair(before: prior, after: current),
            suggestedSize: .wide,
            novelty: 0.7,
            significance: RecapStatistics.significance(fromEffect: abs(delta), saturatingAt: 0.3),
            relevance: 0.7,
            confidence: ctx.confidence(sampleSize: min(ctx.facts.sessionCount, previous.sessionCount))
        )
    }

    // MARK: Firsts

    @Sendable static func newModelsTried(_ ctx: RecapContext) -> RecapCandidate? {
        guard ctx.monthsOfHistory >= 1 else { return nil }
        let fresh = ctx.newModels().filter { $0.sessions >= 2 }
        guard !fresh.isEmpty else { return nil }

        let names = fresh.prefix(3).map(\.label)
        let listed = RecapRuleSupport.list(names)
        let body = fresh.count == 1
            ? "You gave \(listed) its first run this month."
            : "\(listed) joined the rotation for the first time."

        return RecapCandidate(
            id: "new-models:\(ctx.window.key)",
            ruleID: "new-models",
            family: "firsts",
            kind: .milestone,
            tone: .curious,
            headline: fresh.count == 1 ? "Something new." : "New arrivals.",
            body: body,
            metrics: [RecapMetric("New models", Double(fresh.count), .count)],
            comparison: RecapComparison(
                basis: .firstEver,
                referenceLabel: "never before",
                currentValue: Double(fresh.count),
                referenceValue: 0,
                unit: .count
            ),
            visual: .ranking,
            visualData: .ranked(RecapRuleSupport.ranked(fresh, value: { Double($0.sessions) })),
            suggestedSize: .medium,
            novelty: 0.95,
            significance: RecapStatistics.significance(
                fromEffect: Double(fresh.count), saturatingAt: 3
            ),
            relevance: 0.65,
            confidence: ctx.confidence(sampleSize: fresh.reduce(0) { $0 + $1.sessions }, full: 10)
        )
    }

    /// The model you called up exactly once and never again — a small, true,
    /// slightly funny thing.
    @Sendable static func oneHitWonder(_ ctx: RecapContext) -> RecapCandidate? {
        let facts = ctx.facts
        guard facts.models.count >= 4, facts.sessionCount >= 15 else { return nil }
        let singles = facts.models.filter { $0.sessions == 1 }
        guard singles.count == 1, let only = singles.first else { return nil }
        // Only interesting if the rest of the month was busy enough for one
        // session to stand out as deliberate rather than incidental.
        guard only.costShare < 0.05 else { return nil }

        return RecapCandidate(
            id: "one-hit-wonder:\(only.key)",
            ruleID: "one-hit-wonder",
            family: "curio",
            kind: .funFact,
            tone: .playful,
            headline: "One and done.",
            body: "You opened \(only.label) exactly once this month, then never went back.",
            metrics: [RecapMetric("Sessions", 1, .count)],
            visual: .none,
            suggestedSize: .small,
            novelty: 0.85,
            significance: 0.5,
            relevance: 0.35,
            confidence: ctx.confidence(sampleSize: facts.sessionCount)
        )
    }
}
