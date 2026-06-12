import CryptoKit
import Foundation
import XCTest
@testable import OpenBurnBarCore

final class CloudVaultCryptoTests: XCTestCase {
    func test_textAndBlobRoundTrip_decryptsOnlyWithVaultKey() throws {
        let key = Data(repeating: 0x42, count: 32)
        let otherKey = Data(repeating: 0x24, count: 32)

        let sealedText = try CloudVaultCrypto.sealText("private launch plan", keyData: key)
        XCTAssertEqual(try CloudVaultCrypto.openText(sealedText, keyData: key), "private launch plan")
        XCTAssertThrowsError(try CloudVaultCrypto.openText(sealedText, keyData: otherKey))

        let body = Data("full encrypted session markdown".utf8)
        let sealedBlob = try CloudVaultCrypto.sealBlob(body, keyData: key)
        XCTAssertEqual(sealedBlob.schemaVersion, CloudVaultCrypto.currentBlobEnvelopeSchemaVersion)
        XCTAssertNil(sealedBlob.plaintextSHA256)
        XCTAssertEqual(sealedBlob.aad, CloudVaultCrypto.blobEnvelopeAADContext)
        XCTAssertEqual(sealedBlob.integrityHashVersion, CloudVaultCrypto.blobIntegrityHashVersion)
        XCTAssertEqual(sealedBlob.plaintextHMAC, try CloudVaultCrypto.blobPlaintextHMAC(body, keyData: key))
        XCTAssertEqual(try CloudVaultCrypto.openBlob(sealedBlob, keyData: key), body)
        XCTAssertThrowsError(try CloudVaultCrypto.openBlob(sealedBlob, keyData: otherKey))

        let legacyBox = try AES.GCM.seal(body, using: SymmetricKey(data: key))
        let legacyBlob = CloudVaultBlobEnvelope(
            schemaVersion: 1,
            keyVersion: 1,
            plaintextSHA256: CloudVaultCrypto.sha256Hex(body),
            integrityHashVersion: nil,
            sealedBoxBase64: try XCTUnwrap(legacyBox.combined).base64EncodedString(),
            aad: nil
        )
        XCTAssertEqual(try CloudVaultCrypto.openBlob(legacyBlob, keyData: key), body)
    }

    func test_cloudVaultBodyAndChunkHashesAreVaultKeyedHMACs() throws {
        let key = Data(repeating: 0x62, count: 32)
        let otherKey = Data(repeating: 0x63, count: 32)
        let body = Data("secret transcript body".utf8)
        let chunk = "secret transcript chunk"

        let bodyHash = try CloudVaultCrypto.sessionBodyHash(body, keyData: key)
        let sameBodyHash = try CloudVaultCrypto.sessionBodyHash(body, keyData: key)
        let otherBodyHash = try CloudVaultCrypto.sessionBodyHash(body, keyData: otherKey)
        let chunkHash = try CloudVaultCrypto.sessionChunkHash(chunk, keyData: key)

        XCTAssertEqual(bodyHash, sameBodyHash)
        XCTAssertNotEqual(bodyHash, otherBodyHash)
        XCTAssertNotNil(bodyHash.range(of: "^[a-f0-9]{64}$", options: .regularExpression))
        XCTAssertNotNil(chunkHash.range(of: "^[a-f0-9]{64}$", options: .regularExpression))
        XCTAssertNotEqual(bodyHash, CloudVaultCrypto.sha256Hex(body))
        XCTAssertNotEqual(chunkHash, CloudVaultCrypto.sha256Hex(chunk))
        XCTAssertEqual(CloudVaultCrypto.sessionBodyHashVersion, 2)
        XCTAssertEqual(CloudVaultCrypto.sessionChunkHashVersion, 2)
        XCTAssertEqual(CloudVaultCrypto.projectMemoryContentHashVersion, 2)
        XCTAssertEqual(
            try CloudVaultCrypto.expectedSessionBodyHash(
                body,
                keyData: key,
                bodyHashVersion: CloudVaultCrypto.sessionBodyHashVersion
            ),
            bodyHash
        )
        XCTAssertEqual(
            try CloudVaultCrypto.expectedSessionBodyHash(body, keyData: key, bodyHashVersion: 0),
            CloudVaultCrypto.sha256Hex(body)
        )
    }

    func test_cloudVaultAADContextBindingRejectsRelocatedEnvelopes() throws {
        let key = Data(repeating: 0x51, count: 32)
        let context = try CloudVaultAADContext(
            uid: "userA",
            collection: "session_logs",
            docID: "docA",
            field: "sealedBody"
        )
        let wrongField = try CloudVaultAADContext(
            uid: "userA",
            collection: "session_logs",
            docID: "docA",
            field: "sealedTitle"
        )
        let wrongDoc = try CloudVaultAADContext(
            uid: "userA",
            collection: "session_logs",
            docID: "docB",
            field: "sealedBody"
        )

        let sealedText = try CloudVaultCrypto.sealText("context-bound title", keyData: key, aadContext: context)
        XCTAssertEqual(sealedText.schemaVersion, CloudVaultCrypto.currentSealedTextSchemaVersion)
        XCTAssertEqual(sealedText.aad, context.stringValue)
        XCTAssertEqual(try CloudVaultCrypto.openText(sealedText, keyData: key, aadContext: context), "context-bound title")
        XCTAssertThrowsError(try CloudVaultCrypto.openText(sealedText, keyData: key))
        XCTAssertThrowsError(try CloudVaultCrypto.openText(sealedText, keyData: key, aadContext: wrongField))

        let body = Data("context-bound body".utf8)
        let sealedBlob = try CloudVaultCrypto.sealBlob(body, keyData: key, aadContext: context)
        XCTAssertEqual(sealedBlob.aad, context.stringValue)
        XCTAssertEqual(try CloudVaultCrypto.openBlob(sealedBlob, keyData: key, aadContext: context), body)
        XCTAssertThrowsError(try CloudVaultCrypto.openBlob(sealedBlob, keyData: key))
        XCTAssertThrowsError(try CloudVaultCrypto.openBlob(sealedBlob, keyData: key, aadContext: wrongDoc))

        let payload = Data("{\"private\":true}".utf8)
        let vaultKeyID = try CloudVaultCrypto.vaultKeyID(for: key)
        let sealedPayload = try CloudVaultCrypto.sealPayload(payload, keyData: key, vaultKeyID: vaultKeyID, aadContext: context)
        XCTAssertEqual(sealedPayload.aad, context.stringValue)
        XCTAssertEqual(try CloudVaultCrypto.openPayload(sealedPayload, keyData: key, aadContext: context), payload)
        XCTAssertThrowsError(try CloudVaultCrypto.openPayload(sealedPayload, keyData: key))
        XCTAssertThrowsError(try CloudVaultCrypto.openPayload(sealedPayload, keyData: key, aadContext: wrongField))
    }

    func test_sealedPayloadV2BindsEnvelopeMetadataWithAADAndReadsLegacyV1() throws {
        let key = Data(repeating: 0x5A, count: 32)
        let payload = Data("{\"private\":\"gateway notes\"}".utf8)
        let vaultKeyID = try CloudVaultCrypto.vaultKeyID(for: key)

        let sealed = try CloudVaultCrypto.sealPayload(payload, keyData: key, vaultKeyID: vaultKeyID)

        XCTAssertEqual(sealed.schemaVersion, CloudVaultCrypto.currentSealedPayloadSchemaVersion)
        XCTAssertEqual(sealed.aad, CloudVaultCrypto.sealedPayloadAADContext)
        XCTAssertEqual(try CloudVaultCrypto.openPayload(sealed, keyData: key), payload)

        let tamperedKeyVersion = CloudVaultSealedPayload(
            schemaVersion: sealed.schemaVersion,
            algorithm: sealed.algorithm,
            keyVersion: sealed.keyVersion + 1,
            vaultKeyID: sealed.vaultKeyID,
            sealedBoxBase64: sealed.sealedBoxBase64,
            aad: sealed.aad
        )
        XCTAssertThrowsError(try CloudVaultCrypto.openPayload(tamperedKeyVersion, keyData: key))

        let legacyBox = try AES.GCM.seal(payload, using: SymmetricKey(data: key))
        let legacy = CloudVaultSealedPayload(
            schemaVersion: 1,
            algorithm: CloudVaultCrypto.aesGCMAlgorithm,
            keyVersion: 1,
            vaultKeyID: vaultKeyID,
            sealedBoxBase64: try XCTUnwrap(legacyBox.combined).base64EncodedString(),
            aad: nil
        )
        XCTAssertEqual(try CloudVaultCrypto.openPayload(legacy, keyData: key), payload)
    }

    func test_rewrapCloudVaultDocument_resealsTopLevelEnvelopesWithPathBoundAAD() throws {
        let oldKey = Data(repeating: 0x71, count: 32)
        let newKey = Data(repeating: 0x72, count: 32)
        let oldVaultKeyID = try CloudVaultCrypto.vaultKeyID(for: oldKey)
        let newVaultKeyID = try CloudVaultCrypto.vaultKeyID(for: newKey)
        let uid = "userA"
        let collection = "cli_agent_mission_requests"
        let docID = "requestA"
        let stateContext = try CloudVaultAADContext(
            uid: uid,
            collection: collection,
            docID: docID,
            field: "sealedStatePayload"
        )

        let document: [String: Any] = [
            "vaultKeyID": oldVaultKeyID,
            "sealedStateVaultKeyID": oldVaultKeyID,
            "sealedPayload": try CloudVaultCrypto.firestoreDictionary(
                CloudVaultCrypto.sealPayload(
                    Data("{\"prompt\":\"fix launch\"}".utf8),
                    keyData: oldKey,
                    vaultKeyID: oldVaultKeyID
                )
            ),
            "sealedStatePayload": try CloudVaultCrypto.firestoreDictionary(
                CloudVaultCrypto.sealPayload(
                    Data("{\"summary\":\"running\"}".utf8),
                    keyData: oldKey,
                    vaultKeyID: oldVaultKeyID,
                    aadContext: stateContext
                )
            ),
            "sealedDisplayLabel": try CloudVaultCrypto.firestoreDictionary(
                CloudVaultCrypto.sealText("release policy", keyData: oldKey)
            ),
            "plainStatus": "queued"
        ]

        let result = try CloudVaultCrypto.rewrapCloudVaultDocument(
            document,
            uid: uid,
            collection: collection,
            docID: docID,
            oldKeyData: oldKey,
            newKeyData: newKey,
            newVaultKeyID: newVaultKeyID,
            vaultGeneration: 7,
            rotationJobId: "job-7"
        )

        XCTAssertEqual(Set(result.changedFields), Set(["sealedDisplayLabel", "sealedPayload", "sealedStatePayload"]))
        XCTAssertEqual(result.data["plainStatus"] as? String, "queued")
        XCTAssertEqual(result.data["vaultKeyID"] as? String, newVaultKeyID)
        XCTAssertEqual(result.data["sealedStateVaultKeyID"] as? String, newVaultKeyID)
        XCTAssertEqual(result.data["vaultGeneration"] as? Int, 7)
        XCTAssertEqual(result.data["rewrapJobId"] as? String, "job-7")

        let payloadEnvelope = try XCTUnwrap(CloudVaultCrypto.sealedPayload(from: result.data["sealedPayload"]))
        let payloadContext = try CloudVaultAADContext(
            uid: uid,
            collection: collection,
            docID: docID,
            field: "sealedPayload"
        )
        XCTAssertEqual(payloadEnvelope.vaultKeyID, newVaultKeyID)
        XCTAssertEqual(payloadEnvelope.aad, payloadContext.stringValue)
        XCTAssertEqual(
            try CloudVaultCrypto.openPayload(payloadEnvelope, keyData: newKey, aadContext: payloadContext),
            Data("{\"prompt\":\"fix launch\"}".utf8)
        )
        XCTAssertThrowsError(try CloudVaultCrypto.openPayload(payloadEnvelope, keyData: oldKey))

        let stateEnvelope = try XCTUnwrap(CloudVaultCrypto.sealedPayload(from: result.data["sealedStatePayload"]))
        XCTAssertEqual(stateEnvelope.aad, stateContext.stringValue)
        XCTAssertEqual(
            try CloudVaultCrypto.openPayload(stateEnvelope, keyData: newKey, aadContext: stateContext),
            Data("{\"summary\":\"running\"}".utf8)
        )

        let labelEnvelope = try XCTUnwrap(CloudVaultCrypto.decodeSealedText(from: result.data["sealedDisplayLabel"]))
        let labelContext = try CloudVaultAADContext(
            uid: uid,
            collection: collection,
            docID: docID,
            field: "sealedDisplayLabel"
        )
        XCTAssertEqual(labelEnvelope.aad, labelContext.stringValue)
        XCTAssertEqual(try CloudVaultCrypto.openText(labelEnvelope, keyData: newKey, aadContext: labelContext), "release policy")
    }

    func test_rewrapCloudVaultDocument_resealsBlobEnvelopes() throws {
        let oldKey = Data(repeating: 0x81, count: 32)
        let newKey = Data(repeating: 0x82, count: 32)
        let newVaultKeyID = try CloudVaultCrypto.vaultKeyID(for: newKey)
        let body = Data("session markdown body".utf8)
        let document: [String: Any] = [
            "sealedSnapshot": try CloudVaultCrypto.firestoreDictionary(
                CloudVaultCrypto.sealBlob(body, keyData: oldKey)
            )
        ]

        let result = try CloudVaultCrypto.rewrapCloudVaultDocument(
            document,
            uid: "userA",
            collection: "project_memory_snapshots",
            docID: "pm_fixture",
            oldKeyData: oldKey,
            newKeyData: newKey,
            newVaultKeyID: newVaultKeyID
        )

        XCTAssertEqual(result.changedFields, ["sealedSnapshot"])
        let envelope = try XCTUnwrap(CloudVaultCrypto.decodeBlobEnvelope(from: result.data["sealedSnapshot"]))
        let context = try CloudVaultAADContext(
            uid: "userA",
            collection: "project_memory_snapshots",
            docID: "pm_fixture",
            field: "sealedSnapshot"
        )
        XCTAssertEqual(envelope.aad, context.stringValue)
        XCTAssertEqual(try CloudVaultCrypto.openBlob(envelope, keyData: newKey, aadContext: context), body)
        XCTAssertThrowsError(try CloudVaultCrypto.openBlob(envelope, keyData: oldKey))
    }

    func test_tokenHashes_areKeyedStableDeduplicatedAndNotPlaintext() throws {
        let key = Data(repeating: 0x11, count: 32)
        let otherKey = Data(repeating: 0x22, count: 32)
        let text = "BurnBar BurnBar hosted MiniMax encrypted session search"

        let first = try CloudVaultCrypto.tokenHashes(for: text, keyData: key)
        let second = try CloudVaultCrypto.tokenHashes(for: text, keyData: key)
        let other = try CloudVaultCrypto.tokenHashes(for: text, keyData: otherKey)

        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, other)
        XCTAssertEqual(first.count, Set(first).count)
        XCTAssertTrue(first.allSatisfy { $0.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil })
        XCTAssertFalse(first.contains("burnbar"))
        XCTAssertTrue(try CloudVaultCrypto.tokenHashes(for: "the and for", keyData: key).isEmpty)
    }

    func test_searchTokenHashes_supportEncryptedPrefixRecall() throws {
        let key = Data(repeating: 0x55, count: 32)

        let indexHashes = try CloudVaultCrypto.searchIndexTokenHashes(
            for: "/Users/emilionunezgarcia/Developer/LaHormigaDormida",
            keyData: key
        )
        let queryHashes = try CloudVaultCrypto.searchQueryTokenHashes(
            for: "emilio",
            keyData: key
        )
        let shortQueryHashes = try CloudVaultCrypto.searchQueryTokenHashes(
            for: "emi",
            keyData: key
        )
        let unrelatedHashes = try CloudVaultCrypto.searchQueryTokenHashes(
            for: "factory",
            keyData: key
        )

        XCTAssertFalse(Set(indexHashes).isDisjoint(with: queryHashes))
        XCTAssertFalse(Set(indexHashes).isDisjoint(with: shortQueryHashes))
        XCTAssertTrue(Set(indexHashes).isDisjoint(with: unrelatedHashes))
        XCTAssertTrue(indexHashes.allSatisfy { $0.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil })
        XCTAssertFalse(indexHashes.contains("emilio"))
    }

    func test_searchTokenHashes_supportEncryptedExactPhraseRecallWithSingleLetterSignals() throws {
        let key = Data(repeating: 0x56, count: 32)

        let indexHashes = try CloudVaultCrypto.searchIndexTokenHashes(
            for: "Build the X Ads API integration for campaign reporting",
            keyData: key
        )
        let exactQueryHashes = try CloudVaultCrypto.searchQueryTokenHashes(
            for: "x ads api",
            keyData: key
        )
        let partialQueryHashes = try CloudVaultCrypto.searchQueryTokenHashes(
            for: "ads api",
            keyData: key
        )
        let unrelatedHashes = try CloudVaultCrypto.searchQueryTokenHashes(
            for: "transcript cache",
            keyData: key
        )

        XCTAssertFalse(Set(indexHashes).isDisjoint(with: exactQueryHashes))
        XCTAssertFalse(Set(indexHashes).isDisjoint(with: partialQueryHashes))
        XCTAssertTrue(Set(indexHashes).isDisjoint(with: unrelatedHashes))
        XCTAssertTrue(indexHashes.allSatisfy { $0.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil })
        XCTAssertFalse(indexHashes.contains("x_ads_api"))
    }

    func test_semanticHashes_areKeyedStableBoundedAndPreserveEncryptedRecall() throws {
        let key = Data(repeating: 0x33, count: 32)
        let otherKey = Data(repeating: 0x44, count: 32)
        let indexed = "Hosted encrypted session logs with semantic search and cloud vault sync"
        let related = "Find searchable cloud sessions that were encrypted and hosted"
        let unrelated = "Espresso roast tasting notes and ceramic mugs"

        let first = try CloudVaultCrypto.semanticHashes(for: indexed, keyData: key)
        let second = try CloudVaultCrypto.semanticHashes(for: indexed, keyData: key)
        let other = try CloudVaultCrypto.semanticHashes(for: indexed, keyData: otherKey)
        let relatedHashes = try CloudVaultCrypto.semanticHashes(for: related, keyData: key)
        let unrelatedHashes = try CloudVaultCrypto.semanticHashes(for: unrelated, keyData: key)

        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, other)
        XCTAssertLessThanOrEqual(first.count, 24)
        XCTAssertEqual(first.count, Set(first).count)
        XCTAssertTrue(first.allSatisfy { $0.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil })
        XCTAssertFalse(first.contains("encrypted"))
        XCTAssertFalse(Set(first).isDisjoint(with: relatedHashes))
        XCTAssertGreaterThanOrEqual(
            Set(first).intersection(relatedHashes).count,
            Set(first).intersection(unrelatedHashes).count
        )
    }

    func test_semanticHashes_bridgeDomainSynonymsForMeaningSearch() throws {
        let key = Data(repeating: 0x34, count: 32)
        let indexed = "Twitter advertising endpoint integration and campaign reporting"
        let meaningQuery = "x ads api"
        let unrelated = "transcript cache storage setting"

        let indexedHashes = try CloudVaultCrypto.semanticHashes(for: indexed, keyData: key)
        let meaningHashes = try CloudVaultCrypto.semanticHashes(for: meaningQuery, keyData: key)
        let unrelatedHashes = try CloudVaultCrypto.semanticHashes(for: unrelated, keyData: key)

        XCTAssertFalse(Set(indexedHashes).isDisjoint(with: meaningHashes))
        XCTAssertGreaterThan(
            Set(indexedHashes).intersection(meaningHashes).count,
            Set(indexedHashes).intersection(unrelatedHashes).count
        )
        XCTAssertFalse(indexedHashes.contains("twitter"))
    }

    func test_projectMemoryDocID_isDeterministicOpaqueAndKeySensitive() throws {
        let key = Data(repeating: 0x42, count: 32)
        let otherKey = Data(repeating: 0x24, count: 32)
        let slug = "la-hormiga-dormida"

        let first = try CloudVaultCrypto.projectMemoryDocID(forSlug: slug, keyData: key)
        let second = try CloudVaultCrypto.projectMemoryDocID(forSlug: slug, keyData: key)
        let otherSlug = try CloudVaultCrypto.projectMemoryDocID(forSlug: "burnbar", keyData: key)
        let otherVault = try CloudVaultCrypto.projectMemoryDocID(forSlug: slug, keyData: otherKey)

        // Deterministic: same slug + key → same id (upsert idempotency).
        XCTAssertEqual(first, second)
        // Distinct slug → distinct id.
        XCTAssertNotEqual(first, otherSlug)
        // Different vault key → different id (per-user opacity).
        XCTAssertNotEqual(first, otherVault)
        // Opaque shape: "pm_" + 32 lowercase hex — passes requiredIdentifier's
        // [a-z0-9_-] filter, and never echoes the plaintext slug.
        XCTAssertNotNil(first.range(of: "^pm_[a-f0-9]{32}$", options: .regularExpression))
        XCTAssertFalse(first.contains(slug))

        // Independent recomputation of the documented recipe:
        // HKDF<SHA256>(key, salt "OpenBurnBar-DocID-Salt-v1",
        //   info "OpenBurnBar-ProjectMemory-DocID-v1", 32B) → HMAC<SHA256>(slug).prefix16.hex
        let docKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: key),
            salt: Data("OpenBurnBar-DocID-Salt-v1".utf8),
            info: Data("OpenBurnBar-ProjectMemory-DocID-v1".utf8),
            outputByteCount: 32
        )
        let mac = HMAC<SHA256>.authenticationCode(for: Data(slug.utf8), using: docKey)
        let expected = "pm_" + Data(mac).prefix(16).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(first, expected)
    }

    func test_pensieveDedupHash_isVaultKeyedDeterministicAndNotPlaintextSHA256() throws {
        let keyA = Data(repeating: 0xA1, count: 32)
        let keyB = Data(repeating: 0xB2, count: 32)
        let plaintext = "deploy the daemon before midnight"

        let first = try CloudVaultCrypto.pensieveDedupHash(plaintext, keyData: keyA)
        let second = try CloudVaultCrypto.pensieveDedupHash(plaintext, keyData: keyA)
        let other = try CloudVaultCrypto.pensieveDedupHash(plaintext, keyData: keyB)

        // Deterministic per key; per-user keys diverge for identical plaintext.
        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, other)
        // Full HMAC-SHA256 digest (64 hex) — satisfies requireHexDigest.
        XCTAssertNotNil(first.range(of: "^[a-f0-9]{64}$", options: .regularExpression))
        // Never the keyless SHA-256 a curious server could guess (no dedup oracle).
        let plaintextSHA256 = SHA256.hash(data: Data(plaintext.utf8))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertNotEqual(first, plaintextSHA256)

        // Parity with the server test's derivation (knowledgeMemoryDedupHash.test.ts):
        // HKDF<SHA256>(key, salt ∅, info "pensieve-dedup:content", 32B) → HMAC<SHA256>(plaintext).
        let dedupKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: keyA),
            salt: Data(),
            info: Data("pensieve-dedup:content".utf8),
            outputByteCount: 32
        )
        let mac = HMAC<SHA256>.authenticationCode(for: Data(plaintext.utf8), using: dedupKey)
        let expected = Data(mac).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(first, expected)
    }

    func test_pensieveSlugHmac_isVaultKeyedDeterministicAndDistinctFromDedupHash() throws {
        let key = Data(repeating: 0xC3, count: 32)
        let slug = "burnbar-docs-secret-runbook"

        let first = try CloudVaultCrypto.pensieveSlugHmac(slug, keyData: key)
        let second = try CloudVaultCrypto.pensieveSlugHmac(slug, keyData: key)
        let otherSlug = try CloudVaultCrypto.pensieveSlugHmac("notes-security-md", keyData: key)
        let otherKey = try CloudVaultCrypto.pensieveSlugHmac(slug, keyData: Data(repeating: 0xD4, count: 32))

        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, otherSlug)
        XCTAssertNotEqual(first, otherKey)
        XCTAssertNotNil(first.range(of: "^[a-f0-9]{64}$", options: .regularExpression))
        XCTAssertFalse(first.contains(slug))

        // The slug info label differs from content, so the same input under the
        // same key must not collide across the two trapdoors (domain separation).
        let asContent = try CloudVaultCrypto.pensieveDedupHash(slug, keyData: key)
        XCTAssertNotEqual(first, asContent)

        // Parity: HKDF<SHA256>(key, salt ∅, info "pensieve-dedup:slug", 32B) → HMAC<SHA256>(slug).
        let slugKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: key),
            salt: Data(),
            info: Data("pensieve-dedup:slug".utf8),
            outputByteCount: 32
        )
        let mac = HMAC<SHA256>.authenticationCode(for: Data(slug.utf8), using: slugKey)
        let expected = Data(mac).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(first, expected)
    }

    func test_wrappedVaultKeyRoundTrip_unwrapsAcrossGeneratedDeviceKeys() throws {
        let recipient = P256.KeyAgreement.PrivateKey()
        let vaultKey = Data((0..<32).map(UInt8.init))

        let wrapped = try CloudVaultCrypto.wrapVaultKey(
            vaultKey,
            recipientPublicKey: recipient.publicKey.x963Representation
        )
        let unwrapped = try CloudVaultCrypto.unwrapVaultKey(wrapped, privateKey: recipient)

        XCTAssertEqual(unwrapped, vaultKey)
    }

    func test_recoveryWrappedVaultKeyRoundTrip_usesSymmetricRecoveryEnvelope() throws {
        let vaultKey = Data((0..<32).map(UInt8.init))
        let recoveryKey = try CloudVaultCrypto.generateRecoveryKey()

        let wrapped = try CloudVaultCrypto.wrapVaultKeyWithRecovery(
            vaultKey: vaultKey,
            recoveryKey: recoveryKey
        )
        let unwrapped = try CloudVaultCrypto.unwrapVaultKeyWithRecovery(
            wrappedVaultKeyBase64: wrapped.wrappedVaultKeyBase64,
            recoveryKey: recoveryKey
        )

        XCTAssertEqual(unwrapped, vaultKey)
        XCTAssertEqual(wrapped.verificationHash, try CloudVaultCrypto.recoveryVerificationHash(for: recoveryKey))
        XCTAssertNotNil(wrapped.verificationHash.range(of: "^[a-f0-9]{64}$", options: .regularExpression))
    }
}
