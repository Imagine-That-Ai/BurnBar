import Foundation

/// Live Local D box health. Port probes are on `127.0.0.1` only.
/// `listAgents` 200 is not sufficient: the shim answers from disk when `:1338` is down.
enum GrokDBoxHealth: String, Equatable, Sendable {
    /// `:1337` is down, or listAgents fails while `:1338` is also down.
    case cannotList
    /// Shim can list from disk, but the host on `:1338` is not listening. Send is refused.
    case canListHostDown
    /// Host is up but inference proxy `:8787` is down. Send is refused.
    case canListCannotComplete
    /// `:1337`, `:1338`, and `:8787` listen and `listAgents` returns 200 via the shim.
    case ok

    var allowsSend: Bool { self == .ok }

    var userMessage: String {
        switch self {
        case .cannotList:
            return "Local D box is not reachable."
        case .canListHostDown:
            return "local box host is down"
        case .canListCannotComplete:
            return "inference proxy is down"
        case .ok:
            return "Local D box is ready."
        }
    }
}

enum GrokDStatusTone: String, Equatable, Sendable {
    case info
    case success
    case warning
    case error
}

/// Settings pane phase so Off / Listing / Ready / refused / Sent / landed / Done stay distinct.
enum GrokDBoxPhase: String, Equatable, Sendable {
    case off
    case listing
    case ready
    case refused
    case sent
    case userLanded
    case assistantDone
    case stillRunning

    var chipTitle: String {
        switch self {
        case .off: return "Off"
        case .listing: return "Listing"
        case .ready: return "Ready"
        case .refused: return "Unavailable"
        case .sent: return "Sent"
        case .userLanded: return "Prompt landed"
        case .assistantDone: return "Done"
        case .stillRunning: return "Still running"
        }
    }
}

struct GrokDAgentRecord: Identifiable, Equatable, Sendable, Decodable {
    let id: String
    let name: String
    let isRunning: Bool
    let isComposingMessage: Bool
    let lastMessagePreview: String?
    /// Absolute path to this agent's `store.db` when the host includes it.
    let path: String?

    var isBusy: Bool { isRunning || isComposingMessage }

    enum CodingKeys: String, CodingKey {
        case id, name, isRunning, isComposingMessage, lastMessagePreview, path
    }

    init(
        id: String,
        name: String,
        isRunning: Bool,
        isComposingMessage: Bool,
        lastMessagePreview: String? = nil,
        path: String? = nil
    ) {
        self.id = id
        self.name = name
        self.isRunning = isRunning
        self.isComposingMessage = isComposingMessage
        self.lastMessagePreview = lastMessagePreview
        self.path = path
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        isRunning = try c.decodeIfPresent(Bool.self, forKey: .isRunning) ?? false
        isComposingMessage = try c.decodeIfPresent(Bool.self, forKey: .isComposingMessage) ?? false
        lastMessagePreview = try c.decodeIfPresent(String.self, forKey: .lastMessagePreview)
        path = try c.decodeIfPresent(String.self, forKey: .path)
    }
}

struct GrokDTurnHandle: Equatable, Sendable {
    let agentID: String
    let prompt: String
    let acceptedAt: Date
    /// `MAX(rowid)` of `store.db` immediately before `sendPrompt`. Follow only
    /// classifies newer rows so a repeated prompt cannot complete on history.
    /// `unknownWatermark` means the snapshot failed; sqlite follow is skipped.
    let afterRowID: Int64

    static let unknownWatermark: Int64 = -1
}

struct GrokDTurnFollowResult: Equatable, Sendable {
    enum Outcome: String, Equatable, Sendable {
        case completed
        case promptLandedNoReply
        case stillRunning
        case agentMissing
        case cancelled
    }

    let outcome: Outcome
    let lastPreview: String?

    var userMessage: String {
        switch outcome {
        case .completed:
            return "Turn completed."
        case .promptLandedNoReply:
            return "Prompt landed; no assistant reply yet."
        case .stillRunning:
            return "Turn still running. Refresh to check."
        case .agentMissing:
            return "That agent disappeared from the live roster."
        case .cancelled:
            return "Turn follow cancelled."
        }
    }

    var tone: GrokDStatusTone {
        switch outcome {
        case .completed:
            return .success
        case .promptLandedNoReply, .stillRunning:
            return .warning
        case .agentMissing:
            return .error
        case .cancelled:
            return .info
        }
    }
}

enum GrokDHostError: Error, Equatable, Sendable {
    case sendRefused(GrokDBoxHealth)
    case invalidAgentID
    case emptyPrompt
    case unknownAgent(id: String)
    case agentBusy(id: String)
    case missingActiveEnv
    case missingToken
    case notLoopback
    case httpStatus(Int)
    case decoding
    case transport(String)

    var userMessage: String {
        switch self {
        case .sendRefused(let health):
            return health.userMessage
        case .invalidAgentID:
            return "Agent id must be a UUID."
        case .emptyPrompt:
            return "Prompt is empty."
        case .unknownAgent:
            return "That agent is not on the live roster."
        case .agentBusy:
            return "That agent is already running a turn."
        case .missingActiveEnv:
            return "Local D box is not configured."
        case .missingToken:
            return "Local D box token is missing from active-env.json."
        case .notLoopback:
            return "Local D box is loopback-only."
        case .httpStatus(let code):
            return "Local D box HTTP \(code)."
        case .decoding:
            return "Local D box returned an unexpected payload."
        case .transport:
            return "Local D box transport failed."
        }
    }
}
