import Foundation
import XCTest

@testable import OpenBurnBarKernel

/// One cost rule (Wave 2.5, decision 3): the cross-client fixture in
/// `tests/fixtures/cost-rule/v1.json` must produce the identical total here,
/// in Functions, and on Android — normative spec in
/// `tests/fixtures/cost-rule/README.md`.
final class CostRuleTests: XCTestCase {
    func testRuleUnits() {
        XCTAssertEqual(CostRule.effectiveCostUSD(costUSD: 1.25, costUsd: 999, cost: 888), 1.25)
        XCTAssertEqual(CostRule.effectiveCostUSD(costUSD: 0, costUsd: 4, cost: 4), 0)
        XCTAssertEqual(CostRule.effectiveCostUSD(costUSD: nil, costUsd: 0.04, cost: nil), 0.04)
        XCTAssertEqual(CostRule.effectiveCostUSD(costUSD: nil, costUsd: nil, cost: 0.03), 0.03)
        XCTAssertEqual(CostRule.effectiveCostUSD(costUSD: -1, costUsd: 0.25, cost: 5), 0.25)
        XCTAssertEqual(CostRule.effectiveCostUSD(costUSD: -1, costUsd: -2, cost: -3), 0)
        XCTAssertEqual(CostRule.effectiveCostUSD(costUSD: .nan, costUsd: 1, cost: nil), 1)
        XCTAssertEqual(CostRule.effectiveCostUSD(costUSD: .infinity, costUsd: nil, cost: 2), 2)
        XCTAssertEqual(CostRule.effectiveCostUSD(costUSD: nil, costUsd: nil, cost: nil), 0)
    }

    func testFixtureProducesPinnedValuesAndTotal() throws {
        let fixtureURL = try XCTUnwrap(fixtureURL(), "cost-rule fixture missing above \(#filePath)")
        let data = try Data(contentsOf: fixtureURL)
        let decoded = try JSONDecoder().decode(CostRuleFixture.self, from: data)
        XCTAssertEqual(decoded.version, 1)
        var total = 0.0
        for event in decoded.events {
            let effective = CostRule.effectiveCostUSD(
                costUSD: event.number(for: "costUSD"),
                costUsd: event.number(for: "costUsd"),
                cost: event.number(for: "cost")
            )
            XCTAssertEqual(effective, event.expectedEffective, "event \(event.id)")
            total += effective
        }
        XCTAssertEqual(total, decoded.expectedTotal)
    }

    func testTokenUsageDecoderAppliesRuleAndEncodesCanonTwin() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let usage = try decoder.decode(TokenUsage.self, from: Data(tokenUsageJSON.utf8))
        XCTAssertEqual(usage.costUSD, 1.25)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let roundTrip = try JSONDecoder().decode(
            [String: CostRuleAnyDecodable].self,
            from: try encoder.encode(usage)
        )
        XCTAssertEqual(roundTrip["costUSD"]?.value as? Double, 1.25)
        XCTAssertEqual(roundTrip["cost"]?.value as? Double, 1.25)
    }
}

// MARK: - Fixture plumbing

private struct CostRuleFixture: Decodable {
    let version: Int
    let expectedTotal: Double
    let events: [CostRuleFixtureEvent]
}

private struct CostRuleFixtureEvent: Decodable {
    let id: String
    let expectedEffective: Double
    let spellings: [String: CostRuleAnyDecodable]

    private enum KnownKeys: String, CodingKey {
        case id, expectedEffective
    }

    init(from decoder: Decoder) throws {
        let known = try decoder.container(keyedBy: KnownKeys.self)
        id = try known.decode(String.self, forKey: .id)
        expectedEffective = try known.decode(Double.self, forKey: .expectedEffective)
        // Strings must survive as strings (never coerced): decode the dynamic
        // remainder losslessly, then project numbers only in `number(for:)`.
        let dynamic = try decoder.container(keyedBy: CostRuleAnyCodingKey.self)
        var spellings: [String: CostRuleAnyDecodable] = [:]
        for key in dynamic.allKeys where KnownKeys(stringValue: key.stringValue) == nil {
            spellings[key.stringValue] = try dynamic.decode(CostRuleAnyDecodable.self, forKey: key)
        }
        self.spellings = spellings
    }

    /// Projects a spelling to Double only when the JSON value is a number —
    /// strings (and anything else) yield nil, per the no-coercion rule.
    func number(for key: String) -> Double? {
        spellings[key]?.value as? Double
    }
}

private struct CostRuleAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// Minimal lossless JSON value (numbers stay numbers, strings stay strings)
/// so the fixture test — not the decoder — enforces no-coercion.
private struct CostRuleAnyDecodable: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            value = NSNull()
        } else if let number = try? single.decode(Double.self) {
            value = number
        } else if let string = try? single.decode(String.self) {
            value = string
        } else if let bool = try? single.decode(Bool.self) {
            value = bool
        } else {
            value = NSNull()
        }
    }
}

private func fixtureURL() -> URL? {
    var dir: URL? = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0 ..< 6 {
        let candidate = dir?.appendingPathComponent("tests/fixtures/cost-rule/v1.json")
        if let candidate, FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        dir = dir?.deletingLastPathComponent()
    }
    return nil
}

private let tokenUsageJSON = """
    {
        "id": "9C2B8C1E-3F4A-4B5C-8D6E-7F809A0B1C2D",
        "provider": "Claude Code",
        "sessionId": "session-1",
        "projectName": "demo",
        "model": "claude-opus-4-6",
        "inputTokens": 100,
        "outputTokens": 50,
        "costUSD": 1.25,
        "costUsd": 999.0,
        "cost": 888.0,
        "startTime": "2026-09-23T00:00:00Z",
        "endTime": "2026-09-23T00:01:00Z"
    }
    """
