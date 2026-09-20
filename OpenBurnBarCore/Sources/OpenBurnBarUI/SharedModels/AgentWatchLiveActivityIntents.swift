#if os(iOS)
import AppIntents
import Foundation

public enum AgentWatchLiveActivityCommand: Equatable, Sendable {
    case approve(approvalId: String)
    case reject(approvalId: String)
    case halt
}

/// Maps a lock-screen intent onto the overlay receiver. Missing receiver or
/// approval waits; a different approval id is dropped. It does not invent
/// a second control plane.
public enum AgentWatchLiveActivityCommandRouting {
    public enum Effect: Equatable, Sendable {
        case approve
        case reject
        case halt
        case dropMissingReceiver
        case waitingForApproval
        case dropMismatchedApproval
        case dropMissingApproval
    }

    public static func effect(
        for command: AgentWatchLiveActivityCommand,
        hasReceiver: Bool,
        pendingApprovalId: String?
    ) -> Effect {
        guard hasReceiver else { return .dropMissingReceiver }
        switch command {
        case .approve(let approvalId):
            return decisionEffect(issuedApprovalId: approvalId, pendingApprovalId: pendingApprovalId, apply: .approve)
        case .reject(let approvalId):
            return decisionEffect(issuedApprovalId: approvalId, pendingApprovalId: pendingApprovalId, apply: .reject)
        case .halt:
            return .halt
        }
    }

    /// Halt and same-id Approve/Deny wait for iroh / the request frame.
    /// A different approval id is dropped so it cannot attach later.
    public static func retainsQueuedCommand(_ effect: Effect) -> Bool {
        switch effect {
        case .dropMissingReceiver, .waitingForApproval:
            return true
        case .approve, .reject, .halt, .dropMismatchedApproval, .dropMissingApproval:
            return false
        }
    }

    private static func decisionEffect(
        issuedApprovalId: String,
        pendingApprovalId: String?,
        apply: Effect
    ) -> Effect {
        let issued = issuedApprovalId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !issued.isEmpty else { return .dropMissingApproval }
        guard let pending = pendingApprovalId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !pending.isEmpty
        else {
            return .waitingForApproval
        }
        return pending == issued ? apply : .dropMismatchedApproval
    }
}

@MainActor
public enum AgentWatchLiveActivityIntentRouter {
    public typealias Handler = @MainActor (AgentWatchLiveActivityCommand) async -> Void
    private static var handler: Handler?
    private static var pendingCommands: [AgentWatchLiveActivityCommand] = []
    private static var isDraining = false

    public static func perform(_ command: AgentWatchLiveActivityCommand) async {
        guard let handler, !isDraining else {
            pendingCommands.append(command)
            drainPendingIfNeeded()
            return
        }
        await handler(command)
    }

    public static func install(_ handler: @escaping Handler) {
        self.handler = handler
        drainPendingIfNeeded()
    }

    private static func drainPendingIfNeeded() {
        guard !isDraining, handler != nil, !pendingCommands.isEmpty else { return }
        isDraining = true

        Task { @MainActor in
            while !pendingCommands.isEmpty {
                let command = pendingCommands.removeFirst()
                if let handler {
                    await handler(command)
                }
            }
            isDraining = false
        }
    }

    #if DEBUG
    public static func resetForTesting() {
        handler = nil
        pendingCommands.removeAll()
        isDraining = false
    }
    #endif
}

@available(iOS 17.0, *)
public enum AgentWatchLiveActivityIntentSecurity {
    public static let decisionAuthenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    public static let panicAuthenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    public static let isDiscoverable = false

    /// Lock-screen buttons must run without opening the app.
    /// iOS 26 deprecates `openAppWhenRun` in favor of `supportedModes`.
    @available(iOS 26.0, *)
    public static let supportedModes: IntentModes = .background
}

@available(iOS 17.0, *)
public struct AgentApproveIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "Approve"
    public static let description = IntentDescription("Approve the pending Agent Watch action.")
    public static var authenticationPolicy: IntentAuthenticationPolicy {
        AgentWatchLiveActivityIntentSecurity.decisionAuthenticationPolicy
    }
    public static var isDiscoverable: Bool {
        AgentWatchLiveActivityIntentSecurity.isDiscoverable
    }
    @available(iOS 26.0, *)
    public static var supportedModes: IntentModes {
        AgentWatchLiveActivityIntentSecurity.supportedModes
    }

    @Parameter(title: "Approval")
    public var approvalId: String

    public init() {
        self.approvalId = ""
    }

    public init(approvalId: String) {
        self.approvalId = approvalId
    }

    public func perform() async throws -> some IntentResult {
        let trimmed = approvalId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .result() }
        await AgentWatchLiveActivityIntentRouter.perform(.approve(approvalId: trimmed))
        return .result()
    }
}

@available(iOS 17.0, *)
public struct AgentRejectIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "Deny"
    public static let description = IntentDescription("Deny the pending Agent Watch action.")
    public static var authenticationPolicy: IntentAuthenticationPolicy {
        AgentWatchLiveActivityIntentSecurity.decisionAuthenticationPolicy
    }
    public static var isDiscoverable: Bool {
        AgentWatchLiveActivityIntentSecurity.isDiscoverable
    }
    @available(iOS 26.0, *)
    public static var supportedModes: IntentModes {
        AgentWatchLiveActivityIntentSecurity.supportedModes
    }

    @Parameter(title: "Approval")
    public var approvalId: String

    public init() {
        self.approvalId = ""
    }

    public init(approvalId: String) {
        self.approvalId = approvalId
    }

    public func perform() async throws -> some IntentResult {
        let trimmed = approvalId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .result() }
        await AgentWatchLiveActivityIntentRouter.perform(.reject(approvalId: trimmed))
        return .result()
    }
}

@available(iOS 17.0, *)
public typealias AgentDenyIntent = AgentRejectIntent

@available(iOS 17.0, *)
public struct AgentHaltIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "Halt"
    public static let description = IntentDescription("Halt the live Agent Watch session.")
    public static var authenticationPolicy: IntentAuthenticationPolicy {
        AgentWatchLiveActivityIntentSecurity.panicAuthenticationPolicy
    }
    public static var isDiscoverable: Bool {
        AgentWatchLiveActivityIntentSecurity.isDiscoverable
    }
    @available(iOS 26.0, *)
    public static var supportedModes: IntentModes {
        AgentWatchLiveActivityIntentSecurity.supportedModes
    }

    public init() {}

    public func perform() async throws -> some IntentResult {
        await AgentWatchLiveActivityIntentRouter.perform(.halt)
        return .result()
    }
}
#endif
