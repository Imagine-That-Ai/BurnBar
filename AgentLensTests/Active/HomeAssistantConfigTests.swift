import XCTest
@testable import OpenBurnBar

final class HomeAssistantConfigTests: XCTestCase {

    // MARK: - URL normalization

    func testNormalize_acceptsBareLocalHost() throws {
        let url = try XCTUnwrap(HomeAssistantURLNormalizer.normalize("homeassistant.local"))
        XCTAssertEqual(url.scheme, "http")
        XCTAssertEqual(url.host, "homeassistant.local")
        XCTAssertEqual(url.port, 8123)
        XCTAssertTrue(url.path.isEmpty)
    }

    func testNormalize_acceptsLocalHostWithPort() throws {
        let url = try XCTUnwrap(HomeAssistantURLNormalizer.normalize("homeassistant.local:8124"))
        XCTAssertEqual(url.scheme, "http")
        XCTAssertEqual(url.port, 8124)
    }

    func testNormalize_acceptsHTTPSPublicHost() throws {
        let url = try XCTUnwrap(HomeAssistantURLNormalizer.normalize("ha.duckdns.org"))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertNil(url.port)
    }

    func testNormalize_preservesExplicitScheme() throws {
        let url = try XCTUnwrap(HomeAssistantURLNormalizer.normalize("https://my-ha.example.com:8443/path?x=1"))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "my-ha.example.com")
        XCTAssertEqual(url.port, 8443)
        XCTAssertEqual(url.path, "")
        XCTAssertNil(url.query)
    }

    func testNormalize_acceptsRawIPAddress() throws {
        let url = try XCTUnwrap(HomeAssistantURLNormalizer.normalize("192.168.1.50:8123"))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "192.168.1.50")
        XCTAssertEqual(url.port, 8123)
    }

    func testNormalize_rejectsEmpty() {
        XCTAssertNil(HomeAssistantURLNormalizer.normalize(""))
        XCTAssertNil(HomeAssistantURLNormalizer.normalize("   "))
    }

    // MARK: - Webhook URL composition

    func testWebhookURL_isWellFormed() throws {
        let config = HomeAssistantConfig(
            baseURL: try XCTUnwrap(URL(string: "http://homeassistant.local:8123")),
            webhookID: "openburnbar_cast_recover_abc123"
        )
        let url = try XCTUnwrap(config.webhookURL)
        XCTAssertEqual(url.absoluteString, "http://homeassistant.local:8123/api/webhook/openburnbar_cast_recover_abc123")
    }

    func testWebhookURL_isNilWhenNoID() {
        let config = HomeAssistantConfig(
            baseURL: URL(string: "http://homeassistant.local:8123")!,
            webhookID: ""
        )
        XCTAssertNil(config.webhookURL)
    }

    // MARK: - Codable round-trip

    func testCodable_roundTripPreservesFields() throws {
        let original = HomeAssistantConfig(
            baseURL: URL(string: "http://homeassistant.local:8123")!,
            mediaPlayerEntityID: "media_player.kitchen_display",
            mediaPlayerFriendlyName: "Kitchen Display",
            webhookID: "openburnbar_cast_recover_xyz",
            automationEntityID: "automation.openburnbar_smart_display_recovery",
            automationInstalled: true,
            lastTestPassed: true,
            lastVerifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            setupMode: .rest
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(HomeAssistantConfig.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Webhook ID generator

    func testWebhookID_hasFixedLength() {
        let id = HomeAssistantWebhookID.generate()
        XCTAssertEqual(id.count, HomeAssistantWebhookID.prefix.count + HomeAssistantWebhookID.secretLength)
        XCTAssertTrue(id.hasPrefix(HomeAssistantWebhookID.prefix))
    }

    func testWebhookID_recognizesOurOwn() {
        let id = HomeAssistantWebhookID.generate()
        XCTAssertTrue(HomeAssistantWebhookID.isOurs(id))
        XCTAssertFalse(HomeAssistantWebhookID.isOurs("random_other_webhook"))
        XCTAssertFalse(HomeAssistantWebhookID.isOurs(HomeAssistantWebhookID.prefix + "tooshort"))
    }

    func testWebhookID_isRandomBetweenCalls() {
        var seen = Set<String>()
        for _ in 0..<200 {
            seen.insert(HomeAssistantWebhookID.generate())
        }
        XCTAssertEqual(seen.count, 200, "Webhook IDs should be unique across many calls")
    }

    func testWebhookID_isDeterministicWithInjectedRNG() {
        let bytes: [UInt8] = Array(repeating: 0, count: 32)
        let id = HomeAssistantWebhookID.generate(randomBytes: { bytes })
        XCTAssertEqual(id, HomeAssistantWebhookID.prefix + String(repeating: "a", count: 32))
    }
}
