import XCTest
import OpenBurnBarIrohRelay
import OpenBurnBarKernel
@testable import OpenBurnBarMobile

@MainActor
final class HostReachabilityClientTests: XCTestCase {
    func testQueuedToggleRidesOutboundHeartbeatAndClearsOnPhoneToggleAck() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let client = HostReachabilityClient(now: now)
        let keypair = IrohPairingKeypair()

        try client.queueKeepAwakeToggle(
            enabled: true,
            deviceId: "ios-phone-test",
            signingKey: keypair.signingKey,
            issuedAt: now
        )

        XCTAssertTrue(client.desiredPhoneToggleEnabled)
        let outbound = client.outboundHeartbeatCapabilities(base: ["mirror.viewer"])
        XCTAssertEqual(outbound.first, "mirror.viewer")
        XCTAssertTrue(
            outbound.contains { $0.hasPrefix(HostReachabilityCapability.togglePrefix) }
        )

        client.applyMacPresence(
            HermesRealtimeRelayPresenceHeartbeat(
                sentAt: now.addingTimeInterval(2),
                deviceDisplayName: "Alberto’s MacBook Pro",
                capabilities: [
                    HostReachabilityCapability.held,
                    HostReachabilityCapability.phoneToggle
                ]
            )
        )

        XCTAssertNil(client.pendingToggleCapability)
        XCTAssertTrue(client.status.isAwake)
        XCTAssertTrue(client.status.phoneToggleHeld)
        XCTAssertTrue(client.desiredPhoneToggleEnabled)
        XCTAssertEqual(
            client.outboundHeartbeatCapabilities(base: ["mirror.viewer"]),
            ["mirror.viewer"]
        )
    }

    func testSessionAutoArmDoesNotClearAPendingOffToggle() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let client = HostReachabilityClient(now: now)
        let keypair = IrohPairingKeypair()

        try client.queueKeepAwakeToggle(
            enabled: false,
            deviceId: "ios-phone-test",
            signingKey: keypair.signingKey,
            issuedAt: now
        )

        client.applyMacPresence(
            HermesRealtimeRelayPresenceHeartbeat(
                sentAt: now.addingTimeInterval(2),
                deviceDisplayName: "Alberto’s MacBook Pro",
                capabilities: [HostReachabilityCapability.held]
            )
        )

        XCTAssertNotNil(client.pendingToggleCapability)
        XCTAssertTrue(client.status.isAwake)
        XCTAssertFalse(client.status.phoneToggleHeld)
        XCTAssertFalse(client.desiredPhoneToggleEnabled)
    }
}
