import XCTest
@testable import OpenBurnBarCore

final class InsightVerdictDemoFixtureTests: XCTestCase {

    func testFixtureIsRenderable() {
        let v = InsightVerdictDemoFixture.sample()
        XCTAssertTrue(v.isRenderable)
    }

    func testFixtureSurvivesPostProcessor() {
        let v = InsightVerdictDemoFixture.sample()
        let result = InsightVoicePostProcessor().process(v)
        guard case .accepted(let cleaned, let report) = result else {
            return XCTFail("demo fixture should pass post-processor")
        }
        XCTAssertGreaterThanOrEqual(cleaned.bullets.count, 1)
        XCTAssertTrue(report.bannedPhraseHits.isEmpty,
                      "demo fixture should not trigger any banned-phrase hits")
    }

    func testFixtureRingsAreInCanonicalOrder() {
        let v = InsightVerdictDemoFixture.sample()
        XCTAssertEqual(v.rings.map(\.identity), [.spend, .cache, .sessions])
    }

    func testFixtureRecommendationHasSwitchRouterRuleAction() {
        let v = InsightVerdictDemoFixture.sample()
        XCTAssertNotNil(v.recommendation)
        XCTAssertEqual(v.recommendation?.acceptAction.intent, .switchRouterRule)
    }

    func testFixtureSessionTraceIsLogicallyOrdered() {
        let v = InsightVerdictDemoFixture.sample()
        guard let trace = v.sessionTrace else {
            return XCTFail("demo fixture should ship a session trace")
        }
        XCTAssertGreaterThan(trace.duration, 0)
        XCTAssertTrue(trace.lanes.allSatisfy { $0.duration >= 0 })
        XCTAssertEqual(trace.lanes.first?.kind, .prompt)
    }
}
