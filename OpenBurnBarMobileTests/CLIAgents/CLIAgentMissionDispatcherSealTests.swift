import XCTest
import Foundation
import OpenBurnBarComputerUseCore
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

    func test_requiredSignalProducerRejectsMissingEnvelope() {
        XCTAssertThrowsError(
            try MobileCloudVaultSignalPayloads.requireEnvelopeIfRequired(
                payload: ["sealedPayload": "legacy"],
                state: .required,
                domainID: "conversations_chat"
            )
        ) { error in
            guard case MobileCloudVaultSignalPayloadError.signalEnvelopeRequired(let domainID) = error else {
                return XCTFail("Expected signalEnvelopeRequired, got \(error)")
            }
            XCTAssertEqual(domainID, "conversations_chat")
        }
    }

    func test_requiredSignalProducerAcceptsSignalEnvelopeAndOptionalModeAllowsLegacy() throws {
        XCTAssertNoThrow(
            try MobileCloudVaultSignalPayloads.requireEnvelopeIfRequired(
                payload: ["signalEnvelope": ["relayKeyVersion": 4]],
                state: .required,
                domainID: "conversations_chat"
            )
        )
        XCTAssertNoThrow(
            try MobileCloudVaultSignalPayloads.requireEnvelopeIfRequired(
                payload: ["sealedPayload": "legacy"],
                state: .enabled,
                domainID: "conversations_chat"
            )
        )
    }

    func test_wandSelectionCanonicalizesExactRuntimeSetWithoutFallback() {
        XCTAssertEqual(
            FanOutComposerSheet.canonicalRuntimeTokens(["codex", "claude"]),
            ["claude", "codex"]
        )
        XCTAssertFalse(
            FanOutComposerSheet.canonicalRuntimeTokens(["codex", "claude"]).contains("junie")
        )
    }

    func test_directFirestoreMissionFactoryNeverAddsServerOnlySignalEnvelope() throws {
        let key = try CloudVaultCrypto.generateVaultKey()
        let vaultKeyID = try CloudVaultCrypto.vaultKeyID(for: key)
        let direct = try CLIAgentMissionRequestPayloadFactory.buildSealed(
            id: "wand-child-1",
            title: "Pareto child",
            prompt: "Return the marker.",
            missionKind: "parallel",
            requestedRuntime: "claude",
            targetProject: "BurnBar",
            depth: "standard",
            approvalMode: "existing_policy",
            commandsAllowed: false,
            fileEditsAllowed: false,
            uid: "user-1",
            vaultKey: key,
            vaultKeyID: vaultKeyID
        )

        XCTAssertNil(direct["signalEnvelope"])
        XCTAssertNotNil(direct["sealedPayload"])
        XCTAssertEqual(direct["id"] as? String, "wand-child-1")
    }

    func test_missionConsoleHostOpensSealedApprovalMissionFromListListenerPayload() throws {
        let uid = "mission-console-user"
        let documentID = "wand-child-approval"
        let key = try CloudVaultCrypto.generateVaultKey()
        let vaultKeyID = try CloudVaultCrypto.vaultKeyID(for: key)
        var document = try CLIAgentMissionRequestPayloadFactory.buildSealed(
            id: documentID,
            title: "Pareto Claude child",
            prompt: "Return the requested sales-ready marker.",
            missionKind: "parallel",
            requestedRuntime: "claude",
            targetProject: "BurnBar",
            depth: "standard",
            approvalMode: "existing_policy",
            commandsAllowed: false,
            fileEditsAllowed: false,
            uid: uid,
            vaultKey: key,
            vaultKeyID: vaultKeyID
        )
        document["status"] = "waiting_for_approval"
        document["approvalRequestId"] = "approval-wand-child"
        document["approvalStatus"] = "pending"

        XCTAssertNil(
            CLIAgentMissionSnapshot(documentID: documentID, data: document),
            "The production list payload is sealed, so plaintext-only decoding must fail."
        )

        let decoded = try XCTUnwrap(
            CLIAgentMissionSnapshot(
                documentID: documentID,
                data: document,
                vaultKey: key,
                uid: uid
            )
        )
        let host = MobileMissionConsoleHost()
        host.absorbMissionSnapshots(
            [decoded],
            documentCount: 1,
            hasResolvedKey: true
        )

        XCTAssertEqual(host.snapshot.activeTiles.map(\.id), [documentID])
        XCTAssertEqual(host.snapshot.activeTiles.first?.phase, .awaitingApproval)
        XCTAssertEqual(host.snapshot.approvalAsks.map(\.missionID), [documentID])
        XCTAssertEqual(host.snapshot.approvalAsks.first?.runtimeID, "claude")
        XCTAssertNil(host.inlineError)
    }

    // MARK: - cancelMission

    func test_cancelMissionUpdate_sealsSummary_writesNoPlaintextLiveSummary() throws {
        let key = try CloudVaultCrypto.generateVaultKey()
        let vaultKeyID = try CloudVaultCrypto.vaultKeyID(for: key)

        let update = try CLIAgentMissionDispatcher.cancelMissionUpdate(
            uid: "uid-1",
            requestID: "req-cancel",
            vaultKey: key,
            vaultKeyID: vaultKeyID
        )

        // Status flips to cancelled and the seal triplet is present.
        XCTAssertEqual(update["status"] as? String, "cancelled")
        XCTAssertEqual(update["contentSealed"] as? Bool, true)
        XCTAssertEqual(update["sealedStateSchemaVersion"] as? Int, 1)
        XCTAssertEqual(update["sealedStateVaultKeyID"] as? String, vaultKeyID)
        XCTAssertNotNil(update["sealedStatePayload"])
        let sealedState = try XCTUnwrap(update["sealedStatePayload"] as? [String: Any])
        let expectedAAD = try CLIAgentMissionCloudSealer.missionAADContext(
            uid: "uid-1",
            documentID: "req-cancel",
            field: "sealedStatePayload"
        )
        XCTAssertEqual(sealedState["aad"] as? String, expectedAAD.stringValue)

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
        XCTAssertEqual(draft.queuedEventSource, "ios")
        XCTAssertEqual(draft.deliveryMode, .fullStream)
        XCTAssertEqual(draft.targetProject, "BurnBar")
        XCTAssertTrue(draft.prompt.contains("Use only the supplied child outputs"))
        XCTAssertTrue(draft.prompt.contains("Original prompt:"))
        XCTAssertTrue(draft.prompt.contains("Audit mission group synthesis."))
        XCTAssertTrue(draft.prompt.contains("Validated the iOS dispatch path"))
        XCTAssertTrue(draft.prompt.contains("Checked approval and sealed payload boundaries"))
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

    func test_missionGroupSynthesisDraft_usesEventAllowedQueuedSource() throws {
        let draft = CLIAgentMissionDispatcher.missionGroupSynthesisDraft(
            group: Self.baseMissionGroupDocument(),
            childSnapshots: [
                "child-1": try Self.childSnapshot(
                    id: "child-1",
                    title: "Codex result",
                    requestedRuntime: "codex",
                    runtimeName: "Codex",
                    resultPreview: "Codex result.",
                    eventMessage: "Codex completed."
                ),
                "child-2": try Self.childSnapshot(
                    id: "child-2",
                    title: "Claude result",
                    requestedRuntime: "claude",
                    runtimeName: "Claude",
                    resultPreview: "Claude result.",
                    eventMessage: "Claude completed."
                )
            ]
        )

        XCTAssertEqual(draft.sourceSurface, "ios-hermes-square")
        XCTAssertEqual(draft.queuedEventSource, "ios")
        XCTAssertEqual(
            CLIAgentMissionDispatcher.initialQueuedEventSource(
                missionKind: draft.missionKind,
                sourceSurface: draft.sourceSurface
            ),
            "ios"
        )
        let queuedEvent = CLIAgentMissionRequestPayloadFactory.initialQueuedEvent(
            source: draft.queuedEventSource,
            deliveryMode: draft.deliveryMode
        )
        XCTAssertEqual(queuedEvent["source"] as? String, "ios")
        XCTAssertNil(queuedEvent["sourceSurface"])
    }

    func test_missionGroupSynthesisDraft_prefersFullFinalAnswerOverPreview() throws {
        let marker = "FINAL_DETAIL_AFTER_PREVIEW"
        let finalAnswer = String(repeating: "Detailed final answer. ", count: 80) + marker
        let draft = CLIAgentMissionDispatcher.missionGroupSynthesisDraft(
            group: Self.baseMissionGroupDocument(),
            childSnapshots: [
                "child-1": try Self.childSnapshot(
                    id: "child-1",
                    title: "Codex result",
                    requestedRuntime: "codex",
                    runtimeName: "Codex",
                    resultPreview: "Preview only.",
                    eventMessage: "Preview-sized completion.",
                    fullMessage: finalAnswer
                ),
                "child-2": try Self.childSnapshot(
                    id: "child-2",
                    title: "Claude result",
                    requestedRuntime: "claude",
                    runtimeName: "Claude",
                    resultPreview: "Claude result.",
                    eventMessage: "Claude completed."
                )
            ]
        )

        XCTAssertTrue(draft.prompt.contains("Final answer:"))
        XCTAssertTrue(draft.prompt.contains(marker))
        XCTAssertFalse(draft.prompt.contains("Result preview:\nPreview only."))
    }

    func test_missionGroupSynthesisDraft_budgetsEveryChildInLargeFanOut() throws {
        let ids = (1...16).map { "child-\($0)" }
        let runtimes = (1...16).map { "runtime-\($0)" }
        let group = Self.baseMissionGroupDocument(childMissionIDs: ids, runtimeTokens: runtimes)
        var snapshots: [String: CLIAgentMissionSnapshot] = [:]
        for (index, id) in ids.enumerated() {
            let marker = "CHILD_\(index + 1)_FINAL_MARKER"
            let finalAnswer = String(repeating: "x", count: 720)
                + marker
                + String(repeating: "y", count: 4_000)
            snapshots[id] = try Self.childSnapshot(
                id: id,
                title: "Runtime \(index + 1) result",
                requestedRuntime: runtimes[index],
                runtimeName: "Runtime \(index + 1)",
                resultPreview: "Preview \(index + 1).",
                eventMessage: "Completed \(index + 1).",
                fullMessage: finalAnswer
            )
        }

        let draft = CLIAgentMissionDispatcher.missionGroupSynthesisDraft(
            group: group,
            childSnapshots: snapshots
        )

        XCTAssertLessThanOrEqual(draft.prompt.count, 24_000)
        XCTAssertTrue(draft.prompt.contains("### 16. runtime-16 (child-16)"))
        for index in 1...16 {
            XCTAssertTrue(
                draft.prompt.contains("CHILD_\(index)_FINAL_MARKER"),
                "Expected child \(index) to retain a budgeted final-answer marker."
            )
        }
    }

    // MARK: - Helpers

    private static func baseMissionGroupDocument(
        childMissionIDs: [String] = ["child-1", "child-2"],
        runtimeTokens: [String] = ["codex", "claude"]
    ) -> MissionGroupDocument {
        MissionGroupDocument(
            id: "grp-1",
            title: "Audit fan-out",
            prompt: "Audit mission group synthesis.",
            missionKind: "diligence",
            targetProject: "BurnBar",
            childMissionIDs: childMissionIDs,
            runtimeTokens: runtimeTokens,
            parallelismLimit: 2,
            mergeStrategy: .synthesize,
            phase: .awaitingMerge,
            createdAt: ISO8601DateFormatter().date(from: "2026-06-02T12:00:00Z")!,
            updatedAt: ISO8601DateFormatter().date(from: "2026-06-02T12:05:00Z")!
        )
    }

    func test_selectedModelIDFailsClosedWhenActiveWandDidNotRouteRuntime() throws {
        let partialPolicy = WandPolicy(
            selector: .pareto,
            routedModels: [.codex: "gpt-5.5"]
        )

        XCTAssertThrowsError(
            try CLIAgentMissionDispatcher.selectedModelID(
                forRequestedRuntime: "claude",
                wandPolicy: partialPolicy
            )
        ) { error in
            guard case CLIAgentMissionDispatcher.DispatchError.wandRoutingUnavailable = error else {
                return XCTFail("Expected wandRoutingUnavailable, got \(error)")
            }
        }
    }

    func test_selectedModelIDFailsClosedForUnknownRuntimeOnlyWhenWandIsActive() throws {
        let policy = WandPolicy(
            selector: .pareto,
            routedModels: [.codex: "gpt-5.5"]
        )

        XCTAssertThrowsError(
            try CLIAgentMissionDispatcher.selectedModelID(
                forRequestedRuntime: "future-runtime",
                wandPolicy: policy
            )
        ) { error in
            guard case CLIAgentMissionDispatcher.DispatchError.wandRoutingUnavailable = error else {
                return XCTFail("Expected wandRoutingUnavailable, got \(error)")
            }
        }
        XCTAssertNil(
            try CLIAgentMissionDispatcher.selectedModelID(
                forRequestedRuntime: "future-runtime",
                wandPolicy: nil
            )
        )
    }

    func test_resolvedParallelismLimitStaysWithinPersistedChildCount() {
        XCTAssertEqual(
            CLIAgentMissionDispatcher.resolvedParallelismLimit(99, childCount: 2),
            2
        )
        XCTAssertEqual(
            CLIAgentMissionDispatcher.resolvedParallelismLimit(0, childCount: 2),
            1
        )
        XCTAssertEqual(
            CLIAgentMissionDispatcher.resolvedParallelismLimit(nil, childCount: 3),
            3
        )
    }

    func test_resolvedWandPolicyUsesInjectedLiveCatalogsAndFetchesEachRuntimeOnce() async throws {
        let provider = WandCatalogProviderStub(
            results: [
                .codex: .success(Self.catalogResponse(
                    runtime: .codex,
                    modelID: "gpt-5.5",
                    providerID: "openai",
                    source: .codexModelCatalog
                )),
                .claude: .success(Self.catalogResponse(
                    runtime: .claude,
                    modelID: "claude-opus-4-8",
                    providerID: "anthropic",
                    source: .claudeModelCatalog
                ))
            ]
        )

        let resolvedPolicy = try await CLIAgentMissionDispatcher.resolvedWandPolicy(
            WandPolicy(selector: .highestCapability, routedModels: [:]),
            runtimeTokens: ["codex", "codex", "claude"],
            catalogProvider: provider
        )
        let policy = try XCTUnwrap(resolvedPolicy)

        XCTAssertEqual(policy.routedModelID(for: .codex), "gpt-5.5")
        XCTAssertEqual(policy.routedModelID(for: .claude), "claude-opus-4-8")
        XCTAssertEqual(provider.requests.filter { $0 == .codex }.count, 1)
        XCTAssertEqual(provider.requests.filter { $0 == .claude }.count, 1)
    }

    func test_resolvedWandPolicyReportsTheFailingRuntimeAndRootCause() async throws {
        let provider = WandCatalogProviderStub(
            results: [
                .codex: .success(Self.catalogResponse(
                    runtime: .codex,
                    modelID: "gpt-5.5",
                    providerID: "openai",
                    source: .codexModelCatalog
                )),
                .claude: .failure(WandCatalogProviderStub.StubError.catalogOffline)
            ]
        )

        do {
            _ = try await CLIAgentMissionDispatcher.resolvedWandPolicy(
                WandPolicy(selector: .pareto, routedModels: [:]),
                runtimeTokens: ["codex", "claude", "claude"],
                catalogProvider: provider
            )
            XCTFail("Expected wand catalog resolution to fail closed")
        } catch let error as CLIAgentMissionDispatcher.DispatchError {
            guard case let .wandRoutingUnavailable(message) = error else {
                XCTFail("Expected wandRoutingUnavailable, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("Claude: relay catalog offline"))
            XCTAssertTrue(message.contains("No agents were dispatched"))
            XCTAssertFalse(message.localizedCaseInsensitiveContains("Junie"))
            XCTAssertEqual(provider.requests.filter { $0 == .claude }.count, 1)
        }
    }

    func test_resolvedWandPolicyFetchesDistinctRuntimeCatalogsConcurrently() async throws {
        let provider = ConcurrentWandCatalogProviderStub()

        let resolvedPolicy = try await CLIAgentMissionDispatcher.resolvedWandPolicy(
            WandPolicy(selector: .pareto, routedModels: [:]),
            runtimeTokens: ["claude", "codex", "claude"],
            catalogProvider: provider
        )

        XCTAssertEqual(provider.requests.count, 2)
        XCTAssertEqual(resolvedPolicy?.routedModelID(for: .claude), "claude-opus-4-8")
        XCTAssertEqual(resolvedPolicy?.routedModelID(for: .codex), "gpt-5.5")
    }

    private static func catalogResponse(
        runtime: AssistantRuntimeID,
        modelID: String,
        providerID: String,
        source: CLIRuntimeModelSource
    ) -> CLIRuntimeModelCatalogResponse {
        CLIRuntimeModelCatalogResponse(
            runtime: runtime.rawValue,
            generatedAtEpochMillis: 1,
            options: [
                CLIRuntimeModelOption(
                    modelID: modelID,
                    displayName: modelID,
                    providerID: providerID,
                    providerName: providerID,
                    tier: "flagship",
                    source: source
                )
            ]
        )
    }

    private final class WandCatalogProviderStub: CLIRuntimeCatalogProviding {
        enum StubError: LocalizedError {
            case catalogOffline
            case missingFixture

            var errorDescription: String? {
                switch self {
                case .catalogOffline: "relay catalog offline"
                case .missingFixture: "missing catalog fixture"
                }
            }
        }

        enum StubResult {
            case success(CLIRuntimeModelCatalogResponse)
            case failure(StubError)
        }

        let results: [AssistantRuntimeID: StubResult]
        private(set) var requests: [AssistantRuntimeID] = []

        init(results: [AssistantRuntimeID: StubResult]) {
            self.results = results
        }

        func fetchCLIRuntimeModelCatalog(
            runtime: AssistantRuntimeID
        ) async throws -> CLIRuntimeModelCatalogResponse {
            requests.append(runtime)
            guard let result = results[runtime] else { throw StubError.missingFixture }
            switch result {
            case let .success(response): return response
            case let .failure(error): throw error
            }
        }
    }

    private final class ConcurrentWandCatalogProviderStub: CLIRuntimeCatalogProviding {
        enum StubError: LocalizedError {
            case fetchedSerially

            var errorDescription: String? { "catalogs were fetched serially" }
        }

        private(set) var requests: [AssistantRuntimeID] = []

        func fetchCLIRuntimeModelCatalog(
            runtime: AssistantRuntimeID
        ) async throws -> CLIRuntimeModelCatalogResponse {
            requests.append(runtime)
            for _ in 0..<100 where requests.count < 2 {
                await Task.yield()
            }
            guard requests.count == 2 else { throw StubError.fetchedSerially }
            switch runtime {
            case .claude:
                return CLIAgentMissionDispatcherSealTests.catalogResponse(
                    runtime: .claude,
                    modelID: "claude-opus-4-8",
                    providerID: "anthropic",
                    source: .claudeModelCatalog
                )
            case .codex:
                return CLIAgentMissionDispatcherSealTests.catalogResponse(
                    runtime: .codex,
                    modelID: "gpt-5.5",
                    providerID: "openai",
                    source: .codexModelCatalog
                )
            default:
                throw StubError.fetchedSerially
            }
        }
    }

    private static func childSnapshot(
        id: String,
        title: String,
        requestedRuntime: String,
        runtimeName: String,
        resultPreview: String,
        eventMessage: String,
        fullMessage: String? = nil
    ) throws -> CLIAgentMissionSnapshot {
        var event: [String: Any] = [
            "sequence": 1,
            "timestamp": "2026-06-02T12:02:00Z",
            "kind": "final_answer",
            "phase": "completed",
            "title": "Completed",
            "message": eventMessage,
            "isError": false
        ]
        if let fullMessage {
            event["fullMessage"] = fullMessage
        }
        return try XCTUnwrap(
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
                    "events": [event]
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

    // MARK: - Mission approval Deny persist

    func test_denySuccessRemovesAskAndListenerCannotResurrectIt() async throws {
        let responder = StubMissionApprovalResponder()
        let host = MobileMissionConsoleHost(approvalResponder: responder)
        let waiting = try Self.waitingApprovalMission(id: "pareto-final12-codex")
        host.absorbMissionSnapshots([waiting], documentCount: 1, hasResolvedKey: true)

        XCTAssertEqual(host.snapshot.approvalAsks.map(\.missionID), [waiting.id])

        await host.respond(to: waiting.id, approve: false)

        XCTAssertEqual(responder.calls.map(\.requestID), [waiting.id])
        XCTAssertEqual(responder.calls.map(\.approve), [false])
        XCTAssertTrue(host.snapshot.approvalAsks.isEmpty)
        XCTAssertNil(host.approvalResponseError)
        XCTAssertNil(host.inlineError)

        host.absorbMissionSnapshots([waiting], documentCount: 1, hasResolvedKey: true)

        XCTAssertTrue(
            host.snapshot.approvalAsks.isEmpty,
            "A successful Deny must not come back when the listener re-emits the still-waiting document."
        )
        XCTAssertNil(host.approvalResponseError)
    }

    func test_approveSuccessHidesAskWithoutChangingApproveProductPath() async throws {
        let responder = StubMissionApprovalResponder()
        let host = MobileMissionConsoleHost(approvalResponder: responder)
        let waiting = try Self.waitingApprovalMission(id: "pareto-final12-claude")
        host.absorbMissionSnapshots([waiting], documentCount: 1, hasResolvedKey: true)

        await host.respond(to: waiting.id, approve: true)

        XCTAssertEqual(responder.calls.map(\.approve), [true])
        XCTAssertTrue(host.snapshot.approvalAsks.isEmpty)
        XCTAssertEqual(host.snapshot.activeTiles.map(\.id), [waiting.id])
        XCTAssertEqual(host.snapshot.activeTiles.first?.approvalPending, false)
        XCTAssertNil(host.approvalResponseError)
    }

    func test_denyFailureKeepsAskAndSurfacesErrorThroughListenerAbsorb() async throws {
        let responder = StubMissionApprovalResponder()
        responder.result = .failure(
            StubMissionApprovalResponder.StubError.message(
                "Mission approvals require a trusted native device. Trust this device first."
            )
        )
        let host = MobileMissionConsoleHost(approvalResponder: responder)
        let waiting = try Self.waitingApprovalMission(id: "pareto-final11-codex")
        host.absorbMissionSnapshots([waiting], documentCount: 1, hasResolvedKey: true)

        await host.respond(to: waiting.id, approve: false)

        XCTAssertEqual(host.snapshot.approvalAsks.map(\.missionID), [waiting.id])
        XCTAssertEqual(
            host.approvalResponseError,
            "Mission approvals require a trusted native device. Trust this device first."
        )
        XCTAssertEqual(host.inlineError, host.approvalResponseError)

        host.absorbMissionSnapshots([waiting], documentCount: 1, hasResolvedKey: true)

        XCTAssertEqual(
            host.snapshot.approvalAsks.map(\.missionID),
            [waiting.id],
            "A failed Deny must keep the waiting card so the user can retry."
        )
        XCTAssertEqual(
            host.approvalResponseError,
            "Mission approvals require a trusted native device. Trust this device first.",
            "The previous silent no-op cleared the error on the next list snapshot."
        )
        XCTAssertEqual(host.inlineError, host.approvalResponseError)
    }

    func testTransportConsumeStreamUnknownThenCompletedAndMalformedFails() throws {
        var events: [CLIAgentRelayChatEvent] = []
        try CLIAgentRelayChatTransport.dispatchStreamEvents(
            [#"{"kind":"futureKind"}"#, #"{"kind":"completed"}"#]
        ) { events.append($0) }
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].kind, .unknown)
        XCTAssertEqual(events[1].kind, .completed)
        XCTAssertThrowsError(
            try CLIAgentRelayChatTransport.dispatchStreamEvents(["not-json"]) { _ in }
        )
    }

    func test_absorbApproval1RespondThenApproval2ShowsNewCard() async throws {
        let responder = StubMissionApprovalResponder()
        let host = MobileMissionConsoleHost(approvalResponder: responder)
        let first = try Self.waitingApprovalMission(id: "m-dup", approvalRequestId: "approval-1")
        host.absorbMissionSnapshots([first], documentCount: 1, hasResolvedKey: true)
        XCTAssertEqual(host.snapshot.approvalAsks.map(\.missionID), [first.id])

        await host.respond(to: first.id, approve: true)
        XCTAssertEqual(responder.calls.map(\.approve), [true])
        XCTAssertTrue(host.snapshot.approvalAsks.isEmpty)

        let second = try Self.waitingApprovalMission(id: "m-dup", approvalRequestId: "approval-2")
        host.absorbMissionSnapshots([second], documentCount: 1, hasResolvedKey: true)
        XCTAssertEqual(host.snapshot.approvalAsks.map(\.missionID), [first.id])
        XCTAssertEqual(second.approvalRequestId, "approval-2")
    }

    func test_rejectedOrCanceledMissionIsNotWaitingForApproval() throws {
        let rejected = try XCTUnwrap(CLIAgentMissionSnapshot(documentID: "denied-1", data: [
            "id": "denied-1",
            "title": "Denied mission",
            "status": "waiting_for_approval",
            "requestedRuntime": "codex",
            "approvalRequestId": "approval-1",
            "approvalStatus": "rejected",
            "events": []
        ]))
        XCTAssertFalse(rejected.isWaitingForApproval)

        let canceled = try XCTUnwrap(CLIAgentMissionSnapshot(documentID: "denied-2", data: [
            "id": "denied-2",
            "title": "Canceled mission",
            "status": "canceled",
            "requestedRuntime": "claude",
            "approvalRequestId": "approval-2",
            "approvalStatus": "rejected",
            "events": []
        ]))
        XCTAssertFalse(canceled.isWaitingForApproval)
        XCTAssertTrue(canceled.isTerminal)
    }

    private static func waitingApprovalMission(id: String, approvalRequestId: String? = nil) throws -> CLIAgentMissionSnapshot {
        try XCTUnwrap(CLIAgentMissionSnapshot(documentID: id, data: [
            "id": id,
            "title": "Waiting mission",
            "status": "waiting_for_approval",
            "requestedRuntime": "codex",
            "selectedRuntime": "codex",
            "selectedRuntimeName": "Codex",
            "approvalRequestId": approvalRequestId ?? "approval-\(id)",
            "approvalStatus": "pending",
            "approvalTitle": "Approve \(id)",
            "approvalMessage": "Codex is waiting for approval.",
            "createdAt": "2026-07-20T10:04:25Z",
            "events": []
        ]))
    }
}

@MainActor
private final class StubMissionApprovalResponder: MobileMissionApprovalResponding {
    enum StubError: LocalizedError {
        case message(String)

        var errorDescription: String? {
            switch self {
            case .message(let text): return text
            }
        }
    }

    var result: Result<Void, Error> = .success(())
    private(set) var calls: [(requestID: String, approve: Bool)] = []

    func respondToApproval(requestID: String, approve: Bool) async throws {
        calls.append((requestID, approve))
        try result.get()
    }

    func testSealedPayloadCarriesAttachmentRefs() throws {
        let key = Data(repeating: 7, count: 32)
        let ref = CLIAgentMissionAttachmentRef(
            id: "att-1",
            contentBlake3: String(repeating: "ab", count: 32),
            displayName: "note.txt",
            byteCount: 12,
            transport: "cloud"
        )
        let payload = try CLIAgentMissionRequestPayloadFactory.buildSealed(
            id: "req-att",
            title: "t",
            prompt: "p",
            missionKind: "chat",
            requestedRuntime: "codex",
            targetProject: nil,
            depth: "standard",
            approvalMode: "existing_policy",
            commandsAllowed: false,
            fileEditsAllowed: false,
            attachments: [ref],
            vaultKey: key,
            vaultKeyID: "vk"
        )
        XCTAssertNotNil(payload["sealedPayload"])
    }
}
