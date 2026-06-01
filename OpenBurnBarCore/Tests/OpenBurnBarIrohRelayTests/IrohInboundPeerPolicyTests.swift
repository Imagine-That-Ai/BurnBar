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
}