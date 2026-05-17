import XCTest
@testable import OpenBurnBarMedia

final class MediaBudgetEnvelopeTests: XCTestCase {
    func testNormalEnvelopeAllowsAllFeatures() {
        let envelope = MediaBudgetEnvelope.normal
        XCTAssertTrue(envelope.allowsSession(for: .fileTransfer))
        XCTAssertTrue(envelope.allowsSession(for: .screenShare))
        XCTAssertTrue(envelope.allowsSession(for: .videoCall))
        XCTAssertTrue(envelope.allowsSession(for: .computerUse))
    }

    func testSoftCapTightensButAllowsAllFeatures() {
        let envelope = MediaBudgetEnvelope.softCap
        XCTAssertTrue(envelope.allowsSession(for: .fileTransfer))
        XCTAssertTrue(envelope.allowsSession(for: .screenShare))
        XCTAssertTrue(envelope.allowsSession(for: .videoCall))
        XCTAssertTrue(envelope.allowsSession(for: .computerUse))
        // Caps actually drop versus normal.
        XCTAssertLessThan(envelope.screenSharePerSessionMinutes,
                          MediaBudgetEnvelope.normal.screenSharePerSessionMinutes)
        XCTAssertLessThan(envelope.videoCallPerCallMinutes,
                          MediaBudgetEnvelope.normal.videoCallPerCallMinutes)
    }

    func testHardCapDeniesEverySession() {
        let envelope = MediaBudgetEnvelope.hardCap
        XCTAssertFalse(envelope.allowsSession(for: .fileTransfer))
        XCTAssertFalse(envelope.allowsSession(for: .screenShare))
        XCTAssertFalse(envelope.allowsSession(for: .videoCall))
        XCTAssertFalse(envelope.allowsSession(for: .computerUse))
    }

    func testStatusRoundTripsThroughCodable() throws {
        let status = MediaBudgetStatus(
            level: .softCap,
            projectedMonthEndUSD: 745.0,
            monthToDateUSD: 320.5,
            lastEvaluatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            activeEnvelope: .softCap
        )
        let encoded = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(MediaBudgetStatus.self, from: encoded)
        XCTAssertEqual(decoded, status)
    }

    func testSoftCapLevelDecodesFromFirestoreCanonicalString() throws {
        // Master plan uses snake_case for the level enum on the wire.
        let raw = #"{"level":"soft_cap","projectedMonthEndUSD":700,"monthToDateUSD":350,"lastEvaluatedAt":1700000000,"activeEnvelope":{"screenShareDailyMinutes":30,"screenSharePerSessionMinutes":30,"videoCallDailyMinutes":120,"videoCallPerCallMinutes":20,"fileTransferDailyGBIn":2,"fileTransferDailyGBOut":2}}"#
        let decoded = try JSONDecoder().decode(MediaBudgetStatus.self, from: Data(raw.utf8))
        XCTAssertEqual(decoded.level, .softCap)
    }
}
