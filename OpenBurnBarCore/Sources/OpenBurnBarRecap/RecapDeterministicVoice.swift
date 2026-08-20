import Foundation

/// The title and closing paragraph the recap ships with when no model writes them.
///
/// This is not filler. With the editorial layer off — no backend connected, the
/// toggle down, the request timed out — this *is* the recap's voice, so it is
/// assembled from clauses that are individually true and reads as a sentence
/// someone would say, not as a template with slots filled in.
public enum RecapDeterministicVoice {

    // MARK: - Title

    /// Names the month after whatever actually characterised it.
    ///
    /// Chosen from the deck rather than from a fixed phrase, so two different
    /// months do not get the same title.
    public static func title(
        for context: RecapContext,
        cards: [RecapCard]
    ) -> String {
        let month = context.window.monthLabel(calendar: context.calendar)

        guard let lead = cards.first else {
            return "Your \(month) with AI"
        }

        // A month with a genuine record is a month about that record.
        if let record = cards.first(where: { $0.kind == .record }) {
            switch record.candidate.ruleID {
            case "spend-record": return "\(month) was your biggest month yet"
            case "streak", "show-up-rate": return "\(month) was your steadiest month"
            case "busiest-week": return "\(month) had your best week yet"
            case "longest-session": return "\(month) went deep"
            default: return "\(month) set a record"
            }
        }

        switch lead.candidate.ruleID {
        case "headline-project":
            if let project = context.facts.topProject, project.costShare >= 0.5 {
                return "\(month) belonged to \(project.label)"
            }
            return "\(month) had a focus"
        case "focus-shift":
            return context.facts.modelConcentration > (context.previousMonth?.modelConcentration ?? 0)
                ? "\(month) was your settled month"
                : "\(month) was your exploring month"
        case "late-night":
            return "\(month) ran late"
        case "weekday-personality":
            return "\(month) had a rhythm"
        case "model-gain", "favourite-model", "favourite-pairing":
            return "\(month) was when you picked a side"
        case "volume-milestone":
            return "\(month) passed a milestone"
        default:
            return "Your \(month) with AI"
        }
    }

    // MARK: - Closing

    /// Two or three clauses drawn from cards that actually made the deck, so
    /// the closing can never claim something the recap did not show.
    public static func closing(
        for context: RecapContext,
        cards: [RecapCard]
    ) -> String {
        let month = context.window.monthLabel(calendar: context.calendar)
        var clauses: [String] = []

        for card in cards {
            guard clauses.count < 3 else { break }
            if let clause = clause(for: card, context: context) {
                clauses.append(clause)
            }
        }

        guard !clauses.isEmpty else {
            return context.facts.isEmpty
                ? "\(month) was quiet — nothing much to report."
                : "\(month) was a steady month: \(context.facts.sessionCount) sessions across \(context.facts.activeDayCount) days."
        }

        let joined = RecapRuleSupport.list(clauses)
        let opener = "In \(month) you \(joined)."

        // One closing observation, only when the data supports one.
        if let tail = tail(for: context) {
            return opener + " " + tail
        }
        return opener
    }

    // MARK: - Clauses

    private static func clause(for card: RecapCard, context: RecapContext) -> String? {
        let facts = context.facts
        switch card.candidate.ruleID {
        case "show-up-rate":
            return "worked with agents on \(facts.activeDayCount) of \(facts.dayCount) days"
        case "streak":
            return "put together a \(facts.longestActiveStreak)-day streak"
        case "favourite-model":
            guard let model = facts.topModel else { return nil }
            return "leaned on \(model.label) for \(RecapRuleSupport.percent(model.sessionShare)) of your sessions"
        case "favourite-pairing":
            guard let pairing = facts.topPairing else { return nil }
            return "settled into \(pairing.label)"
        case "headline-project":
            guard let project = facts.topProject else { return nil }
            return "spent \(RecapRuleSupport.approximateFraction(project.costShare)) of it on \(project.label)"
        case "busiest-week":
            guard let week = facts.busiestWeek else { return nil }
            return "had your busiest stretch around \(RecapRuleSupport.dayRange(from: week.startDate, to: week.endDate, calendar: context.calendar))"
        case "late-night":
            return "did \(RecapRuleSupport.percent(facts.lateNightCostShare)) of the work after midnight"
        case "weekday-personality":
            guard let peak = facts.peakWeekday else { return nil }
            return "kept returning on \(RecapRuleSupport.weekdayPlural(peak, calendar: context.calendar))"
        case "session-length-trend":
            guard let previous = context.previousMonth,
                  previous.sessionStats.medianSeconds > 0 else { return nil }
            let longer = facts.sessionStats.medianSeconds > previous.sessionStats.medianSeconds
            return longer ? "let sessions run longer" : "kept sessions shorter"
        case "spend-shift":
            guard let previous = context.previousMonth, previous.totalCostUSD > 0 else { return nil }
            let delta = (facts.totalCostUSD - previous.totalCostUSD) / previous.totalCostUSD
            return "moved spend \(RecapRuleSupport.deltaPhrase(delta))"
        case "new-models":
            return "gave a few new models their first run"
        case "cache-efficiency":
            return "got \(RecapRuleSupport.percent(facts.cacheHitRate)) of your prompt tokens out of cache"
        default:
            return nil
        }
    }

    /// The "and one thing quietly became true" note the brief asks for. Only
    /// fires when there is a real second-order observation to make.
    private static func tail(for context: RecapContext) -> String? {
        guard let previous = context.previousMonth else { return nil }

        let concentrationDelta = context.facts.modelConcentration - previous.modelConcentration
        if concentrationDelta >= 0.08, let pairing = context.facts.topPairing {
            return "One pairing — \(pairing.label) — quietly became your default."
        }
        if concentrationDelta <= -0.08 {
            return "You spread the work wider than you did the month before."
        }
        if context.facts.sessionStats.medianSeconds > previous.sessionStats.medianSeconds * 1.25 {
            return "Your sessions got noticeably longer, which usually means you were handing over bigger problems."
        }
        return nil
    }
}
