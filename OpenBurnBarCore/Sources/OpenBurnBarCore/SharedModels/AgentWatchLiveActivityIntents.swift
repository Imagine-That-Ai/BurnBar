#if os(iOS)
import AppIntents
import Foundation

public enum AgentWatchLiveActivityCommand: String, Sendable {
    case approve
    case reject
    case halt
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
public struct AgentApproveIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource = "Approve"
    public static var description = IntentDescription("Approve the pending Agent Watch action.")

    public init() {}

    public func perform() async throws -> some IntentResult {
        await AgentWatchLiveActivityIntentRouter.perform(.approve)
        return .result()
    }
}

@available(iOS 17.0, *)
public struct AgentRejectIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource = "Reject"
    public static var description = IntentDescription("Reject the pending Agent Watch action.")

    public init() {}

    public func perform() async throws -> some IntentResult {
        await AgentWatchLiveActivityIntentRouter.perform(.reject)
        return .result()
    }
}

@available(iOS 17.0, *)
public struct AgentHaltIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource = "Halt"
    public static var description = IntentDescription("Halt the live Agent Watch session.")

    public init() {}

    public func perform() async throws -> some IntentResult {
        await AgentWatchLiveActivityIntentRouter.perform(.halt)
        return .result()
    }
}
#endif
