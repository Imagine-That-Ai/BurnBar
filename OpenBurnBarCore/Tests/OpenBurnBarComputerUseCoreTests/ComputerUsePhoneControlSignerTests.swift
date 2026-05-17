import XCTest
import CryptoKit
@testable import OpenBurnBarComputerUseCore

final class ComputerUsePhoneControlSignerTests: XCTestCase {
    struct ToyIntent: Codable, Hashable {
        let kind: String
        let nx: Double?
        let ny: Double?
    }

    private let signer = ComputerUsePhoneControlSigner()

    func testRoundTripVerifySucceeds() throws {
        let priv = Curve25519.Signing.PrivateKey()
        let pub = priv.publicKey
        let intent = ToyIntent(kind: "tap", nx: 0.5, ny: 0.5)
        let signed = try signer.sign(
            intent: intent,
            peerNodeId: "peer-1",
            counter: 1,
            timestamp: Date(),
            privateKey: priv
        )
        try signer.verify(
            intent: intent,
            authority: signed,
            peerPublicKey: pub,
            lastSeenCounter: 0,
            now: Date()
        )
    }

    func testTamperedIntentFails() throws {
        let priv = Curve25519.Signing.PrivateKey()
        let pub = priv.publicKey
        let signed = try signer.sign(
            intent: ToyIntent(kind: "tap", nx: 0.5, ny: 0.5),
            peerNodeId: "peer-1",
            counter: 1,
            timestamp: Date(),
            privateKey: priv
        )
        XCTAssertThrowsError(try signer.verify(
            intent: ToyIntent(kind: "tap", nx: 0.9, ny: 0.5),
            authority: signed,
            peerPublicKey: pub,
            lastSeenCounter: 0,
            now: Date()
        )) { error in
            guard case ComputerUsePhoneControlSigner.VerifyError.intentHashMismatch = error else {
                XCTFail("expected intentHashMismatch, got \(error)")
                return
            }
        }
    }

    func testCounterReplayRejected() throws {
        let priv = Curve25519.Signing.PrivateKey()
        let pub = priv.publicKey
        let intent = ToyIntent(kind: "tap", nx: 0.1, ny: 0.1)
        let signed = try signer.sign(
            intent: intent,
            peerNodeId: "peer-1",
            counter: 5,
            timestamp: Date(),
            privateKey: priv
        )
        XCTAssertThrowsError(try signer.verify(
            intent: intent,
            authority: signed,
            peerPublicKey: pub,
            lastSeenCounter: 5,
            now: Date()
        )) { error in
            guard case ComputerUsePhoneControlSigner.VerifyError.counterReplay = error else {
                XCTFail("expected counterReplay, got \(error)")
                return
            }
        }
    }

    func testStaleTimestampRejected() throws {
        let priv = Curve25519.Signing.PrivateKey()
        let pub = priv.publicKey
        let intent = ToyIntent(kind: "tap", nx: 0.1, ny: 0.1)
        let now = Date()
        let signed = try signer.sign(
            intent: intent,
            peerNodeId: "peer-1",
            counter: 7,
            timestamp: now.addingTimeInterval(-30),
            privateKey: priv
        )
        XCTAssertThrowsError(try signer.verify(
            intent: intent,
            authority: signed,
            peerPublicKey: pub,
            lastSeenCounter: 0,
            now: now
        )) { error in
            guard case ComputerUsePhoneControlSigner.VerifyError.staleTimestamp = error else {
                XCTFail("expected staleTimestamp, got \(error)")
                return
            }
        }
    }

    func testForeignPublicKeyRejected() throws {
        let priv = Curve25519.Signing.PrivateKey()
        let attackerPub = Curve25519.Signing.PrivateKey().publicKey
        let intent = ToyIntent(kind: "tap", nx: 0.1, ny: 0.1)
        let signed = try signer.sign(
            intent: intent,
            peerNodeId: "peer-1",
            counter: 1,
            timestamp: Date(),
            privateKey: priv
        )
        XCTAssertThrowsError(try signer.verify(
            intent: intent,
            authority: signed,
            peerPublicKey: attackerPub,
            lastSeenCounter: 0,
            now: Date()
        )) { error in
            guard case ComputerUsePhoneControlSigner.VerifyError.signatureFailed = error else {
                XCTFail("expected signatureFailed, got \(error)")
                return
            }
        }
    }

    func testSignablePayloadIsByteStableAcrossInstances() {
        let signerA = ComputerUsePhoneControlSigner()
        let signerB = ComputerUsePhoneControlSigner()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000.123)
        let p1 = signerA.signablePayload(intentHashHex: "abc", counter: 42, timestamp: timestamp)
        let p2 = signerB.signablePayload(intentHashHex: "abc", counter: 42, timestamp: timestamp)
        XCTAssertEqual(p1, p2)
    }
}
