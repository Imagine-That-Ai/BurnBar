import XCTest
@testable import OpenBurnBarCore
@testable import OpenBurnBarRecap
// Rule families are internal to the Insights module; reach them directly
// rather than widening their access purely for tests.
@testable import OpenBurnBarInsights

final class RecapRulesAndRankerTests: XCTestCase {

    private let calendar = RecapFixtures.calendar()
    private let august = RecapWindow(year: 2026, month: 8)

    // MARK: - Data floors

    /// The core discipline: a rule with nothing solid to say says nothing.
    /// This is what makes a first run, a quiet month, and a platform without
    /// conversation data all behave without special cases.
    func testThinMonthProducesNoCandidates() {
        let facts = RecapFacts.build(
            batch: RecapFixtures.thinMonth(august, calendar: calendar),
            builtAt: august.end(calendar: calendar),
            calendar: calendar
        )
        let context = RecapContext(facts: facts, history: [], calendar: calendar)
        XCTAssertTrue(RecapCandidateGenerator.candidates(for: context).isEmpty)
    }

    func testBusyMonthWithHistoryProducesCandidates() {
        let context = RecapFixtures.context(august, historyMonths: 3, calendar: calendar)
        let candidates = RecapCandidateGenerator.candidates(for: context)
        XCTAssertGreaterThanOrEqual(candidates.count, 5)
        // Every candidate must carry at least one number it is allowed to cite.
        for candidate in candidates {
            XCTAssertFalse(candidate.metrics.isEmpty, "\(candidate.ruleID) shipped no metrics")
            XCTAssertFalse(candidate.headline.isEmpty)
            XCTAssertFalse(candidate.body.isEmpty)
        }
    }

    func testFirstEverMonthMakesNoComparisons() {
        let context = RecapContext(
            facts: RecapFixtures.facts(august, calendar: calendar),
            history: [],
            calendar: calendar
        )
        let candidates = RecapCandidateGenerator.candidates(for: context)
        for candidate in candidates {
            if let basis = candidate.comparison?.basis {
                XCTAssertNotEqual(basis, .previousMonth, "\(candidate.ruleID) compared to a month we don't have")
                XCTAssertNotEqual(basis, .allTimeRecord, "\(candidate.ruleID) claimed a record with no history")
            }
        }
    }

    /// A partially-read month may still be summarised, but it must never claim
    /// a total, a record, or a "most ever".
    func testPartialMonthSuppressesAbsoluteClaims() {
        let full = RecapFixtures.busyMonth(august, calendar: calendar)
        let partial = RecapRowBatch(
            window: august,
            usages: full.usages,
            sessions: full.sessions,
            isPartial: true,
            hasSessionData: true,
            exactShare: 1.0
        )
        let facts = RecapFacts.build(batch: partial, builtAt: august.end(calendar: calendar), calendar: calendar)
        let history = august.priorMonths(4).map { RecapFixtures.facts($0, calendar: calendar, costScale: 0.3) }
        let context = RecapContext(facts: facts, history: history, calendar: calendar)

        XCTAssertFalse(context.allowsAbsoluteClaims)
        let ruleIDs = Set(RecapCandidateGenerator.candidates(for: context).map(\.ruleID))
        for banned in ["spend-record", "busiest-week", "busiest-day", "longest-session",
                       "show-up-rate", "spend-shift", "cost-per-session", "volume-milestone"] {
            XCTAssertFalse(ruleIDs.contains(banned), "\(banned) fired on a partial month")
        }
    }

    /// Missing conversation data is not the same as "you used no tools".
    func testToolRulesStaySilentWithoutSessionData() {
        let batch = RecapFixtures.busyMonth(august, calendar: calendar)
        let withoutSessions = RecapRowBatch(
            window: august,
            usages: batch.usages,
            sessions: [],
            hasSessionData: false,
            exactShare: 1.0
        )
        let facts = RecapFacts.build(batch: withoutSessions, builtAt: august.end(calendar: calendar), calendar: calendar)
        let context = RecapContext(
            facts: facts,
            history: august.priorMonths(3).map { RecapFixtures.facts($0, calendar: calendar) },
            calendar: calendar
        )
        let ruleIDs = Set(RecapCandidateGenerator.candidates(for: context).map(\.ruleID))
        XCTAssertFalse(ruleIDs.contains("signature-tool"))
        XCTAssertFalse(ruleIDs.contains("new-tools"))
    }

    // MARK: - Individual rules

    func testWeekdayPersonalityFindsTheBiasedDay() throws {
        let context = RecapFixtures.context(august, historyMonths: 2, calendar: calendar)
        let candidate = try XCTUnwrap(RecapRhythmRules.weekdayPersonality(context))
        // The fixture doubles Tuesday's sessions.
        XCTAssertTrue(candidate.headline.contains("Tuesday"), candidate.headline)
        XCTAssertEqual(candidate.comparison?.basis, .uniform)
    }

    /// With few sessions, some weekday always leads by chance. The uniformity
    /// test is what stops that from becoming a card.
    func testWeekdayPersonalityIgnoresSmallSamples() {
        let usages = (1...6).map { index in
            RecapFixtures.usage(
                session: "s\(index)",
                start: RecapFixtures.date(2026, 8, 4, 10, calendar: calendar)
            )
        }
        let facts = RecapFacts.build(
            batch: RecapRowBatch(window: august, usages: usages, hasSessionData: false),
            builtAt: august.end(calendar: calendar),
            calendar: calendar
        )
        let context = RecapContext(facts: facts, history: [], calendar: calendar)
        XCTAssertNil(RecapRhythmRules.weekdayPersonality(context))
    }

    func testModelGainRequiresBothMonthsToBeSubstantial() {
        let facts = RecapFixtures.facts(august, calendar: calendar)
        let tinyPrevious = RecapFacts.build(
            batch: RecapFixtures.thinMonth(august.previous, calendar: calendar),
            builtAt: august.start(calendar: calendar),
            calendar: calendar
        )
        let context = RecapContext(facts: facts, history: [tinyPrevious], calendar: calendar)
        XCTAssertNil(RecapFleetRules.biggestModelGain(context))
    }

    // MARK: - Ranker

    func testRankerCapsRepetitionByFamilyAndKind() {
        let limits = RecapRanker.Limits.standard
        let context = RecapFixtures.context(august, historyMonths: 6, calendar: calendar)
        let cards = RecapRanker.rank(
            candidates: RecapCandidateGenerator.candidates(for: context), limits: limits
        )

        var families: [String: Int] = [:]
        var kinds: [RecapInsightKind: Int] = [:]
        for card in cards {
            families[card.candidate.family, default: 0] += 1
            kinds[card.kind, default: 0] += 1
        }
        for (family, count) in families {
            XCTAssertLessThanOrEqual(count, limits.maxPerFamily, "family \(family) over cap")
        }
        for (kind, count) in kinds {
            // The readmission pass may add one card back past the cap on purpose.
            XCTAssertLessThanOrEqual(count, limits.maxPerKind + 1, "kind \(kind) over cap")
        }
        XCTAssertLessThanOrEqual(cards.count, limits.maximumCards)
    }

    func testRankerOpensOnAFullWidthMoment() throws {
        let context = RecapFixtures.context(august, historyMonths: 6, calendar: calendar)
        let cards = RecapRanker.rank(candidates: RecapCandidateGenerator.candidates(for: context))
        let opener = try XCTUnwrap(cards.first)
        XCTAssertTrue(opener.size == .hero || opener.size == .fullBleed)
        XCTAssertTrue(opener.size.isFullWidth(in: 3))
    }

    func testRankerLimitsOversizedMoments() {
        let context = RecapFixtures.context(august, historyMonths: 6, calendar: calendar)
        let limits = RecapRanker.Limits.standard
        let cards = RecapRanker.rank(
            candidates: RecapCandidateGenerator.candidates(for: context), limits: limits
        )
        let oversized = cards.dropFirst().filter { $0.size == .hero || $0.size == .fullBleed }
        XCTAssertLessThanOrEqual(oversized.count, limits.maxAdditionalHeroes)
    }

    func testRankerIsDeterministic() {
        let context = RecapFixtures.context(august, historyMonths: 4, calendar: calendar)
        let candidates = RecapCandidateGenerator.candidates(for: context)
        let first = RecapRanker.rank(candidates: candidates).map(\.id)
        let second = RecapRanker.rank(candidates: candidates).map(\.id)
        XCTAssertEqual(first, second)
    }

    func testGeneratorIsDeterministic() {
        let context = RecapFixtures.context(august, historyMonths: 4, calendar: calendar)
        XCTAssertEqual(
            RecapCandidateGenerator.candidates(for: context),
            RecapCandidateGenerator.candidates(for: context)
        )
    }

    // MARK: - Deterministic voice

    func testDeterministicVoiceProducesRealCopy() {
        let context = RecapFixtures.context(august, historyMonths: 4, calendar: calendar)
        let cards = RecapRanker.rank(candidates: RecapCandidateGenerator.candidates(for: context))
        let title = RecapDeterministicVoice.title(for: context, cards: cards)
        let closing = RecapDeterministicVoice.closing(for: context, cards: cards)

        XCTAssertFalse(title.isEmpty)
        XCTAssertTrue(title.contains("August"), title)
        XCTAssertGreaterThan(closing.count, 40)
        XCTAssertTrue(closing.hasSuffix(".") || closing.hasSuffix("!"), closing)
        // The fallback voice must not contain unresolved template artifacts.
        XCTAssertFalse(closing.contains("{"), closing)
    }
}
