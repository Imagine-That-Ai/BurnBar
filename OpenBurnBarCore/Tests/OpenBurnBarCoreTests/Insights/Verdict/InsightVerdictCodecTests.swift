import XCTest
@testable import OpenBurnBarCore

final class InsightVerdictCodecTests: XCTestCase {

    private func makeMinimalRings() -> [VerdictRing] {
        [
            VerdictRing(identity: .spend, label: "Spend", current: 4.12, target: 12,
                        unit: .usd, valueLabel: "$4.12 / $12"),
            VerdictRing(identity: .cache, label: "Cache", current: 91, target: 85,
                        unit: .percent, valueLabel: "91% / 85%"),
            VerdictRing(identity: .sessions, label: "Sessions", current: 3, target: 2,
                        unit: .sessions, valueLabel: "3 / 2")
        ]
    }

    private func sampleVerdict() -> InsightVerdict {
        InsightVerdict(
            window: .today,
            headline: "You spent $4.12 yesterday — 28% under your 4-week average.",
            subhead: "Cache held at 91%.",
            rings: makeMinimalRings(),
            bullets: [
                VerdictBullet(
                    type: .comparison,
                    claim: "You spent $4.12 — 28% under your 4-week average.",
                    citations: [InsightCitation(kind: .day(date: "2026-05-15"), label: "yesterday")]
                )
            ],
            provenance: InsightModelTag(
                providerKey: "local-rules",
                modelID: "rule-based-v2",
                displayName: "Local rules",
                egressTier: .localOnly
            ),
            isRuleBased: true
        )
    }

    func testRoundTripJSONPreservesAllFields() throws {
        let original = sampleVerdict()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(InsightVerdict.self, from: data)

        XCTAssertEqual(decoded.headline, original.headline)
        XCTAssertEqual(decoded.subhead, original.subhead)
        XCTAssertEqual(decoded.rings.count, 3)
        XCTAssertEqual(decoded.bullets.count, 1)
        XCTAssertEqual(decoded.bullets.first?.citations.count, 1)
        XCTAssertEqual(decoded.window, .today)
        XCTAssertEqual(decoded.provenance.providerKey, "local-rules")
        XCTAssertTrue(decoded.isRuleBased)
        XCTAssertEqual(decoded.schemaVersion, InsightVerdict.currentSchemaVersion)
    }

    func testDecodingToleratesMissingOptionalsAndExtraFields() throws {
        let json = """
        {
          "id": "8E5C6F1E-1A4E-4C9B-9C8E-EA3F2A8E6B11",
          "schemaVersion": 1,
          "generatedAt": "2026-05-16T12:00:00Z",
          "window": "today",
          "headline": "Test",
          "rings": [
            {"identity": "spend", "label": "Spend", "current": 1, "target": 2, "unit": "usd", "valueLabel": "1/2", "tint": "ember"},
            {"identity": "cache", "label": "Cache", "current": 50, "target": 85, "unit": "pct", "valueLabel": "50/85", "tint": "silver"},
            {"identity": "sessions", "label": "Sessions", "current": 1, "target": 2, "unit": "sessions", "valueLabel": "1/2", "tint": "mercury"}
          ],
          "provenance": {
            "providerKey": "x",
            "modelID": "y",
            "displayName": "Z",
            "egressTier": "localOnly",
            "stampedAt": "2026-05-16T12:00:00Z"
          },
          "futureField": {"some": "value"}
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(InsightVerdict.self, from: json)
        XCTAssertEqual(decoded.headline, "Test")
        XCTAssertEqual(decoded.bullets.count, 0)
        XCTAssertNil(decoded.subhead)
        XCTAssertEqual(decoded.confidence, .medium)
    }

    func testInitTruncatesHeadlineToMaxLength() {
        let long = String(repeating: "A", count: 500)
        let v = InsightVerdict(
            window: .today,
            headline: long,
            rings: makeMinimalRings(),
            provenance: InsightModelTag(providerKey: "p", modelID: "m", displayName: "M", egressTier: .localOnly)
        )
        XCTAssertEqual(v.headline.count, InsightVerdict.headlineMaxLength)
    }

    func testInitCapsBulletsAndFollowUps() {
        let manyBullets = (0..<10).map { i in
            VerdictBullet(
                type: .reflectiveFact,
                claim: "claim \(i) with 12 numbers",
                citations: [InsightCitation(kind: .day(date: "2026-05-16"), label: "today")]
            )
        }
        let manyFollowUps = (0..<10).map { "follow up \($0)?" }
        let v = InsightVerdict(
            window: .today,
            headline: "Test headline",
            rings: makeMinimalRings(),
            bullets: manyBullets,
            provenance: InsightModelTag(providerKey: "p", modelID: "m", displayName: "M", egressTier: .localOnly),
            followUps: manyFollowUps
        )
        XCTAssertEqual(v.bullets.count, InsightVerdict.maxBullets)
        XCTAssertEqual(v.followUps.count, InsightVerdict.maxFollowUps)
    }

    func testIsRenderableRequiresThreeRingsAndCitedBullets() {
        let twoRings = makeMinimalRings().dropLast()
        let badRings = InsightVerdict(
            window: .today,
            headline: "x",
            rings: Array(twoRings),
            provenance: InsightModelTag(providerKey: "p", modelID: "m", displayName: "M", egressTier: .localOnly)
        )
        XCTAssertFalse(badRings.isRenderable)

        let cited = InsightVerdict(
            window: .today,
            headline: "x",
            rings: makeMinimalRings(),
            bullets: [
                VerdictBullet(
                    type: .reflectiveFact,
                    claim: "1 fact",
                    citations: [InsightCitation(kind: .day(date: "2026-05-16"), label: "today")]
                )
            ],
            provenance: InsightModelTag(providerKey: "p", modelID: "m", displayName: "M", egressTier: .localOnly)
        )
        XCTAssertTrue(cited.isRenderable)
    }
}
