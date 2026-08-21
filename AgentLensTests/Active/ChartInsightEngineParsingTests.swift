import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

final class ChartInsightEngineParsingTests: XCTestCase {

    func test_cacheDecision_neverReusesInsightsForDifferentSnapshotKey() {
        let now = Date(timeIntervalSince1970: 10_000)
        let cached = ChartsDataService.SnapshotKey(usagesVersion: 7, timeRange: .today)
        let requested = ChartsDataService.SnapshotKey(usagesVersion: 8, timeRange: .last7Days)

        XCTAssertEqual(
            ChartInsightEngine.cacheDecision(
                cachedKey: cached,
                cachedAt: now.addingTimeInterval(-60),
                requestedKey: requested,
                now: now
            ),
            .throttle
        )
        XCTAssertEqual(
            ChartInsightEngine.cacheDecision(
                cachedKey: cached,
                cachedAt: now.addingTimeInterval(-16 * 60),
                requestedKey: requested,
                now: now
            ),
            .generate
        )
    }

    func test_cacheDecision_reusesOnlyAnExactSnapshotKey() {
        let now = Date(timeIntervalSince1970: 10_000)
        let key = ChartsDataService.SnapshotKey(usagesVersion: 7, timeRange: .today)

        XCTAssertEqual(
            ChartInsightEngine.cacheDecision(
                cachedKey: key,
                cachedAt: now.addingTimeInterval(-60 * 60),
                requestedKey: key,
                now: now
            ),
            .reuse
        )
    }

    private let validPayload = """
    {"insights":[{"id":"a","severity":"warning","title":"Spend doubled",\
    "body":"This week's burn is 2x last week's.","metricRefs":["weekOverWeekDelta"]}],\
    "suggestedCharts":[{"kind":"modelConcentration","reason":"One model dominates."}]}
    """

    // MARK: Happy path

    func test_parse_validJSON() throws {
        let result = try XCTUnwrap(ChartInsightParser.parse(validPayload))
        XCTAssertEqual(result.insights.count, 1)
        XCTAssertEqual(result.insights[0].severity, .warning)
        XCTAssertEqual(result.insights[0].metricRefs, ["weekOverWeekDelta"])
        XCTAssertEqual(result.suggestedCharts.map(\.kind), [.modelConcentration])
    }

    func test_parse_fencedJSONWithProse() throws {
        let text = "Here are your insights!\n```json\n\(validPayload)\n```\nHope that helps."
        let result = try XCTUnwrap(ChartInsightParser.parse(text))
        XCTAssertEqual(result.insights.count, 1)
    }

    // MARK: Tolerance

    func test_parse_dropsUnknownChartKinds() throws {
        let text = """
        {"insights":[{"title":"t","body":"b","metricRefs":["burnOverTime","madeUpKind"]}],\
        "suggestedCharts":[{"kind":"alsoMadeUp","reason":"nope"},{"kind":"cacheROI","reason":"yes"}]}
        """
        let result = try XCTUnwrap(ChartInsightParser.parse(text))
        XCTAssertEqual(result.insights[0].metricRefs, ["burnOverTime"])
        XCTAssertEqual(result.suggestedCharts.map(\.kind), [.cacheROI])
    }

    func test_parse_missingSeverity_defaultsToInfo() throws {
        let text = #"{"insights":[{"title":"t","body":"b"}]}"#
        let result = try XCTUnwrap(ChartInsightParser.parse(text))
        XCTAssertEqual(result.insights[0].severity, .info)
    }

    func test_parse_truncatesOversizedText() throws {
        let longTitle = String(repeating: "x", count: 500)
        let text = #"{"insights":[{"title":"\#(longTitle)","body":"b"}]}"#
        let result = try XCTUnwrap(ChartInsightParser.parse(text))
        XCTAssertLessThanOrEqual(result.insights[0].title.count, 80)
    }

    // MARK: Failure modes

    func test_parse_malformed_returnsNil() {
        XCTAssertNil(ChartInsightParser.parse("I could not analyze your data, sorry!"))
        XCTAssertNil(ChartInsightParser.parse("{\"insights\": [unterminated"))
        XCTAssertNil(ChartInsightParser.parse(""))
    }

    func test_parse_emptyPayload_returnsNil() {
        XCTAssertNil(ChartInsightParser.parse(#"{"insights":[],"suggestedCharts":[]}"#))
    }

    // MARK: JSON object extraction
    //
    // The extractor lives in Insights as `ModelResponseJSON`; the recap needed
    // the same fence-tolerant parse; these cases follow it so the behaviour
    // stays covered at its one implementation.

    func test_extractJSONObject_balancesNestedBracesAndStrings() {
        let text = #"noise {"a": {"b": "close } brace in string"}, "c": 1} trailing"#
        XCTAssertEqual(
            ModelResponseJSON.extractFirstObject(from: text),
            #"{"a": {"b": "close } brace in string"}, "c": 1}"#
        )
    }

    func test_extractJSONObject_noObject_returnsNil() {
        XCTAssertNil(ModelResponseJSON.extractFirstObject(from: "no braces here"))
    }

    // MARK: Metrics serializer

    func test_compactJSON_producesValidJSONWithoutSensitiveFields() throws {
        let snapshot = ChartsSnapshot.build(
            rows: ChartsSnapshotFixtures.sampleRows(),
            recentRows: ChartsSnapshotFixtures.sampleRows(),
            timeRange: .last7Days,
            usagesVersion: 1
        )
        let json = ChartInsightMetrics.compactJSON(from: snapshot)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        XCTAssertNotNil(object["totalCostUSD"])
        XCTAssertNotNil(object["burnDaily"])
        // No session ids, project names, or device identifiers leave the app.
        XCTAssertFalse(json.contains("sessionId"))
        XCTAssertFalse(json.contains("session-"))
        XCTAssertFalse(json.contains("deviceId"))
        XCTAssertFalse(json.contains("SecretProject"))
    }

    func test_prompt_embedsSchemaAndKinds() {
        let prompt = ChartInsightMetrics.prompt(metricsJSON: "{}")
        XCTAssertTrue(prompt.contains("suggestedCharts"))
        XCTAssertTrue(prompt.contains(ChartKind.burnOverTime.rawValue))
        XCTAssertTrue(prompt.contains("ONLY a JSON object"))
    }
}
