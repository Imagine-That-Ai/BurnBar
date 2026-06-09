import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarComputerUseCore

final class AgentCapabilityGrantTests: XCTestCase {
    func test_agentCapabilityGrant_isInactiveAfterExpiryOrRevocation() {
        let now = Date(timeIntervalSince1970: 1_000)
        let active = AgentCapabilityGrant.sessionGrant(
            runtimeID: .hermes,
            threadID: "thread-1",
            capabilities: [.desktopBrowser],
            now: now,
            duration: 60
        )

        XCTAssertTrue(active.isActive(now: now.addingTimeInterval(1)))
        XCTAssertFalse(active.isActive(now: now.addingTimeInterval(61)))
        XCTAssertFalse(active.revoked().isActive(now: now.addingTimeInterval(1)))
    }

    func test_agentDesktopToolDefinitions_gateBrowserScreenshotsSeparately() {
        let grant = AgentCapabilityGrant.sessionGrant(
            runtimeID: .hermes,
            threadID: "thread-1",
            capabilities: [.desktopBrowser],
            now: Date(),
            duration: 60
        )

        let toolNames = Set(AgentDesktopToolDefinitions.tools(for: grant).map(\.name))

        XCTAssertTrue(toolNames.contains(BurnBarToolKind.browserGoto.rawValue))
        XCTAssertTrue(toolNames.contains(BurnBarToolKind.browserClick.rawValue))
        XCTAssertFalse(toolNames.contains(BurnBarToolKind.browserScreenshot.rawValue))
    }

    func test_agentDesktopToolDefinitions_exposeWorkspaceAndShellOnlyWhenGranted() {
        let grant = AgentCapabilityGrant.sessionGrant(
            runtimeID: .codex,
            threadID: "thread-1",
            capabilities: [.workspaceRead, .workspaceWrite],
            now: Date(),
            duration: 60
        )

        let toolNames = Set(AgentDesktopToolDefinitions.openAITools(for: grant).compactMap { descriptor in
            (descriptor["function"] as? [String: Any])?["name"] as? String
        })

        XCTAssertTrue(toolNames.contains("workspace_read_file"))
        XCTAssertTrue(toolNames.contains("workspace_list_files"))
        XCTAssertTrue(toolNames.contains("workspace_write_file"))
        XCTAssertFalse(toolNames.contains("shell_run"))
    }

    func test_permissionPresetsSeparateAllFromYOLO() {
        XCTAssertFalse(AgentPermissionPreset.all.capabilities.contains(.shellUnrestricted))
        XCTAssertTrue(AgentPermissionPreset.yolo.capabilities.contains(.shellUnrestricted))
        XCTAssertEqual(AgentPermissionPreset.all.trustMode, .manual)
        XCTAssertEqual(AgentPermissionPreset.yolo.trustMode, .trusted)
    }

    func test_customDangerousCapabilitySetRequiresLocalAuthentication() {
        XCTAssertFalse(
            AgentDesktopCapability.requiresLocalAuthentication(
                capabilities: [.workspaceRead, .workspaceWrite, .shell],
                trustMode: .manual
            )
        )
        XCTAssertTrue(
            AgentDesktopCapability.requiresLocalAuthentication(
                capabilities: [.workspaceRead, .desktopSystemInput],
                trustMode: .manual
            )
        )
        XCTAssertTrue(
            AgentDesktopCapability.requiresLocalAuthentication(
                capabilities: [.workspaceRead],
                trustMode: .trusted
            )
        )
    }

    func test_desktopPresetCanExportWorkspaceFilesToDesktopDrop() {
        let grant = AgentCapabilityGrant.sessionGrant(
            runtimeID: .hermes,
            threadID: "thread-1",
            capabilities: AgentPermissionPreset.desktop.capabilities,
            now: Date(),
            duration: 60
        )

        let toolNames = Set(AgentDesktopToolDefinitions.tools(for: grant).map(\.name))

        XCTAssertTrue(toolNames.contains("workspace_write_file"))
        XCTAssertTrue(toolNames.contains("desktop_export_file"))
        XCTAssertFalse(toolNames.contains("shell_run_unrestricted"))
    }

    func test_grantRequestRoundTripsThroughWireModel() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let placeholder = HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: "",
            counter: 0,
            timestamp: now,
            intentHashBlake3: "",
            signatureEd25519: ""
        )
        let request = AgentCapabilityGrantRequest(
            requestID: "grant-1",
            runtimeID: .claude,
            threadID: "thread-1",
            preset: .desktop,
            deliveryMode: .liveThenQueued,
            requestedAt: now,
            expiresAt: now.addingTimeInterval(300),
            sourceDeviceID: "iphone-1",
            clientIntentID: "intent-1",
            localAuthenticationSatisfied: true
        )

        let decoded = try AgentCapabilityGrantRequest(wire: request.wire(authority: placeholder))

        XCTAssertEqual(decoded.requestID, request.requestID)
        XCTAssertEqual(decoded.runtimeID, .claude)
        XCTAssertEqual(decoded.preset, .desktop)
        XCTAssertEqual(decoded.capabilities, AgentPermissionPreset.desktop.capabilities)
        XCTAssertEqual(decoded.deliveryMode, .liveThenQueued)
        XCTAssertTrue(decoded.localAuthenticationSatisfied)
    }

    func test_wireModelRejectsPresetCapabilityTrustMismatch() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let authority = HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: "ios-phone-000000000000000000000000",
            counter: 1,
            timestamp: now,
            intentHashBlake3: String(repeating: "a", count: 64),
            signatureEd25519: "signature"
        )
        let forged = HermesRealtimeRelayAgentGrantRequest(
            requestId: "grant-forged",
            runtime: AssistantRuntimeID.codex.rawValue,
            threadId: "thread-1",
            preset: AgentPermissionPreset.low.rawValue,
            capabilities: AgentPermissionPreset.yolo.capabilities.map(\.rawValue).sorted(),
            trustMode: ComputerUseTrustMode.trusted.rawValue,
            deliveryMode: AgentGrantDeliveryMode.liveThenQueued.rawValue,
            requestedAt: now,
            expiresAt: now.addingTimeInterval(300),
            grantDurationSeconds: 300,
            sourceDeviceId: "iphone-1",
            clientIntentId: "intent-1",
            localAuthenticationSatisfied: true,
            authority: authority
        )

        XCTAssertThrowsError(try AgentCapabilityGrantRequest(wire: forged)) { error in
            XCTAssertEqual(error as? AgentCapabilityGrantWireError, .presetCapabilityMismatch)
        }
    }
}
