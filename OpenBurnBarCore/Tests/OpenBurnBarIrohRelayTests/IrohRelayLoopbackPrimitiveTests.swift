import XCTest
@testable import OpenBurnBarIrohRelay
import OpenBurnBarCore

final class IrohRelayLoopbackPrimitiveTests: XCTestCase {
    func testTwoTransportsCanShakeHandsThenShutdown() async throws {
        let rendezvous = LoopbackIrohRelayRendezvous()
        let mac = LoopbackIrohRelayTransport(nodeId: "mac-x", rendezvous: rendezvous)
        let ios = LoopbackIrohRelayTransport(nodeId: "ios-x", rendezvous: rendezvous)
        _ = try await mac.start()
        _ = try await ios.start()
        await ios.shutdown()
        await mac.shutdown()
    }

    func testHostAcceptResolvesAfterDial() async throws {
        let rendezvous = LoopbackIrohRelayRendezvous()
        let mac = LoopbackIrohRelayTransport(nodeId: "mac-y", rendezvous: rendezvous)
        let ios = LoopbackIrohRelayTransport(nodeId: "ios-y", rendezvous: rendezvous)
        _ = try await mac.start()
        _ = try await ios.start()

        async let acceptTask: any IrohRelayStream = mac.accept(timeout: 2)
        let dialed = try await ios.connect(to: "mac-y", timeout: 2)
        let accepted = try await acceptTask

        // Just send a ping frame to prove the streams pair up correctly.
        let ping = HermesRealtimeRelayFrame(
            type: .ping,
            uid: "u",
            connectionId: "c",
            requestId: nil,
            protocolVersion: 1
        )
        try await dialed.send(ping)
        let received = try await accepted.receive()
        XCTAssertEqual(received?.type, .ping)

        await dialed.close()
        await accepted.close()
        await ios.shutdown()
        await mac.shutdown()
    }
}
