import CryptoKit
import Foundation
import XCTest
@testable import OpenBurnBarCore
@testable import OpenBurnBarKernel

final class CloudVaultCryptoTests: XCTestCase {
    func test_generateVaultKeyThrowsWhenSystemRandomFails() {
        let original = CloudVaultCrypto.secureRandomCopyBytes
        CloudVaultCrypto.secureRandomCopyBytes = { _, _, _ in errSecNotAvailable }
        defer { CloudVaultCrypto.secureRandomCopyBytes = original }

        XCTAssertThrowsError(try CloudVaultCrypto.generateVaultKey()) { error in
            guard case CloudVaultCryptoError.keychainError(let status) = error else {
                return XCTFail("Expected keychainError, got \(error)")
            }
            XCTAssertEqual(status, Int(errSecNotAvailable))
        }
    }

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

    func test_openTextRejectsFutureSchemaBeforeDecrypting() throws {
        let key = Data(repeating: 0x42, count: 32)
        let context = try CloudVaultAADContext(
            uid: "user",
            collection: "session_logs",
            docID: "doc",
            field: "sealedTitle"
        )
        let sealed = try CloudVaultCrypto.sealText("future", keyData: key, aadContext: context)
        let future = CloudVaultSealedText(
            schemaVersion: CloudVaultCrypto.currentSealedTextSchemaVersion + 1,
            algorithm: sealed.algorithm,
            keyVersion: sealed.keyVersion,
            nonce: sealed.nonce,
            ciphertext: sealed.ciphertext,
            tag: sealed.tag,
            aad: sealed.aad
        )

        XCTAssertThrowsError(try CloudVaultCrypto.openText(future, keyData: key, aadContext: context)) { error in
            guard case CloudVaultCryptoError.invalidEnvelope = error else {
                return XCTFail("Expected invalidEnvelope, got \(error)")
            }
        }
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

    func test_roamingProfilePayloadRoundTripBindsUidAndDomainAAD() throws {
        let key = Data(repeating: 0x42, count: 32)
        let updatedAt = Date(timeIntervalSince1970: 1_780_111_222)
        let payload = RoamingProfilePayload(
            routerMode: .sameModelFailover,
            crossProviderFailoverEnabled: false,
            accountOrder: ["anthropic-primary"],
            providerAccounts: [
                RoamingProfileProviderAccount(
                    id: "anthropic-primary",
                    providerID: ProviderID(rawValue: "anthropic"),
                    label: "Claude Code",
                    identityHint: "user@example.com",
                    status: .connected,
                    credentialKind: .bearer,
                    storageScope: .deviceKeychain,
                    redactedLabel: "Stored in Mac Keychain",
                    sourceDeviceID: "mac-1",
                    isDefault: true,
                    sortKey: 0,
                    createdAt: updatedAt.addingTimeInterval(-60),
                    updatedAt: updatedAt
                )
            ],
            ollamaEndpoints: [
                RoamingOllamaEndpoint(id: "local", baseURL: "http://127.0.0.1:11434", label: "Local Ollama", priority: 1)
            ],
            equivalenceOverrides: [
                RoamingModelEquivalenceOverride(canonicalModelID: "gpt-5.5", action: .pin, classID: "frontier")
            ],
            quotaDisplayPreferences: RoamingQuotaDisplayPreferences(
                providerOrder: ["anthropic", "openai"],
                visibleProviders: ["anthropic"],
                hiddenBuckets: ["anthropic:daily"],
                bucketOrders: ["anthropic": ["5h", "weekly"]],
                percentageDisplayMode: "usedPercent",
                cumulativeAcrossAccounts: true
            ),
            updatedAt: updatedAt,
            sourceDeviceID: "mac-1"
        )

        let sealed = try CloudVaultCrypto.sealRoamingProfile(payload, keyData: key, uid: "alice")

        XCTAssertEqual(sealed.schemaVersion, CloudVaultCrypto.currentSealedPayloadSchemaVersion)
        XCTAssertEqual(sealed.aad, try CloudVaultCrypto.roamingProfileAADContext(uid: "alice").stringValue)
        XCTAssertEqual(sealed.aad?.contains(CloudVaultCrypto.roamingProfileAADDomain), true)
        XCTAssertEqual(try CloudVaultCrypto.openRoamingProfile(sealed, keyData: key, uid: "alice"), payload)
        XCTAssertThrowsError(try CloudVaultCrypto.openRoamingProfile(sealed, keyData: key, uid: "bob"))
    }

    func test_roamingProfilePayloadRejectsSecretLikeMaterialBeforeSealing() throws {
        let key = Data(repeating: 0x43, count: 32)
        let payload = RoamingProfilePayload(
            routerMode: .providerFamilyFailover,
            crossProviderFailoverEnabled: true,
            accountOrder: [],
            providerAccounts: [],
            ollamaEndpoints: [],
            equivalenceOverrides: [],
            quotaDisplayPreferences: RoamingQuotaDisplayPreferences(),
            updatedAt: Date(timeIntervalSince1970: 1_780_111_222),
            sourceDeviceID: "Bearer sk-this-should-not-roam-1234567890"
        )

        XCTAssertThrowsError(try CloudVaultCrypto.sealRoamingProfile(payload, keyData: key, uid: "alice")) { error in
            XCTAssertTrue(error is RoamingProfilePayloadError)
        }
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

    func test_rewrapCloudVaultDocument_resealsNestedMissionEventWithPathBoundAAD() throws {
        let oldKey = Data(repeating: 0x91, count: 32)
        let newKey = Data(repeating: 0x92, count: 32)
        let oldVaultKeyID = try CloudVaultCrypto.vaultKeyID(for: oldKey)
        let newVaultKeyID = try CloudVaultCrypto.vaultKeyID(for: newKey)
        let uid = "userA"
        let collection = "cli_agent_mission_requests/events"
        let docID = "requestA/000001"
        let eventContext = try CloudVaultAADContext(
            uid: uid,
            collection: collection,
            docID: docID,
            field: "sealedPayload"
        )
        let eventBody = Data("{\"message\":\"build is running\"}".utf8)
        let document: [String: Any] = [
            "contentSealed": true,
            "vaultKeyID": oldVaultKeyID,
            "sealedPayload": try CloudVaultCrypto.firestoreDictionary(
                CloudVaultCrypto.sealPayload(
                    eventBody,
                    keyData: oldKey,
                    vaultKeyID: oldVaultKeyID,
                    aadContext: eventContext
                )
            )
        ]

        let result = try CloudVaultCrypto.rewrapCloudVaultDocument(
            document,
            uid: uid,
            collection: collection,
            docID: docID,
            oldKeyData: oldKey,
            newKeyData: newKey,
            newVaultKeyID: newVaultKeyID,
            vaultGeneration: 8,
            rotationJobId: "job-8"
        )

        XCTAssertEqual(result.changedFields, ["sealedPayload"])
        XCTAssertEqual(result.data["vaultKeyID"] as? String, newVaultKeyID)
        XCTAssertEqual(result.data["vaultGeneration"] as? Int, 8)
        XCTAssertEqual(result.data["rewrapJobId"] as? String, "job-8")

        let envelope = try XCTUnwrap(CloudVaultCrypto.sealedPayload(from: result.data["sealedPayload"]))
        XCTAssertEqual(envelope.vaultKeyID, newVaultKeyID)
        XCTAssertEqual(envelope.aad, eventContext.stringValue)
        XCTAssertEqual(try CloudVaultCrypto.openPayload(envelope, keyData: newKey, aadContext: eventContext), eventBody)
        XCTAssertThrowsError(try CloudVaultCrypto.openPayload(envelope, keyData: oldKey, aadContext: eventContext))

        let topLevelContext = try CloudVaultAADContext(
            uid: uid,
            collection: "cli_agent_mission_requests",
            docID: "requestA",
            field: "sealedPayload"
        )
        XCTAssertThrowsError(try CloudVaultCrypto.openPayload(envelope, keyData: newKey, aadContext: topLevelContext))
    }

    func test_rewrapCloudVaultDocument_skipsMissionEventsAlreadyOnNewVaultKey() throws {
        let oldKey = Data(repeating: 0x91, count: 32)
        let newKey = Data(repeating: 0x92, count: 32)
        let newVaultKeyID = try CloudVaultCrypto.vaultKeyID(for: newKey)
        let uid = "userA"
        let collection = "cli_agent_mission_requests/events"
        let docID = "requestA/000002"
        let eventContext = try CloudVaultAADContext(
            uid: uid,
            collection: collection,
            docID: docID,
            field: "sealedPayload"
        )
        let sealed = try CloudVaultCrypto.sealPayload(
            Data("{\"message\":\"new event\"}".utf8),
            keyData: newKey,
            vaultKeyID: newVaultKeyID,
            aadContext: eventContext
        )
        let document: [String: Any] = [
            "contentSealed": true,
            "vaultKeyID": newVaultKeyID,
            "sealedPayload": try CloudVaultCrypto.firestoreDictionary(sealed)
        ]

        let result = try CloudVaultCrypto.rewrapCloudVaultDocument(
            document,
            uid: uid,
            collection: collection,
            docID: docID,
            oldKeyData: oldKey,
            newKeyData: newKey,
            newVaultKeyID: newVaultKeyID,
            vaultGeneration: 8,
            rotationJobId: "job-8"
        )

        XCTAssertTrue(result.changedFields.isEmpty)
        XCTAssertNil(result.data["vaultGeneration"])
        XCTAssertNil(result.data["rewrapJobId"])
        let envelope = try XCTUnwrap(CloudVaultCrypto.sealedPayload(from: result.data["sealedPayload"]))
        XCTAssertEqual(envelope.vaultKeyID, newVaultKeyID)
        XCTAssertEqual(try CloudVaultCrypto.openPayload(envelope, keyData: newKey, aadContext: eventContext), Data("{\"message\":\"new event\"}".utf8))
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

    /// A vault-key rotation must carry `users/{uid}/memory_facts` with it, or
    /// every synced memory (chat and agent-sourced alike) is stranded on the
    /// retired generation. `memory_facts` reaches the rewrap through the
    /// `pensieve` data domain's `document_envelopes` strategy; this pins the
    /// crypto half — the sealed body reseals under the path-bound AAD the
    /// Firestore rules validate, `(uid, "memory_facts", docID, "sealedMemory")`.
    func test_rewrapCloudVaultDocument_resealsMemoryFactSealedMemory() throws {
        let oldKey = Data(repeating: 0x51, count: 32)
        let newKey = Data(repeating: 0x52, count: 32)
        let newVaultKeyID = try CloudVaultCrypto.vaultKeyID(for: newKey)
        let uid = "userA"
        let docID = String(repeating: "a", count: 64)
        let context = try CloudVaultAADContext(
            uid: uid,
            collection: "memory_facts",
            docID: docID,
            field: "sealedMemory"
        )
        let body = Data(#"{"memoryID":"mem_1","text":"prefers ripgrep"}"#.utf8)

        let document: [String: Any] = [
            "uid": uid,
            "docID": docID,
            "schemaVersion": 1,
            "sourceKind": "agent",
            "kind": "decision",
            "reviewStatus": "approved",
            "citationCount": 0,
            "sealedMemory": try CloudVaultCrypto.firestoreDictionary(
                CloudVaultCrypto.sealBlob(body, keyData: oldKey, aadContext: context)
            )
        ]

        let result = try CloudVaultCrypto.rewrapCloudVaultDocument(
            document,
            uid: uid,
            collection: "memory_facts",
            docID: docID,
            oldKeyData: oldKey,
            newKeyData: newKey,
            newVaultKeyID: newVaultKeyID,
            vaultGeneration: 4,
            rotationJobId: "rotation-job-1"
        )

        XCTAssertEqual(result.changedFields, ["sealedMemory"])
        XCTAssertEqual(result.data["vaultGeneration"] as? Int, 4)
        XCTAssertEqual(result.data["rewrapJobId"] as? String, "rotation-job-1")
        // Plaintext metadata rides through untouched — the rules validate it.
        XCTAssertEqual(result.data["sourceKind"] as? String, "agent")
        XCTAssertEqual(result.data["kind"] as? String, "decision")

        let envelope = try XCTUnwrap(CloudVaultCrypto.decodeBlobEnvelope(from: result.data["sealedMemory"]))
        XCTAssertGreaterThanOrEqual(envelope.schemaVersion, 2)
        XCTAssertEqual(envelope.aad, context.stringValue)
        XCTAssertEqual(try CloudVaultCrypto.openBlob(envelope, keyData: newKey, aadContext: context), body)
        XCTAssertThrowsError(try CloudVaultCrypto.openBlob(envelope, keyData: oldKey, aadContext: context))
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

    func test_escrowPayloadRoundTrip_preservesAssociatedDataAndVariableLengthPayloads() throws {
        let recipient = P256.KeyAgreement.PrivateKey()
        let plaintext = Data("provider-secret-with-variable-length".utf8)
        let aad = Data("grant-id|device-id|provider-id".utf8)
        let wire = try CloudVaultCrypto.sealEscrowPayload(
            plaintext,
            recipientPublicKey: recipient.publicKey.x963Representation,
            authenticating: aad
        )
        XCTAssertEqual(
            try CloudVaultCrypto.openEscrowPayload(wire, privateKey: recipient, authenticating: aad),
            plaintext
        )
        XCTAssertThrowsError(
            try CloudVaultCrypto.openEscrowPayload(
                wire,
                privateKey: recipient,
                authenticating: Data("wrong-context".utf8)
            )
        )
    }

    func test_escrowPayloadRejectsMalformedP256KeysAndWire() throws {
        XCTAssertThrowsError(
            try CloudVaultCrypto.sealEscrowPayload(
                Data("secret".utf8),
                recipientPublicKey: Data(repeating: 0, count: 65)
            )
        ) { error in
            guard case CloudVaultCryptoError.invalidPublicKey = error else {
                return XCTFail("Expected invalidPublicKey, got \(error)")
            }
        }
        let recipient = P256.KeyAgreement.PrivateKey()
        XCTAssertThrowsError(
            try CloudVaultCrypto.openEscrowPayload(Data(repeating: 0, count: 92), privateKey: recipient)
        ) { error in
            guard case CloudVaultCryptoError.invalidEnvelope = error else {
                return XCTFail("Expected invalidEnvelope, got \(error)")
            }
        }
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

    // MARK: - T-CVS-06: enforced v1 (global) AAD cutover

    func test_v1AADRejectionFlag_defaultsOnAndOverridable() {
        // RR-8 cutover: legacy v1 AAD acceptance is closed by default, with an
        // explicit local rollback override for emergency recovery.
        XCTAssertTrue(CloudVaultV1AADRejectionFlag.defaultEnabled)

        let defaults = ephemeralDefaults()
        XCTAssertTrue(CloudVaultV1AADRejectionFlag.isEnabled(defaults: defaults))
        defaults.set(false, forKey: CloudVaultV1AADRejectionFlag.userDefaultsKey)
        XCTAssertFalse(CloudVaultV1AADRejectionFlag.isEnabled(defaults: defaults))
    }

    func test_aadResolution_acceptsV1WhenOff_rejectsV1WhenOn() throws {
        let context = try CloudVaultAADContext(
            uid: "userA",
            collection: "project_memory_snapshots",
            docID: "pm_fixture",
            field: "sealedSnapshot"
        )

        // v2 (full domain-separated) AAD is accepted regardless of the flag.
        XCTAssertEqual(
            try CloudVaultCrypto.resolveAADForTesting(
                envelopeAAD: context.stringValue,
                context: context,
                rejectLegacyV1: false
            ),
            context.data
        )
        XCTAssertEqual(
            try CloudVaultCrypto.resolveAADForTesting(
                envelopeAAD: context.stringValue,
                context: context,
                rejectLegacyV1: true
            ),
            context.data
        )

        // v1 (global) AAD is accepted pre-cutover (flag off)…
        XCTAssertEqual(
            try CloudVaultCrypto.resolveAADForTesting(
                envelopeAAD: context.legacyV1StringValue,
                context: context,
                rejectLegacyV1: false
            ),
            context.legacyV1Data
        )

        // …and refused post-cutover (flag on) so the weaker path is removed.
        XCTAssertThrowsError(
            try CloudVaultCrypto.resolveAADForTesting(
                envelopeAAD: context.legacyV1StringValue,
                context: context,
                rejectLegacyV1: true
            )
        ) { error in
            guard case CloudVaultCryptoError.invalidEnvelope = error else {
                return XCTFail("Expected invalidEnvelope rejecting v1 AAD, got \(error)")
            }
        }
    }

    func test_openBlob_v1AADEnvelope_opensWhenOff_rejectsWhenOn() throws {
        let key = Data(repeating: 0x73, count: 32)
        let body = Data("legacy v1-AAD sealed body".utf8)
        let context = try CloudVaultAADContext(
            uid: "userB",
            collection: "project_memory_snapshots",
            docID: "pm_v1_fixture",
            field: "sealedSnapshot"
        )
        let v1Envelope = try makeV1AADBlobEnvelope(body, keyData: key, context: context)

        // Pre-cutover (flag off): the v1 envelope still decrypts.
        let originalDefault = CloudVaultV1AADRejectionFlag.defaultEnabled
        CloudVaultV1AADRejectionFlag.defaultEnabled = false
        defer { CloudVaultV1AADRejectionFlag.defaultEnabled = originalDefault }
        XCTAssertEqual(
            try CloudVaultCrypto.openBlob(v1Envelope, keyData: key, aadContext: context),
            body
        )

        // Post-cutover (flag on): the same v1 envelope is refused (fail closed).
        CloudVaultV1AADRejectionFlag.defaultEnabled = true
        XCTAssertThrowsError(
            try CloudVaultCrypto.openBlob(v1Envelope, keyData: key, aadContext: context)
        ) { error in
            guard case CloudVaultCryptoError.invalidEnvelope = error else {
                return XCTFail("Expected invalidEnvelope rejecting v1 blob, got \(error)")
            }
        }
    }

    /// Seal a v2-schema blob that authenticates with the *legacy v1* AAD string,
    /// reproducing a pre-backfill at-rest record so the cutover gate can be
    /// exercised end-to-end through ``CloudVaultCrypto/openBlob``.
    private func makeV1AADBlobEnvelope(
        _ data: Data,
        keyData: Data,
        context: CloudVaultAADContext
    ) throws -> CloudVaultBlobEnvelope {
        let sealed = try AES.GCM.seal(
            data,
            using: SymmetricKey(data: keyData),
            authenticating: context.legacyV1Data
        )
        let combined = try XCTUnwrap(sealed.combined)
        return CloudVaultBlobEnvelope(
            keyVersion: CloudVaultCrypto.currentKeyVersion,
            plaintextHMAC: try CloudVaultCrypto.blobPlaintextHMAC(data, keyData: keyData),
            sealedBoxBase64: combined.base64EncodedString(),
            aad: context.legacyV1StringValue
        )
    }

    private func ephemeralDefaults() -> UserDefaults {
        let suite = "cloudvault.v1aad.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
