import XCTest
import OpenBurnBarComputerUseCore
import OpenBurnBarCore
@testable import OpenBurnBar

/// Covers the error-swallow remediations in `CLIAgentMissionRequestListener.swift`
/// that were judged to MATTER.
///
/// The load-bearing case is the persona-scope decode: the Mac listener applies a
/// `personaScopeJSON` envelope (tool allow-list, file globs, shell prefixes,
/// permit-shell / permit-file-edits gates) to the spawned CLI subprocess. The
/// previous `try?` swallowed a malformed-envelope decode failure and fell back to
/// `.empty`, which dispatches the mission with NO persona sandbox at all — full
/// shell + unrestricted file edits — silently widening the sandbox the operator
/// asked to narrow. The remediation FAILS CLOSED: a present-but-malformed scope is
/// refused instead of fail-open dispatched.
///
/// Kept outside any `@MainActor` suite: `CLIAgentMissionPersonaScopeResolution` is
/// a pure value type, so the checks need no app-host MainActor queue.
final class CLIAgentMissionRequestListenerMattersTests: XCTestCase {
    @MainActor
    func testApprovalTransitionGetsNewQueueIdentityAndUnparksMission() {
        let pending: [String: Any] = [
            "status": "waiting_for_approval",
            "approvalStatus": "pending",
            "approvalRequestId": "approval-1"
        ]
        let approved: [String: Any] = [
            "status": "waiting_for_approval",
            "approvalStatus": "approved",
            "approvalRequestId": "approval-1"
        ]

        let pendingIdentity = CLIAgentMissionRequestListener.processingIdentity(
            documentID: "mission-1",
            data: pending
        )
        let approvedIdentity = CLIAgentMissionRequestListener.processingIdentity(
            documentID: "mission-1",
            data: approved
        )

        XCTAssertNotEqual(pendingIdentity, approvedIdentity)
        XCTAssertEqual(
            MissionClaimGate.ignoreReason(pending, localBodyID: "body-a"),
            "remains parked for mobile approval"
        )
        XCTAssertNil(MissionClaimGate.ignoreReason(approved, localBodyID: "body-a"))
    }

    @MainActor
    func testMalformedPendingApprovalIsNotSilentlyParked() {
        XCTAssertNil(
            MissionClaimGate.ignoreReason(
                [
                    "status": "waiting_for_approval",
                    "approvalStatus": "pending"
                ],
                localBodyID: "body-a"
            )
        )
    }

    // MARK: - Wand routing authority

    @MainActor
    func testGroupedMissionKeepsConcreteDispatchRoute() {
        let context = MissionGroupClaimContext(
            groupID: "group",
            siblingIndex: 0,
            siblingCount: 2,
            parallelismLimit: 2,
            tierCap: 2
        )

        XCTAssertFalse(
            CLIAgentMissionRequestListener.shouldResolveWandRouting(
                context: context,
                data: ["requestedModelID": "anthropic/claude-sonnet-4"]
            ),
            "A mobile Pareto or Manual route must not be replaced by the Mac's default Ministry wand."
        )
    }

    @MainActor
    func testMacWandGroupWithoutConcreteRouteStillUsesMinistry() {
        let context = MissionGroupClaimContext(
            groupID: "group",
            siblingIndex: 1,
            siblingCount: 2,
            parallelismLimit: 2,
            tierCap: 2
        )

        XCTAssertTrue(
            CLIAgentMissionRequestListener.shouldResolveWandRouting(
                context: context,
                data: [:]
            )
        )
        XCTAssertTrue(
            CLIAgentMissionRequestListener.shouldResolveWandRouting(
                context: context,
                data: ["requestedModelID": "  \n"]
            )
        )
        XCTAssertFalse(
            CLIAgentMissionRequestListener.shouldResolveWandRouting(
                context: nil,
                data: [:]
            )
        )
    }

    @MainActor
    func testConcreteDispatchRouteBypassesMinistryAtListenerBoundary() async {
        let context = MissionGroupClaimContext(
            groupID: "group",
            siblingIndex: 0,
            siblingCount: 2,
            parallelismLimit: 2,
            tierCap: 2
        )

        do {
            let concreteSelection = try await CLIAgentMissionRequestListener.resolveWandRoutingIfNeeded(
                context: context,
                data: ["requestedModelID": "anthropic/claude-sonnet-4"]
            )
            let ungroupedSelection = try await CLIAgentMissionRequestListener.resolveWandRoutingIfNeeded(
                context: nil,
                data: [:]
            )

            XCTAssertNil(concreteSelection)
            XCTAssertNil(ungroupedSelection)
        } catch {
            XCTFail("Concrete and ungrouped routes must bypass Ministry without error: \(error)")
        }
    }

    // MARK: - Legitimate "no scope" path stays open

    func testMissingScopeResolvesToEmptyWithoutRefusing() {
        let resolution = CLIAgentMissionPersonaScopeResolution.resolve(from: [:])
        guard case .resolved(let overrides) = resolution else {
            XCTFail("Missing personaScopeJSON must resolve, not refuse: \(resolution)"); return
        }
        XCTAssertEqual(overrides, .empty, "No scope must keep the plan's env verbatim.")
        XCTAssertNil(overrides.envelope)
        XCTAssertTrue(overrides.extraEnvironment.isEmpty)
    }

    func testEmptyScopeStringResolvesToEmpty() {
        let resolution = CLIAgentMissionPersonaScopeResolution.resolve(
            from: ["personaScopeJSON": "   \n  "]
        )
        guard case .resolved(let overrides) = resolution else {
            XCTFail("Whitespace-only scope must resolve to empty, not refuse: \(resolution)"); return
        }
        XCTAssertEqual(overrides, .empty)
    }

    // MARK: - Valid scope is applied (restrictions actually propagate)

    func testValidRestrictiveScopeResolvesAndPropagatesSandbox() throws {
        let envelope = PersonaScopeEnvelope(
            agentURI: "agent://burnbar/claude",
            personaID: "tech-reviewer",
            permittedTools: ["read_file", "grep"],
            permittedFileGlobs: ["src/**"],
            permittedShellPrefixes: [],
            permitShell: false,
            permitFileEdits: false
        )
        let json = try envelope.jsonString()
        let resolution = CLIAgentMissionPersonaScopeResolution.resolve(
            from: ["personaScopeJSON": json]
        )
        guard case .resolved(let overrides) = resolution else {
            XCTFail("A valid scope must resolve: \(resolution)"); return
        }
        // Compare the security-relevant fields, not full envelope equality:
        // `appliedAt` is a timestamp stamped at resolution time, so a whole-struct
        // compare is non-deterministic.
        let resolvedEnvelope = try XCTUnwrap(overrides.envelope)
        XCTAssertEqual(resolvedEnvelope.personaID, envelope.personaID)
        XCTAssertEqual(resolvedEnvelope.permittedTools, envelope.permittedTools)
        XCTAssertEqual(resolvedEnvelope.permittedFileGlobs, envelope.permittedFileGlobs)
        XCTAssertEqual(resolvedEnvelope.permittedShellPrefixes, envelope.permittedShellPrefixes)
        XCTAssertEqual(resolvedEnvelope.permitShell, envelope.permitShell)
        XCTAssertEqual(resolvedEnvelope.permitFileEdits, envelope.permitFileEdits)
        // The restrictive flags must reach the subprocess env namespace.
        XCTAssertEqual(overrides.extraEnvironment["BURNBAR_PERSONA_PERMIT_SHELL"], "0")
        XCTAssertEqual(overrides.extraEnvironment["BURNBAR_PERSONA_PERMIT_FILE_EDITS"], "0")
        XCTAssertEqual(overrides.extraEnvironment["BURNBAR_PERSONA_TOOLS_ALLOWLIST"], "read_file,grep")
    }

    // MARK: - FAIL CLOSED: malformed present scope is refused, not fail-open

    func testMalformedScopeIsRefusedNotFailOpen() {
        let resolution = CLIAgentMissionPersonaScopeResolution.resolve(
            from: ["personaScopeJSON": "{ this is not valid json"]
        )
        guard case .refused(let message) = resolution else {
            XCTFail("Malformed personaScopeJSON must FAIL CLOSED, got: \(resolution)"); return
        }
        XCTAssertFalse(message.isEmpty, "Refusal must carry an actionable message for the device.")
        // Critically: it must NOT silently degrade to the permissive `.empty`.
        XCTAssertNotEqual(
            resolution,
            .resolved(.empty),
            "A malformed scope must never fall back to an unrestricted dispatch."
        )
    }

    func testRestrictiveScopeCorruptionDoesNotWidenSandbox() {
        // A scope that the operator built to DENY shell, then corrupted on the
        // wire, must not silently become a full-shell dispatch.
        let corrupted = #"{"schemaVersion":1,"permitShell":fa"#  // truncated/garbage
        let resolution = CLIAgentMissionPersonaScopeResolution.resolve(
            from: ["personaScopeJSON": corrupted]
        )
        switch resolution {
        case .refused:
            break // correct: fail closed
        case .resolved(let overrides):
            XCTFail("Corrupted restrictive scope widened the sandbox to: \(overrides)")
        }
    }

    func testWrongTypeJSONIsRefused() {
        // A JSON array (or any non-object) is not a valid envelope and must be
        // refused rather than swallowed into `.empty`.
        let resolution = CLIAgentMissionPersonaScopeResolution.resolve(
            from: ["personaScopeJSON": "[1, 2, 3]"]
        )
        guard case .refused = resolution else {
            XCTFail("Non-object persona scope JSON must fail closed: \(resolution)"); return
        }
    }

    func testStreamingStatusRedactsAssistantPreviewSecrets() {
        let providerToken = "sk-" + "1234567890abcdef"
        let assistant = ChatMessageRecord(
            id: "assistant-secret-preview",
            role: .assistant,
            content: "Final answer token=\(providerToken) bearer abcdefghijklmnopqrstuvwxyz012345",
            timestamp: Date(timeIntervalSince1970: 1_730_000_000)
        )

        let message = CLIAgentMissionRequestListener.deriveStreamingStatusMessage(
            assistantMessage: assistant,
            backend: CLIAgentMissionBackend(rawValue: "codex", displayName: "Codex")
        )

        XCTAssertTrue(message.contains("[REDACTED]"))
        XCTAssertFalse(message.contains(providerToken))
        XCTAssertFalse(message.lowercased().contains("bearer abcdef"))
        XCTAssertLessThanOrEqual(message.count, 420)
    }

    func testStreamingStatusRedactsToolDetailSecrets() {
        let providerToken = "sk-" + "1234567890abcdef"
        let assistant = ChatMessageRecord(
            id: "assistant-tool-secret",
            role: .assistant,
            content: "",
            timestamp: Date(timeIntervalSince1970: 1_730_000_000),
            transcriptPieces: [
                ChatTranscriptPiece(
                    id: "tool-1",
                    kind: .toolUse,
                    value: "Shell",
                    detail: "token=\(providerToken) bearer abcdefghijklmnopqrstuvwxyz012345"
                )
            ]
        )

        let message = CLIAgentMissionRequestListener.deriveStreamingStatusMessage(
            assistantMessage: assistant,
            backend: CLIAgentMissionBackend(rawValue: "codex", displayName: "Codex")
        )

        XCTAssertTrue(message.contains("[REDACTED]"))
        XCTAssertFalse(message.contains(providerToken))
        XCTAssertFalse(message.lowercased().contains("bearer abcdef"))
        XCTAssertLessThanOrEqual(message.count, 420)
    }

    // MARK: - M1 characterization (split-brain remediation, Phase 2)
    //
    // These tables pin the CURRENT verdict behavior of the GUI mission
    // authority's pure decision functions (`CLIAgentMissionRuntimePlanner`),
    // so the daemon-side `daemon.mission.authorizeRemote` port (M2) and the
    // later routing changes (M3 shadow mode, M4 enforcement) are provably
    // behavior-preserving. A row change here is a mission-security policy
    // change, not a test update. The Firestore-coupled halves of the GUI
    // authority (LiveCLIAgentMissionDeviceTrustChecker, shouldPauseForApproval)
    // cannot be pinned as pure tables — their verdict semantics are mirrored
    // by the daemon authorizer's own tables in OpenBurnBarDaemonTests.

    private func backend(_ chatBackend: ChatBackendID) -> CLIAgentMissionBackend {
        CLIAgentMissionBackend(chatBackend: chatBackend)
    }

    func testCharacterization_M1_MacCLIAssistantConsentTable() {
        // Every chat backend: only Hermes runs remote missions without the
        // Mac CLI-assistant consent toggle.
        let consentExempt: Set<ChatBackendID> = [.hermes]
        for chatBackend in ChatBackendID.allCases {
            XCTAssertEqual(
                CLIAgentMissionRuntimePlanner.requiresMacCLIAssistantConsentForRemoteMission(
                    backend: backend(chatBackend)
                ),
                !consentExempt.contains(chatBackend),
                "consent requirement drifted for \(chatBackend.rawValue)"
            )
        }

        // Raw (non-ChatBackendID) runtimes: opencode/ollama require consent;
        // anything else falls through to no consent requirement.
        struct RawRow { let raw: String; let expected: Bool }
        let rawRows: [RawRow] = [
            RawRow(raw: "opencode", expected: true),
            RawRow(raw: "ollama", expected: true),
            RawRow(raw: " OpenCode ", expected: true),
            RawRow(raw: "grok", expected: false),
            RawRow(raw: "mystery-runtime", expected: false)
        ]
        for row in rawRows {
            XCTAssertEqual(
                CLIAgentMissionRuntimePlanner.requiresMacCLIAssistantConsentForRemoteMission(
                    backend: CLIAgentMissionBackend(rawValue: row.raw, displayName: row.raw)
                ),
                row.expected,
                "raw runtime consent drifted for '\(row.raw)'"
            )
        }
    }

    // The GUI's pre-dispatch approval DECISION table
    // (`CLIAgentMissionRuntimePlanner.requiresPreDispatchApproval`) was DELETED
    // in split-brain M4: that allow / requires-approval / deny decision now lives
    // solely in the daemon's `BurnBarRemoteMissionAuthorizationPolicy`, whose
    // characterization is pinned by OpenBurnBarDaemonTests
    // (`BurnBarRemoteMissionAuthorizationTests.testApprovalVerdictTable` /
    // `.testMacCLIAssistantBackendsRequireConsentBeforeAuthorization`) and by the
    // GUI↔daemon parity gate (`MissionRemoteAuthorizationParityTests`). The
    // shared `InsightMissionApprovalPolicy` half stays covered by
    // OpenBurnBarCoreTests. The Mac CLI-assistant CONSENT table below stays: it
    // is the execution-side local-privacy gate that survives M4.

    func testCharacterization_M1_CapabilityGrantIsNeverWiderThanRequested() {
        // The app-side capability grant built for spawned CLI missions:
        // workspaceRead is the unconditional baseline; shell and workspaceWrite
        // are granted ONLY when the mission document requested them. Absent
        // keys are non-grants (fail closed), and no other capability is ever
        // added.
        struct Row {
            let commands: Bool?
            let fileEdits: Bool?
            let expected: Set<AgentDesktopCapability>
        }
        let rows: [Row] = [
            Row(commands: nil, fileEdits: nil, expected: [.workspaceRead]),
            Row(commands: false, fileEdits: false, expected: [.workspaceRead]),
            Row(commands: true, fileEdits: false, expected: [.workspaceRead, .shell]),
            Row(commands: false, fileEdits: true, expected: [.workspaceRead, .workspaceWrite]),
            Row(commands: true, fileEdits: true, expected: [.workspaceRead, .shell, .workspaceWrite])
        ]
        for row in rows {
            var data: [String: Any] = [:]
            if let commands = row.commands { data["commandsAllowed"] = commands }
            if let fileEdits = row.fileEdits { data["fileEditsAllowed"] = fileEdits }
            let grant = CLIAgentMissionRuntimePlanner.capabilityGrant(for: backend(.codex), data: data)
            XCTAssertEqual(
                grant.capabilities,
                row.expected,
                "grant width drifted for commands=\(String(describing: row.commands)) fileEdits=\(String(describing: row.fileEdits))"
            )
            XCTAssertEqual(grant.trustMode, .manual, "mission grants must stay manual-trust")
            XCTAssertTrue(
                grant.capabilities.isDisjoint(with: [
                    .desktopBrowser, .desktopSystemInput, .desktopScreenshot,
                    .accessibilityInspect, .desktopFileExport, .shellUnrestricted
                ]),
                "mission grants must never include desktop/HID capabilities"
            )
        }

        // The working directory flows from targetProject verbatim (tilde-expanded).
        let withWorkspace = CLIAgentMissionRuntimePlanner.capabilityGrant(
            for: backend(.codex),
            data: ["targetProject": "/tmp/mission-workspace"]
        )
        XCTAssertEqual(withWorkspace.workspaceRootPath, "/tmp/mission-workspace")
        let withoutWorkspace = CLIAgentMissionRuntimePlanner.capabilityGrant(for: backend(.codex), data: [:])
        XCTAssertNil(withoutWorkspace.workspaceRootPath)
    }

    @MainActor
    func testVisibleTerminalSessionPermissionsAndTeardown() async throws {
        let fileManager = FileManager.default
        let sessionID = "test-session-\(UUID().uuidString)"

        // 1. Ensure clean state before start
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("OpenBurnBarVisibleCLI", isDirectory: true)
        let sessionURL = rootURL.appendingPathComponent(sessionID, isDirectory: true)
        try? fileManager.removeItem(at: sessionURL)
        XCTAssertFalse(fileManager.fileExists(atPath: sessionURL.path))

        let workspace = try VisibleTerminalSessionWorkspace.prepare(
            sessionID: sessionID,
            fileManager: fileManager
        )

        let attributes = try fileManager.attributesOfItem(atPath: workspace.sessionURL.path)
        let permissions = attributes[.posixPermissions] as? NSNumber
        XCTAssertEqual((permissions?.uint16Value ?? 0) & 0o777, 0o700, "Session directory must be restricted to 0o700")

        let logAttributes = try fileManager.attributesOfItem(atPath: workspace.logURL.path)
        let logPermissions = logAttributes[.posixPermissions] as? NSNumber
        XCTAssertEqual((logPermissions?.uint16Value ?? 0) & 0o777, 0o600, "terminal.log must be restricted to 0o600")

        // 2. Ensure the folder has been completely deleted after cleanup.
        workspace.cleanup(fileManager: fileManager)
        XCTAssertFalse(fileManager.fileExists(atPath: sessionURL.path), "Session directory must be cleaned up on exit.")
    }
}

final class CLIAgentMissionRuntimePlannerMattersTests: XCTestCase {
    private func resolve(_ runtime: String) -> CLIAgentMissionBackend {
        CLIAgentMissionRuntimePlanner.resolve(
            requestedRuntime: runtime,
            missionKind: nil,
            enabledBackends: ChatBackendID.allCases
        )
    }

    func testCanonicalMuseTokenResolvesToFirstClassBackend() {
        let backend = resolve("muse")
        XCTAssertEqual(backend.chatBackend, .muse)
        XCTAssertFalse(backend.usesDirectCLI)
    }

    func testMuseAliasTokensResolveThroughCanonicalID() {
        // The default arm resolves through the canonical id, so alias tokens
        // land on the first-class backend instead of a freeform custom one.
        for alias in ["muse-code", "musecode", "muse_code", "meta-muse", "Muse Code"] {
            let backend = resolve(alias)
            XCTAssertEqual(backend.chatBackend, .muse, "alias \(alias) must resolve to .muse")
            XCTAssertFalse(backend.usesDirectCLI)
        }
    }

    func testLegacyAliasTokensStillResolveToFirstClassBackends() {
        XCTAssertEqual(resolve("jetbrains-junie").chatBackend, .junie)
        XCTAssertEqual(resolve("vercel-fx").chatBackend, .fx)
    }

    func testUnknownTokenStillFallsBackToCustomBackend() {
        let backend = resolve("not-a-runtime")
        XCTAssertNil(backend.chatBackend)
        XCTAssertTrue(backend.usesDirectCLI)
    }
}
