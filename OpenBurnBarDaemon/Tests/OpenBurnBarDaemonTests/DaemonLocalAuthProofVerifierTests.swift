import CryptoKit
import Foundation
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
@testable import OpenBurnBarDaemon
import XCTest

/// T-DMN-04: the daemon INDEPENDENTLY re-verifies the single-use, op-hash-bound
/// Ed25519 local-auth proof against a PINNED phone verifying key, so the proof
/// binding survives a compromise of the first-party app.
final class DaemonLocalAuthProofVerifierTests: XCTestCase {
    private let deviceId = "device-abc"
    private let intentHash = String(repeating: "a", count: 64)

    private func makeProof(
        privateKey: Curve25519.Signing.PrivateKey,
        proofId: String = UUID().uuidString,
        deviceId: String,
        intentHash: String,
        authenticatedAt: Date,
        expiresAt: Date
    ) throws -> HermesRealtimeRelayAgentGrantLocalAuthProof {
        try ComputerUsePhoneControlSigner().signLocalAuthProof(
            proofId: proofId,
            deviceId: deviceId,
            signedIntentHash: intentHash,
            authenticatedAt: authenticatedAt,
            expiresAt: expiresAt,
            privateKey: privateKey
        )
    }

    private func makeVerifier(
        pinned: [String: PhoneControlVerifyingKey],
        ledger: DaemonConsumedLocalAuthProofLedger = DaemonConsumedLocalAuthProofLedger()
    ) -> DaemonLocalAuthProofVerifier {
        DaemonLocalAuthProofVerifier(
            resolvePinnedKey: { deviceId in pinned[deviceId] },
            consumeProof: { proofId, expiresAt in ledger.consume(proofId: proofId, expiresAt: expiresAt) }
        )
    }

    func test_acceptsProofSignedByPinnedKeyAndBoundToIntent() throws {
        let now = Date()
        let key = Curve25519.Signing.PrivateKey()
        let proof = try makeProof(
            privateKey: key,
            deviceId: deviceId,
            intentHash: intentHash,
            authenticatedAt: now,
            expiresAt: now.addingTimeInterval(120)
        )
        let verifier = makeVerifier(pinned: [deviceId: .ed25519(key.publicKey)])
        let result = try verifier.verify(
            proof: proof,
            expectedDeviceId: deviceId,
            expectedIntentHashHex: intentHash,
            now: now
        )
        XCTAssertEqual(result.deviceId, deviceId)
        XCTAssertEqual(result.proofId, proof.proofId)
    }

    func test_rejectsProofSignedByDifferentKey_appCompromiseForgery() throws {
        // App compromise: a forged proof signed by an attacker key, but the daemon
        // pins the REAL phone key. Must fail closed.
        let now = Date()
        let attackerKey = Curve25519.Signing.PrivateKey()
        let pinnedRealKey = Curve25519.Signing.PrivateKey()
        let forged = try makeProof(
            privateKey: attackerKey,
            deviceId: deviceId,
            intentHash: intentHash,
            authenticatedAt: now,
            expiresAt: now.addingTimeInterval(120)
        )
        let verifier = makeVerifier(pinned: [deviceId: .ed25519(pinnedRealKey.publicKey)])
        XCTAssertThrowsError(
            try verifier.verify(proof: forged, expectedDeviceId: deviceId, expectedIntentHashHex: intentHash, now: now)
        ) { error in
            XCTAssertEqual(error as? DaemonLocalAuthProofVerifier.VerificationFailure, .signatureInvalid)
        }
    }

    func test_rejectsWhenNoKeyIsPinnedForDevice() throws {
        let now = Date()
        let key = Curve25519.Signing.PrivateKey()
        let proof = try makeProof(
            privateKey: key,
            deviceId: deviceId,
            intentHash: intentHash,
            authenticatedAt: now,
            expiresAt: now.addingTimeInterval(120)
        )
        let verifier = makeVerifier(pinned: [:])
        XCTAssertThrowsError(
            try verifier.verify(proof: proof, expectedDeviceId: deviceId, expectedIntentHashHex: intentHash, now: now)
        ) { error in
            XCTAssertEqual(error as? DaemonLocalAuthProofVerifier.VerificationFailure, .noPinnedKey(deviceId: deviceId))
        }
    }

    func test_rejectsProofBoundToDifferentOpHash() throws {
        // Op-hash binding: a proof minted for a benign op cannot be retargeted to
        // a different (high-risk) op hash the daemon is about to execute.
        let now = Date()
        let key = Curve25519.Signing.PrivateKey()
        let proof = try makeProof(
            privateKey: key,
            deviceId: deviceId,
            intentHash: intentHash,
            authenticatedAt: now,
            expiresAt: now.addingTimeInterval(120)
        )
        let verifier = makeVerifier(pinned: [deviceId: .ed25519(key.publicKey)])
        let otherHash = String(repeating: "b", count: 64)
        XCTAssertThrowsError(
            try verifier.verify(proof: proof, expectedDeviceId: deviceId, expectedIntentHashHex: otherHash, now: now)
        ) { error in
            guard case .wrongIntent = error as? DaemonLocalAuthProofVerifier.VerificationFailure else {
                return XCTFail("expected wrongIntent, got \(error)")
            }
        }
    }

    func test_rejectsProofForDifferentDevice() throws {
        let now = Date()
        let key = Curve25519.Signing.PrivateKey()
        let proof = try makeProof(
            privateKey: key,
            deviceId: "other-device",
            intentHash: intentHash,
            authenticatedAt: now,
            expiresAt: now.addingTimeInterval(120)
        )
        let verifier = makeVerifier(pinned: [deviceId: .ed25519(key.publicKey)])
        XCTAssertThrowsError(
            try verifier.verify(proof: proof, expectedDeviceId: deviceId, expectedIntentHashHex: intentHash, now: now)
        ) { error in
            guard case .wrongDevice = error as? DaemonLocalAuthProofVerifier.VerificationFailure else {
                return XCTFail("expected wrongDevice, got \(error)")
            }
        }
    }

    func test_rejectsExpiredProof() throws {
        let now = Date()
        let key = Curve25519.Signing.PrivateKey()
        let proof = try makeProof(
            privateKey: key,
            deviceId: deviceId,
            intentHash: intentHash,
            authenticatedAt: now.addingTimeInterval(-200),
            expiresAt: now.addingTimeInterval(-10)
        )
        let verifier = makeVerifier(pinned: [deviceId: .ed25519(key.publicKey)])
        XCTAssertThrowsError(
            try verifier.verify(proof: proof, expectedDeviceId: deviceId, expectedIntentHashHex: intentHash, now: now)
        ) { error in
            XCTAssertEqual(error as? DaemonLocalAuthProofVerifier.VerificationFailure, .expired)
        }
    }

    func test_rejectsProofWithWindowLongerThanMaxTTL() throws {
        let now = Date()
        let key = Curve25519.Signing.PrivateKey()
        let proof = try makeProof(
            privateKey: key,
            deviceId: deviceId,
            intentHash: intentHash,
            authenticatedAt: now,
            expiresAt: now.addingTimeInterval(DaemonLocalAuthProofVerifier.maxProofLifetime + 60)
        )
        let verifier = makeVerifier(pinned: [deviceId: .ed25519(key.publicKey)])
        XCTAssertThrowsError(
            try verifier.verify(proof: proof, expectedDeviceId: deviceId, expectedIntentHashHex: intentHash, now: now)
        ) { error in
            XCTAssertEqual(error as? DaemonLocalAuthProofVerifier.VerificationFailure, .windowTooLong)
        }
    }

    func test_singleUse_rejectsSecondVerificationOfSameProof() throws {
        let now = Date()
        let key = Curve25519.Signing.PrivateKey()
        let proof = try makeProof(
            privateKey: key,
            deviceId: deviceId,
            intentHash: intentHash,
            authenticatedAt: now,
            expiresAt: now.addingTimeInterval(120)
        )
        let ledger = DaemonConsumedLocalAuthProofLedger()
        let verifier = makeVerifier(pinned: [deviceId: .ed25519(key.publicKey)], ledger: ledger)

        XCTAssertNoThrow(
            try verifier.verify(proof: proof, expectedDeviceId: deviceId, expectedIntentHashHex: intentHash, now: now)
        )
        XCTAssertThrowsError(
            try verifier.verify(proof: proof, expectedDeviceId: deviceId, expectedIntentHashHex: intentHash, now: now)
        ) { error in
            XCTAssertEqual(error as? DaemonLocalAuthProofVerifier.VerificationFailure, .replay(proofId: proof.proofId))
        }
    }

    func test_forgedSignatureDoesNotBurnProofId() throws {
        // A failed-signature probe must NOT consume the proof id, so a later
        // legitimate proof with that id (single-use ledger) is not pre-burned.
        let now = Date()
        let realKey = Curve25519.Signing.PrivateKey()
        let attackerKey = Curve25519.Signing.PrivateKey()
        let sharedProofId = UUID().uuidString
        let ledger = DaemonConsumedLocalAuthProofLedger()
        let verifier = makeVerifier(pinned: [deviceId: .ed25519(realKey.publicKey)], ledger: ledger)

        let forged = try makeProof(
            privateKey: attackerKey,
            proofId: sharedProofId,
            deviceId: deviceId,
            intentHash: intentHash,
            authenticatedAt: now,
            expiresAt: now.addingTimeInterval(120)
        )
        XCTAssertThrowsError(
            try verifier.verify(proof: forged, expectedDeviceId: deviceId, expectedIntentHashHex: intentHash, now: now)
        )
        XCTAssertFalse(ledger.isConsumed(proofId: sharedProofId), "a forged-signature probe must not consume the id")

        let legit = try makeProof(
            privateKey: realKey,
            proofId: sharedProofId,
            deviceId: deviceId,
            intentHash: intentHash,
            authenticatedAt: now,
            expiresAt: now.addingTimeInterval(120)
        )
        XCTAssertNoThrow(
            try verifier.verify(proof: legit, expectedDeviceId: deviceId, expectedIntentHashHex: intentHash, now: now)
        )
    }

    func test_tamperedFieldInvalidatesSignature() throws {
        let now = Date()
        let key = Curve25519.Signing.PrivateKey()
        var proof = try makeProof(
            privateKey: key,
            deviceId: deviceId,
            intentHash: intentHash,
            authenticatedAt: now,
            expiresAt: now.addingTimeInterval(120)
        )
        // Tamper the expiry to extend the window AFTER signing (signature no longer
        // covers these bytes).
        proof.expiresAt = now.addingTimeInterval(240)
        let verifier = makeVerifier(pinned: [deviceId: .ed25519(key.publicKey)])
        XCTAssertThrowsError(
            try verifier.verify(proof: proof, expectedDeviceId: deviceId, expectedIntentHashHex: intentHash, now: now)
        ) { error in
            XCTAssertEqual(error as? DaemonLocalAuthProofVerifier.VerificationFailure, .signatureInvalid)
        }
    }
}
