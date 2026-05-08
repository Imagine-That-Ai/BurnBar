import XCTest
@testable import OpenBurnBar

final class HomeAssistantCastRecoveryClientTests: XCTestCase {

    func testPayload_includesDeviceDashboardAndReason() throws {
        let device = CastDevice(
            serviceName: "Google-Nest-Hub-abc",
            friendlyName: "Kitchen Display",
            host: "192.168.68.79",
            port: 8009,
            model: "Google Nest Hub Max",
            identifier: "abc"
        )
        let dashboardURL = try XCTUnwrap(URL(string: "http://192.168.68.87:8787/render.html"))
        let data = try XCTUnwrap(HomeAssistantCastRecoveryClient.payload(
            device: device,
            dashboardURL: dashboardURL,
            reason: "port timeout"
        ))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["source"] as? String, "openburnbar")
        XCTAssertEqual(json["action"] as? String, "cast_recovery")
        XCTAssertEqual(json["dashboardURL"] as? String, dashboardURL.absoluteString)
        XCTAssertEqual(json["reason"] as? String, "port timeout")

        let encodedDevice = try XCTUnwrap(json["device"] as? [String: Any])
        XCTAssertEqual(encodedDevice["friendlyName"] as? String, "Kitchen Display")
        XCTAssertEqual(encodedDevice["host"] as? String, "192.168.68.79")
        XCTAssertEqual(encodedDevice["port"] as? Int, 8009)
    }

    func testTrigger_skipsWhenWebhookMissing() async throws {
        let device = CastDevice(
            serviceName: "svc",
            friendlyName: "Hub",
            host: "192.0.2.1",
            port: 8009,
            model: "Google Nest Hub",
            identifier: "id"
        )
        let dashboardURL = try XCTUnwrap(URL(string: "http://example.local/render.html"))
        let outcome = await HomeAssistantCastRecoveryClient().trigger(
            webhookURL: nil,
            device: device,
            dashboardURL: dashboardURL,
            reason: "test"
        )
        XCTAssertEqual(outcome, .skipped)
    }
}
