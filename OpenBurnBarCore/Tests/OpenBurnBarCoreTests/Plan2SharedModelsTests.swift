import XCTest
@testable import OpenBurnBarCore

// Plan 2 — shared-types contract tests. Locks the runtime discriminator,
// default gateway URLs, and device-link doc shape so any future driver of
// the Assistants surface (iOS, macOS, Android, Functions) decodes the same
// way.

final class Plan2SharedModelsTests: XCTestCase {
    // MARK: AssistantRuntimeID

    func test_assistantRuntimeID_caseRawValuesMatchRelayDiscriminator() {
        // These rawValues are persisted on every platform — UserDefaults
        // (`assistants.activeRuntime`, `chat.tilePreferences.v1`) on Apple
        // platforms, SharedPreferences on Android. Any rename is a migration.
        XCTAssertEqual(AssistantRuntimeID.hermes.rawValue, "hermes")
        XCTAssertEqual(AssistantRuntimeID.pi.rawValue, "pi")
        XCTAssertEqual(AssistantRuntimeID.codex.rawValue, "codex")
        XCTAssertEqual(AssistantRuntimeID.claude.rawValue, "claude")
        XCTAssertEqual(AssistantRuntimeID.openClaw.rawValue, "openclaw")
        XCTAssertEqual(AssistantRuntimeID.droid.rawValue, "droid")
        XCTAssertEqual(AssistantRuntimeID.forge.rawValue, "forge")
        XCTAssertEqual(AssistantRuntimeID.antigravity.rawValue, "antigravity")
        XCTAssertEqual(
            AssistantRuntimeID.allCases,
            [.hermes, .pi, .codex, .claude, .openClaw, .droid, .forge, .antigravity]
        )
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
        XCTAssertEqual(
            AssistantRuntimeID.droid.defaultGatewayURL.absoluteString,
            "http://127.0.0.1:8642"
        )
        XCTAssertEqual(
            AssistantRuntimeID.forge.defaultGatewayURL.absoluteString,
            "http://127.0.0.1:8642"
        )
        XCTAssertEqual(
            AssistantRuntimeID.antigravity.defaultGatewayURL.absoluteString,
            "http://127.0.0.1:8642"
        )
    }

    func test_assistantRuntimeID_glyphsAreStableAcrossPlatforms() {
        XCTAssertEqual(AssistantRuntimeID.hermes.glyph, "\u{263F}")
        XCTAssertEqual(AssistantRuntimeID.pi.glyph, "\u{03C0}")
        XCTAssertEqual(AssistantRuntimeID.droid.glyph, "\u{25C6}")
        XCTAssertEqual(AssistantRuntimeID.forge.glyph, "\u{25B0}")
        XCTAssertEqual(AssistantRuntimeID.antigravity.glyph, "\u{2727}")
    }

    func test_assistantRuntimeID_codableRoundTrip() throws {
        let payload = try JSONEncoder().encode([AssistantRuntimeID.pi, .hermes])
        let decoded = try JSONDecoder().decode([AssistantRuntimeID].self, from: payload)
        XCTAssertEqual(decoded, [.pi, .hermes])
    }

    func test_realtimeRelayFrameCarriesOptionalRuntimeDiscriminator() throws {
        let original = HermesRealtimeRelayFrame(
            type: .requestStart,
            uid: "user-1",
            connectionId: "pi-relay-mac",
            requestId: "req-1",
            runtime: AssistantRuntimeID.pi.rawValue,
            payload: HermesRealtimeRelayPayload(
                operation: .models,
                method: "GET",
                payloadCiphertext: "cipher",
                wrappedKey: "wrapped",
                relayEncryption: HermesRelayCrypto.algorithm,
                relayKeyVersion: HermesRelayCrypto.keyVersion
            )
        )

        let blob = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HermesRealtimeRelayFrame.self, from: blob)

        XCTAssertEqual(decoded.runtime, "pi")
        XCTAssertEqual(decoded.requestId, "req-1")
    }

    func test_realtimeRelayClipboardRequestAndResponseRoundTrip() throws {
        let authority = HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: "ios-phone-node",
            counter: 42,
            timestamp: Date(timeIntervalSince1970: 1_774_000_000),
            intentHashBlake3: "abc123",
            signatureEd25519: "signature"
        )
        let request = HermesRealtimeRelayClipboardRequest(
            requestId: "clipboard-req-1",
            action: .pasteToMac,
            contentType: "text/plain",
            text: "paste me",
            maxBytes: 65_536,
            clientIntentId: "client-intent-1",
            authority: authority
        )
        let requestFrame = HermesRealtimeRelayFrame(
            type: .controlClipboardRequest,
            uid: "user-1",
            connectionId: "mac-conn-1",
            requestId: request.requestId,
            control: HermesRealtimeRelayControlPayload(
                streamClass: "control.clipboard",
                sessionId: "session-1",
                clipboardRequest: request
            )
        )
        let response = HermesRealtimeRelayClipboardResponse(
            requestId: request.requestId,
            action: .pasteToMac,
            status: .accepted,
            contentType: "text/plain",
            byteCount: 8,
            detail: "pasted"
        )
        let responseFrame = HermesRealtimeRelayFrame(
            type: .controlClipboardResponse,
            uid: "user-1",
            connectionId: "mac-conn-1",
            requestId: request.requestId,
            control: HermesRealtimeRelayControlPayload(
                streamClass: "control.clipboard",
                sessionId: "session-1",
                clipboardResponse: response
            )
        )

        let decoder = JSONDecoder()
        let decodedRequest = try decoder.decode(
            HermesRealtimeRelayFrame.self,
            from: JSONEncoder().encode(requestFrame)
        )
        let decodedResponse = try decoder.decode(
            HermesRealtimeRelayFrame.self,
            from: JSONEncoder().encode(responseFrame)
        )

        XCTAssertEqual(decodedRequest.type, .controlClipboardRequest)
        XCTAssertEqual(decodedRequest.control?.clipboardRequest, request)
        XCTAssertEqual(decodedRequest.control?.clipboardRequest?.action.rawValue, "paste_to_mac")
        XCTAssertEqual(decodedResponse.type, .controlClipboardResponse)
        XCTAssertEqual(decodedResponse.control?.clipboardResponse, response)
        XCTAssertEqual(decodedResponse.control?.clipboardResponse?.status.rawValue, "accepted")
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
