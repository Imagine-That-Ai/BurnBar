import XCTest
import CryptoKit
import OpenBurnBarCore
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

    func testInvalidBase64SignatureRejected() throws {
        let priv = Curve25519.Signing.PrivateKey()
        let intent = ToyIntent(kind: "tap", nx: 0.5, ny: 0.5)
        let signed = try signer.sign(
            intent: intent,
            peerNodeId: "peer-1",
            counter: 1,
            timestamp: Date(),
            privateKey: priv
        )
        let invalid = ComputerUsePhoneControlSigner.SignedAuthority(
            peerNodeId: signed.peerNodeId,
            counter: signed.counter,
            timestamp: signed.timestamp,
            intentHashHex: signed.intentHashHex,
            signatureBase64: "not base64!"
        )
        XCTAssertThrowsError(try signer.verify(
            intent: intent,
            authority: invalid,
            peerPublicKey: priv.publicKey,
            lastSeenCounter: 0,
            now: Date()
        )) { error in
            guard case ComputerUsePhoneControlSigner.VerifyError.invalidBase64Signature = error else {
                XCTFail("expected invalidBase64Signature, got \(error)")
                return
            }
        }
    }

    func testTamperedIntentHashRejectedBeforeSignatureCheck() throws {
        let priv = Curve25519.Signing.PrivateKey()
        let intent = ToyIntent(kind: "tap", nx: 0.5, ny: 0.5)
        let signed = try signer.sign(
            intent: intent,
            peerNodeId: "peer-1",
            counter: 1,
            timestamp: Date(),
            privateKey: priv
        )
        let tampered = ComputerUsePhoneControlSigner.SignedAuthority(
            peerNodeId: signed.peerNodeId,
            counter: signed.counter,
            timestamp: signed.timestamp,
            intentHashHex: String(repeating: "0", count: 64),
            signatureBase64: signed.signatureBase64
        )
        XCTAssertThrowsError(try signer.verify(
            intent: intent,
            authority: tampered,
            peerPublicKey: priv.publicKey,
            lastSeenCounter: 0,
            now: Date()
        )) { error in
            guard case ComputerUsePhoneControlSigner.VerifyError.intentHashMismatch = error else {
                XCTFail("expected intentHashMismatch, got \(error)")
                return
            }
        }
    }

    func testFutureTimestampOutsideFreshnessRejected() throws {
        let priv = Curve25519.Signing.PrivateKey()
        let now = Date()
        let intent = ToyIntent(kind: "tap", nx: 0.5, ny: 0.5)
        let signed = try signer.sign(
            intent: intent,
            peerNodeId: "peer-1",
            counter: 1,
            timestamp: now.addingTimeInterval(30),
            privateKey: priv
        )
        XCTAssertThrowsError(try signer.verify(
            intent: intent,
            authority: signed,
            peerPublicKey: priv.publicKey,
            lastSeenCounter: 0,
            now: now
        )) { error in
            guard case ComputerUsePhoneControlSigner.VerifyError.staleTimestamp = error else {
                XCTFail("expected staleTimestamp, got \(error)")
                return
            }
        }
    }

    func testCounterZeroIsValidWhenNothingSeen() throws {
        let priv = Curve25519.Signing.PrivateKey()
        let intent = ToyIntent(kind: "tap", nx: 0.2, ny: 0.8)
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
            peerPublicKey: priv.publicKey,
            lastSeenCounter: 0,
            now: Date()
        )
    }

    func testEqualCounterRejectedButNextCounterAccepted() throws {
        let priv = Curve25519.Signing.PrivateKey()
        let intent = ToyIntent(kind: "tap", nx: 0.2, ny: 0.8)
        let signed = try signer.sign(
            intent: intent,
            peerNodeId: "peer-1",
            counter: 11,
            timestamp: Date(),
            privateKey: priv
        )
        XCTAssertThrowsError(try signer.verify(
            intent: intent,
            authority: signed,
            peerPublicKey: priv.publicKey,
            lastSeenCounter: 11,
            now: Date()
        ))
        try signer.verify(
            intent: intent,
            authority: signed,
            peerPublicKey: priv.publicKey,
            lastSeenCounter: 10,
            now: Date()
        )
    }

    func testCanonicalIntentHashIgnoresPropertyOrder() throws {
        struct IntentA: Codable { let kind: String; let nx: Double; let ny: Double }
        struct IntentB: Codable { let ny: Double; let kind: String; let nx: Double }
        let a = IntentA(kind: "tap", nx: 0.1, ny: 0.9)
        let b = IntentB(ny: 0.9, kind: "tap", nx: 0.1)
        XCTAssertEqual(
            try signer.canonicalIntentHashHex(intent: a),
            try signer.canonicalIntentHashHex(intent: b)
        )
    }

    func testRealtimeInputIntentHashExcludesAuthorityEnvelope() throws {
        let placeholder = authority(
            peerNodeId: "",
            counter: 0,
            intentHash: "",
            signature: ""
        )
        let final = authority(
            peerNodeId: "phone-node",
            counter: 42,
            intentHash: String(repeating: "a", count: 64),
            signature: Data(repeating: 0x7A, count: 64).base64EncodedString()
        )
        let intentBeforeSigning = HermesRealtimeRelayInputIntent(
            kind: .tap,
            normalizedX: 0.25,
            normalizedY: 0.75,
            authority: placeholder
        )
        let intentAfterSigning = HermesRealtimeRelayInputIntent(
            kind: .tap,
            normalizedX: 0.25,
            normalizedY: 0.75,
            authority: final
        )

        XCTAssertEqual(
            try signer.canonicalInputIntentHashHex(intent: intentBeforeSigning),
            try signer.canonicalInputIntentHashHex(intent: intentAfterSigning)
        )
    }

    func testRealtimeInputIntentRoundTripSucceedsAfterAuthorityIsAttached() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let placeholder = authority(peerNodeId: "", counter: 0, intentHash: "", signature: "")
        var intent = HermesRealtimeRelayInputIntent(
            kind: .shortcut,
            key: "c",
            modifiers: ["cmd"],
            authority: placeholder
        )

        let signed = try signer.sign(
            intent: intent,
            peerNodeId: "phone-node",
            counter: 3,
            timestamp: Date(),
            privateKey: privateKey
        )
        intent.authority = HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: signed.peerNodeId,
            counter: signed.counter,
            timestamp: signed.timestamp,
            intentHashBlake3: signed.intentHashHex,
            signatureEd25519: signed.signatureBase64
        )

        try signer.verify(
            intent: intent,
            authority: signed,
            peerPublicKey: privateKey.publicKey,
            lastSeenCounter: 2,
            now: Date()
        )
    }

    func testRealtimeScrollIntentHashCoversDragEndpoint() throws {
        let placeholder = authority(peerNodeId: "", counter: 0, intentHash: "", signature: "")
        let original = HermesRealtimeRelayInputIntent(
            kind: .scroll,
            normalizedX: 0.4,
            normalizedY: 0.5,
            normalizedX2: 0.4,
            normalizedY2: 0.2,
            authority: placeholder
        )
        let changedEndpoint = HermesRealtimeRelayInputIntent(
            kind: .scroll,
            normalizedX: 0.4,
            normalizedY: 0.5,
            normalizedX2: 0.4,
            normalizedY2: 0.8,
            authority: placeholder
        )

        XCTAssertNotEqual(
            try signer.canonicalInputIntentHashHex(intent: original),
            try signer.canonicalInputIntentHashHex(intent: changedEndpoint)
        )
    }

    func testRealtimeInputIntentHashCoversClientIntentId() throws {
        let placeholder = authority(peerNodeId: "", counter: 0, intentHash: "", signature: "")
        let original = HermesRealtimeRelayInputIntent(
            kind: .tap,
            normalizedX: 0.4,
            normalizedY: 0.5,
            clientIntentId: "intent-a",
            authority: placeholder
        )
        let changedClientIntent = HermesRealtimeRelayInputIntent(
            kind: .tap,
            normalizedX: 0.4,
            normalizedY: 0.5,
            clientIntentId: "intent-b",
            authority: placeholder
        )

        XCTAssertNotEqual(
            try signer.canonicalInputIntentHashHex(intent: original),
            try signer.canonicalInputIntentHashHex(intent: changedClientIntent)
        )
    }

    func testRealtimeInputIntentTamperedActionFieldFailsAfterAuthorityAttached() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let placeholder = authority(peerNodeId: "", counter: 0, intentHash: "", signature: "")
        let original = HermesRealtimeRelayInputIntent(
            kind: .tap,
            normalizedX: 0.1,
            normalizedY: 0.2,
            authority: placeholder
        )
        let signed = try signer.sign(
            intent: original,
            peerNodeId: "phone-node",
            counter: 4,
            timestamp: Date(),
            privateKey: privateKey
        )
        let tampered = HermesRealtimeRelayInputIntent(
            kind: .tap,
            normalizedX: 0.9,
            normalizedY: 0.2,
            authority: HermesRealtimeRelayAuthorityEnvelope(
                peerNodeId: signed.peerNodeId,
                counter: signed.counter,
                timestamp: signed.timestamp,
                intentHashBlake3: signed.intentHashHex,
                signatureEd25519: signed.signatureBase64
            )
        )

        XCTAssertThrowsError(try signer.verify(
            intent: tampered,
            authority: signed,
            peerPublicKey: privateKey.publicKey,
            lastSeenCounter: 3,
            now: Date()
        )) { error in
            guard case ComputerUsePhoneControlSigner.VerifyError.intentHashMismatch = error else {
                XCTFail("expected intentHashMismatch, got \(error)")
                return
            }
        }
    }

    private func authority(
        peerNodeId: String,
        counter: UInt64,
        intentHash: String,
        signature: String
    ) -> HermesRealtimeRelayAuthorityEnvelope {
        HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: peerNodeId,
            counter: counter,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            intentHashBlake3: intentHash,
            signatureEd25519: signature
        )
    }
}
