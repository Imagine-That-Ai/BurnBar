import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import Foundation
import XCTest

// Listener-queue characterization extracted from OpenBurnBarHTTPGatewayServerTests.swift
// to keep that god-file under the SwiftLint type_body_length ratchet (it may only shrink).
extension BurnBarHTTPGatewayServerTests {
    func testGatewayListenerUsesDedicatedLaunchCriticalQueue() async throws {
        let harness = try GatewayHarness()
        let identity = await harness.listenerQueueIdentity()

        XCTAssertEqual(identity.label, BurnBarHTTPGatewayServer.listenerQueueLabel)
        XCTAssertEqual(identity.qosClass, .userInitiated)
    }
}

extension GatewayHarness {
    func listenerQueueIdentity() async -> (label: String, qosClass: DispatchQoS.QoSClass) {
        let queue = await server.listenerQueue
        return (queue.label, queue.qos.qosClass)
    }
}
