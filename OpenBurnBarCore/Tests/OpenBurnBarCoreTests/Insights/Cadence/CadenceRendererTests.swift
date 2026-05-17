import XCTest
@testable import OpenBurnBarCore

final class CadenceRendererTests: XCTestCase {

    private func makeVerdict(
        headline: String = "You spent $4.12 yesterday.",
        bullets: [VerdictBullet] = [],
        rings: [VerdictRing] = [],
        keyNumbers: [VerdictNumber] = [],
        recommendation: VerdictRecommendation? = nil,
        window: VerdictWindow = .today
    ) -> InsightVerdict {
        InsightVerdict(
            generatedAt: Date(),
            window: window,
            headline: headline,
            rings: rings.isEmpty ? [
                VerdictRing(identity: .spend, label: "Spend", current: 4.12, target: 12.0, unit: .usd, valueLabel: "$4.12"),
                VerdictRing(identity: .cache, label: "Cache", current: 91, target: 85, unit: .percent, valueLabel: "91%"),
                VerdictRing(identity: .sessions, label: "Sessions", current: 3, target: 2, unit: .sessions, valueLabel: "3")
            ] : rings,
            keyNumbers: keyNumbers,
            bullets: bullets,
            recommendation: recommendation,
            provenance: InsightModelTag(providerKey: "test", modelID: "m", displayName: "Test", egressTier: .localOnly)
        )
    }

    // MARK: - Morning Brief

    func testMorningBriefProducesPushPayload() {
        let verdict = makeVerdict(bullets: [
            VerdictBullet(type: .pattern, claim: "First bullet", citations: [], confidence: .high),
            VerdictBullet(type: .pattern, claim: "Second bullet", citations: [], confidence: .medium)
        ])
        let artifact = MorningBriefRenderer().render(verdict: verdict)

        XCTAssertEqual(artifact.cadence, .daily)
        if case .push(let title, let body, let deepLink) = artifact.payload {
            XCTAssertEqual(title, verdict.headline)
            XCTAssertTrue(body.contains("•"))
            XCTAssertEqual(deepLink, "openburnbar://insights/today")
        } else {
            XCTFail("Expected push payload")
        }
    }

    func testMorningBriefFallsBackToHeadlineWhenNoBullets() {
        let verdict = makeVerdict(bullets: [])
        let artifact = MorningBriefRenderer().render(verdict: verdict)

        if case .push(_, let body, _) = artifact.payload {
            // Body falls back to headline when no bullets exist
            XCTAssertEqual(body, verdict.headline)
        } else {
            XCTFail("Expected push payload")
        }
    }

    // MARK: - Weekly Recap

    func testWeeklyRecapLockedSchema() {
        let bullets = [
            VerdictBullet(type: .achievement, claim: "Refactored auth layer", citations: [], confidence: .high),
            VerdictBullet(type: .anomaly, claim: "Cache hit rate dropped to 62%", citations: [], confidence: .medium),
            VerdictBullet(type: .risk, claim: "Quota at 89%", citations: [], confidence: .high),
            VerdictBullet(type: .recommendation, claim: "Switch to Haiku for tests", citations: [], confidence: .medium)
        ]
        let verdict = makeVerdict(bullets: bullets, window: .thisWeek)
        let artifact = WeeklyRecapRenderer().render(verdict: verdict, priorVerdict: nil)

        XCTAssertEqual(artifact.cadence, .weekly)
        if case .email(let subject, let htmlBody) = artifact.payload {
            XCTAssertTrue(subject.contains("week"))
            XCTAssertTrue(htmlBody.contains("NUMBERS"))
            XCTAssertTrue(htmlBody.contains("WINS"))
            XCTAssertTrue(htmlBody.contains("SURPRISES"))
            XCTAssertTrue(htmlBody.contains("RISKS"))
            XCTAssertTrue(htmlBody.contains("TRY NEXT WEEK"))
        } else {
            XCTFail("Expected email payload")
        }
    }

    func testWeeklyRecapEscapesHtmlContent() {
        let headline = "<script>alert(1)</script>"
        // Inject script into the WEEKLY body by putting it in a bullet claim
        let bullet = VerdictBullet(type: .pattern, claim: headline, citations: [], confidence: .medium)
        let verdict = makeVerdict(headline: "Week headline", bullets: [bullet], window: .thisWeek)
        let artifact = WeeklyRecapRenderer().render(verdict: verdict, priorVerdict: nil)

        if case .email(_, let htmlBody) = artifact.payload {
            // The raw HTML should NOT contain unescaped script tags anywhere
            XCTAssertFalse(htmlBody.contains("<script>"), "Raw <script> found in HTML body")
            // The escaped version must be present
            XCTAssertTrue(htmlBody.contains("&lt;script&gt;"), "Escaped script tag not found in body")
        } else {
            XCTFail("Expected email payload")
        }
    }

    func testWeeklyRecapNoTrailingSpaceWhenDeltaNil() {
        let ring = VerdictRing(identity: .spend, label: "Spend", current: 4.12, target: 12.0, unit: .usd, valueLabel: "$4.12", delta: nil)
        let verdict = makeVerdict(rings: [ring])
        let artifact = WeeklyRecapRenderer().render(verdict: verdict, priorVerdict: nil)

        if case .email(_, let htmlBody) = artifact.payload {
            // There should not be a trailing space before the <br> following the spend line
            XCTAssertFalse(htmlBody.contains("$4.12  <br>"))
        } else {
            XCTFail("Expected email payload")
        }
    }

    func testWeeklyRecapPreservesDecimalDelta() {
        let delta = VerdictDelta(value: 4.60, unit: .usd, baseline: "last week", direction: .lowerIsBetter)
        let ring = VerdictRing(identity: .spend, label: "Spend", current: 4.12, target: 12.0, unit: .usd, valueLabel: "$4.12", delta: delta)
        let verdict = makeVerdict(rings: [ring])
        let artifact = WeeklyRecapRenderer().render(verdict: verdict, priorVerdict: nil)

        if case .email(_, let htmlBody) = artifact.payload {
            XCTAssertTrue(htmlBody.contains("+4.60$"))
            XCTAssertFalse(htmlBody.contains("+4$"))
        } else {
            XCTFail("Expected email payload")
        }
    }

    // MARK: - Monthly Review

    func testMonthlyReviewLongFormStructure() {
        let numbers = [
            VerdictNumber(id: "spend", label: "Spend", value: "$42.00", rawValue: 42.0, unit: .usd, delta: VerdictDelta(value: -12.0, unit: .usd, baseline: "last month", direction: .lowerIsBetter)),
            VerdictNumber(id: "sessions", label: "Sessions", value: "15", rawValue: 15, unit: .sessions, delta: nil)
        ]
        let verdict = makeVerdict(keyNumbers: numbers, window: .thisMonth)
        let artifact = MonthlyReviewRenderer().render(verdict: verdict)

        XCTAssertEqual(artifact.cadence, .monthly)
        if case .email(let subject, let htmlBody) = artifact.payload {
            XCTAssertTrue(subject.contains("Monthly"))
            XCTAssertTrue(htmlBody.contains("TOP NUMBERS"))
            XCTAssertTrue(htmlBody.contains("HIGHLIGHTS"))
            // The number value and label should be in the body
            XCTAssertTrue(htmlBody.contains("Spend"), "Missing 'Spend'")
            XCTAssertTrue(htmlBody.contains("$42.00"), "Missing '$42.00'")
            XCTAssertTrue(htmlBody.contains("Sessions"), "Missing 'Sessions'")
            XCTAssertTrue(htmlBody.contains("15"), "Missing '15'")
        } else {
            XCTFail("Expected email payload")
        }
    }

    // MARK: - Year in Coding

    func testYearInCodingAggregatesSpend() {
        let v1 = makeVerdict(rings: [
            VerdictRing(identity: .spend, label: "S", current: 10.0, target: 100, unit: .usd, valueLabel: "10")
        ])
        let v2 = makeVerdict(rings: [
            VerdictRing(identity: .spend, label: "S", current: 20.0, target: 100, unit: .usd, valueLabel: "20")
        ])
        let artifact = YearInCodingRenderer().render(verdict: v1, allVerdicts: [v1, v2])

        XCTAssertEqual(artifact.cadence, .annual)
        if case .push(let title, let body, _) = artifact.payload {
            XCTAssertEqual(title, "Your Year in Coding")
            XCTAssertTrue(body.contains("$30.00"))
            XCTAssertTrue(body.contains("Sessions logged"))
        } else {
            XCTFail("Expected push payload")
        }
    }

    func testYearInCodingPicksHighestConfidenceInsight() {
        let v1 = makeVerdict(bullets: [
            VerdictBullet(type: .pattern, claim: "Low confidence", citations: [], confidence: .low),
            VerdictBullet(type: .pattern, claim: "High confidence", citations: [], confidence: .high)
        ])
        let artifact = YearInCodingRenderer().render(verdict: v1, allVerdicts: [v1])

        if case .push(_, let body, _) = artifact.payload {
            XCTAssertTrue(body.contains("High confidence"))
            XCTAssertFalse(body.contains("Low confidence"))
        } else {
            XCTFail("Expected push payload")
        }
    }

    func testYearInCodingFiltersUnknownProviders() {
        let v1 = makeVerdict(bullets: [
            VerdictBullet(type: .pattern, claim: "A", citations: [
                InsightCitation(kind: .agent(provider: "anthropic"), label: "Anthropic")
            ], confidence: .medium),
            VerdictBullet(type: .pattern, claim: "B", citations: [], confidence: .medium)
        ])
        let artifact = YearInCodingRenderer().render(verdict: v1, allVerdicts: [v1])

        if case .push(_, let body, _) = artifact.payload {
            // "Unknown" should not be the top provider
            XCTAssertTrue(body.contains("Anthropic"))
        } else {
            XCTFail("Expected push payload")
        }
    }

    // MARK: - VerdictDelta.Unit.symbol

    func testUnitSymbols() {
        XCTAssertEqual(VerdictDelta.Unit.usd.symbol, "$")
        XCTAssertEqual(VerdictDelta.Unit.tokens.symbol, " tokens")
        XCTAssertEqual(VerdictDelta.Unit.percent.symbol, "%")
        XCTAssertEqual(VerdictDelta.Unit.milliseconds.symbol, "ms")
        XCTAssertEqual(VerdictDelta.Unit.count.symbol, "")
    }
}
