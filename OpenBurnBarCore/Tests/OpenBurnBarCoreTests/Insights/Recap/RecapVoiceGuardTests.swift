import XCTest
@testable import OpenBurnBarCore
@testable import OpenBurnBarInsights
@testable import OpenBurnBarRecap

/// The guard that makes model-written prose safe to ship.
final class RecapVoiceGuardTests: XCTestCase {

    private let calendar = RecapFixtures.calendar()
    private let august = RecapWindow(year: 2026, month: 8)

    // MARK: - Helpers

    private func candidate(
        id: String = "favourite-model:opus",
        headline: String = "You found a favorite.",
        body: String = "Claude Opus 5 handled 41% of your sessions.",
        metrics: [RecapMetric] = [
            RecapMetric("Share of sessions", 0.41, .percent),
            RecapMetric("Sessions", 87, .count)
        ]
    ) -> RecapCandidate {
        RecapCandidate(
            id: id,
            ruleID: "favourite-model",
            family: "model:opus",
            kind: .personality,
            tone: .celebratory,
            headline: headline,
            body: body,
            metrics: metrics,
            visual: .spotlight,
            suggestedSize: .medium,
            novelty: 0.8, significance: 0.8, relevance: 0.8, confidence: 0.8
        )
    }

    private func card(_ candidate: RecapCandidate) -> RecapCard {
        RecapCard(candidate: candidate, size: .medium)
    }

    private func response(
        headline: String,
        body: String,
        id: String = "favourite-model:opus",
        title: String = "August was your builder month",
        closing: String = "You leaned on one model, kept sessions long, and stayed at it most days of the month."
    ) -> RecapVoiceResponse {
        RecapVoiceResponse(
            monthTitle: title,
            monthSubtitle: nil,
            monthInOneSentence: closing,
            cards: [.init(id: id, headline: headline, body: body, drop: nil, promote: nil)]
        )
    }

    // MARK: - Numeric containment

    /// The failure this whole layer exists to prevent: fluent, plausible,
    /// and not a number anyone computed.
    func testInventedNumberIsRejected() {
        let subject = candidate()
        let processor = RecapVoicePostProcessor()
        let result = processor.process(
            response: response(
                headline: "A clear favorite.",
                body: "Claude Opus 5 handled 63% of your sessions, up from 12% before."
            ),
            deterministicCards: [card(subject)],
            fallbackTitle: "Your August with AI",
            fallbackClosing: "A steady month.",
            mapping: .identity
        )

        guard case let .accepted(outcome, report) = result else {
            XCTFail("expected acceptance with a fallback card")
            return
        }
        XCTAssertEqual(report.cardsVoiced, 0)
        XCTAssertEqual(report.cardsFellBack, 1)
        XCTAssertFalse(report.numericViolations.isEmpty)
        // The card still ships — with the sentence we computed.
        XCTAssertEqual(outcome.cards.first?.body, subject.body)
        XCTAssertFalse(outcome.cards.first?.isVoiceAuthored ?? true)
    }

    func testNumbersDrawnFromMetricsAreAccepted() {
        let subject = candidate()
        let processor = RecapVoicePostProcessor()
        let result = processor.process(
            response: response(
                headline: "You picked a favorite.",
                body: "Claude Opus 5 took 41% of your sessions — 87 of them in all."
            ),
            deterministicCards: [card(subject)],
            fallbackTitle: "Your August with AI",
            fallbackClosing: "A steady month.",
            mapping: .identity
        )

        guard case let .accepted(outcome, report) = result else {
            XCTFail("expected acceptance")
            return
        }
        XCTAssertEqual(report.cardsVoiced, 1)
        XCTAssertTrue(outcome.cards.first?.isVoiceAuthored ?? false)
        XCTAssertEqual(outcome.cards.first?.body, "Claude Opus 5 took 41% of your sessions — 87 of them in all.")
    }

    /// Writing "$41" for a metric of "$41.20" is readability, not invention.
    func testRoundedCurrencyVariantIsAllowed() {
        let subject = candidate(
            body: "You spent $41.20.",
            metrics: [RecapMetric("Spend", 41.20, .usd)]
        )
        let vocabulary = RecapVoicePostProcessor.vocabulary(for: subject)
        XCTAssertNil(RecapVoicePostProcessor.numericViolation(in: "About $41 this month.", vocabulary: vocabulary))
        XCTAssertNotNil(RecapVoicePostProcessor.numericViolation(in: "About $52 this month.", vocabulary: vocabulary))
    }

    func testNumericTokenNormalisation() {
        XCTAssertEqual(RecapVoicePostProcessor.numericTokens(in: "1,842 prompts"), ["1842"])
        XCTAssertEqual(RecapVoicePostProcessor.numericTokens(in: "$41.20 and 41.0%"), ["41.2", "41"])
        XCTAssertEqual(RecapVoicePostProcessor.numericTokens(in: "no digits here"), [])
    }

    // MARK: - Voice

    func testBannedPhraseFallsBack() {
        let subject = candidate()
        let processor = RecapVoicePostProcessor()
        let result = processor.process(
            response: response(
                headline: "You crushed it.",
                body: "Claude Opus 5 handled 41% of your sessions."
            ),
            deterministicCards: [card(subject)],
            fallbackTitle: "Your August with AI",
            fallbackClosing: "A steady month.",
            mapping: .identity
        )
        guard case let .accepted(_, report) = result else { XCTFail("expected acceptance")
 return }
        XCTAssertEqual(report.cardsFellBack, 1)
        XCTAssertFalse(report.bannedPhraseHits.isEmpty)
    }

    func testUnknownCardIDsAreIgnored() {
        let subject = candidate()
        let processor = RecapVoicePostProcessor()
        let result = processor.process(
            response: response(headline: "Nice.", body: "Something about 41%.", id: "not-a-real-card"),
            deterministicCards: [card(subject)],
            fallbackTitle: "Your August with AI",
            fallbackClosing: "A steady month.",
            mapping: .identity
        )
        guard case let .accepted(outcome, report) = result else { XCTFail("expected acceptance")
 return }
        XCTAssertEqual(report.unknownIDs, 1)
        // The real card is still there — omission is not a decision.
        XCTAssertEqual(outcome.cards.map(\.id), [subject.id])
    }

    func testDropIsHonouredButCannotEmptyTheRecap() {
        let cards = (1...6).map { index in
            card(candidate(id: "card-\(index)"))
        }
        let processor = RecapVoicePostProcessor(minimumCards: 4)
        let dropAll = RecapVoiceResponse(
            monthTitle: "August was your builder month",
            monthSubtitle: nil,
            monthInOneSentence: "You leaned on one model and stayed at it most days of the month.",
            cards: cards.map { .init(id: $0.id, headline: "x", body: "y", drop: true, promote: nil) }
        )
        let result = processor.process(
            response: dropAll,
            deterministicCards: cards,
            fallbackTitle: "Your August with AI",
            fallbackClosing: "A steady month.",
            mapping: .identity
        )
        guard case .rejected(let reason, _) = result else {
            XCTFail("a model must not be able to empty the recap")
            return
        }
        XCTAssertEqual(reason, .nothingSurvived)
    }

    func testPromoteResizesACard() {
        let subject = candidate()
        let processor = RecapVoicePostProcessor()
        let promoted = RecapVoiceResponse(
            monthTitle: "August was your builder month",
            monthSubtitle: nil,
            monthInOneSentence: "You leaned on one model and stayed at it most days of the month.",
            cards: [.init(
                id: subject.id,
                headline: "You picked a favorite.",
                body: "Claude Opus 5 took 41% of your sessions.",
                drop: nil,
                promote: true
            )]
        )
        let result = processor.process(
            response: promoted,
            deterministicCards: [card(subject)],
            fallbackTitle: "Your August with AI",
            fallbackClosing: "A steady month.",
            mapping: .identity
        )
        guard case let .accepted(outcome, _) = result else { XCTFail("expected acceptance")
 return }
        XCTAssertEqual(outcome.cards.first?.size, .hero)
    }

    // MARK: - Redaction

    func testRedactionRoundTripsAndPrefersLongerNames() {
        var redaction = RecapRedaction()
        redaction.register("BurnBar")
        redaction.register("BurnBar Mobile")

        let original = "BurnBar Mobile took over from BurnBar this month."
        let redacted = redaction.redact(original)
        XCTAssertFalse(redacted.contains("BurnBar"))
        XCTAssertEqual(redaction.restore(redacted), original)
    }

    func testInventedPlaceholderIsRejected() {
        var redaction = RecapRedaction()
        redaction.register("BurnBar")
        let subject = candidate()
        let processor = RecapVoicePostProcessor()

        let result = processor.process(
            response: response(
                headline: "Focus moved.",
                body: "{project9} took 41% of your month."
            ),
            deterministicCards: [card(subject)],
            fallbackTitle: "Your August with AI",
            fallbackClosing: "A steady month.",
            mapping: RecapPromptMapping(redaction: redaction, idByToken: [:])
        )
        guard case let .accepted(outcome, report) = result else { XCTFail("expected acceptance")
 return }
        XCTAssertEqual(report.unresolvedTokenHits, 1)
        XCTAssertFalse(outcome.cards.first?.body.contains("{project") ?? true)
    }

    /// Nothing private may reach the payload, and the tokens must survive it.
    func testPromptPayloadCarriesNoProjectNames() {
        let context = RecapFixtures.context(august, historyMonths: 3, calendar: calendar)
        let candidates = RecapCandidateGenerator.candidates(for: context)
        let (payload, mapping) = RecapPromptPayload.build(context: context, candidates: candidates)
        let json = payload.json()

        XCTAssertFalse(mapping.redaction.isEmpty, "fixture months use project names")
        XCTAssertEqual(mapping.idByToken.count, candidates.count)
        // Opaque ids only — a rule id like "headline-project:burnbar" must never travel.
        XCTAssertTrue(mapping.idByToken.keys.allSatisfy { $0.hasPrefix("c") })
        for project in context.facts.projects {
            XCTAssertFalse(
                json.localizedCaseInsensitiveContains(project.label),
                "project name \(project.label) leaked into the prompt payload"
            )
        }
        // Model and provider names are product identifiers and do travel.
        XCTAssertTrue(json.contains("Claude Opus 5") || json.contains("GPT-5"))
    }

    // MARK: - Quantities in words

    /// The numeric guard reads digits, so "nearly half" used to sail through it
    /// while inventing the claim outright.
    func testQuantityWordsAreRejected() {
        let subject = candidate()
        let processor = RecapVoicePostProcessor()
        for phrase in ["Claude Opus 5 handled nearly half your sessions.",
                       "It doubled since last month.",
                       "The vast majority of your work ran through it."] {
            let result = processor.process(
                response: response(headline: "A favorite.", body: phrase),
                deterministicCards: [card(subject)],
                fallbackTitle: "Your August with AI",
                fallbackClosing: "A steady month.",
                mapping: .identity
            )
            guard case let .accepted(outcome, report) = result else {
                XCTFail("expected acceptance with a fallback for: \(phrase)")
                return
            }
            XCTAssertEqual(report.cardsFellBack, 1, phrase)
            XCTAssertEqual(outcome.cards.first?.body, subject.body, phrase)
        }
    }

    /// Short names are the ones most likely to be a client or employer code.
    func testShortProjectNamesAreStillTokenized() {
        var redaction = RecapRedaction()
        redaction.register("fx")
        XCTAssertFalse(redaction.isEmpty, "a two-letter project must still be tokenized")

        let redacted = redaction.redact("fx took most of the month")
        XCTAssertFalse(redacted.contains("fx"))
        XCTAssertEqual(redaction.restore(redacted), "fx took most of the month")
    }

    /// ...but tokenizing them must not corrupt unrelated words.
    func testShortNamesMatchOnWordBoundariesOnly() {
        var redaction = RecapRedaction()
        redaction.register("fx")
        let text = "the prefix and the suffix stayed intact, fx did not"
        let redacted = redaction.redact(text)
        XCTAssertTrue(redacted.contains("prefix"), redacted)
        XCTAssertTrue(redacted.contains("suffix"), redacted)
        XCTAssertEqual(redaction.restore(redacted), text)
    }

    // MARK: - JSON extraction

    func testJSONExtractionSurvivesFencesAndBracesInStrings() {
        let text = """
        Sure! Here you go:
        ```json
        {"monthTitle": "August {was} your month", "cards": []}
        ```
        """
        let extracted = ModelResponseJSON.extractFirstObject(from: text)
        XCTAssertEqual(extracted, #"{"monthTitle": "August {was} your month", "cards": []}"#)
    }
}
