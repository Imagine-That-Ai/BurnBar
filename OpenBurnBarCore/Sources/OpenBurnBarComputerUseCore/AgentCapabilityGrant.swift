import Foundation
import OpenBurnBarCore

/// Capabilities that a human can grant to one assistant runtime for one
/// chat thread. No assistant receives any of these by default.
public enum AgentDesktopCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case desktopBrowser = "desktop_browser"
    case desktopSystemInput = "desktop_system_input"
    case desktopScreenshot = "desktop_screenshot"
    case accessibilityInspect = "accessibility_inspect"
    case desktopFileExport = "desktop_file_export"
    case workspaceRead = "workspace_read"
    case workspaceWrite = "workspace_write"
    case shell
    case shellUnrestricted = "shell_unrestricted"

    public var displayName: String {
        switch self {
        case .desktopBrowser: return "Browser"
        case .desktopSystemInput: return "Mac input"
        case .desktopScreenshot: return "Screenshots"
        case .accessibilityInspect: return "Accessibility inspect"
        case .desktopFileExport: return "Desktop export"
        case .workspaceRead: return "Workspace read"
        case .workspaceWrite: return "Workspace write"
        case .shell: return "Shell"
        case .shellUnrestricted: return "Unrestricted shell"
        }
    }

    public static var boundedCases: Set<AgentDesktopCapability> {
        Set(allCases).subtracting([.shellUnrestricted])
    }

    public static func requiresLocalAuthentication(
        capabilities: Set<AgentDesktopCapability>,
        trustMode: ComputerUseTrustMode
    ) -> Bool {
        if trustMode == .trusted { return true }
        let privileged: Set<AgentDesktopCapability> = [
            .desktopBrowser,
            .desktopSystemInput,
            .desktopScreenshot,
            .desktopFileExport,
            .workspaceWrite,
            .shell,
            .shellUnrestricted
        ]
        return !capabilities.isDisjoint(with: privileged)
    }

    public static func requiresMacApproval(
        capabilities: Set<AgentDesktopCapability>,
        trustMode: ComputerUseTrustMode
    ) -> Bool {
        if trustMode == .trusted { return true }
        let lowRisk: Set<AgentDesktopCapability> = [.workspaceRead]
        return !capabilities.isSubset(of: lowRisk)
    }
}

public enum AgentCapabilityGrantStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case active
    case revoked
    case expired
}

public enum AgentGrantDeliveryMode: String, Codable, CaseIterable, Hashable, Sendable {
    /// Apply over the live Computer Use relay stream only.
    case live
    /// Persist a short-lived signed request for the Mac to consume when it reconnects.
    case queued
    /// Try the live relay first, then queue the same signed request if the Mac is offline.
    case liveThenQueued = "live_then_queued"
}

public enum AgentGrantDecisionStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case applied
    case queued
    case revoked
    case denied
    case expired
}

public enum AgentGrantDenialReason: String, Codable, CaseIterable, Hashable, Sendable {
    case malformedRequest = "malformed_request"
    case unsupportedRuntime = "unsupported_runtime"
    case expired
    case signatureFailure = "signature_failure"
    case counterReplay = "counter_replay"
    case staleTimestamp = "stale_timestamp"
    case noPairedMac = "no_paired_mac"
    case localAuthenticationRequired = "local_authentication_required"
    case localAuthProofRequired = "local_auth_proof_required"
    case localAuthProofInvalid = "local_auth_proof_invalid"
    case macApprovalRequired = "mac_approval_required"
    case yoloUnavailable = "yolo_unavailable"
    case grantPresetMismatch = "grant_preset_mismatch"
    case unknown
}

public enum AgentPermissionPreset: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case off
    case low
    case workspace
    case desktop
    case all
    case yolo

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off: return "Off"
        case .low: return "Low"
        case .workspace: return "Workspace"
        case .desktop: return "Desktop"
        case .all: return "All"
        case .yolo: return "YOLO"
        }
    }

    public var subtitle: String {
        switch self {
        case .off: return "No tools"
        case .low: return "Read only"
        case .workspace: return "Workspace files"
        case .desktop: return "Browser, view, export"
        case .all: return "All bounded tools"
        case .yolo: return "Trusted everything"
        }
    }

    public var symbolName: String {
        switch self {
        case .off: return "nosign"
        case .low: return "eye"
        case .workspace: return "folder"
        case .desktop: return "display"
        case .all: return "checkmark.shield"
        case .yolo: return "bolt.shield"
        }
    }

    public var capabilities: Set<AgentDesktopCapability> {
        switch self {
        case .off:
            return []
        case .low:
            return [.workspaceRead]
        case .workspace:
            return [.workspaceRead, .workspaceWrite, .shell]
        case .desktop:
            return [
                .desktopBrowser,
                .desktopScreenshot,
                .accessibilityInspect,
                .workspaceRead,
                .workspaceWrite,
                .desktopFileExport
            ]
        case .all:
            return AgentDesktopCapability.boundedCases
        case .yolo:
            return Set(AgentDesktopCapability.allCases)
        }
    }

    public var trustMode: ComputerUseTrustMode {
        self == .yolo ? .trusted : .manual
    }

    public var requiresLocalAuthentication: Bool {
        AgentDesktopCapability.requiresLocalAuthentication(capabilities: capabilities, trustMode: trustMode)
    }

    public func matches(capabilities: Set<AgentDesktopCapability>, trustMode: ComputerUseTrustMode) -> Bool {
        capabilities == self.capabilities && trustMode == self.trustMode
    }
}

/// Signed mobile request to grant or revoke desktop tools for one runtime
/// thread. The request itself is intentionally short-lived; the resulting
/// grant has its own 30-minute default expiry.
public struct AgentCapabilityGrantRequest: Codable, Hashable, Identifiable, Sendable {
    public static let defaultGrantDuration: TimeInterval = 30 * 60
    public static let defaultRequestTTL: TimeInterval = 5 * 60

    public let requestID: String
    public let runtimeID: AssistantRuntimeID
    public let threadID: String
    public var preset: AgentPermissionPreset
    public var capabilities: Set<AgentDesktopCapability>
    public var trustMode: ComputerUseTrustMode
    public var deliveryMode: AgentGrantDeliveryMode
    public var requestedAt: Date
    public var expiresAt: Date
    public var grantDurationSeconds: TimeInterval
    public var sourceDeviceID: String
    public var clientIntentID: String
    public var localAuthenticationSatisfied: Bool
    public var localAuthProof: HermesRealtimeRelayAgentGrantLocalAuthProof?

    public var id: String { requestID }

    public init(
        requestID: String = UUID().uuidString,
        runtimeID: AssistantRuntimeID,
        threadID: String,
        preset: AgentPermissionPreset,
        capabilities: Set<AgentDesktopCapability>? = nil,
        trustMode: ComputerUseTrustMode? = nil,
        deliveryMode: AgentGrantDeliveryMode = .liveThenQueued,
        requestedAt: Date = Date(),
        expiresAt: Date? = nil,
        grantDurationSeconds: TimeInterval = AgentCapabilityGrantRequest.defaultGrantDuration,
        sourceDeviceID: String,
        clientIntentID: String = UUID().uuidString,
        localAuthenticationSatisfied: Bool = false,
        localAuthProof: HermesRealtimeRelayAgentGrantLocalAuthProof? = nil
    ) {
        self.requestID = requestID
        self.runtimeID = runtimeID
        self.threadID = threadID
        self.preset = preset
        self.capabilities = capabilities ?? preset.capabilities
        self.trustMode = trustMode ?? preset.trustMode
        self.deliveryMode = deliveryMode
        self.requestedAt = requestedAt
        self.expiresAt = expiresAt ?? requestedAt.addingTimeInterval(Self.defaultRequestTTL)
        self.grantDurationSeconds = grantDurationSeconds
        self.sourceDeviceID = sourceDeviceID
        self.clientIntentID = clientIntentID
        self.localAuthenticationSatisfied = localAuthenticationSatisfied
        self.localAuthProof = localAuthProof
    }

    public func isFresh(now: Date = Date()) -> Bool {
        expiresAt > now
    }

    public func grantExpiresAt(now: Date = Date()) -> Date {
        now.addingTimeInterval(grantDurationSeconds)
    }

    public func makeGrant(workspaceRootPath: String? = nil, now: Date = Date()) -> AgentCapabilityGrant {
        AgentCapabilityGrant.sessionGrant(
            runtimeID: runtimeID,
            threadID: threadID,
            capabilities: capabilities,
            trustMode: trustMode,
            workspaceRootPath: workspaceRootPath,
            sourceDeviceID: sourceDeviceID,
            now: now,
            duration: grantDurationSeconds
        )
    }
}

public struct AgentCapabilityGrantReceipt: Codable, Hashable, Identifiable, Sendable {
    public let receiptID: String
    public let requestID: String
    public let runtimeID: AssistantRuntimeID
    public let threadID: String
    public var status: AgentGrantDecisionStatus
    public var appliedGrantID: String?
    public var capabilities: Set<AgentDesktopCapability>
    public var trustMode: ComputerUseTrustMode
    public var receivedAt: Date
    public var grantExpiresAt: Date?
    public var sourceDeviceID: String?
    public var denialReason: AgentGrantDenialReason?
    public var message: String?

    public var id: String { receiptID }

    public init(
        receiptID: String = UUID().uuidString,
        requestID: String,
        runtimeID: AssistantRuntimeID,
        threadID: String,
        status: AgentGrantDecisionStatus,
        appliedGrantID: String? = nil,
        capabilities: Set<AgentDesktopCapability>,
        trustMode: ComputerUseTrustMode,
        receivedAt: Date = Date(),
        grantExpiresAt: Date? = nil,
        sourceDeviceID: String? = nil,
        denialReason: AgentGrantDenialReason? = nil,
        message: String? = nil
    ) {
        self.receiptID = receiptID
        self.requestID = requestID
        self.runtimeID = runtimeID
        self.threadID = threadID
        self.status = status
        self.appliedGrantID = appliedGrantID
        self.capabilities = capabilities
        self.trustMode = trustMode
        self.receivedAt = receivedAt
        self.grantExpiresAt = grantExpiresAt
        self.sourceDeviceID = sourceDeviceID
        self.denialReason = denialReason
        self.message = message
    }
}

/// Source of truth for the permission toggle shown in chat. The grant is
/// deliberately scoped to a runtime + thread + expiry; it is never sticky
/// across new conversations.
public struct AgentCapabilityGrant: Codable, Hashable, Identifiable, Sendable {
    public let grantID: String
    public let runtimeID: AssistantRuntimeID
    public let threadID: String
    public var capabilities: Set<AgentDesktopCapability>
    public var trustMode: ComputerUseTrustMode
    public var scopeRuleIDs: [String]
    public var expiresAt: Date
    public var status: AgentCapabilityGrantStatus
    public let sourceDeviceID: String?
    public let workspaceRootPath: String?
    public let createdAt: Date

    public var id: String { grantID }

    public init(
        grantID: String = UUID().uuidString,
        runtimeID: AssistantRuntimeID,
        threadID: String,
        capabilities: Set<AgentDesktopCapability>,
        trustMode: ComputerUseTrustMode,
        scopeRuleIDs: [String] = [],
        expiresAt: Date,
        status: AgentCapabilityGrantStatus = .active,
        sourceDeviceID: String? = nil,
        workspaceRootPath: String? = nil,
        createdAt: Date = Date()
    ) {
        self.grantID = grantID
        self.runtimeID = runtimeID
        self.threadID = threadID
        self.capabilities = capabilities
        self.trustMode = trustMode
        self.scopeRuleIDs = scopeRuleIDs
        self.expiresAt = expiresAt
        self.status = status
        self.sourceDeviceID = sourceDeviceID
        self.workspaceRootPath = workspaceRootPath
        self.createdAt = createdAt
    }

    public static func sessionGrant(
        runtimeID: AssistantRuntimeID,
        threadID: String,
        capabilities: Set<AgentDesktopCapability>,
        trustMode: ComputerUseTrustMode = .manual,
        workspaceRootPath: String? = nil,
        sourceDeviceID: String? = nil,
        now: Date = Date(),
        duration: TimeInterval = 30 * 60
    ) -> AgentCapabilityGrant {
        AgentCapabilityGrant(
            runtimeID: runtimeID,
            threadID: threadID,
            capabilities: capabilities,
            trustMode: trustMode,
            expiresAt: now.addingTimeInterval(duration),
            sourceDeviceID: sourceDeviceID,
            workspaceRootPath: workspaceRootPath,
            createdAt: now
        )
    }

    public func isActive(now: Date = Date()) -> Bool {
        status == .active && expiresAt > now && !capabilities.isEmpty
    }

    public func supports(_ capability: AgentDesktopCapability, now: Date = Date()) -> Bool {
        isActive(now: now) && capabilities.contains(capability)
    }

    public func supportsAll(_ required: [AgentDesktopCapability], now: Date = Date()) -> Bool {
        isActive(now: now) && required.allSatisfy { capabilities.contains($0) }
    }

    public func revoked() -> AgentCapabilityGrant {
        var copy = self
        copy.status = .revoked
        return copy
    }
}
