import Foundation

// MARK: - Managed Agent Runtime Kind

/// Identity of a managed agent runtime adapter. Used by Settings UI,
/// `ChatEngineBackendStrip`, and the shared runtime gate to address a specific
/// adapter without leaking CLI-specific knowledge.
enum ManagedAgentRuntimeKind: String, Hashable, CaseIterable, Sendable {
    case hermes
    case piAgent

    var displayName: String {
        switch self {
        case .hermes: return "Hermes"
        case .piAgent: return "Pi Agent"
        }
    }

    /// Default gateway base URL the adapter listens on if the user has not
    /// configured a custom endpoint.
    var defaultGatewayBaseURL: URL {
        switch self {
        case .hermes: return URL(string: "http://127.0.0.1:8642")!
        case .piAgent: return URL(string: "http://127.0.0.1:8765")!
        }
    }

    /// Open-action button copy. Mirrors the Hermes Settings affordance so the
    /// Pi runtime card reads as a sibling, not a different feature.
    var openActionLabel: String {
        switch self {
        case .hermes: return "Open Hermes + Gateway"
        case .piAgent: return "Open Pi + Gateway"
        }
    }
}

// MARK: - Managed Agent Runtime Status

/// Snapshot describing the live state of a managed agent runtime. The shape is
/// generic across Hermes and Pi so the Settings card UI and the runtime gate
/// can render either without branching on adapter kind.
struct ManagedAgentRuntimeStatus: Equatable, Sendable {
    /// Absolute path to the resolved CLI executable, when found.
    var executablePath: String?
    /// Whether the adapter's OpenAI-compatible gateway responds on `/v1/models`.
    var gatewayRunning: Bool = false
    /// Whether the adapter's companion app/process (Hermes Dashboard, Pi app)
    /// is currently running. For Pi this reflects the active instance launcher.
    var appRunning: Bool = false
    /// Model name reported by the gateway, if available.
    var modelName: String?
    /// Free-form Redis status string. Empty until probed.
    var redisStatus: String?
    /// Currently selected instance identifier, when known.
    var selectedInstanceID: String?
    /// Known instances discovered through gateway or Redis.
    var instances: [ManagedAgentInstance] = []
    /// Operator-facing message suitable for the Settings card body.
    var message: String = ""

    /// True when chat can route through this runtime right now: CLI resolved
    /// and the gateway is up. Redis is optional, never required.
    var isReady: Bool {
        executablePath != nil && gatewayRunning
    }
}

// MARK: - Managed Agent Instance

/// Lightweight per-instance descriptor surfaced to the Settings UI. Hermes
/// always exposes exactly one synthetic instance ("default"); Pi may expose
/// many when Redis discovery is wired up.
struct ManagedAgentInstance: Equatable, Identifiable, Hashable, Sendable {
    let id: String
    var displayName: String
    var isOnline: Bool
    var activeSessionID: String?
    var gatewayBaseURL: URL?

    init(
        id: String,
        displayName: String,
        isOnline: Bool = true,
        activeSessionID: String? = nil,
        gatewayBaseURL: URL? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.isOnline = isOnline
        self.activeSessionID = activeSessionID
        self.gatewayBaseURL = gatewayBaseURL
    }
}

// MARK: - Managed Agent Runtime Adapter Protocol

/// Adapter contract every managed runtime implements. Implementations should
/// be cheap to construct because Settings and the runtime gate instantiate
/// them inside SwiftUI `@State`.
///
/// Method names use the `managed` prefix so adapter-specific entry points
/// (e.g. `HermesRuntimeLauncher.refreshStatus` returning
/// `HermesRuntimeStatus`) can coexist without overload-resolution ambiguity.
@MainActor
protocol ManagedAgentRuntimeAdapter: AnyObject {
    var kind: ManagedAgentRuntimeKind { get }
    var managedStatus: ManagedAgentRuntimeStatus { get }
    var isBusy: Bool { get }
    var lastError: String? { get }

    /// Read the runtime state without mutating processes. Safe to call from
    /// task contexts during app launch and Settings refresh.
    @discardableResult
    func refreshManagedStatus(
        baseURL: URL,
        bearerToken: String?
    ) async -> ManagedAgentRuntimeStatus

    /// Mutating call: ensure the gateway is up, ensure the companion
    /// app/instance is running, then probe and return the resulting status.
    @discardableResult
    func openManagedRuntime(
        baseURL: URL,
        bearerToken: String?
    ) async -> ManagedAgentRuntimeStatus
}
