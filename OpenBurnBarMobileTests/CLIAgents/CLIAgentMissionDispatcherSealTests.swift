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
        let key = try CloudVaultCrypto.generateVaultKey()
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
        let key = try CloudVaultCrypto.generateVaultKey()
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
        let key = try CloudVaultCrypto.generateVaultKey()
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

    func test_missionSnapshotOpensPathBoundLegacyPayloadAndRejectsRelocation() throws {
        let uid = "mission-legacy-user-\(UUID().uuidString)"
        let documentID = "mission-legacy-bound"
        let key = try CloudVaultCrypto.generateVaultKey()
        let vaultKeyID = try CloudVaultCrypto.vaultKeyID(for: key)
        let doc = try CLIAgentMissionRequestPayloadFactory.buildSealed(
            id: documentID,
            title: "Bound legacy mission",
            prompt: "Verify AAD.",
            missionKind: "chat",
            requestedRuntime: "codex",
            targetProject: "BurnBar",
            depth: "standard",
            approvalMode: "existing_policy",
            commandsAllowed: false,
            fileEditsAllowed: false,
            uid: uid,
            vaultKey: key,
            vaultKeyID: vaultKeyID
        )

        let snapshot = try XCTUnwrap(
            CLIAgentMissionSnapshot(
                documentID: documentID,
                data: doc,
                vaultKey: key,
                uid: uid
            )
        )
        XCTAssertEqual(snapshot.title, "Bound legacy mission")
        XCTAssertEqual(snapshot.targetProject, "BurnBar")

        XCTAssertNil(
            CLIAgentMissionSnapshot(
                documentID: "mission-legacy-relocated",
                data: doc,
                vaultKey: key,
                uid: uid
            ),
            "CLI mission legacy CloudVault payloads must fail closed when moved to another Firestore document."
        )
    }

    func test_missionSnapshotOpensPathBoundSignalEnvelopeAndRejectsRelocation() throws {
        let uid = "mission-signal-user-\(UUID().uuidString)"
        let documentID = "mission-signal"
        let identity = OpenBurnBarSignalIdentityKeypair.generateInMemory(deviceId: "device-1")
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
            binding: binding,
            senderIdentityKeyId: identity.identityKeyId,
            senderIdentityPrivateKey: identity.privateKeyData
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
        let key = try CloudVaultCrypto.generateVaultKey()
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
        let key = try CloudVaultCrypto.generateVaultKey()
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

    func test_missionGroupSynthesisDraft_isReadOnlyHermesAndCarriesChildResults() throws {
        let group = Self.baseMissionGroupDocument()
        let snapshots = [
            "child-1": try Self.childSnapshot(
                id: "child-1",
                title: "Codex result",
                requestedRuntime: "codex",
                runtimeName: "Codex",
                resultPreview: "Codex found the group merge path records intent but never starts a second-stage mission.",
                eventMessage: "Validated the iOS dispatch path and Mac listener schema."
            ),
            "child-2": try Self.childSnapshot(
                id: "child-2",
                title: "Claude result",
                requestedRuntime: "claude",
                runtimeName: "Claude Code",
                resultPreview: "Claude flagged that synthesis must stay read-only and pass through cli_agent_mission_requests.",
                eventMessage: "Checked approval and sealed payload boundaries."
            )
        ]

        let draft = CLIAgentMissionDispatcher.missionGroupSynthesisDraft(
            group: group,
            childSnapshots: snapshots
        )

        XCTAssertEqual(draft.title, "Synthesize Audit fan-out")
        XCTAssertEqual(draft.missionKind, "synthesizer")
        XCTAssertEqual(draft.requestedRuntime, "hermes")
        XCTAssertEqual(draft.approvalMode, "read_only")
        XCTAssertFalse(draft.commandsAllowed)
        XCTAssertFalse(draft.fileEditsAllowed)
        XCTAssertEqual(draft.sourceSurface, "ios-hermes-square")
        XCTAssertEqual(draft.deliveryMode, .fullStream)
        XCTAssertEqual(draft.targetProject, "BurnBar")
        XCTAssertTrue(draft.prompt.contains("Use only the supplied child outputs"))
        XCTAssertTrue(draft.prompt.contains("Original prompt:"))
        XCTAssertTrue(draft.prompt.contains("Audit mission group synthesis."))
        XCTAssertTrue(draft.prompt.contains("Codex found the group merge path"))
        XCTAssertTrue(draft.prompt.contains("Claude flagged that synthesis must stay read-only"))
    }

    func test_missionGroupSynthesisDraft_buildsStandardSealedMissionRequest() throws {
        let group = Self.baseMissionGroupDocument()
        let snapshots = [
            "child-1": try Self.childSnapshot(
                id: "child-1",
                title: "Codex result",
                requestedRuntime: "codex",
                runtimeName: "Codex",
                resultPreview: "Codex result.",
                eventMessage: "Codex completed."
            )
        ]
        let draft = CLIAgentMissionDispatcher.missionGroupSynthesisDraft(
            group: group,
            childSnapshots: snapshots
        )
        let key = try CloudVaultCrypto.generateVaultKey()
        let vaultKeyID = try CloudVaultCrypto.vaultKeyID(for: key)

        let payload = try CLIAgentMissionRequestPayloadFactory.buildSealed(
            id: "synth-1",
            title: draft.title,
            prompt: draft.prompt,
            missionKind: draft.missionKind,
            requestedRuntime: draft.requestedRuntime,
            targetProject: draft.targetProject,
            depth: draft.depth,
            approvalMode: draft.approvalMode,
            commandsAllowed: draft.commandsAllowed,
            fileEditsAllowed: draft.fileEditsAllowed,
            sourceSurface: draft.sourceSurface,
            deliveryMode: draft.deliveryMode,
            vaultKey: key,
            vaultKeyID: vaultKeyID
        )

        XCTAssertEqual(payload["id"] as? String, "synth-1")
        XCTAssertEqual(payload["missionKind"] as? String, "synthesizer")
        XCTAssertEqual(payload["requestedRuntime"] as? String, "hermes")
        XCTAssertEqual(payload["depth"] as? String, "standard")
        XCTAssertEqual(payload["approvalMode"] as? String, "read_only")
        XCTAssertEqual(payload["commandsAllowed"] as? Bool, false)
        XCTAssertEqual(payload["fileEditsAllowed"] as? Bool, false)
        XCTAssertEqual(payload["source"] as? String, "ios-insights")
        XCTAssertEqual(payload["sourceSurface"] as? String, "ios-hermes-square")
        XCTAssertEqual(payload["deliveryMode"] as? String, "full_stream")
        XCTAssertNil(payload["title"])
        XCTAssertNil(payload["prompt"])
        XCTAssertNil(payload["targetProject"])
        XCTAssertNil(payload["groupID"])
        XCTAssertEqual(payload["contentSealed"] as? Bool, true)
        XCTAssertEqual(payload["sealedSchemaVersion"] as? Int, 2)
        XCTAssertEqual(payload["vaultKeyID"] as? String, vaultKeyID)

        let snapshot = try XCTUnwrap(
            CLIAgentMissionSnapshot(documentID: "synth-1", data: payload, vaultKey: key)
        )
        XCTAssertEqual(snapshot.title, draft.title)
        XCTAssertEqual(snapshot.requestedRuntime, "hermes")
        XCTAssertEqual(snapshot.targetProject, "BurnBar")
        XCTAssertEqual(snapshot.deliveryMode, .fullStream)
        XCTAssertEqual(snapshot.liveSummary, "Mission queued from this device. Waiting for the signed-in Mac agent listener to claim it.")
    }

    // MARK: - Helpers

    private static func baseMissionGroupDocument() -> MissionGroupDocument {
        MissionGroupDocument(
            id: "grp-1",
            title: "Audit fan-out",
            prompt: "Audit mission group synthesis.",
            missionKind: "diligence",
            targetProject: "BurnBar",
            childMissionIDs: ["child-1", "child-2"],
            runtimeTokens: ["codex", "claude"],
            parallelismLimit: 2,
            mergeStrategy: .synthesize,
            phase: .awaitingMerge,
            createdAt: ISO8601DateFormatter().date(from: "2026-06-02T12:00:00Z")!,
            updatedAt: ISO8601DateFormatter().date(from: "2026-06-02T12:05:00Z")!
        )
    }

    private static func childSnapshot(
        id: String,
        title: String,
        requestedRuntime: String,
        runtimeName: String,
        resultPreview: String,
        eventMessage: String
    ) throws -> CLIAgentMissionSnapshot {
        try XCTUnwrap(
            CLIAgentMissionSnapshot(
                documentID: id,
                data: [
                    "id": id,
                    "title": title,
                    "status": "completed",
                    "requestedRuntime": requestedRuntime,
                    "selectedRuntime": requestedRuntime,
                    "selectedRuntimeName": runtimeName,
                    "targetProject": "BurnBar",
                    "liveSummary": "\(runtimeName) returned a result.",
                    "resultPreview": resultPreview,
                    "createdAt": "2026-06-02T12:01:00Z",
                    "events": [
                        [
                            "sequence": 1,
                            "timestamp": "2026-06-02T12:02:00Z",
                            "kind": "final_answer",
                            "phase": "completed",
                            "title": "Completed",
                            "message": eventMessage,
                            "isError": false
                        ]
                    ]
                ]
            )
        )
    }

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
