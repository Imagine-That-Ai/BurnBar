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

struct GrokDAgentRecord: Identifiable, Equatable, Sendable, Decodable {
    let id: String
    let name: String
    let isRunning: Bool
    let isComposingMessage: Bool

    var isBusy: Bool { isRunning || isComposingMessage }

    enum CodingKeys: String, CodingKey {
        case id, name, isRunning, isComposingMessage
    }

    init(id: String, name: String, isRunning: Bool, isComposingMessage: Bool) {
        self.id = id
        self.name = name
        self.isRunning = isRunning
        self.isComposingMessage = isComposingMessage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        isRunning = try c.decodeIfPresent(Bool.self, forKey: .isRunning) ?? false
        isComposingMessage = try c.decodeIfPresent(Bool.self, forKey: .isComposingMessage) ?? false
    }
}

struct GrokDTurnHandle: Equatable, Sendable {
    let agentID: String
    let prompt: String
    let acceptedAt: Date
}

enum GrokDHostError: Error, Equatable {
    case sendRefused(GrokDBoxHealth)
    case invalidAgentID
    case agentBusy(id: String)
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
        case .agentBusy:
            return "That agent is already running a turn."
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
