import Foundation

// MARK: - Chat Mode

/// The chat panel's mode (M4). The orchestrator channel is a chat MODE in the
/// existing panel — not a parallel messenger: both modes share the same input
/// box, streaming placeholder, history thread, and message list (VAL-ORCH-006).
///
/// The mode is persisted PER THREAD (VAL-ORCH-024): switching modes mid-thread
/// keeps the history intact, applies the new mode's prompt only to
/// post-switch messages, and the per-thread mode survives app relaunch.
enum ChatMode: String, Codable, CaseIterable, Sendable {
    /// BurnBar's local data analyst persona (the pre-existing chat behavior).
    case analyst
    /// The fleet orchestrator channel: answers are generated via CLIBridge
    /// with the scoped orchestrator prompt + fleet-snapshot context.
    case orchestrator

    /// UserDefaults key for the per-thread mode. Keyed by thread id so each
    /// history thread remembers its own mode (VAL-ORCH-024).
    static func defaultsKey(threadID: String) -> String {
        "chatThreadMode_\(threadID)"
    }

    /// Loads the persisted mode for a thread (defaults to `.analyst`).
    static func persistedMode(threadID: String) -> ChatMode {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey(threadID: threadID)) else {
            return .analyst
        }
        return ChatMode(rawValue: raw) ?? .analyst
    }

    /// Persists the mode for a thread.
    static func persist(_ mode: ChatMode, threadID: String) {
        UserDefaults.standard.set(mode.rawValue, forKey: defaultsKey(threadID: threadID))
    }

    /// Short label for the mode picker.
    var label: String {
        switch self {
        case .analyst:
            return "Analyst"
        case .orchestrator:
            return "Orchestrator"
        }
    }

    /// SF Symbol for the mode picker.
    var iconName: String {
        switch self {
        case .analyst:
            return "sparkles"
        case .orchestrator:
            return "network"
        }
    }
}
