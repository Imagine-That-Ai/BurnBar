import Foundation
import OpenBurnBarCore
@testable import OpenBurnBarSignalCore
import XCTest

/// Phase 2.5 G4 — rotation/rewrap cross-device handoff KAT.
///
/// Proves the cross-device key-handoff invariants the rotation/rewrap worker
/// (`MobileCloudVaultRotationRewrapWorker` / the mac + Android equivalents) depends
/// on, exercised at the pure crypto core they delegate to per document
/// (`CloudVaultCrypto.rewrapCloudVaultDocument`). The workers themselves require
/// live Firestore/Functions/Storage and are not unit-testable; this KAT pins the
/// crypto contract: after rotation the NEW key opens, the OLD wrap is gone (old key
/// fails closed), a stale pre-rotation ciphertext fails closed, and the Signal
/// identity transition (v1 -> v2) the rotation event records is well-formed.
///
/// Uses the AES-256-GCM symmetric vault path (`sealPayload`/`openPayload`), so the
/// Signal envelope format/relay-key versions are untouched (flag-OFF).
final class CloudVaultRotationHandoffKATTests: XCTestCase {
    func test_rotationHandoff_newKeyOpens_oldWrapGone_staleClaimFailsClosed() throws {
        let uid = "user-1"
        let collection = "session_logs"
        let docID = "doc-1"

        // OLD and NEW symmetric vault keys (publicly-derived 32-byte fillers, never real keys).
        let oldKey = Data(repeating: 0x41, count: 32)
        let newKey = Data(repeating: 0x42, count: 32)
        let oldVaultKeyID = try CloudVaultCrypto.vaultKeyID(for: oldKey)
        let newVaultKeyID = try CloudVaultCrypto.vaultKeyID(for: newKey)
        XCTAssertNotEqual(oldVaultKeyID, newVaultKeyID)

        let payloadContext = try CloudVaultAADContext(uid: uid, collection: collection, docID: docID, field: "sealedPayload")
        let blobContext = try CloudVaultAADContext(uid: uid, collection: collection, docID: docID, field: "sealedSnapshot")
        let payloadPlaintext = Data("{\"body\":\"pre-rotation secret\"}".utf8)
        let blobPlaintext = Data("session markdown body".utf8)

        // Seal a document under the OLD vault key (the pre-rotation state).
        let staleEnvelope = try CloudVaultCrypto.sealPayload(payloadPlaintext, keyData: oldKey, vaultKeyID: oldVaultKeyID)
        let document: [String: Any] = [
            "vaultKeyID": oldVaultKeyID,
            "sealedPayload": try CloudVaultCrypto.firestoreDictionary(staleEnvelope),
            "sealedSnapshot": try CloudVaultCrypto.firestoreDictionary(
                CloudVaultCrypto.sealBlob(blobPlaintext, keyData: oldKey)
            ),
            "plainStatus": "active"
        ]

        // REWRAP — exactly what the rotation worker performs per document on handoff.
        let rewrapJobId = "rewrap_\(newVaultKeyID.prefix(12))"
        let result = try CloudVaultCrypto.rewrapCloudVaultDocument(
            document,
            uid: uid,
            collection: collection,
            docID: docID,
            oldKeyData: oldKey,
            newKeyData: newKey,
            newVaultKeyID: newVaultKeyID,
            vaultGeneration: 2,
            rotationJobId: rewrapJobId
        )

        XCTAssertEqual(result.data["vaultKeyID"] as? String, newVaultKeyID)
        XCTAssertEqual(result.data["vaultGeneration"] as? Int, 2)
        XCTAssertEqual(result.data["rewrapJobId"] as? String, rewrapJobId)
        XCTAssertTrue(result.changedFields.contains("sealedPayload"))
        XCTAssertTrue(result.changedFields.contains("sealedSnapshot"))
        XCTAssertEqual(result.data["plainStatus"] as? String, "active")

        // NEW key opens the resealed envelopes.
        let resealedPayload = try XCTUnwrap(CloudVaultCrypto.sealedPayload(from: result.data["sealedPayload"]))
        XCTAssertEqual(resealedPayload.vaultKeyID, newVaultKeyID)
        XCTAssertNotEqual(resealedPayload.vaultKeyID, oldVaultKeyID)
        XCTAssertEqual(
            try CloudVaultCrypto.openPayload(resealedPayload, keyData: newKey, aadContext: payloadContext),
            payloadPlaintext
        )
        let resealedBlob = try XCTUnwrap(CloudVaultCrypto.decodeBlobEnvelope(from: result.data["sealedSnapshot"]))
        XCTAssertEqual(
            try CloudVaultCrypto.openBlob(resealedBlob, keyData: newKey, aadContext: blobContext),
            blobPlaintext
        )

        // OLD wrap is gone: the OLD key no longer opens the resealed payload. The vaultKeyID guard
        // fires (the presented key's id != the envelope's new id) → a structured .invalidEnvelope,
        // not a raw AEAD failure.
        XCTAssertThrowsError(try CloudVaultCrypto.openPayload(resealedPayload, keyData: oldKey, aadContext: payloadContext)) { error in
            guard case CloudVaultCryptoError.invalidEnvelope = error else {
                return XCTFail("expected .invalidEnvelope from the vaultKeyID guard, got \(error)")
            }
        }
        // The blob envelope carries no vaultKeyID, so the OLD key fails closed at the AEAD layer.
        XCTAssertThrowsError(try CloudVaultCrypto.openBlob(resealedBlob, keyData: oldKey, aadContext: blobContext))

        // STALE pre-rotation claim fails closed: a reader holding the OLD ciphertext and now
        // presenting the NEW key cannot open it — the vaultKeyID guard rejects it, not silent.
        XCTAssertThrowsError(try CloudVaultCrypto.openPayload(staleEnvelope, keyData: newKey, aadContext: payloadContext)) { error in
            guard case CloudVaultCryptoError.invalidEnvelope = error else {
                return XCTFail("expected .invalidEnvelope from the vaultKeyID guard, got \(error)")
            }
        }
    }

    func test_signalIdentityHandoff_producesADistinctNewIdentityForTheSameDevice() {
        // The cross-device handoff publishes a NEW Signal identity key (keyVersion N+1) for the same
        // device. The append-only rotation EVENT that records the transition (fromKeyVersion <
        // toKeyVersion, rewrapJobId-when-required) is shaped + bounds-checked by buildRotationEventDoc,
        // covered in the TS signalPrekeyDirectory suite. Here we pin the identity transition itself:
        // generateInMemory must yield the canonical id AND a materially-different keypair (not a
        // re-label of the same key), which is what makes "new identity opens / old fails" meaningful.
        let oldIdentity = OpenBurnBarSignalIdentityKeypair.generateInMemory(deviceId: "mac-1", keyVersion: 1)
        let newIdentity = OpenBurnBarSignalIdentityKeypair.generateInMemory(deviceId: "mac-1", keyVersion: 2)

        XCTAssertEqual(oldIdentity.identityKeyId, "mac-1_1")
        XCTAssertEqual(newIdentity.identityKeyId, "mac-1_2")
        XCTAssertLessThan(oldIdentity.keyVersion, newIdentity.keyVersion)
        XCTAssertNotEqual(oldIdentity.publicKeyData, newIdentity.publicKeyData)
        XCTAssertNotEqual(oldIdentity.publicKeyFingerprint, newIdentity.publicKeyFingerprint)
    }
}
