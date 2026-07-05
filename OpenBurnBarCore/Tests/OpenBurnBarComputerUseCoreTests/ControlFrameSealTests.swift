import XCTest
import CryptoKit
@testable import OpenBurnBarComputerUseCore

/// F10 — control-frame confidentiality seal.
final class ControlFrameSealTests: XCTestCase {
    private let seal = ControlFrameSeal()

    private func key() throws -> SymmetricKey {
        try seal.deriveSessionKey(hpkeSessionKey: Data(repeating: 0x5A, count: 32), salt: Data("req-1".utf8))
    }

    func testRoundTripOpensToOriginalJSON() throws {
        let k = try key()
        let json = Data(#"{"clipboardRequest":{"text":"secret password"}}"#.utf8)
        let sealed = try seal.seal(plaintext: json, key: k, peerNodeId: "ios-se-abc", frameType: "control.clipboard.request")
        XCTAssertTrue(ControlFrameSeal.isSealedEnvelope(sealed))
        XCTAssertFalse(sealed.contains(Data("secret password".utf8)), "control JSON must not appear in cleartext")
        let opened = try seal.open(envelope: sealed, key: k, peerNodeId: "ios-se-abc", frameType: "control.clipboard.request")
        XCTAssertEqual(opened, json)
    }

    func testWrongPeerNodeIdFailsToOpen() throws {
        let k = try key()
        let sealed = try seal.seal(plaintext: Data("{}".utf8), key: k, peerNodeId: "ios-se-abc", frameType: "control.input.intent")
        XCTAssertThrowsError(try seal.open(envelope: sealed, key: k, peerNodeId: "ios-se-OTHER", frameType: "control.input.intent"))
    }

    func testWrongFrameTypeFailsToOpen() throws {
        let k = try key()
        let sealed = try seal.seal(plaintext: Data("{}".utf8), key: k, peerNodeId: "ios-se-abc", frameType: "control.input.intent")
        XCTAssertThrowsError(try seal.open(envelope: sealed, key: k, peerNodeId: "ios-se-abc", frameType: "control.approval.response"))
    }

    func testWrongKeyFailsToOpen() throws {
        let sealed = try seal.seal(plaintext: Data("{}".utf8), key: try key(), peerNodeId: "p", frameType: "control.input.intent")
        let other = try seal.deriveSessionKey(hpkeSessionKey: Data(repeating: 0x01, count: 32), salt: Data("req-1".utf8))
        XCTAssertThrowsError(try seal.open(envelope: sealed, key: other, peerNodeId: "p", frameType: "control.input.intent"))
    }

    func testTamperedCiphertextFailsToOpen() throws {
        let k = try key()
        var sealed = try seal.seal(plaintext: Data("payload".utf8), key: k, peerNodeId: "p", frameType: "t")
        sealed[sealed.count - 2] ^= 0xFF
        XCTAssertThrowsError(try seal.open(envelope: sealed, key: k, peerNodeId: "p", frameType: "t"))
    }

    func testNegotiationRequiresBothPeers() {
        XCTAssertTrue(ControlFrameSealNegotiation.resolveSealingEnabled(localSupports: true, remoteSupports: true))
        XCTAssertFalse(ControlFrameSealNegotiation.resolveSealingEnabled(localSupports: true, remoteSupports: false))
        XCTAssertEqual(ControlFrameSealNegotiation.capability, "control_seal_v1")
    }
}
