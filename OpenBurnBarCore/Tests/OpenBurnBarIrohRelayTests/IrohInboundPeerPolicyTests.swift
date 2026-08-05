import XCTest
@testable import OpenBurnBarIrohRelay

final class IrohInboundPeerPolicyTests: XCTestCase {
    func testAllowsListedPeer() {
        let policy = IrohInboundPeerPolicy(allowedPeerNodeIds: ["ABC123"])
        XCTAssertTrue(policy.allows(remotePeerNodeId: "abc123"))
    }

    func testRejectsUnknownPeer() {
        let policy = IrohInboundPeerPolicy(allowedPeerNodeIds: ["ABC123"])
        XCTAssertFalse(policy.allows(remotePeerNodeId: "other-peer"))
        XCTAssertFalse(policy.allows(remotePeerNodeId: nil))
    }

    func testCanonicalTransportNodeIdTreatsBase32AndHexAsSameKey() throws {
        let hex = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
        let base32 = "aaaqeayeaudaocajbifqydiob4ibceqtcqkrmfyydenbwha5dypq"

        XCTAssertEqual(IrohNodeIdNormalization.canonicalTransportNodeId(hex.uppercased()), hex)
        XCTAssertEqual(IrohNodeIdNormalization.canonicalTransportNodeId(base32), hex)

        let binding = try XCTUnwrap(IrohControllerRouteBinding(
            sourceDeviceId: "ios-device-1",
            transportNodeId: hex,
            authorityPeerNodeId: "ios-phone-authority-1",
            generation: 3,
            registeredAtMillis: 1_000,
            expiresAtMillis: 2_000
        ))
        let policy = IrohInboundPeerPolicy(routeBindings: [binding])
        XCTAssertEqual(policy.binding(for: base32, atMillis: 1_500), binding)
        XCTAssertTrue(policy.allows(remotePeerNodeId: base32, atMillis: 1_500))
    }

    func testRouteBindingRejectsMalformedAmbiguousAndExpiredRoutes() throws {
        let nodeId = String(repeating: "a", count: 64)
        XCTAssertNil(IrohNodeIdNormalization.canonicalTransportNodeId("not-a-node"))
        XCTAssertNil(IrohNodeIdNormalization.canonicalTransportNodeId(String(repeating: "z", count: 52)))
        XCTAssertNil(IrohControllerRouteBinding(
            sourceDeviceId: "ios-device-1",
            transportNodeId: nodeId,
            authorityPeerNodeId: "ios-phone-authority-1",
            generation: 0,
            registeredAtMillis: 1_000,
            expiresAtMillis: 2_000
        ))

        let first = try XCTUnwrap(IrohControllerRouteBinding(
            sourceDeviceId: "ios-device-1",
            transportNodeId: nodeId,
            authorityPeerNodeId: "ios-phone-authority-1",
            generation: 1,
            registeredAtMillis: 1_000,
            expiresAtMillis: 2_000
        ))
        let duplicate = try XCTUnwrap(IrohControllerRouteBinding(
            sourceDeviceId: "ios-device-2",
            transportNodeId: nodeId,
            authorityPeerNodeId: "ios-phone-authority-2",
            generation: 2,
            registeredAtMillis: 1_000,
            expiresAtMillis: 3_000
        ))
        XCTAssertFalse(IrohInboundPeerPolicy(routeBindings: [first]).allows(
            remotePeerNodeId: nodeId,
            atMillis: 2_000
        ))
        XCTAssertFalse(IrohInboundPeerPolicy(routeBindings: [first, duplicate]).allows(
            remotePeerNodeId: nodeId,
            atMillis: 1_500
        ))
    }

    func testAllowsDistinctRoutesForMultipleTrustedControllerDevices() throws {
        let firstNodeID = String(repeating: "a", count: 64)
        let secondNodeID = String(repeating: "b", count: 64)
        let first = try XCTUnwrap(IrohControllerRouteBinding(
            sourceDeviceId: "ios-device-1",
            transportNodeId: firstNodeID,
            authorityPeerNodeId: "ios-phone-authority-1",
            generation: 1,
            registeredAtMillis: 1_000,
            expiresAtMillis: 3_000
        ))
        let second = try XCTUnwrap(IrohControllerRouteBinding(
            sourceDeviceId: "android-device-1",
            transportNodeId: secondNodeID,
            authorityPeerNodeId: "android-phone-authority-1",
            generation: 2,
            registeredAtMillis: 1_000,
            expiresAtMillis: 3_000
        ))
        let policy = IrohInboundPeerPolicy(routeBindings: [first, second])

        XCTAssertEqual(policy.binding(for: firstNodeID, atMillis: 2_000), first)
        XCTAssertEqual(policy.binding(for: secondNodeID, atMillis: 2_000), second)
        XCTAssertTrue(policy.allows(remotePeerNodeId: firstNodeID, atMillis: 2_000))
        XCTAssertTrue(policy.allows(remotePeerNodeId: secondNodeID, atMillis: 2_000))
    }
}
