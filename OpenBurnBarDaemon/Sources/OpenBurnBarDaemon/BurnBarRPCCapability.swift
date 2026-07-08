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
    /// Local membership cache reads plus Stripe checkout/restore handoff.
    case membership
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
    /// Project-scoped durable memory reads.
    case memoryRead = "memory_read"
    /// Project-scoped durable memory writes.
    case memoryWrite = "memory_write"
    /// Project code search/symbol graph reads.
    case codeRead = "code_read"
    /// Project code indexing writes.
    case codeWrite = "code_write"
    /// Operator-only code-store diagnostics (schema version, store sizes, forget
    /// backlog). Excluded from the readOnly/runClient profiles so only the trusted
    /// first-party controller can inspect store internals.
    case codeOperator = "code_operator"

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
             .providerCustomModelUpsert, .providerCustomModelRemove,
             .providerModelDisplayNameSet, .providerModelDisplayNameClear:
            return .config
        case .usageRecord, .usageRecent,
             .proxyRouteLogRecent, .proxyRouteLogClear, .perfMeasure:
            return .observability
        case .membershipStatus, .membershipCheckoutURL, .membershipRestore:
            return .membership
        case .connectorPlaneGet, .connectorConfigUpdate, .connectorAction,
             .browserToolingGet, .browserToolingUpdate, .browserAction:
            return .tooling
        case .computerUseSessionStart, .computerUseInvoke,
             .computerUseApprovalPending, .computerUseApprovalRespond,
             .computerUsePanicHalt, .computerUseAuditExport:
            return .computerUse
        case .phoneControlPinProvision:
            // T-DMN-04: provisioning mutates daemon trust state; classify with
            // config-credential writes so only a fully-trusted first-party peer
            // can pin a phone key.
            return .config
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
             .subscriptionStart, .subscriptionResume,
             .workspaceExecuteTool, .workspaceToolResult, .approvalRespond:
            return .run
        case .searchQuery:
            return .search
        case .memoryRemember, .memoryForget:
            return .memoryWrite
        case .memoryRecall, .memoryAuditTrail, .memoryAnalytics:
            return .memoryRead
        case .codeIndexProject, .codeWatchProject:
            return .codeWrite
        case .codeSearch, .codeContextPack, .codeGetSymbol, .codeFindReferences,
             .codeCallGraph, .codeDiagnostics, .codeIndexStatus, .codeExplore:
            return .codeRead
        case .codeOpsDiagnostics:
            return .codeOperator
        }
    }
}

/// The attenuated capability set a peer/session is scoped to. The control-socket
/// server consults this before dispatching any RPC and refuses (fail closed) any
/// method whose capability is not in the set.
public struct BurnBarPeerCapabilityProfile: Hashable, Sendable, Codable {
    public let capabilities: Set<BurnBarRPCCapability>
    public let allowedMethods: Set<BurnBarRPCMethod>?

    public init(
        capabilities: Set<BurnBarRPCCapability>,
        allowedMethods: Set<BurnBarRPCMethod>? = nil
    ) {
        self.capabilities = capabilities
        self.allowedMethods = allowedMethods
    }

    /// Whether `method` is permitted under this profile.
    public func permits(_ method: BurnBarRPCMethod) -> Bool {
        if let allowedMethods {
            return allowedMethods.contains(method)
        }
        return capabilities.contains(BurnBarRPCCapability.capability(for: method))
    }

    /// Method-level view of this profile. Capability-scoped profiles expand to
    /// all methods in their capability groups; method-scoped profiles stay exact.
    public var permittedMethods: Set<BurnBarRPCMethod> {
        Set(BurnBarRPCMethod.allCases.filter(permits))
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
        capabilities: [.lifecycle, .observability, .membership, .search, .memoryRead, .codeRead]
    )

    /// A controller that drives runs but is denied the computer-use/HID surface
    /// and config-credential writes — the minimum a chat/run client needs.
    public static let runClient = BurnBarPeerCapabilityProfile(
        capabilities: [.lifecycle, .client, .run, .tooling, .observability, .membership, .search, .missionControl, .memoryRead, .codeRead]
    )

    /// Signed CLI support posture. Keep this as an exact method allowlist, not
    /// coarse capability groups: the CLI needs `run.resume`, for example, but
    /// must not inherit the rest of the workspace tool/run-dispatch surface.
    public static let cliSupport = methodScoped([
        .health,
        .controllerSummary,
        .questionsList,
        .followupsList,
        .missionsList,
        .missionApprove,
        .simulatorList,
        .simulatorReplay,
        .memoryRecall,
        .codeIndexProject,
        .codeWatchProject,
        .codeSearch,
        .codeIndexStatus,
        .runCreate,
        .runResume
    ])

    /// Intersect with `other` so a peer can only ever be FURTHER attenuated,
    /// never widened. Useful when layering a session scope on top of a peer scope.
    public func attenuated(to other: BurnBarPeerCapabilityProfile) -> BurnBarPeerCapabilityProfile {
        Self.methodScoped(permittedMethods.intersection(other.permittedMethods))
    }

    private static func methodScoped(_ methods: Set<BurnBarRPCMethod>) -> BurnBarPeerCapabilityProfile {
        BurnBarPeerCapabilityProfile(
            capabilities: Set(methods.map { BurnBarRPCCapability.capability(for: $0) }),
            allowedMethods: methods
        )
    }
}
