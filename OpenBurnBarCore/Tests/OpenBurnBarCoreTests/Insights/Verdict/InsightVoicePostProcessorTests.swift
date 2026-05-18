import XCTest
@testable import OpenBurnBarCore

final class InsightVoicePostProcessorTests: XCTestCase {

    private func makeRings() -> [VerdictRing] {
        [
            VerdictRing(identity: .spend, label: "Spend", current: 1, target: 2,
                        unit: .usd, valueLabel: "1/2"),
            VerdictRing(identity: .cache, label: "Cache", current: 1, target: 2,
                        unit: .percent, valueLabel: "1/2"),
            VerdictRing(identity: .sessions, label: "Sessions", current: 1, target: 2,
                        unit: .sessions, valueLabel: "1/2")
        ]
    }

    private func makeVerdict(
        headline: String = "You spent $4.12 yesterday — 28% under average.",
        bullets: [VerdictBullet] = [],
        recommendation: VerdictRecommendation? = nil,
        anomaly: VerdictAnomaly? = nil
    ) -> InsightVerdict {
        InsightVerdict(
            window: .today,
            headline: headline,
            rings: makeRings(),
            bullets: bullets,
            anomaly: anomaly,
            recommendation: recommendation,
            provenance: InsightModelTag(providerKey: "anthropic", modelID: "claude-sonnet-4-6",
                                        displayName: "Claude Sonnet 4.6", egressTier: .userKey)
        )
    }

    func testDropsBulletWithBannedPhrase() {
        let v = makeVerdict(
            bullets: [
                VerdictBullet(
                    type: .reflectiveFact,
                    claim: "Based on the data, you spent $4 today.",
                    citations: [InsightCitation(kind: .day(date: "2026-05-16"), label: "today")]
                ),
                VerdictBullet(
                    type: .reflectiveFact,
                    claim: "You spent $4 today.",
                    citations: [InsightCitation(kind: .day(date: "2026-05-16"), label: "today")]
                )
            ]
        )
        let processor = InsightVoicePostProcessor()
        guard case .accepted(let clean, let report) = processor.process(v) else {
            return XCTFail("expected acceptance")
        }
        XCTAssertEqual(clean.bullets.count, 1)
        XCTAssertEqual(clean.bullets.first?.claim, "You spent $4 today.")
        XCTAssertEqual(report.bulletsDropped, 1)
        XCTAssertTrue(report.bannedPhraseHits.contains("based on the data"))
    }

    func testRejectsHeadlineContainingBannedPhrase() {
        let v = makeVerdict(headline: "It seems that you spent $4 today.")
        guard case .rejected(let reason, _) = InsightVoicePostProcessor().process(v) else {
            return XCTFail("expected rejection")
        }
        XCTAssertEqual(reason, .headlineBannedPhrase)
    }

    func testDropsBulletWithoutNumericToken() {
        let v = makeVerdict(
            bullets: [
                VerdictBullet(
                    type: .reflectiveFact,
                    claim: "Spending was higher than usual.",  // no digits
                    citations: [InsightCitation(kind: .day(date: "2026-05-16"), label: "today")]
                ),
                VerdictBullet(
                    type: .reflectiveFact,
                    claim: "You logged 7 sessions today.",
                    citations: [InsightCitation(kind: .day(date: "2026-05-16"), label: "today")]
                )
            ]
        )
        guard case .accepted(let clean, let report) = InsightVoicePostProcessor().process(v) else {
            return XCTFail("expected acceptance")
        }
        XCTAssertEqual(clean.bullets.count, 1)
        XCTAssertEqual(report.bulletsDropped, 1)
    }

    func testDropsBulletWithNoCitationsViaValidator() {
        let v = makeVerdict(
            bullets: [
                VerdictBullet(
                    type: .reflectiveFact,
                    claim: "You spent $4 today.",
                    citations: [InsightCitation(kind: .session(id: "unknown_session", provider: nil), label: "x")]
                ),
                VerdictBullet(
                    type: .reflectiveFact,
                    claim: "You spent $4 today.",
                    citations: [InsightCitation(kind: .day(date: "2026-05-16"), label: "today")]
                )
            ]
        )
        let validator: InsightVoicePostProcessor.CitationValidator = { citation in
            switch citation.kind {
            case .session: return false
            default: return true
            }
        }
        guard case .accepted(let clean, let report) = InsightVoicePostProcessor()
            .process(v, citationValidator: validator) else {
            return XCTFail("expected acceptance")
        }
        XCTAssertEqual(clean.bullets.count, 1)
        XCTAssertEqual(report.bulletsDropped, 1)
    }

    func testRejectsWhenNoBulletsSurvive() {
        let v = makeVerdict(
            bullets: [
                VerdictBullet(
                    type: .reflectiveFact,
                    claim: "Based on the data, nothing happened.",
                    citations: [InsightCitation(kind: .day(date: "2026-05-16"), label: "today")]
                )
            ]
        )
        guard case .rejected(let reason, _) = InsightVoicePostProcessor().process(v) else {
            return XCTFail("expected rejection")
        }
        XCTAssertEqual(reason, .noBulletsAfterProcessing)
    }

    func testRejectsBadRingCount() {
        let v = InsightVerdict(
            window: .today,
            headline: "You spent $4 today.",
            rings: [],
            bullets: [
                VerdictBullet(
                    type: .reflectiveFact,
                    claim: "You spent $4 today.",
                    citations: [InsightCitation(kind: .day(date: "2026-05-16"), label: "today")]
                )
            ],
            provenance: InsightModelTag(providerKey: "x", modelID: "y", displayName: "Z", egressTier: .localOnly)
        )
        guard case .rejected(let reason, _) = InsightVoicePostProcessor().process(v) else {
            return XCTFail("expected rejection")
        }
        XCTAssertEqual(reason, .ringCountInvalid)
    }

    func testDemotesRecommendationTypeBulletWhenActionMissing() {
        let v = makeVerdict(
            bullets: [
                VerdictBullet(
                    type: .recommendation,
                    claim: "Switch to Haiku to save $14 this week.",
                    citations: [InsightCitation(kind: .day(date: "2026-05-16"), label: "today")],
                    acceptAction: nil
                )
            ]
        )
        guard case .accepted(let clean, _) = InsightVoicePostProcessor().process(v) else {
            return XCTFail("expected acceptance")
        }
        XCTAssertEqual(clean.bullets.count, 1)
        XCTAssertEqual(clean.bullets.first?.type, .pattern,
                       "recommendation without action should demote to pattern")
    }

    func testActionLabelTruncatedToTwentyEightChars() {
        let longLabel = String(repeating: "X", count: 80)
        let v = makeVerdict(
            bullets: [
                VerdictBullet(
                    type: .recommendation,
                    claim: "Switch to Haiku to save $14 this week.",
                    citations: [InsightCitation(kind: .day(date: "2026-05-16"), label: "today")],
                    acceptAction: VerdictAcceptAction(label: longLabel, intent: .switchRouterRule)
                )
            ]
        )
        guard case .accepted(let clean, _) = InsightVoicePostProcessor().process(v) else {
            return XCTFail("expected acceptance")
        }
        XCTAssertEqual(clean.bullets.first?.acceptAction?.label.count, 28)
    }
}
