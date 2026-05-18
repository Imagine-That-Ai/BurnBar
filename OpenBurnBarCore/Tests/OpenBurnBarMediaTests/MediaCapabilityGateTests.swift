import XCTest
@testable import OpenBurnBarMedia

final class MediaCapabilityGateTests: XCTestCase {
    func testAlwaysAllowGateAllowsEveryFeature() async {
        let gate = AlwaysAllowMediaCapabilityGate()
        for feature in [MediaStreamClass.Feature.fileTransfer, .screenShare, .videoCall] {
            let check = await gate.check(
                feature: feature,
                sessionDurationLimitSeconds: nil,
                sessionByteBudget: nil
            )
            XCTAssertTrue(check.isAllowed, "expected allowed for \(feature)")
        }
    }

    func testAllowedCheckCarriesEnvelope() async {
        let gate = AlwaysAllowMediaCapabilityGate()
        let check = await gate.check(
            feature: .fileTransfer,
            sessionDurationLimitSeconds: nil,
            sessionByteBudget: nil
        )
        guard case let .allowed(envelope) = check else {
            return XCTFail("expected .allowed")
        }
        XCTAssertEqual(envelope.feature, .fileTransfer)
    }

    func testEnvelopeRoundTripsThroughCodable() throws {
        let envelope = MediaCapabilityEnvelope(
            feature: .videoCall,
            remainingSecondsToday: 14_400,
            remainingBytesToday: nil,
            perSessionMaxSeconds: 1_800,
            perSessionMaxBytes: nil,
            concurrentSessionsRemaining: 1
        )
        let encoded = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(MediaCapabilityEnvelope.self, from: encoded)
        XCTAssertEqual(decoded, envelope)
    }
}
