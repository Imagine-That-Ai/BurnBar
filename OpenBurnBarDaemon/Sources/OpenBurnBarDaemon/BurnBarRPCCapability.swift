import Foundation
import OpenBurnBarCore

/// T-DMN-01 — per-operation capability attenuation for the main control socket.
///
/// Threat model this closes: today every peer that satisfies the first-party
/// code-signature gate (RR-3 / `BurnBarDaemonPeerAuthenticator`) AND knows the
/// socket bearer token may invoke EVERY RPC method — the full run-dispatch,
/// config-write, connector, and computer-use/HID surface. So a single compromised
/// first-party process inherits the daemon's entire agency from a code-sign
/// identity alone.
///
/// Capability attenuation breaks that: each method belongs to exactly one
/// capability group, and a peer/session is scoped to the minimum set of groups it
/// needs. A peer that only needs read-only catalog/usage data is admitted for
/// those groups and refused — fail closed — the moment it reaches for run
/// dispatch, a config write, or the computer-use/HID surface. The bearer token +
/// code signature still authenticate WHO is connecting; the capability set bounds
/// WHAT they may do.
public enum BurnBarRPCCapability: String, CaseIterable, Hashable, Sendable, Codable {
    /// Lifecycle + read-only catalog/health. Safe for every authenticated peer.
    case lifecycle
    /// Provider/connector credential + config writes (mutate stored secrets).
    case config
    /// Usage + proxy-route observability reads/writes.
    case observability
    /// Connector-plane + browser tooling actions.
    case tooling
    /// Computer-use / HID-adjacent agency (session start, invoke, approvals,
    /// panic-halt, audit export). The highest-risk group.
    case computerUse = "computer_use"
    /// Mission-control + controller surface (missions, questions, followups,
    /// notifications, simulator).
    case missionControl = "mission_control"
    /// Client attach/claim/detach handshakes.
    case client
    /// Run lifecycle + workspace tool execution + approvals.
    case run
    /// Indexed search queries.
    case search

    /// The single capability group that gates `method`. Every method maps to
    /// exactly one group so the attenuation set is total and unambiguous — a new
    /// RPC method that is not classified here will fail to compile this switch.
    public static func capability(for method: BurnBarRPCMethod) -> BurnBarRPCCapability {
        switch method {
        case .health, .catalog, .authBootstrap:
            return .lifecycle
        case .configGet, .configUpdate,
             .providerCredentialSlotUpsert, .providerCredentialSlotRemove,
             .providerModelVariantUpsert, .providerModelVariantRemove,
             .providerModelAliasUpsert, .providerModelAliasRemove,
             .providerModelDisplayNameSet, .providerModelDisplayNameClear:
            return .config
        case .usageRecord, .usageRecent,
             .proxyRouteLogRecent, .proxyRouteLogClear:
            return .observability
        case .connectorPlaneGet, .connectorConfigUpdate, .connectorAction,
             .browserToolingGet, .browserToolingUpdate, .browserAction:
            return .tooling
        case .computerUseSessionStart, .computerUseInvoke,
             .computerUseApprovalPending, .computerUseApprovalRespond,
             .computerUsePanicHalt, .computerUseAuditExport:
            return .computerUse
        case .controllerSummary, .controllerRuntimeSnapshot,
             .controllerProjectsList, .controllerProjectGet,
             .controllerProjectUpsert, .reviewRunRecord,
             .questionCreate, .questionGet, .questionsList, .questionAnswer,
             .followupCreate, .followupsList, .followupDone, .followupSnooze, .followupCalendar,
             .missionCreate, .missionsList, .missionGet, .missionApprove, .missionCancel,
             .missionDispatchPacket, .missionRecordResult,
             .notificationConfigGet, .notificationConfigUpdate, .notificationHealth, .notificationCommand,
             .simulatorRun, .simulatorList, .simulatorReplay, .projectionRebuild:
            return .missionControl
        case .clientAttach, .clientClaimControl, .clientDetach:
            return .client
        case .runCreate, .runList, .runGet, .runPoll, .runCancel, .runRetry, .runResume,
             .workspaceExecuteTool, .workspaceToolResult, .approvalRespond:
            return .run
        case .searchQuery:
            return .search
        }
    }
}

/// The attenuated capability set a peer/session is scoped to. The control-socket
/// server consults this before dispatching any RPC and refuses (fail closed) any
/// method whose capability is not in the set.
public struct BurnBarPeerCapabilityProfile: Hashable, Sendable, Codable {
    public let capabilities: Set<BurnBarRPCCapability>

    public init(capabilities: Set<BurnBarRPCCapability>) {
        self.capabilities = capabilities
    }

    /// Whether `method` is permitted under this profile.
    public func permits(_ method: BurnBarRPCMethod) -> Bool {
        capabilities.contains(BurnBarRPCCapability.capability(for: method))
    }

    /// Full agency — every capability group. This is the BACKWARD-COMPATIBLE
    /// default the daemon wires for the trusted first-party controller app so
    /// existing behavior is preserved (no method is newly refused) unless a
    /// caller deliberately requests an attenuated profile. New, less-trusted
    /// session types should request the minimum profile they need instead.
    public static let full = BurnBarPeerCapabilityProfile(
        capabilities: Set(BurnBarRPCCapability.allCases)
    )

    /// Read-only posture: lifecycle + read observability + search. No config
    /// writes, no run dispatch, no computer-use/HID agency.
    public static let readOnly = BurnBarPeerCapabilityProfile(
        capabilities: [.lifecycle, .observability, .search]
    )

    /// A controller that drives runs but is denied the computer-use/HID surface
    /// and config-credential writes — the minimum a chat/run client needs.
    public static let runClient = BurnBarPeerCapabilityProfile(
        capabilities: [.lifecycle, .client, .run, .tooling, .observability, .search, .missionControl]
    )

    /// Intersect with `other` so a peer can only ever be FURTHER attenuated,
    /// never widened. Useful when layering a session scope on top of a peer scope.
    public func attenuated(to other: BurnBarPeerCapabilityProfile) -> BurnBarPeerCapabilityProfile {
        BurnBarPeerCapabilityProfile(capabilities: capabilities.intersection(other.capabilities))
    }
}
