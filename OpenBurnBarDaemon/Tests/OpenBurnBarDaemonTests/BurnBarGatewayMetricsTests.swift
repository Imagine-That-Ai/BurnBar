import OpenBurnBarCore
import XCTest
@testable import OpenBurnBarDaemon

final class BurnBarGatewayMetricsTests: XCTestCase {
    func test_liveSnapshotIncludesGatewayCounters() {
        let snapshot = BurnBarGatewayMetricsSnapshot.live(gatewayEnabled: true)

        XCTAssertEqual(snapshot.gatewayEnabled, true)
        XCTAssertGreaterThanOrEqual(snapshot.uptimeSeconds, 0)
        XCTAssertEqual(snapshot.protocolVersion, BurnBarProtocolVersion.current)
        XCTAssertEqual(snapshot.counters["gateway_enabled"], 1)
    }

    func test_liveSnapshotEncodesToJSON() throws {
        let snapshot = BurnBarGatewayMetricsSnapshot.live(gatewayEnabled: false)
        let data = try JSONEncoder().encode(snapshot)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(json?["gatewayEnabled"] as? Bool, false)
        XCTAssertNotNil(json?["generatedAt"])
        XCTAssertNotNil(json?["counters"])
    }
}
