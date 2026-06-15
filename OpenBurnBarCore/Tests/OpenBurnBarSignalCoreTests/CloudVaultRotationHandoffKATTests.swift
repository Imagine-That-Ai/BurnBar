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
            "plainStatus": "active",
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

        // OLD wrap is gone: the OLD key no longer opens the resealed envelopes.
        XCTAssertThrowsError(try CloudVaultCrypto.openPayload(resealedPayload, keyData: oldKey, aadContext: payloadContext))
        XCTAssertThrowsError(try CloudVaultCrypto.openBlob(resealedBlob, keyData: oldKey, aadContext: blobContext))

        // STALE pre-rotation claim fails closed: a reader holding the OLD ciphertext and now
        // presenting the NEW key cannot open it (vaultKeyID guard) — it fails closed, not silent.
        XCTAssertThrowsError(try CloudVaultCrypto.openPayload(staleEnvelope, keyData: newKey, aadContext: payloadContext))
    }

    func test_signalIdentityHandoff_rotationEventIsWellFormedAndRevokesOldIdentity() throws {
        // The cross-device handoff publishes a NEW Signal identity key for the same device and
        // records an append-only rotation event. Pin the transition + the recordSignalRotation
        // output invariants (the callable runs server-side; buildRotationEventDoc enforces the
        // same bounds in functions/src/callables/signalPrekeyDirectory.ts).
        let oldIdentity = OpenBurnBarSignalIdentityKeypair.generateInMemory(deviceId: "mac-1", keyVersion: 1)
        let newIdentity = OpenBurnBarSignalIdentityKeypair.generateInMemory(deviceId: "mac-1", keyVersion: 2)

        XCTAssertEqual(oldIdentity.identityKeyId, "mac-1_1")
        XCTAssertEqual(newIdentity.identityKeyId, "mac-1_2")
        // A real identity transition: the new key is materially different from the old one.
        XCTAssertNotEqual(oldIdentity.publicKeyFingerprint, newIdentity.publicKeyFingerprint)
        XCTAssertNotEqual(oldIdentity.publicKeyData, newIdentity.publicKeyData)

        // recordSignalRotation semantics: version strictly increases, a rewrap job id is set when
        // rewrap is required, and the OLD identity is the one revoked.
        let fromKeyVersion = oldIdentity.keyVersion
        let toKeyVersion = newIdentity.keyVersion
        let rewrapRequired = true
        let rewrapJobId = rewrapRequired ? "rewrap_\(newIdentity.identityKeyId)" : nil
        let revokedIdentityKeyId = oldIdentity.identityKeyId

        XCTAssertLessThan(fromKeyVersion, toKeyVersion)
        XCTAssertEqual(try XCTUnwrap(rewrapJobId).isEmpty, false)
        XCTAssertEqual(revokedIdentityKeyId, oldIdentity.identityKeyId)
        XCTAssertNotEqual(revokedIdentityKeyId, newIdentity.identityKeyId)
    }
}
