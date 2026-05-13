import XCTest
@testable import OpenBurnBar

final class CastDeviceTests: XCTestCase {

    func testIconKind_routesByModelName() {
        XCTAssertEqual(make(model: "Google Nest Hub").iconKind, .nestHub)
        XCTAssertEqual(make(model: "Google Nest Hub Max").iconKind, .nestHubMax)
        XCTAssertEqual(make(model: "Chromecast").iconKind, .chromecast)
        XCTAssertEqual(make(model: "Nest Mini").iconKind, .nestSpeaker)
        XCTAssertEqual(make(model: "Nest Audio").iconKind, .nestSpeaker)
        XCTAssertEqual(make(model: "Some Random TV").iconKind, .generic)
    }

    func testHashable_usesAllFieldsConsistently() {
        let a = make(serviceName: "svc-1", friendlyName: "Hub", model: "Nest Hub")
        let b = make(serviceName: "svc-1", friendlyName: "Hub", model: "Nest Hub")
        let c = make(serviceName: "svc-2", friendlyName: "Hub", model: "Nest Hub")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testCodable_roundTripsAllFields() throws {
        let device = make(model: "Google Nest Hub Max")
        let data = try JSONEncoder().encode(device)
        let decoded = try JSONDecoder().decode(CastDevice.self, from: data)
        XCTAssertEqual(decoded, device)
        XCTAssertEqual(decoded.iconKind, .nestHubMax)
        XCTAssertEqual(decoded.supportsDisplay, device.supportsDisplay)
    }

    func testInit_supportsDisplay_defaultsToTrue() {
        let device = make()
        XCTAssertTrue(device.supportsDisplay)
    }

    func testInit_canBeMarkedAudioOnly() {
        let device = CastDevice(
            serviceName: "svc",
            friendlyName: "Mini",
            host: "192.0.2.1",
            port: 8009,
            model: "Google Nest Mini",
            identifier: "id",
            supportsDisplay: false
        )
        XCTAssertFalse(device.supportsDisplay)
    }

    @MainActor
    func testRepairSelectionPicksLikelyNestHubWhenMultipleDisplaysExist() {
        let devices = [
            make(
                serviceName: "Google-Nest-Hub-Max-kitchen",
                friendlyName: "Kitchen Display",
                host: "192.168.68.40",
                model: "Google Nest Hub Max"
            ),
            make(
                serviceName: "Chromecast-living-room",
                friendlyName: "Living Room TV",
                host: "192.168.68.41",
                model: "Chromecast"
            ),
            make(
                serviceName: "Google-Nest-Hub-desk",
                friendlyName: "Alberto's Display",
                host: "192.168.68.42",
                model: "Google Nest Hub"
            )
        ]

        let selected = SmartHubBridgeController.preferredRepairCastDevice(from: devices)

        XCTAssertEqual(selected?.friendlyName, "Alberto's Display")
    }

    private func make(
        serviceName: String = "Google-Nest-Hub-abc",
        friendlyName: String = "Living Room Hub",
        host: String = "192.0.2.1",
        port: Int = 8009,
        model: String = "Google Nest Hub",
        identifier: String = "id-1"
    ) -> CastDevice {
        CastDevice(
            serviceName: serviceName,
            friendlyName: friendlyName,
            host: host,
            port: port,
            model: model,
            identifier: identifier,
            lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}
