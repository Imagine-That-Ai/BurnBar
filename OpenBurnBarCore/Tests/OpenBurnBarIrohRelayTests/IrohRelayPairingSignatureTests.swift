import CryptoKit
import XCTest
@testable import OpenBurnBarIrohRelay

final class IrohRelayPairingSignatureTests: XCTestCase {
    func testValidSignatureVerifies() throws {
        let keypair = IrohPairingKeypair()
        let now = Date(timeIntervalSince1970: 1_714_200_000)
        let record = try IrohPairingSignature.sign(
            uid: "u-1",
            connectionId: "relay-mac",
            nodeId: "abc123",
            publishedAtMillis: Int64(now.timeIntervalSince1970 * 1000),
            with: keypair.signingKey
        )
        try IrohPairingSignature.verify(record, publicKey: keypair.publicKeyRaw, now: now)
    }

    func testTamperedNodeIdRejected() throws {
        let keypair = IrohPairingKeypair()
        let now = Date(timeIntervalSince1970: 1_714_200_000)
        var record = try IrohPairingSignature.sign(
            uid: "u-1",
            connectionId: "relay-mac",
            nodeId: "abc123",
            publishedAtMillis: Int64(now.timeIntervalSince1970 * 1000),
            with: keypair.signingKey
        )
        record = IrohPairingRecord(
            uid: record.uid,
            connectionId: record.connectionId,
            nodeId: "totally-different-node",
            publishedAtMillis: record.publishedAtMillis,
            protocolVersion: record.protocolVersion,
            signature: record.signature
        )

        XCTAssertThrowsError(try IrohPairingSignature.verify(record, publicKey: keypair.publicKeyRaw, now: now)) { error in
            XCTAssertEqual(error as? IrohPairingError, .invalidSignature)
        }
    }

    func testStaleRecordRejected() throws {
        let keypair = IrohPairingKeypair()
        let signedAt = Date(timeIntervalSince1970: 1_714_000_000)
        let record = try IrohPairingSignature.sign(
            uid: "u-1",
            connectionId: "relay-mac",
            nodeId: "abc123",
            publishedAtMillis: Int64(signedAt.timeIntervalSince1970 * 1000),
            with: keypair.signingKey
        )
        // 25h later
        let later = signedAt.addingTimeInterval(25 * 60 * 60)
        XCTAssertThrowsError(try IrohPairingSignature.verify(record, publicKey: keypair.publicKeyRaw, now: later)) { error in
            XCTAssertEqual(error as? IrohPairingError, .expired)
        }
    }

    func testWrongPublicKeyRejected() throws {
        let keypair = IrohPairingKeypair()
        let attacker = IrohPairingKeypair()
        let now = Date(timeIntervalSince1970: 1_714_200_000)
        let record = try IrohPairingSignature.sign(
            uid: "u-1",
            connectionId: "relay-mac",
            nodeId: "abc123",
            publishedAtMillis: Int64(now.timeIntervalSince1970 * 1000),
            with: keypair.signingKey
        )
        XCTAssertThrowsError(try IrohPairingSignature.verify(record, publicKey: attacker.publicKeyRaw, now: now)) { error in
            XCTAssertEqual(error as? IrohPairingError, .invalidSignature)
        }
    }

    func testMalformedSignatureRejected() throws {
        let keypair = IrohPairingKeypair()
        let now = Date(timeIntervalSince1970: 1_714_200_000)
        let record = IrohPairingRecord(
            uid: "u-1",
            connectionId: "relay-mac",
            nodeId: "abc123",
            publishedAtMillis: Int64(now.timeIntervalSince1970 * 1000),
            signature: "%%%not-base64%%%"
        )
        XCTAssertThrowsError(try IrohPairingSignature.verify(record, publicKey: keypair.publicKeyRaw, now: now)) { error in
            XCTAssertEqual(error as? IrohPairingError, .malformed)
        }
    }

    func testInvalidPublicKeyMaterialRejected() throws {
        let keypair = IrohPairingKeypair()
        let now = Date(timeIntervalSince1970: 1_714_200_000)
        let record = try IrohPairingSignature.sign(
            uid: "u-1",
            connectionId: "relay-mac",
            nodeId: "abc123",
            publishedAtMillis: Int64(now.timeIntervalSince1970 * 1000),
            with: keypair.signingKey
        )
        let bogus = Data([0xff, 0x00, 0xff])
        XCTAssertThrowsError(try IrohPairingSignature.verify(record, publicKey: bogus, now: now)) { error in
            XCTAssertEqual(error as? IrohPairingError, .invalidPublicKey)
        }
    }
}
