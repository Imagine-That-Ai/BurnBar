import XCTest
import CryptoKit
import OpenBurnBarCore
@testable import OpenBurnBarComputerUseCore

final class ComputerUsePhoneControlSignerTests: XCTestCase {
    private struct ToyIntent: Codable, Hashable {
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

    func testRealtimeInputIntentHashCoversMouseButton() throws {
        let placeholder = authority(peerNodeId: "", counter: 0, intentHash: "", signature: "")
        let leftClick = HermesRealtimeRelayInputIntent(
            kind: .tap,
            normalizedX: 0.4,
            normalizedY: 0.5,
            mouseButton: 0,
            authority: placeholder
        )
        let rightClick = HermesRealtimeRelayInputIntent(
            kind: .tap,
            normalizedX: 0.4,
            normalizedY: 0.5,
            mouseButton: 1,
            authority: placeholder
        )

        XCTAssertNotEqual(
            try signer.canonicalInputIntentHashHex(intent: leftClick),
            try signer.canonicalInputIntentHashHex(intent: rightClick)
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

    func testAgentContextTargetSigningAndVerification() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let placeholder = HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: "",
            counter: 0,
            timestamp: Date(timeIntervalSince1970: 0),
            intentHashBlake3: "",
            signatureEd25519: ""
        )
        let target = HermesRealtimeRelayAgentContextTarget(
            requestId: UUID().uuidString,
            sessionId: "test-session",
            runtime: "hermes",
            threadId: "test-thread",
            displayId: "main",
            normalizedX: 0.25,
            normalizedY: 0.75,
            normalizedRect: HermesRealtimeRelayNormalizedRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3),
            instruction: "Click this button",
            focusContext: nil,
            clientIntentId: UUID().uuidString,
            requestedAt: Date(),
            authority: placeholder
        )
        let signed = try signer.sign(
            target: target,
            peerNodeId: "phone-node",
            counter: 12,
            timestamp: Date(),
            privateKey: privateKey
        )

        let signedTarget = HermesRealtimeRelayAgentContextTarget(
            requestId: target.requestId,
            sessionId: target.sessionId,
            runtime: target.runtime,
            threadId: target.threadId,
            displayId: target.displayId,
            normalizedX: target.normalizedX,
            normalizedY: target.normalizedY,
            normalizedRect: target.normalizedRect,
            instruction: target.instruction,
            focusContext: target.focusContext,
            clientIntentId: target.clientIntentId,
            requestedAt: target.requestedAt,
            authority: HermesRealtimeRelayAuthorityEnvelope(
                peerNodeId: signed.peerNodeId,
                counter: signed.counter,
                timestamp: signed.timestamp,
                intentHashBlake3: signed.intentHashHex,
                signatureEd25519: signed.signatureBase64
            )
        )

        try signer.verify(
            target: signedTarget,
            authority: signed,
            peerPublicKey: privateKey.publicKey,
            lastSeenCounter: 11,
            now: Date()
        )
    }

    func testRealtimeClipboardRequestHashExcludesAuthorityEnvelope() throws {
        let placeholder = authority(peerNodeId: "", counter: 0, intentHash: "", signature: "")
        let final = authority(
            peerNodeId: "phone-node",
            counter: 42,
            intentHash: String(repeating: "b", count: 64),
            signature: Data(repeating: 0x5A, count: 64).base64EncodedString()
        )
        let beforeSigning = HermesRealtimeRelayClipboardRequest(
            requestId: "clipboard-1",
            action: .pasteToMac,
            contentType: "text/plain",
            text: "hello",
            maxBytes: 65_536,
            clientIntentId: "intent-1",
            authority: placeholder
        )
        let afterSigning = HermesRealtimeRelayClipboardRequest(
            requestId: "clipboard-1",
            action: .pasteToMac,
            contentType: "text/plain",
            text: "hello",
            maxBytes: 65_536,
            clientIntentId: "intent-1",
            authority: final
        )

        XCTAssertEqual(
            try signer.canonicalClipboardRequestHashHex(request: beforeSigning),
            try signer.canonicalClipboardRequestHashHex(request: afterSigning)
        )
    }

    func testRealtimeClipboardRequestRoundTripSucceedsAfterAuthorityIsAttached() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let placeholder = authority(peerNodeId: "", counter: 0, intentHash: "", signature: "")
        var request = HermesRealtimeRelayClipboardRequest(
            requestId: "clipboard-2",
            action: .grabFromMac,
            contentType: "text/plain",
            maxBytes: 65_536,
            clientIntentId: "intent-2",
            authority: placeholder
        )

        let signed = try signer.sign(
            clipboardRequest: request,
            peerNodeId: "phone-node",
            counter: 8,
            timestamp: Date(),
            privateKey: privateKey
        )
        request.authority = HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: signed.peerNodeId,
            counter: signed.counter,
            timestamp: signed.timestamp,
            intentHashBlake3: signed.intentHashHex,
            signatureEd25519: signed.signatureBase64
        )

        try signer.verify(
            clipboardRequest: request,
            authority: signed,
            peerPublicKey: privateKey.publicKey,
            lastSeenCounter: 7,
            now: Date()
        )
    }

    func testRealtimeClipboardRequestRejectsReplayCounter() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let placeholder = authority(peerNodeId: "", counter: 0, intentHash: "", signature: "")
        var request = HermesRealtimeRelayClipboardRequest(
            requestId: "clipboard-replay",
            action: .pasteToMac,
            contentType: "text/plain",
            text: "hello",
            maxBytes: 65_536,
            clientIntentId: "intent-replay",
            authority: placeholder
        )

        let signed = try signer.sign(
            clipboardRequest: request,
            peerNodeId: "phone-node",
            counter: 12,
            timestamp: Date(),
            privateKey: privateKey
        )
        request.authority = HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: signed.peerNodeId,
            counter: signed.counter,
            timestamp: signed.timestamp,
            intentHashBlake3: signed.intentHashHex,
            signatureEd25519: signed.signatureBase64
        )

        XCTAssertThrowsError(
            try signer.verify(
                clipboardRequest: request,
                authority: signed,
                peerPublicKey: privateKey.publicKey,
                lastSeenCounter: 12,
                now: Date()
            )
        ) { error in
            guard case ComputerUsePhoneControlSigner.VerifyError.counterReplay(let lastSeen, let attempted) = error else {
                XCTFail("expected counterReplay, got \(error)")
                return
            }
            XCTAssertEqual(lastSeen, 12)
            XCTAssertEqual(attempted, 12)
        }
    }

    func testRealtimeClipboardRequestHashCoversTextAndClientIntentId() throws {
        let placeholder = authority(peerNodeId: "", counter: 0, intentHash: "", signature: "")
        let original = HermesRealtimeRelayClipboardRequest(
            requestId: "clipboard-3",
            action: .pasteToMac,
            contentType: "text/plain",
            text: "first",
            maxBytes: 65_536,
            clientIntentId: "intent-a",
            authority: placeholder
        )
        let changedText = HermesRealtimeRelayClipboardRequest(
            requestId: "clipboard-3",
            action: .pasteToMac,
            contentType: "text/plain",
            text: "second",
            maxBytes: 65_536,
            clientIntentId: "intent-a",
            authority: placeholder
        )
        let changedIntent = HermesRealtimeRelayClipboardRequest(
            requestId: "clipboard-3",
            action: .pasteToMac,
            contentType: "text/plain",
            text: "first",
            maxBytes: 65_536,
            clientIntentId: "intent-b",
            authority: placeholder
        )

        XCTAssertNotEqual(
            try signer.canonicalClipboardRequestHashHex(request: original),
            try signer.canonicalClipboardRequestHashHex(request: changedText)
        )
        XCTAssertNotEqual(
            try signer.canonicalClipboardRequestHashHex(request: original),
            try signer.canonicalClipboardRequestHashHex(request: changedIntent)
        )
    }

    func testRemoteUnlockCredentialHashExcludesAuthorityAndCoversCiphertext() throws {
        let placeholder = authority(peerNodeId: "", counter: 0, intentHash: "", signature: "")
        let final = authority(
            peerNodeId: "phone-node",
            counter: 42,
            intentHash: String(repeating: "c", count: 64),
            signature: Data(repeating: 0x4A, count: 64).base64EncodedString()
        )
        let beforeSigning = remoteUnlockCredential(ciphertextBase64: "Y2lwaGVyLWE=", authority: placeholder)
        let afterSigning = remoteUnlockCredential(ciphertextBase64: "Y2lwaGVyLWE=", authority: final)
        let tamperedCiphertext = remoteUnlockCredential(ciphertextBase64: "Y2lwaGVyLWI=", authority: placeholder)

        XCTAssertEqual(
            try signer.canonicalRemoteUnlockCredentialHashHex(credential: beforeSigning),
            try signer.canonicalRemoteUnlockCredentialHashHex(credential: afterSigning)
        )
        XCTAssertNotEqual(
            try signer.canonicalRemoteUnlockCredentialHashHex(credential: beforeSigning),
            try signer.canonicalRemoteUnlockCredentialHashHex(credential: tamperedCiphertext)
        )
    }

    func testRemoteUnlockCredentialSigningRoundTripSucceedsAfterAuthorityAttached() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        var credential = remoteUnlockCredential(
            ciphertextBase64: "Y2lwaGVy",
            authority: authority(peerNodeId: "", counter: 0, intentHash: "", signature: "")
        )

        let signed = try signer.sign(
            remoteUnlockCredential: credential,
            peerNodeId: "phone-node",
            counter: 14,
            timestamp: Date(),
            privateKey: privateKey
        )
        credential.authority = HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: signed.peerNodeId,
            counter: signed.counter,
            timestamp: signed.timestamp,
            intentHashBlake3: signed.intentHashHex,
            signatureEd25519: signed.signatureBase64
        )

        try signer.verify(
            remoteUnlockCredential: credential,
            authority: signed,
            peerPublicKey: privateKey.publicKey,
            lastSeenCounter: 13,
            now: Date()
        )
    }

    func testRemoteUnlockSessionHashSurvivesRelayDateEncodingRoundTrip() throws {
        let issuedAt = Date(timeIntervalSince1970: 1_700_000_000.123789)
        let session = HermesRealtimeRelayRemoteUnlockSession(
            requestId: "remote-unlock-request",
            sessionId: "remote-unlock-session",
            intent: .request,
            requesterDisplayName: "Alberto's iPhone",
            viewerDeviceId: "ios-device",
            requestedAt: issuedAt,
            expiresAt: issuedAt.addingTimeInterval(60),
            localAuthenticationSatisfied: true,
            requestedLockState: .screenLocked,
            requestedBackend: .openBurnBarVirtualHID,
            authority: authority(peerNodeId: "", counter: 0, intentHash: "", signature: "")
        )

        let decoded = try JSONDecoder().decode(
            HermesRealtimeRelayRemoteUnlockSession.self,
            from: JSONEncoder().encode(session)
        )

        XCTAssertEqual(
            try signer.canonicalRemoteUnlockSessionHashHex(session: session),
            try signer.canonicalRemoteUnlockSessionHashHex(session: decoded)
        )
    }

    func testRemoteUnlockCredentialSignatureSurvivesRelayDateEncodingRoundTrip() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let issuedAt = Date(timeIntervalSince1970: 1_700_000_000.123789)
        var credential = HermesRealtimeRelayRemoteUnlockCredentialEnvelope(
            requestId: "remote-unlock-credential",
            sessionId: "remote-unlock-session",
            clientIntentId: "client-intent",
            credentialKind: .typedPassword,
            recipientKeyId: "hpke-key",
            algorithm: RemoteUnlockPolicy.credentialEnvelopeAlgorithm,
            ciphertextBase64: "Y2lwaGVy",
            aadBase64: "YWFk",
            redactedByteCount: 8,
            requestedAt: issuedAt,
            expiresAt: issuedAt.addingTimeInterval(30),
            authority: authority(peerNodeId: "", counter: 0, intentHash: "", signature: "")
        )

        let signed = try signer.sign(
            remoteUnlockCredential: credential,
            peerNodeId: "phone-node",
            counter: 14,
            timestamp: issuedAt,
            privateKey: privateKey
        )
        credential.authority = HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: signed.peerNodeId,
            counter: signed.counter,
            timestamp: signed.timestamp,
            intentHashBlake3: signed.intentHashHex,
            signatureEd25519: signed.signatureBase64
        )

        let decoded = try JSONDecoder().decode(
            HermesRealtimeRelayRemoteUnlockCredentialEnvelope.self,
            from: JSONEncoder().encode(credential)
        )

        XCTAssertEqual(
            try signer.canonicalRemoteUnlockCredentialHashHex(credential: credential),
            try signer.canonicalRemoteUnlockCredentialHashHex(credential: decoded)
        )
        try signer.verify(
            remoteUnlockCredential: decoded,
            authority: signed,
            peerPublicKey: privateKey.publicKey,
            lastSeenCounter: 13,
            now: issuedAt
        )
    }

    func testApprovalResponseSignatureBindsPendingRequestHashAndIgnoresAuthorityCarrier() throws {
        let priv = Curve25519.Signing.PrivateKey()
        let issuedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let request = HermesRealtimeRelayApprovalRequest(
            approvalId: "approval-1",
            runId: "run-1",
            sessionId: "session-1",
            toolKind: "desktop.click",
            title: "Click",
            message: "Click the button",
            beforeScreenshotBlake3: "screenshot-hash",
            actionSummary: "Click the button",
            requestedAt: issuedAt,
            trustMode: "manual"
        )
        var response = HermesRealtimeRelayApprovalResponse(
            approvalId: request.approvalId,
            decision: .approve,
            respondedBy: "phone",
            respondedAt: issuedAt.addingTimeInterval(1),
            note: "approved",
            requestHashBlake3: try signer.canonicalApprovalRequestHashHex(request: request)
        )

        let signed = try signer.sign(
            approvalResponse: response,
            peerNodeId: "ios-phone-0123456789abcdef01234567",
            counter: 42,
            timestamp: issuedAt.addingTimeInterval(1),
            privateKey: priv
        )
        let unsignedHash = try signer.canonicalApprovalResponseHashHex(response: response)
        response.authority = HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: signed.peerNodeId,
            counter: signed.counter,
            timestamp: signed.timestamp,
            intentHashBlake3: signed.intentHashHex,
            signatureEd25519: signed.signatureBase64
        )

        XCTAssertEqual(try signer.canonicalApprovalResponseHashHex(response: response), unsignedHash)
        XCTAssertEqual(signed.intentHashHex, unsignedHash)

        var tampered = response
        tampered.requestHashBlake3 = String(repeating: "f", count: 64)
        XCTAssertNotEqual(try signer.canonicalApprovalResponseHashHex(response: tampered), signed.intentHashHex)
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

    private func remoteUnlockCredential(
        ciphertextBase64: String,
        authority: HermesRealtimeRelayAuthorityEnvelope
    ) -> HermesRealtimeRelayRemoteUnlockCredentialEnvelope {
        HermesRealtimeRelayRemoteUnlockCredentialEnvelope(
            requestId: "remote-unlock-credential",
            sessionId: "remote-unlock-session",
            clientIntentId: "client-intent",
            credentialKind: .typedPassword,
            recipientKeyId: "hpke-key",
            algorithm: RemoteUnlockPolicy.credentialEnvelopeAlgorithm,
            ciphertextBase64: ciphertextBase64,
            aadBase64: "YWFk",
            redactedByteCount: 8,
            requestedAt: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: Date(timeIntervalSince1970: 1_700_000_030),
            authority: authority
        )
    }
}
