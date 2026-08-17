import Foundation

/// Local chat-open modes Fleet can request. Shipping chat does not yet have a
/// dedicated orchestrator workspace, so this stays Fleet-owned.
enum FleetChatMode: Equatable {
    case orchestrator
}

// MARK: - Fleet chat open policy

/// Decision table for Fleet → chat. Isolated so consent continuation can
/// be asserted without standing up DashboardView.
enum FleetChatOpenDecision: Equatable {
    case showConsent
    case present(mode: FleetChatMode?)
}

enum FleetChatConsentContinuation: Equatable {
    case presentOrchestrator
    case dismiss
}

enum FleetChatOpenPolicy {
    static func decision(consentShown: Bool, requestedMode: FleetChatMode?) -> FleetChatOpenDecision {
        if requestedMode == .orchestrator, !consentShown {
            return .showConsent
        }
        return .present(mode: requestedMode)
    }

    static func afterConsent(pendingOrchestrator: Bool, allowed: Bool) -> FleetChatConsentContinuation {
        guard pendingOrchestrator else { return .dismiss }
        return allowed ? .presentOrchestrator : .dismiss
    }
}
