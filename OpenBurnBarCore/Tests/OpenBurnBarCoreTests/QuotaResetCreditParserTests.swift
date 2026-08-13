import XCTest
@testable import OpenBurnBarCore

final class QuotaResetCreditParserTests: XCTestCase {
    func test_parsesKnownInventoryKey() throws {
        let json = """
        {
          "reset_credits": [
            {
              "id": "card-1",
              "expires_at": "2026-09-01T00:00:00Z",
              "source": "promotional"
            }
          ]
        }
        """.data(using: .utf8)!
        let credits = QuotaResetCreditParser.parse(payload: json, now: Date(timeIntervalSince1970: 1_787_011_200))
        XCTAssertEqual(credits.map(\.id), ["card-1"])
        XCTAssertEqual(credits.first?.source, .promotional)
    }

    func test_unknownPayload_isEmpty() throws {
        let json = #"{"rate_limit":{"primary_window":{"used_percent":12}}}"#.data(using: .utf8)!
        XCTAssertTrue(QuotaResetCreditParser.parse(payload: json).isEmpty)
    }

    func test_expiredAndRedeemedCards_areDropped() throws {
        let json = """
        {
          "banked_resets": [
            { "id": "old", "expires_at": "2020-01-01T00:00:00Z" },
            { "id": "used", "expires_at": "2026-09-01T00:00:00Z", "redeemed": true },
            { "id": "live", "expires_at": "2026-09-01T00:00:00Z" }
          ]
        }
        """.data(using: .utf8)!
        let credits = QuotaResetCreditParser.parse(payload: json, now: Date(timeIntervalSince1970: 1_787_011_200))
        XCTAssertEqual(credits.map(\.id), ["live"])
    }
}
