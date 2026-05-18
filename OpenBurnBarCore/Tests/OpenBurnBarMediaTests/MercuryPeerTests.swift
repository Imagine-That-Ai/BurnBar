import XCTest
@testable import OpenBurnBarMedia

final class MercuryPeerTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    func testCodableRoundTripPreservesAllFields() throws {
        let peer = MercuryPeer(
            connectionID: "conn-abc",
            displayName: "Alberto's Mac",
            isOnline: true,
            lastSeenAt: referenceDate,
            capabilities: [.mirrorHost, .fileReceive, .callReceive]
        )

        let encoded = try JSONEncoder().encode(peer)
        let decoded = try JSONDecoder().decode(MercuryPeer.self, from: encoded)

        XCTAssertEqual(decoded, peer)
        XCTAssertEqual(decoded.connectionID, "conn-abc")
        XCTAssertEqual(decoded.displayName, "Alberto's Mac")
        XCTAssertTrue(decoded.isOnline)
        XCTAssertEqual(decoded.capabilities, [.mirrorHost, .fileReceive, .callReceive])
    }

    func testWireFormatHasDeterministicCapabilityOrder() throws {
        // Encode the same peer twice with capabilities given in
        // different orders — the wire form should be byte-identical.
        let peerA = MercuryPeer(
            connectionID: "c1",
            displayName: "Mac",
            isOnline: true,
            lastSeenAt: referenceDate,
            capabilities: [.callReceive, .mirrorHost, .fileSend]
        )
        let peerB = MercuryPeer(
            connectionID: "c1",
            displayName: "Mac",
            isOnline: true,
            lastSeenAt: referenceDate,
            capabilities: [.fileSend, .callReceive, .mirrorHost]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let dataA = try encoder.encode(peerA)
        let dataB = try encoder.encode(peerB)

        XCTAssertEqual(dataA, dataB,
                       "capability set ordering must be deterministic on the wire")
    }

    func testUnknownCapabilityStringsAreFilteredDuringDecode() throws {
        // Simulate a future build advertising a capability the current
        // enum doesn't know about. The decoder should drop the unknown
        // value rather than failing the whole struct.
        let raw = #"""
        {
          "connectionID": "c1",
          "displayName": "Future Mac",
          "isOnline": true,
          "lastSeenAt": 1700000000,
          "capabilities": ["mirror.host", "telepathy.send", "file.receive"]
        }
        """#
        let peer = try JSONDecoder().decode(MercuryPeer.self, from: Data(raw.utf8))
        XCTAssertEqual(peer.capabilities, [.mirrorHost, .fileReceive])
    }

    func testCanRequestMirrorTruthTable() {
        let onlineWithHost = MercuryPeer(
            connectionID: "c1", displayName: "Mac", isOnline: true,
            lastSeenAt: referenceDate, capabilities: [.mirrorHost]
        )
        XCTAssertTrue(onlineWithHost.canRequestMirror)

        let offlineWithHost = MercuryPeer(
            connectionID: "c1", displayName: "Mac", isOnline: false,
            lastSeenAt: referenceDate, capabilities: [.mirrorHost]
        )
        XCTAssertFalse(offlineWithHost.canRequestMirror)

        let onlineWithoutHost = MercuryPeer(
            connectionID: "c1", displayName: "Mac", isOnline: true,
            lastSeenAt: referenceDate, capabilities: [.callReceive, .fileReceive]
        )
        XCTAssertFalse(onlineWithoutHost.canRequestMirror)
    }

    func testCanPlaceCallAndCanSendFileTruthTables() {
        let mac = MercuryPeer(
            connectionID: "c1", displayName: "Mac", isOnline: true,
            lastSeenAt: referenceDate,
            capabilities: MercuryPeer.macFallbackCapabilities
        )
        XCTAssertTrue(mac.canPlaceCall)
        XCTAssertTrue(mac.canSendFile)

        let offlineMac = MercuryPeer(
            connectionID: "c1", displayName: "Mac", isOnline: false,
            lastSeenAt: referenceDate,
            capabilities: MercuryPeer.macFallbackCapabilities
        )
        XCTAssertFalse(offlineMac.canPlaceCall)
        XCTAssertFalse(offlineMac.canSendFile)
    }

    func testFallbackCapabilitySetsAreSane() {
        XCTAssertTrue(MercuryPeer.macFallbackCapabilities.contains(.mirrorHost))
        XCTAssertTrue(MercuryPeer.macFallbackCapabilities.contains(.callReceive))
        XCTAssertTrue(MercuryPeer.iphoneFallbackCapabilities.contains(.mirrorViewer))
        XCTAssertTrue(MercuryPeer.iphoneFallbackCapabilities.contains(.fileReceive))
        XCTAssertFalse(MercuryPeer.iphoneFallbackCapabilities.contains(.mirrorHost),
                       "iPhone is the viewer in v1, not the host")
    }
}
