import Foundation
import OpenBurnBarInsights
import OpenBurnBarKernel

// MARK: - Craft rules
//
// What the work was actually *about*: which projects held attention, which
// tools the agents reached for. Tool rules require conversation-level data, so
// they stay silent on platforms that cannot see it — which is a data floor, not
// a special case.

enum RecapCraftRules {

    static let all: [@Sendable (RecapContext) -> RecapCandidate?] = [
        headlineProject,
        projectBreadth,
        projectHandover,
        newProject,
        signatureTool,
        newTools
    ]

    // MARK: Projects

    @Sendable static func headlineProject(_ ctx: RecapContext) -> RecapCandidate? {
        let facts = ctx.facts
        guard facts.projects.count >= 2,
              facts.sessionCount >= 8,
              let top = facts.projects.first,
              top.costShare >= 0.25 else { return nil }

        let priorTopMonths = ctx.monthsWhereTop(key: top.key, in: \.projects)
        let returning = priorTopMonths > 0

        return RecapCandidate(
            id: "headline-project:\(top.key)",
            ruleID: "headline-project",
            family: "project:\(top.key)",
            kind: returning ? .personality : .trend,
            tone: .reflective,
            headline: returning ? "Still the main thing." : "Where your month went.",
            body: "\(top.label) took \(RecapRuleSupport.approximateFraction(top.costShare)) of your agent work, across \(top.sessions) session\(top.sessions == 1 ? "" : "s").",
            metrics: [
                RecapMetric("Share of work", top.costShare, .percent),
                RecapMetric("Sessions", Double(top.sessions), .count)
            ],
            comparison: ctx.previousShare(key: top.key, in: \.projects).map { previous in
                RecapComparison(
                    basis: .previousMonth,
                    referenceLabel: ctx.facts.window.previous.monthLabel(calendar: ctx.calendar),
                    currentValue: top.costShare,
                    referenceValue: previous.costShare,
                    unit: .percent
                )
            },
            visual: .ranking,
            visualData: .ranked(RecapRuleSupport.ranked(facts.projects)),
            suggestedSize: .wide,
            novelty: ctx.novelty(repeatedInPriorMonths: priorTopMonths),
            significance: RecapStatistics.significance(fromEffect: top.costShare, saturatingAt: 0.7),
            relevance: 0.9,
            confidence: ctx.confidence(sampleSize: top.sessions)
        )
    }

    /// How many things were in the air at once.
    @Sendable static func projectBreadth(_ ctx: RecapContext) -> RecapCandidate? {
        let facts = ctx.facts
        let count = facts.projects.count
        guard count >= 3, facts.sessionCount >= 10 else { return nil }

        let average = ctx.average { Double($0.projects.count) }
        let comparison = average.map { value in
            RecapComparison(
                basis: .personalAverage,
                referenceLabel: "your usual month",
                currentValue: Double(count),
                referenceValue: value,
                unit: .count
            )
        }

        // Only worth saying when it is unusual for them, or plainly a lot.
        let deviation = average.map { abs(Double(count) - $0) / max($0, 1) } ?? 0
        guard count >= 6 || deviation >= 0.4 else { return nil }

        let busier = average.map { Double(count) > $0 } ?? true

        return RecapCandidate(
            id: "project-breadth:\(ctx.window.key)",
            ruleID: "project-breadth",
            family: "project-shape",
            kind: .comparison,
            tone: .curious,
            headline: busier ? "A lot of plates spinning." : "Fewer things, more depth.",
            body: "You touched \(count) different projects this month.",
            metrics: [RecapMetric("Projects", Double(count), .count)],
            comparison: comparison,
            visual: .bigNumber,
            suggestedSize: .small,
            novelty: 0.6,
            significance: RecapStatistics.significance(
                fromEffect: max(deviation, Double(count) / 12), saturatingAt: 0.8
            ),
            relevance: 0.65,
            confidence: ctx.confidence(sampleSize: facts.sessionCount)
        )
    }

    /// The month's attention moved from one project to another.
    @Sendable static func projectHandover(_ ctx: RecapContext) -> RecapCandidate? {
        guard let previous = ctx.previousMonth,
              let current = ctx.facts.projects.first,
              let prior = previous.projects.first,
              current.key != prior.key,
              current.costShare >= 0.25,
              prior.costShare >= 0.25,
              ctx.facts.sessionCount >= 10,
              previous.sessionCount >= 10 else { return nil }

        let priorNowShare = ctx.facts.project(key: prior.key)?.costShare ?? 0
        let previousLabel = previous.window.monthLabel(calendar: ctx.calendar)

        return RecapCandidate(
            id: "project-handover:\(current.key)",
            ruleID: "project-handover",
            family: "project-shape",
            kind: .trend,
            tone: .reflective,
            headline: "Your focus moved.",
            body: priorNowShare < 0.05
                ? "\(prior.label) led \(previousLabel). This month it all but disappeared, and \(current.label) took over."
                : "\(prior.label) led \(previousLabel); \(current.label) leads now.",
            metrics: [
                RecapMetric("\(current.label) now", current.costShare, .percent),
                RecapMetric("\(prior.label) now", priorNowShare, .percent)
            ],
            comparison: RecapComparison(
                basis: .previousMonth,
                referenceLabel: previousLabel,
                currentValue: current.costShare,
                referenceValue: prior.costShare,
                unit: .percent
            ),
            visual: .beforeAfter,
            visualData: .pair(before: prior.costShare, after: current.costShare),
            suggestedSize: .wide,
            novelty: 0.9,
            significance: RecapStatistics.significance(
                fromEffect: current.costShare + (prior.costShare - priorNowShare), saturatingAt: 1.0
            ),
            relevance: 0.85,
            confidence: ctx.confidence(sampleSize: ctx.facts.sessionCount)
        )
    }

    @Sendable static func newProject(_ ctx: RecapContext) -> RecapCandidate? {
        guard ctx.monthsOfHistory >= 2 else { return nil }
        let fresh = ctx.newProjects().filter { $0.sessions >= 3 }
        guard let biggest = fresh.max(by: { $0.costShare < $1.costShare }),
              biggest.costShare >= 0.1 else { return nil }

        return RecapCandidate(
            id: "new-project:\(biggest.key)",
            ruleID: "new-project",
            family: "firsts",
            kind: .milestone,
            tone: .curious,
            headline: "Something new on the bench.",
            body: "\(biggest.label) appeared for the first time and already took \(RecapRuleSupport.percent(biggest.costShare)) of the month.",
            metrics: [
                RecapMetric("Share of work", biggest.costShare, .percent),
                RecapMetric("Sessions", Double(biggest.sessions), .count)
            ],
            comparison: RecapComparison(
                basis: .firstEver,
                referenceLabel: "never before",
                currentValue: biggest.costShare,
                referenceValue: 0,
                unit: .percent
            ),
            visual: .spotlight,
            suggestedSize: .medium,
            novelty: 0.95,
            significance: RecapStatistics.significance(
                fromEffect: biggest.costShare, saturatingAt: 0.4
            ),
            relevance: 0.8,
            confidence: ctx.confidence(sampleSize: biggest.sessions, full: 15)
        )
    }

    // MARK: Tools

    /// The tool the agents reached for most. Requires conversation data.
    @Sendable static func signatureTool(_ ctx: RecapContext) -> RecapCandidate? {
        guard ctx.allowsSessionClaims else { return nil }
        let facts = ctx.facts
        guard facts.tools.count >= 3,
              let top = facts.tools.first,
              top.share >= 0.3,
              facts.sessionCount >= 10 else { return nil }

        return RecapCandidate(
            id: "signature-tool:\(top.name)",
            ruleID: "signature-tool",
            family: "tools",
            kind: .personality,
            tone: .curious,
            headline: "The tool they always reach for.",
            body: "\(top.name) showed up in \(RecapRuleSupport.percent(top.share)) of your sessions — more than any other tool.",
            metrics: [
                RecapMetric("Sessions using it", top.share, .percent),
                RecapMetric("Sessions", Double(top.count), .count)
            ],
            visual: .ranking,
            visualData: .ranked(RecapRuleSupport.rankedTools(facts.tools)),
            suggestedSize: .medium,
            novelty: ctx.hasSeenTool(top.name) ? 0.5 : 0.85,
            significance: RecapStatistics.significance(fromEffect: top.share, saturatingAt: 0.75),
            relevance: 0.7,
            confidence: ctx.confidence(sampleSize: top.count)
        )
    }

    @Sendable static func newTools(_ ctx: RecapContext) -> RecapCandidate? {
        guard ctx.allowsSessionClaims, ctx.monthsOfHistory >= 1 else { return nil }
        let fresh = ctx.newTools().filter { $0.count >= 3 }
        guard fresh.count >= 2 else { return nil }

        let names = fresh.prefix(3).map(\.name).joined(separator: ", ")

        return RecapCandidate(
            id: "new-tools:\(ctx.window.key)",
            ruleID: "new-tools",
            family: "tools",
            kind: .milestone,
            tone: .curious,
            headline: "Your agents learned new moves.",
            body: "\(names) turned up in your sessions for the first time.",
            metrics: [RecapMetric("New tools", Double(fresh.count), .count)],
            visual: .ranking,
            visualData: .ranked(RecapRuleSupport.rankedTools(fresh)),
            suggestedSize: .medium,
            novelty: 0.9,
            significance: RecapStatistics.significance(
                fromEffect: Double(fresh.count), saturatingAt: 4
            ),
            relevance: 0.6,
            confidence: ctx.confidence(sampleSize: fresh.reduce(0) { $0 + $1.count }, full: 15)
        )
    }
}
