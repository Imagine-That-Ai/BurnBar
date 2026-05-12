import XCTest
@testable import OpenBurnBarCore

// Plan 2 — shared-types contract tests. Locks the runtime discriminator,
// default gateway URLs, and device-link doc shape so any future driver of
// the Assistants surface (iOS, macOS, Android, Functions) decodes the same
// way.

final class Plan2SharedModelsTests: XCTestCase {
    // MARK: AssistantRuntimeID

    func test_assistantRuntimeID_caseRawValuesMatchRelayDiscriminator() {
        XCTAssertEqual(AssistantRuntimeID.hermes.rawValue, "hermes")
        XCTAssertEqual(AssistantRuntimeID.pi.rawValue, "pi")
        XCTAssertEqual(AssistantRuntimeID.allCases, [.hermes, .pi])
    }

    func test_assistantRuntimeID_defaultGatewayURLsAreLoopback() {
        XCTAssertEqual(
            AssistantRuntimeID.hermes.defaultGatewayURL.absoluteString,
            "http://127.0.0.1:8642"
        )
        XCTAssertEqual(
            AssistantRuntimeID.pi.defaultGatewayURL.absoluteString,
            "http://127.0.0.1:8765"
        )
    }

    func test_assistantRuntimeID_glyphsAreStableAcrossPlatforms() {
        XCTAssertEqual(AssistantRuntimeID.hermes.glyph, "\u{263F}")
        XCTAssertEqual(AssistantRuntimeID.pi.glyph, "\u{03C0}")
    }

    func test_assistantRuntimeID_codableRoundTrip() throws {
        let payload = try JSONEncoder().encode([AssistantRuntimeID.pi, .hermes])
        let decoded = try JSONDecoder().decode([AssistantRuntimeID].self, from: payload)
        XCTAssertEqual(decoded, [.pi, .hermes])
    }

    // MARK: PiConnectionMode/Status

    func test_piConnectionMode_rawValuesStable() {
        // Pi modes use camelCase tokens to match Hermes — the relay JSON
        // serializes them verbatim and Firestore stores them under
        // `mode: "directURL"`.
        XCTAssertEqual(PiConnectionMode.local.rawValue, "local")
        XCTAssertEqual(PiConnectionMode.directURL.rawValue, "directURL")
        XCTAssertEqual(PiConnectionMode.relayLink.rawValue, "relayLink")
    }

    func test_piConnectionStatus_rawValuesStable() {
        XCTAssertEqual(PiConnectionStatus.online.rawValue, "online")
        XCTAssertEqual(PiConnectionStatus.degraded.rawValue, "degraded")
        XCTAssertEqual(PiConnectionStatus.unauthorized.rawValue, "unauthorized")
        XCTAssertEqual(PiConnectionStatus.revoked.rawValue, "revoked")
    }

    // MARK: ProviderAccountDeviceLinkDoc

    func test_providerAccountDeviceLinkDoc_idComposesAccountAndDevice() {
        let doc = ProviderAccountDeviceLinkDoc(
            accountID: "acct-1",
            deviceID: "macbook-pro",
            deviceDisplayName: "Alberto's Mac",
            capability: .owner
        )
        XCTAssertEqual(doc.id, "acct-1_macbook-pro")
        XCTAssertEqual(doc.capability, .owner)
        XCTAssertEqual(doc.status, .active)
        XCTAssertEqual(doc.schemaVersion, 1)
    }

    func test_providerAccountDeviceLinkDoc_capabilitiesAreExactlyOwnerUseAdd() {
        XCTAssertEqual(
            Set(DeviceLinkCapability.allCases),
            Set([.owner, .use, .add])
        )
    }

    func test_providerAccountDeviceLinkDoc_statusesAreActiveOrRevoked() {
        XCTAssertEqual(
            Set(DeviceLinkStatus.allCases),
            Set([.active, .revoked])
        )
    }

    func test_providerAccountDeviceLinkDoc_codableRoundTrip() throws {
        let original = ProviderAccountDeviceLinkDoc(
            accountID: "acct-2",
            deviceID: "iphone-15",
            deviceDisplayName: "Alberto's iPhone",
            capability: .add,
            status: .active
        )
        let blob = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProviderAccountDeviceLinkDoc.self, from: blob)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.capability, .add)
        XCTAssertEqual(decoded.deviceDisplayName, "Alberto's iPhone")
    }
}
