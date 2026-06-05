import XCTest
import Foundation
import OpenBurnBarCore
import OpenBurnBarSignalCore
@testable import OpenBurnBarMobile

/// Verifies the privacy-leak remediation for the iOS mission write regressions:
/// `cancelMission` and `mergeMissionGroup` must SEAL their private summaries
/// into `sealedStatePayload` rather than writing plaintext `liveSummary` /
/// `synthesisSummary` top-level. The seal shape mirrors the already-correct
/// Android dispatcher (`sealedMissionStateUpdate` / `sealGroupPayload`).
@MainActor
final class CLIAgentMissionDispatcherSealTests: XCTestCase {

    // MARK: - cancelMission

    func test_cancelMissionUpdate_sealsSummary_writesNoPlaintextLiveSummary() throws {
        let key = CloudVaultCrypto.generateVaultKey()
        let vaultKeyID = try CloudVaultCrypto.vaultKeyID(for: key)

        let update = try CLIAgentMissionDispatcher.cancelMissionUpdate(
            vaultKey: key,
            vaultKeyID: vaultKeyID
        )

        // Status flips to cancelled and the seal triplet is present.
        XCTAssertEqual(update["status"] as? String, "cancelled")
        XCTAssertEqual(update["contentSealed"] as? Bool, true)
        XCTAssertEqual(update["sealedStateSchemaVersion"] as? Int, 1)
        XCTAssertEqual(update["sealedStateVaultKeyID"] as? String, vaultKeyID)
        XCTAssertNotNil(update["sealedStatePayload"])

        // Critically: NO plaintext private text leaks top-level.
        XCTAssertNil(update["liveSummary"])
        XCTAssertNil(update["resultPreview"])
        XCTAssertNil(update["errorMessage"])

        // The diff keys exactly match the validMobileMissionCancel() allowlist.
        let allowed: Set<String> = [
            "status", "contentSealed", "sealedStatePayload",
            "sealedStateSchemaVersion", "sealedStateVaultKeyID", "updatedAt"
        ]
        XCTAssertTrue(Set(update.keys).isSubset(of: allowed), "Unexpected keys: \(Set(update.keys).subtracting(allowed))")

        // Round-trips through the snapshot reader back to the cancel summary.
        var doc: [String: Any] = [
            "title": "Cancelled mission",
            "requestedRuntime": "codex"
        ]
        for (k, v) in update { doc[k] = v }
        let snapshot = try XCTUnwrap(
            CLIAgentMissionSnapshot(documentID: "req-1", data: doc, vaultKey: key)
        )
        XCTAssertEqual(snapshot.status, "cancelled")
        XCTAssertEqual(snapshot.liveSummary, "Mission cancelled by user.")
    }

    func test_cancelMissionUpdate_summaryUnreadableWithoutKey() throws {
        let key = CloudVaultCrypto.generateVaultKey()
        let vaultKeyID = try CloudVaultCrypto.vaultKeyID(for: key)
        let update = try CLIAgentMissionDispatcher.cancelMissionUpdate(vaultKey: key, vaultKeyID: vaultKeyID)

        var doc: [String: Any] = ["title": "Cancelled mission", "requestedRuntime": "codex"]
        for (k, v) in update { doc[k] = v }

        // Without the vault key the private summary stays sealed (legacy
        // fallback finds no plaintext liveSummary).
        let snapshot = try XCTUnwrap(
            CLIAgentMissionSnapshot(documentID: "req-1", data: doc, vaultKey: nil)
        )
        XCTAssertEqual(snapshot.status, "cancelled")
        XCTAssertNil(snapshot.liveSummary)
    }

    func test_missionSnapshotFallsBackToLegacySealedPayloadWhenOptionalSignalEnvelopeCannotOpen() throws {
        let key = CloudVaultCrypto.generateVaultKey()
        let vaultKeyID = try CloudVaultCrypto.vaultKeyID(for: key)
        var doc = try CLIAgentMissionRequestPayloadFactory.buildSealed(
            id: "mission-fallback",
            title: "Fallback mission",
            prompt: "Investigate the sealed rollout.",
            missionKind: "chat",
            requestedRuntime: "codex",
            targetProject: "BurnBar",
            depth: "standard",
            approvalMode: "existing_policy",
            commandsAllowed: false,
            fileEditsAllowed: false,
            vaultKey: key,
            vaultKeyID: vaultKeyID
        )
        doc["signalEnvelope"] = [
            "signalEnvelopeFormatVersion": 1,
            "mode": "at-rest",
            "plaintext": "not a valid Signal envelope"
        ]

        let snapshot = try XCTUnwrap(
            CLIAgentMissionSnapshot(
                documentID: "mission-fallback",
                data: doc,
                vaultKey: key,
                signalIdentity: nil,
                uid: "mission-user-\(UUID().uuidString)"
            )
        )
        XCTAssertEqual(snapshot.title, "Fallback mission")
        XCTAssertEqual(snapshot.targetProject, "BurnBar")
        XCTAssertEqual(snapshot.liveSummary, "Chat queued from this device. Waiting for the signed-in Mac agent listener to claim it.")
    }

    func test_missionSnapshotOpensPathBoundSignalEnvelopeAndRejectsRelocation() throws {
        let uid = "mission-signal-user-\(UUID().uuidString)"
        let documentID = "mission-signal"
        let identity = try OpenBurnBarSignalIdentityKeyStore(
            service: "com.openburnbar.tests.cli-signal-\(UUID().uuidString)"
        ).loadOrCreate(uid: uid, deviceId: "device-1")
        let privatePayload = Data("""
        {
          "title": "Signal mission",
          "targetProject": "BurnBar",
          "liveSummary": "Opened from Signal"
        }
        """.utf8)
        let binding = CloudVaultSignalBinding(
            uid: uid,
            collection: "cli_agent_mission_requests",
            docId: documentID,
            field: "signalEnvelope"
        )
        let envelope = try OpenBurnBarSignalAtRest.sealPayload(
            privatePayload,
            recipients: [identity.atRestRecipient()],
            binding: binding
        )
        let doc: [String: Any] = [
            "id": documentID,
            "status": "queued",
            "requestedRuntime": "codex",
            "contentSealed": true,
            "signalEnvelope": try CloudVaultCrypto.signalEnvelopeDictionary(envelope)
        ]

        let snapshot = try XCTUnwrap(
            CLIAgentMissionSnapshot(
                documentID: documentID,
                data: doc,
                vaultKey: nil,
                signalIdentity: identity,
                uid: uid
            )
        )
        XCTAssertEqual(snapshot.title, "Signal mission")
        XCTAssertEqual(snapshot.targetProject, "BurnBar")
        XCTAssertEqual(snapshot.liveSummary, "Opened from Signal")

        XCTAssertNil(
            CLIAgentMissionSnapshot(
                documentID: "mission-relocated",
                data: doc,
                vaultKey: nil,
                signalIdentity: identity,
                uid: uid
            ),
            "CLI mission Signal envelopes must fail closed when moved to another Firestore document."
        )
    }

    // MARK: - mergeMissionGroup

    func test_mergeMissionGroupUpdate_withoutSynthesis_isPlaintextSafe() {
        let update = CLIAgentMissionDispatcher.mergeMissionGroupUpdate(winnerMissionID: "child-2")
        XCTAssertEqual(update["phase"] as? String, MissionGroupPhase.merged.rawValue)
        XCTAssertEqual(update["winnerMissionID"] as? String, "child-2")
        // No synthesis => no seal fields and no plaintext synthesisSummary.
        XCTAssertNil(update["synthesisSummary"])
        XCTAssertNil(update["sealedStatePayload"])
        XCTAssertNil(update["contentSealed"])
    }

    func test_mergeMissionGroupUpdate_sealsSynthesis_writesNoPlaintext() throws {
        let key = CloudVaultCrypto.generateVaultKey()
        let vaultKeyID = try CloudVaultCrypto.vaultKeyID(for: key)

        let update = try CLIAgentMissionDispatcher.mergeMissionGroupUpdate(
            winnerMissionID: "child-1",
            synthesisSummary: "Codex won; merged final answer.",
            vaultKey: key,
            vaultKeyID: vaultKeyID
        )

        XCTAssertEqual(update["phase"] as? String, MissionGroupPhase.merged.rawValue)
        XCTAssertEqual(update["winnerMissionID"] as? String, "child-1")
        XCTAssertEqual(update["contentSealed"] as? Bool, true)
        XCTAssertEqual(update["sealedStateSchemaVersion"] as? Int, 1)
        XCTAssertEqual(update["sealedStateVaultKeyID"] as? String, vaultKeyID)
        XCTAssertNotNil(update["sealedStatePayload"])

        // No plaintext synthesis leaks top-level (validMissionGroup rejects it).
        XCTAssertNil(update["synthesisSummary"])

        // The reader opens sealedStatePayload for synthesisSummary.
        var doc = try Self.baseSealedMissionGroupDocument(vaultKey: key, vaultKeyID: vaultKeyID)
        for (k, v) in update { doc[k] = v }
        let group = try XCTUnwrap(
            MissionGroupDocument(documentID: "grp-1", data: doc, vaultKey: key)
        )
        XCTAssertEqual(group.phase, .merged)
        XCTAssertEqual(group.winnerMissionID, "child-1")
        XCTAssertEqual(group.synthesisSummary, "Codex won; merged final answer.")
    }

    func test_mergeMissionGroupUpdate_synthesisUnreadableWithoutKey() throws {
        let key = CloudVaultCrypto.generateVaultKey()
        let vaultKeyID = try CloudVaultCrypto.vaultKeyID(for: key)
        let update = try CLIAgentMissionDispatcher.mergeMissionGroupUpdate(
            winnerMissionID: nil,
            synthesisSummary: "Secret synthesis.",
            vaultKey: key,
            vaultKeyID: vaultKeyID
        )

        var doc = try Self.baseSealedMissionGroupDocument(vaultKey: key, vaultKeyID: vaultKeyID)
        for (k, v) in update { doc[k] = v }
        let group = try XCTUnwrap(
            MissionGroupDocument(documentID: "grp-1", data: doc, vaultKey: nil)
        )
        XCTAssertEqual(group.phase, .merged)
        // Sealed-only synthesis stays hidden without the vault key.
        XCTAssertNil(group.synthesisSummary)
    }

    // MARK: - Helpers

    /// A realistic sealed mission_groups request document — title/prompt/
    /// targetProject live inside `sealedPayload`, mirroring production
    /// (`CLIAgentMissionRequestPayloadFactory.sealGroupPayload`). The merge
    /// update is merged onto this so the `MissionGroupDocument` decoder accepts
    /// it exactly as it would post-`setData(merge:true)`.
    private static func baseSealedMissionGroupDocument(
        vaultKey: Data,
        vaultKeyID: String
    ) throws -> [String: Any] {
        let base: [String: Any] = [
            "id": "grp-1",
            "missionKind": "diligence",
            "childMissionIDs": ["child-1", "child-2"],
            "runtimeTokens": ["codex", "claude"],
            "parallelismLimit": 2,
            "mergeStrategy": "pick_one",
            "phase": MissionGroupPhase.awaitingMerge.rawValue,
            "createdAt": "2026-06-02T12:00:00Z",
            "updatedAt": "2026-06-02T12:00:00Z",
            "schemaVersion": 1
        ]
        return try CLIAgentMissionRequestPayloadFactory.sealGroupPayload(
            base,
            title: "Fan-out mission",
            prompt: "Investigate the spike.",
            targetProject: "BurnBar",
            vaultKey: vaultKey,
            vaultKeyID: vaultKeyID
        )
    }
}
