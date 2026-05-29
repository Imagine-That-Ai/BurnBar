import XCTest
@testable import OpenBurnBarCore

/// Phase 12 — interactive single-window CLI. Locks the wire shape of the new
/// `agentTerminal` mirror-request payload and the `macInteractiveCLI`
/// presentation mode so older peers stay compatible and the discriminators
/// never silently drift.
final class AgentTerminalMirrorRequestTests: XCTestCase {

    private func makeRequest(
        agentTerminal: HermesRealtimeRelayAgentTerminalRequest?
    ) -> HermesRealtimeRelayMirrorRequest {
        HermesRealtimeRelayMirrorRequest(
            requestId: "req-1",
            requestedAt: Date(timeIntervalSince1970: 1_700_000_000),
            requesterDisplayName: "Alberto's iPhone",
            streamClass: "media.screen.video",
            viewerId: "viewer-1",
            agentTerminal: agentTerminal
        )
    }

    // MARK: Round-trip

    func test_mirrorRequest_withAgentTerminal_roundTrips() throws {
        let original = makeRequest(
            agentTerminal: HermesRealtimeRelayAgentTerminalRequest(
                runtimeId: "hermes",
                workingDirectory: "/Users/me/project",
                interactive: true,
                modelID: "claude-opus-4-8"
            )
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HermesRealtimeRelayMirrorRequest.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.agentTerminal?.runtimeId, "hermes")
        XCTAssertEqual(decoded.agentTerminal?.workingDirectory, "/Users/me/project")
        XCTAssertEqual(decoded.agentTerminal?.interactive, true)
        XCTAssertEqual(decoded.agentTerminal?.modelID, "claude-opus-4-8")
    }

    func test_mirrorRequest_withoutAgentTerminal_roundTrips() throws {
        let original = makeRequest(agentTerminal: nil)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HermesRealtimeRelayMirrorRequest.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertNil(decoded.agentTerminal)
    }

    // MARK: Backward compatibility

    func test_mirrorRequest_decodesLegacyPayloadWithoutAgentTerminalKey() throws {
        // A payload produced by an older peer that never knew the field.
        let legacyJSON = """
        {
          "requestId": "req-legacy",
          "requestedAt": "2023-11-14T22:13:20Z",
          "requesterDisplayName": "Old iPhone",
          "streamClass": "media.screen.video"
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(HermesRealtimeRelayMirrorRequest.self, from: legacyJSON)
        XCTAssertNil(decoded.agentTerminal)
        XCTAssertEqual(decoded.requestId, "req-legacy")
    }

    func test_agentTerminalRequest_interactiveDefaultsTrueWhenAbsent() throws {
        // `interactive` omitted by a forward-compat peer should default to true.
        let json = #"{ "runtimeId": "codex" }"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(HermesRealtimeRelayAgentTerminalRequest.self, from: json)
        XCTAssertEqual(decoded.runtimeId, "codex")
        XCTAssertTrue(decoded.interactive)
        XCTAssertNil(decoded.workingDirectory)
        XCTAssertNil(decoded.modelID)
    }

    func test_agentTerminalRequest_roundTrips() throws {
        let original = HermesRealtimeRelayAgentTerminalRequest(
            runtimeId: "droid",
            workingDirectory: nil,
            interactive: false,
            modelID: nil
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HermesRealtimeRelayAgentTerminalRequest.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertFalse(decoded.interactive)
    }

    // MARK: Presentation mode

    func test_presentationMode_macInteractiveCLI_rawValueAndCases() {
        XCTAssertEqual(CLIAgentChatPresentationMode.macInteractiveCLI.rawValue, "mac_interactive_cli")
        XCTAssertEqual(
            CLIAgentChatPresentationMode.allCases,
            [.nativeChat, .macVisibleCLI, .macInteractiveCLI]
        )
    }

    func test_presentationMode_unknownRawValueDecodesViaFallbackInit() {
        // Callers use `CLIAgentChatPresentationMode(rawValue:) ?? .nativeChat`.
        XCTAssertNil(CLIAgentChatPresentationMode(rawValue: "something_new"))
        XCTAssertEqual(CLIAgentChatPresentationMode(rawValue: "mac_interactive_cli"), .macInteractiveCLI)
    }
}
