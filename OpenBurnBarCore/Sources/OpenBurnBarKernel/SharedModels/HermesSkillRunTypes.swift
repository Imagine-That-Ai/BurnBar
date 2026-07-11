import Foundation

// MARK: - Hermes Skill Runs
//
// Skill Runs are Hermes-originated mission requests that a phone or tablet can
// preview, dispatch to the Mac, and follow live. These wire values are shared
// by iOS, iPadOS, Android, Firestore rules, and the Hermes skill docs.

public enum HermesSkillRunID: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case whatHappened = "what_happened"
    case burnForensics = "burn_forensics"
    case patternMiner = "pattern_miner"
    case compareAgents = "compare_agents"
    case nextActionCoach = "next_action_coach"
    case handoffBuilder = "handoff_builder"
    case regressionWatch = "regression_watch"
    case runPulse = "run_pulse"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .whatHappened:    return "What Happened?"
        case .burnForensics:   return "Burn Forensics"
        case .patternMiner:    return "Pattern Miner"
        case .compareAgents:   return "Compare Agents"
        case .nextActionCoach: return "Next Action Coach"
        case .handoffBuilder:  return "Handoff Builder"
        case .regressionWatch: return "Regression Watch"
        case .runPulse:        return "Run Pulse"
        }
    }
}

public enum SkillRunDeliveryMode: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    /// Notify only when the user needs to act or the run reaches a terminal result.
    case actionOnly = "action_only"
    /// Show every timeline event on the companion surface as it arrives.
    case fullStream = "full_stream"
    /// Keep the run available in Mission Console without surfacing notifications.
    case muted

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .actionOnly: return "Action alerts"
        case .fullStream: return "Full stream"
        case .muted:      return "Muted"
        }
    }

    public var description: String {
        switch self {
        case .actionOnly:
            return "Only approval prompts and final results interrupt you."
        case .fullStream:
            return "Every status, tool, artifact, and result event appears live."
        case .muted:
            return "No alerts. The full timeline stays in Mission Console."
        }
    }
}

public enum SkillRunEventImportance: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case quiet
    case normal
    case actionRequired = "action_required"
    case terminal

    public var id: String { rawValue }
}
