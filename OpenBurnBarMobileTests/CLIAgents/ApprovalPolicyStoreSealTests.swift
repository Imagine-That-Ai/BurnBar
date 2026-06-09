import XCTest
import Foundation
import OpenBurnBarCore
@testable import OpenBurnBarMobile

/// Verifies the privacy-leak remediation for `users/{uid}/approval_policies`:
/// the iOS store (the only cloud writer) must SEAL the private text fields
/// (`displayLabel` / `targetProject` / `fileGlob`) into `CloudVaultSealedText`
/// envelopes and name the document with an OPAQUE keyed hash instead of the
/// cleartext class hash (which baked `glob=`/`project=` into the doc ID).
///
/// Matching stays entirely client-side, so the round-trip must preserve the
/// in-memory class hash and `ApprovalPolicy.matches(...)` behaviour.
@MainActor
final class ApprovalPolicyStoreSealTests: XCTestCase {

    private func samplePolicy() -> ApprovalPolicy {
        ApprovalPolicy(
            missionKind: "shell",
            toolName: "bash",
            fileGlob: "src/**",
            runtimeID: "codex",
            targetProject: "TopSecretProject",
            decision: .approve,
            displayLabel: "All shell commands for Codex on TopSecretProject",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: nil,
            matchCount: 3
        )
    }

    private let testUID = "approval-policy-test-user"

    // MARK: - encode seals private text, drops plaintext + cleartext id

    func test_encode_sealsPrivateText_writesNoPlaintextFieldsOrID() throws {
        let key = CloudVaultCrypto.generateVaultKey()
        let policy = samplePolicy()

        let docID = try ApprovalPolicyStore.opaqueCloudDocumentID(forClassHash: policy.id, vaultKey: key)
        let payload = try ApprovalPolicyStore.encode(policy, uid: testUID, documentID: docID, vaultKey: key)

        // Sealed envelopes present and well-formed (canonical CloudVaultSealedText).
        for field in ["sealedDisplayLabel", "sealedTargetProject", "sealedFileGlob"] {
            let envelope = try XCTUnwrap(payload[field] as? [String: Any], "missing \(field)")
            XCTAssertEqual(envelope["algorithm"] as? String, "AES-256-GCM")
            XCTAssertNotNil(envelope["keyVersion"])
            XCTAssertNotNil(envelope["nonce"])
            XCTAssertNotNil(envelope["ciphertext"])
            XCTAssertNotNil(envelope["tag"])
            XCTAssertEqual(envelope["schemaVersion"] as? Int, 2)
            XCTAssertEqual(
                envelope["aad"] as? String,
                "OpenBurnBar-CloudVault-aad-v2|\(testUID)|approval_policies|\(docID)|\(field)|2|\(field)"
            )
        }

        // No plaintext private text leaks, and the cleartext class-hash `id`
        // (which itself bakes glob=/project=) is gone from the document body.
        XCTAssertNil(payload["displayLabel"])
        XCTAssertNil(payload["targetProject"])
        XCTAssertNil(payload["fileGlob"])
        XCTAssertNil(payload["id"])

        // Opaque client-bucketing trapdoors are 32-hex.
        let projectKeyHash = try XCTUnwrap(payload["projectKeyHash"] as? String)
        let fileGlobHash = try XCTUnwrap(payload["fileGlobHash"] as? String)
        XCTAssertTrue(Self.isHex32(projectKeyHash), "projectKeyHash not 32-hex: \(projectKeyHash)")
        XCTAssertTrue(Self.isHex32(fileGlobHash), "fileGlobHash not 32-hex: \(fileGlobHash)")

        // No raw private substring survives anywhere in the serialized payload.
        let serialized = String(describing: payload)
        XCTAssertFalse(serialized.contains("TopSecretProject"))
        XCTAssertFalse(serialized.contains("All shell commands"))
        XCTAssertFalse(serialized.contains("glob=src"))
        XCTAssertFalse(serialized.contains("project=TopSecretProject"))

        // Non-private discriminators stay in clear for client matching.
        XCTAssertEqual(payload["decision"] as? String, "approve")
        XCTAssertEqual(payload["missionKind"] as? String, "shell")
        XCTAssertEqual(payload["toolName"] as? String, "bash")
        XCTAssertEqual(payload["runtimeID"] as? String, "codex")
        XCTAssertEqual(payload["matchCount"] as? Int, 3)
        XCTAssertEqual(payload["schemaVersion"] as? Int, 2)
    }

    // MARK: - opaque doc id is deterministic, opaque, collision-stable

    func test_opaqueDocumentID_isDeterministicOpaqueHex_andNotCleartext() throws {
        let key = CloudVaultCrypto.generateVaultKey()
        let policy = samplePolicy()

        let id1 = try ApprovalPolicyStore.opaqueCloudDocumentID(forClassHash: policy.id, vaultKey: key)
        let id2 = try ApprovalPolicyStore.opaqueCloudDocumentID(forClassHash: policy.id, vaultKey: key)

        // Deterministic for the same class + key (upsert idempotency).
        XCTAssertEqual(id1, id2)

        // Opaque shape: "ap_" + 32 hex, and it leaks none of the cleartext class.
        XCTAssertTrue(id1.hasPrefix("ap_"))
        XCTAssertTrue(Self.isHex32(String(id1.dropFirst(3))), "doc id suffix not 32-hex: \(id1)")
        XCTAssertFalse(id1.contains("glob="))
        XCTAssertFalse(id1.contains("project="))
        XCTAssertFalse(id1.contains("TopSecretProject"))
        XCTAssertFalse(id1.contains("src"))

        // The cleartext class-hash doc id (legacy scheme) differs — so the
        // migration delete path actually removes the leaky document.
        XCTAssertNotEqual(id1, ApprovalPolicyStore.legacyCleartextDocumentID(policy.id))
    }

    func test_opaqueDocumentID_distinctClassesDoNotCollide() throws {
        // Two policies that differ ONLY in the private project name must map to
        // different opaque ids (guards against the multi-token splitter collapsing
        // the class hash to the hash of its first token).
        let key = CloudVaultCrypto.generateVaultKey()
        let a = ApprovalPolicy(
            missionKind: "shell", toolName: "bash", fileGlob: "src/**",
            runtimeID: "codex", targetProject: "ProjectAlpha",
            decision: .approve, displayLabel: "A"
        )
        let b = ApprovalPolicy(
            missionKind: "shell", toolName: "bash", fileGlob: "src/**",
            runtimeID: "codex", targetProject: "ProjectBravo",
            decision: .approve, displayLabel: "B"
        )

        let idA = try ApprovalPolicyStore.opaqueCloudDocumentID(forClassHash: a.id, vaultKey: key)
        let idB = try ApprovalPolicyStore.opaqueCloudDocumentID(forClassHash: b.id, vaultKey: key)
        XCTAssertNotEqual(idA, idB)
    }

    func test_opaqueDocumentID_differsAcrossVaultKeys() throws {
        let policy = samplePolicy()
        let id1 = try ApprovalPolicyStore.opaqueCloudDocumentID(forClassHash: policy.id, vaultKey: CloudVaultCrypto.generateVaultKey())
        let id2 = try ApprovalPolicyStore.opaqueCloudDocumentID(forClassHash: policy.id, vaultKey: CloudVaultCrypto.generateVaultKey())
        XCTAssertNotEqual(id1, id2)
    }

    // MARK: - decode round-trips and keeps the matcher working

    func test_encodeDecode_roundTrip_preservesClassHashAndMatching() throws {
        let key = CloudVaultCrypto.generateVaultKey()
        let policy = samplePolicy()
        let docID = try ApprovalPolicyStore.opaqueCloudDocumentID(forClassHash: policy.id, vaultKey: key)
        let payload = try ApprovalPolicyStore.encode(policy, uid: testUID, documentID: docID, vaultKey: key)

        let decoded = try XCTUnwrap(
            ApprovalPolicyStore.decode(documentID: docID, data: payload, vaultKey: key, uid: testUID)
        )

        // Private fields are recovered.
        XCTAssertEqual(decoded.displayLabel, policy.displayLabel)
        XCTAssertEqual(decoded.targetProject, policy.targetProject)
        XCTAssertEqual(decoded.fileGlob, policy.fileGlob)
        XCTAssertEqual(decoded.missionKind, policy.missionKind)
        XCTAssertEqual(decoded.toolName, policy.toolName)
        XCTAssertEqual(decoded.runtimeID, policy.runtimeID)
        XCTAssertEqual(decoded.decision, policy.decision)
        XCTAssertEqual(decoded.matchCount, policy.matchCount)

        // The in-memory class hash is recomputed identically (matching unchanged).
        XCTAssertEqual(decoded.id, policy.id)

        // The matcher still resolves the same ask after a seal -> open round-trip.
        XCTAssertTrue(decoded.matches(
            missionKind: "shell", toolName: "bash",
            filePath: "src/app/main.swift", runtimeID: "codex",
            targetProject: "TopSecretProject"
        ))
        XCTAssertFalse(decoded.matches(
            missionKind: "shell", toolName: "bash",
            filePath: "src/app/main.swift", runtimeID: "codex",
            targetProject: "OtherProject"
        ))
        XCTAssertNil(
            ApprovalPolicyStore.decode(documentID: "ap_wrong_document", data: payload, vaultKey: key, uid: testUID),
            "v2 sealed approval policies must be bound to the Firestore document ID via AAD"
        )
    }

    // MARK: - legacy plaintext fallback

    func test_decode_legacyPlaintextDocument_stillDecodes() throws {
        // A pre-migration document carrying the old plaintext fields (and no
        // sealed envelopes) must still render — LEGACY fallback.
        let legacy: [String: Any] = [
            "id": "decision=approve|mk=shell|tool=bash|glob=src/**|runtime=codex|project=LegacyProj",
            "displayLabel": "Legacy label",
            "decision": "approve",
            "missionKind": "shell",
            "toolName": "bash",
            "fileGlob": "src/**",
            "runtimeID": "codex",
            "targetProject": "LegacyProj",
            "createdAt": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_700_000_000)),
            "matchCount": 7,
            "schemaVersion": 1
        ]

        // Decodes with a key (sealed fields absent -> legacy path).
        let withKey = try XCTUnwrap(
            ApprovalPolicyStore.decode(documentID: "legacy", data: legacy, vaultKey: CloudVaultCrypto.generateVaultKey())
        )
        XCTAssertEqual(withKey.displayLabel, "Legacy label")
        XCTAssertEqual(withKey.targetProject, "LegacyProj")
        XCTAssertEqual(withKey.fileGlob, "src/**")
        XCTAssertEqual(withKey.matchCount, 7)

        // And without any key on this device (still legacy plaintext).
        let noKey = try XCTUnwrap(
            ApprovalPolicyStore.decode(documentID: "legacy", data: legacy, vaultKey: nil)
        )
        XCTAssertEqual(noKey.displayLabel, "Legacy label")
        XCTAssertEqual(noKey.targetProject, "LegacyProj")
    }

    // MARK: - sealed but no key -> hidden, never a leak

    func test_decode_sealedFields_withoutKey_doNotLeak() throws {
        let key = CloudVaultCrypto.generateVaultKey()
        let policy = samplePolicy()
        let docID = try ApprovalPolicyStore.opaqueCloudDocumentID(forClassHash: policy.id, vaultKey: key)
        let payload = try ApprovalPolicyStore.encode(policy, uid: testUID, documentID: docID, vaultKey: key)

        // No key on this device: displayLabel is required, so the whole record
        // is dropped rather than surfacing any plaintext (there is none to leak).
        let decoded = ApprovalPolicyStore.decode(documentID: docID, data: payload, vaultKey: nil, uid: testUID)
        XCTAssertNil(decoded)
    }

    func test_decode_sealedFields_wrongKey_doNotLeak() throws {
        let writeKey = CloudVaultCrypto.generateVaultKey()
        let policy = samplePolicy()
        let docID = try ApprovalPolicyStore.opaqueCloudDocumentID(forClassHash: policy.id, vaultKey: writeKey)
        let payload = try ApprovalPolicyStore.encode(policy, uid: testUID, documentID: docID, vaultKey: writeKey)

        // A different vault key cannot open the envelopes -> sealed fields resolve
        // to nil; the required displayLabel is unreadable so the record is dropped.
        let decoded = ApprovalPolicyStore.decode(documentID: docID, data: payload, vaultKey: CloudVaultCrypto.generateVaultKey(), uid: testUID)
        XCTAssertNil(decoded)
    }

    // MARK: - Helpers

    private static func isHex32(_ s: String) -> Bool {
        s.count == 32 && s.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil
    }
}
