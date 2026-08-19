import XCTest
@testable import OpenBurnBarKernel

/// Persistence is where a schedule quietly becomes the wrong schedule. These
/// pin that every cadence survives the round trip exactly, and that a row which
/// cannot describe a real schedule is dropped rather than coerced.
final class StandingOrderRowTests: XCTestCase {

    private let created = Date(timeIntervalSince1970: 1_770_000_000)
    private let updated = Date(timeIntervalSince1970: 1_770_000_500)

    private func order(
        cadence: StandingOrder.Cadence,
        capabilities: Set<String> = [],
        target: String? = nil,
        enabled: Bool = true,
        lastFired: Date? = nil
    ) -> StandingOrder {
        StandingOrder(
            id: "order-1",
            title: "Nightly suite",
            instruction: "run the full suite",
            cadence: cadence,
            targetBodyID: target,
            requiredCapabilities: capabilities,
            isEnabled: enabled,
            lastFiredAt: lastFired,
            createdAt: created
        )
    }

    private func roundTrip(_ order: StandingOrder) -> StandingOrder? {
        StandingOrderRow(order: order, updatedAt: updated).order
    }

    // MARK: - Round trips

    func test_intervalCadenceRoundTrips() {
        let original = order(cadence: .everyMinutes(45))
        XCTAssertEqual(roundTrip(original), original)
    }

    func test_dailyCadenceRoundTrips() {
        let original = order(cadence: .daily(hour: 6, minute: 5))
        XCTAssertEqual(roundTrip(original), original)
    }

    func test_weeklyCadenceRoundTrips() {
        let original = order(cadence: .weekly(weekday: 6, hour: 22, minute: 30))
        XCTAssertEqual(roundTrip(original), original)
    }

    func test_everyFieldSurvivesTheRoundTrip() {
        let original = order(
            cadence: .weekly(weekday: 2, hour: 9, minute: 0),
            capabilities: ["hermes_chat", "fleet_probe"],
            target: "mac-mini",
            enabled: false,
            lastFired: created
        )
        XCTAssertEqual(roundTrip(original), original)
    }

    func test_rowRecordsTheDecomposedCadenceForSQLToRead() {
        let row = StandingOrderRow(
            order: order(cadence: .weekly(weekday: 3, hour: 14, minute: 45)),
            updatedAt: updated
        )
        XCTAssertEqual(row.cadenceKind, "weekly")
        XCTAssertEqual(row.cadenceWeekday, 3)
        XCTAssertEqual(row.cadenceHour, 14)
        XCTAssertEqual(row.cadenceMinute, 45)
        XCTAssertNil(row.cadenceMinutes, "an unused component stays null")
    }

    func test_intervalRowLeavesClockComponentsNull() {
        let row = StandingOrderRow(
            order: order(cadence: .everyMinutes(15)),
            updatedAt: updated
        )
        XCTAssertEqual(row.cadenceKind, "interval")
        XCTAssertEqual(row.cadenceMinutes, 15)
        XCTAssertNil(row.cadenceHour)
        XCTAssertNil(row.cadenceMinute)
        XCTAssertNil(row.cadenceWeekday)
    }

    // MARK: - Capabilities

    func test_capabilitiesSerialiseDeterministically() {
        let first = StandingOrderRow(
            order: order(cadence: .everyMinutes(5), capabilities: ["b", "a", "c"]),
            updatedAt: updated
        )
        let second = StandingOrderRow(
            order: order(cadence: .everyMinutes(5), capabilities: ["c", "a", "b"]),
            updatedAt: updated
        )
        XCTAssertEqual(first.requiredCapabilities, "a\nb\nc")
        XCTAssertEqual(first, second, "set ordering must not produce a spurious row diff")
    }

    func test_emptyCapabilitiesRoundTripAsEmpty() {
        let row = StandingOrderRow(
            order: order(cadence: .everyMinutes(5)),
            updatedAt: updated
        )
        XCTAssertEqual(row.requiredCapabilities, "")
        XCTAssertEqual(row.order?.requiredCapabilities, [])
    }

    func test_capabilityDecodingIgnoresBlankLines() {
        XCTAssertEqual(StandingOrderRow.decode("a\n\n  \nb\n"), ["a", "b"])
    }

    // MARK: - Refusing bad rows

    /// Silently rescheduling somebody's nightly job to some other time is worse
    /// than not running it, so a row that cannot describe a real schedule is
    /// dropped rather than defaulted.
    func test_unknownCadenceKindIsDropped() {
        var row = StandingOrderRow(
            order: order(cadence: .everyMinutes(5)),
            updatedAt: updated
        )
        row.cadenceKind = "fortnightly"
        XCTAssertNil(row.order)
    }

    func test_intervalRowWithoutItsMinutesIsDropped() {
        var row = StandingOrderRow(
            order: order(cadence: .everyMinutes(5)),
            updatedAt: updated
        )
        row.cadenceMinutes = nil
        XCTAssertNil(row.order)
    }

    func test_nonPositiveIntervalIsDropped() {
        var row = StandingOrderRow(
            order: order(cadence: .everyMinutes(5)),
            updatedAt: updated
        )
        row.cadenceMinutes = 0
        XCTAssertNil(row.order)
    }

    func test_dailyRowMissingItsClockIsDropped() {
        var row = StandingOrderRow(
            order: order(cadence: .daily(hour: 9, minute: 0)),
            updatedAt: updated
        )
        row.cadenceMinute = nil
        XCTAssertNil(row.order)
    }

    func test_outOfRangeClockIsDropped() {
        var row = StandingOrderRow(
            order: order(cadence: .daily(hour: 9, minute: 0)),
            updatedAt: updated
        )
        row.cadenceHour = 24
        XCTAssertNil(row.order)
    }

    func test_outOfRangeWeekdayIsDropped() {
        var row = StandingOrderRow(
            order: order(cadence: .weekly(weekday: 2, hour: 9, minute: 0)),
            updatedAt: updated
        )
        row.cadenceWeekday = 8
        XCTAssertNil(row.order)
    }

    func test_weeklyRowMissingItsWeekdayIsDropped() {
        var row = StandingOrderRow(
            order: order(cadence: .weekly(weekday: 2, hour: 9, minute: 0)),
            updatedAt: updated
        )
        row.cadenceWeekday = nil
        XCTAssertNil(row.order)
    }

    // MARK: - Cloud mirror

    /// The same row type is the Firestore document, so it has to survive JSON
    /// as faithfully as it survives SQLite.
    func test_rowRoundTripsThroughJSONForTheCloudMirror() throws {
        let row = StandingOrderRow(
            order: order(
                cadence: .weekly(weekday: 6, hour: 22, minute: 30),
                capabilities: ["hermes_chat"],
                target: "mac-mini",
                lastFired: created
            ),
            updatedAt: updated
        )
        let data = try JSONEncoder().encode(row)
        XCTAssertEqual(try JSONDecoder().decode(StandingOrderRow.self, from: data), row)
    }

    func test_cadenceKindVocabularyIsStable() {
        XCTAssertEqual(
            Set(StandingOrderRow.CadenceKind.allCases.map(\.rawValue)),
            ["interval", "daily", "weekly"]
        )
    }
}
