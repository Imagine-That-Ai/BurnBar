import XCTest
import OpenBurnBarCore
import OpenBurnBarMedia
@testable import OpenBurnBarMobile

/// Regression cover for the 2026-07-28 "Reconnecting forever" report.
///
/// A Mac whose iroh host fails to start still publishes `status: online` —
/// its chat gateway is healthy and that field is shared by both transports.
/// What it *does* say is `realtimeRelayStatus: "offline"` plus a capability
/// list without the realtime marker. Before this fix the iOS peer source
/// handed back the full `macFallbackCapabilities` set for any online relay,
/// so the Live sheet advertised `Ask to Mirror` against a Mac that could not
/// serve it and sat on "connecting"/"reconnecting" instead of naming the fault.
final class MercuryPeerCapabilityFallbackTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func relay(
        realtimeRelayStatus: String?,
        capabilities: [String]
    ) -> HermesConnectionRecord {
        HermesConnectionRecord(
            id: "relay-host-test",
            displayName: "Alberto's MacBook Pro Hermes Relay",
            mode: .relayLink,
            status: .online,
            realtimeRelayStatus: realtimeRelayStatus,
            capabilities: capabilities,
            updatedAt: referenceDate
        )
    }

    // MARK: - Narrowing on an explicit offline statement

    func testRealtimeOfflineRelayDropsMirrorAndCall() {
        let record = relay(
            realtimeRelayStatus: "offline",
            capabilities: ["remote_relay", "chat_completions", "cli_agent_chat"]
        )

        let capabilities = MercuryPeerSource.fallbackCapabilities(for: record)

        XCTAssertFalse(
            capabilities.contains(.mirrorHost),
            "A Mac reporting realtimeRelayStatus=offline cannot host a mirror."
        )
        XCTAssertFalse(capabilities.contains(.callReceive))
    }

    func testPopulatedCapabilitiesWithoutRealtimeMarkerDropsMirror() {
        // The Mac omits `realtime_relay` from `capabilities` whenever
        // `realtimeReady` is false, so an explicit list that lacks the marker
        // is just as authoritative as the status string.
        let record = relay(
            realtimeRelayStatus: nil,
            capabilities: ["remote_relay", "cli_agent_chat"]
        )

        XCTAssertTrue(MercuryPeerSource.isRealtimeExplicitlyUnavailable(record))
        XCTAssertFalse(
            MercuryPeerSource.fallbackCapabilities(for: record).contains(.mirrorHost)
        )
    }

    // MARK: - Staying permissive everywhere else

    func testRealtimeOnlineRelayKeepsFullFallbackSet() {
        let record = relay(
            realtimeRelayStatus: "online",
            capabilities: ["remote_relay", HermesRealtimeRelayProtocol.capability]
        )

        XCTAssertFalse(MercuryPeerSource.isRealtimeExplicitlyUnavailable(record))
        XCTAssertEqual(
            MercuryPeerSource.fallbackCapabilities(for: record),
            MercuryPeer.macFallbackCapabilities
        )
    }

    func testLegacyMacWithNoSignalsKeepsFullFallbackSet() {
        // A Mac predating the realtime advertise publishes neither an explicit
        // status nor a capability list. It must stay "assume capable" so this
        // change never regresses an older, working host.
        let record = relay(realtimeRelayStatus: nil, capabilities: [])

        XCTAssertFalse(MercuryPeerSource.isRealtimeExplicitlyUnavailable(record))
        XCTAssertEqual(
            MercuryPeerSource.fallbackCapabilities(for: record),
            MercuryPeer.macFallbackCapabilities
        )
    }

    func testMissingRelayRecordKeepsFullFallbackSet() {
        // No record at all means the peer was resolved from a live control
        // stream or a heartbeat; nothing has claimed realtime is down.
        XCTAssertEqual(
            MercuryPeerSource.fallbackCapabilities(for: nil),
            MercuryPeer.macFallbackCapabilities
        )
    }

    func testFileTransferSurvivesRealtimeOutage() {
        // File send/receive does not ride the realtime mirror path, so the
        // narrowed set must keep it — otherwise this fix would break a
        // capability the Mac genuinely still serves.
        let record = relay(
            realtimeRelayStatus: "offline",
            capabilities: ["remote_relay"]
        )

        let capabilities = MercuryPeerSource.fallbackCapabilities(for: record)
        XCTAssertTrue(capabilities.contains(.fileSend))
        XCTAssertTrue(capabilities.contains(.fileReceive))
    }
}
