import Foundation

// MARK: - Voice Command Contracts (Hermes Square §6.7)
//
// Cross-platform shapes for the hold-to-talk voice surface. Pure-logic
// intent resolver lives here so iOS / Android share the same intent
// taxonomy and routing logic.

public enum VoiceIntent: Codable, Sendable, Hashable, Equatable {
    /// Speak straight into the current thread.
    case sendMessageToCurrentThread(text: String)
    /// Open the named agent's brand zone or thread.
    case openAgent(agentURI: String)
    /// Dispatch a new mission (`prompt`) to a runtime hint (or auto).
    case dispatchMission(prompt: String, runtimeHint: String?)
    /// Search the federated index.
    case search(query: String)
    /// Ambient briefing — "what's important?"
    case ambientBriefing
    /// Could not classify; fall back to chat with Hermes.
    case fallbackToHermes(text: String)

    public var displayLabel: String {
        switch self {
        case .sendMessageToCurrentThread:  return "Reply to current thread"
        case .openAgent:                   return "Open agent"
        case .dispatchMission:             return "Dispatch mission"
        case .search:                      return "Search"
        case .ambientBriefing:             return "Ambient briefing"
        case .fallbackToHermes:            return "Ask Hermes"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, text, agentURI, prompt, runtimeHint, query
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "sendMessageToCurrentThread":
            self = .sendMessageToCurrentThread(text: try c.decode(String.self, forKey: .text))
        case "openAgent":
            self = .openAgent(agentURI: try c.decode(String.self, forKey: .agentURI))
        case "dispatchMission":
            self = .dispatchMission(
                prompt: try c.decode(String.self, forKey: .prompt),
                runtimeHint: try? c.decode(String.self, forKey: .runtimeHint)
            )
        case "search":
            self = .search(query: try c.decode(String.self, forKey: .query))
        case "ambientBriefing":
            self = .ambientBriefing
        case "fallbackToHermes":
            self = .fallbackToHermes(text: try c.decode(String.self, forKey: .text))
        default:
            self = .fallbackToHermes(text: "")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .sendMessageToCurrentThread(let text):
            try c.encode("sendMessageToCurrentThread", forKey: .kind)
            try c.encode(text, forKey: .text)
        case .openAgent(let uri):
            try c.encode("openAgent", forKey: .kind)
            try c.encode(uri, forKey: .agentURI)
        case .dispatchMission(let prompt, let hint):
            try c.encode("dispatchMission", forKey: .kind)
            try c.encode(prompt, forKey: .prompt)
            try c.encodeIfPresent(hint, forKey: .runtimeHint)
        case .search(let query):
            try c.encode("search", forKey: .kind)
            try c.encode(query, forKey: .query)
        case .ambientBriefing:
            try c.encode("ambientBriefing", forKey: .kind)
        case .fallbackToHermes(let text):
            try c.encode("fallbackToHermes", forKey: .kind)
            try c.encode(text, forKey: .text)
        }
    }
}

// MARK: - Resolver

/// Pure-logic intent resolver. Takes a transcript string + a list of
/// known agent identities, returns the best intent classification.
/// Deliberately rule-based for Phase D — no LLM dependency. Cheap to
/// run, easy to test, falls back to chatting with Hermes when ambiguous.
public enum VoiceIntentResolver {

    /// Resolve `transcript` against a current registry. The `currentThreadAgentURI`
    /// hints at which agent the user is currently chatting with; when present
    /// and the transcript doesn't match another intent, the resolver assumes
    /// the user wants to reply in that thread.
    public static func resolve(
        transcript: String,
        installedAgentNames: [String: String], // displayName lowercase → URI
        currentThreadAgentURI: String? = nil
    ) -> VoiceIntent {
        let cleaned = transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return .fallbackToHermes(text: "") }
        let lower = cleaned.lowercased()

        // Ambient briefing — high-precedence single phrases.
        let ambientPhrases = [
            "what's important", "whats important", "what is important",
            "give me the briefing", "ambient briefing", "what's new", "whats new"
        ]
        if ambientPhrases.contains(where: { lower.contains($0) }) {
            return .ambientBriefing
        }

        // Search — "search for X", "find X".
        if let searchPrefix = ["search for ", "search ", "find me ", "find "].first(where: { lower.hasPrefix($0) }) {
            let query = cleaned.dropFirst(searchPrefix.count)
            return .search(query: String(query).trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // Open agent — "open Claude", "show me Codex".
        let openPrefixes = ["open ", "show me ", "switch to "]
        for prefix in openPrefixes {
            if lower.hasPrefix(prefix) {
                let nameRaw = cleaned.dropFirst(prefix.count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let uri = installedAgentNames[nameRaw.lowercased()] {
                    return .openAgent(agentURI: uri)
                }
            }
        }

        // Dispatch mission — "dispatch X to Claude", "have Codex run X".
        let dispatchPatterns: [(prefix: String, separator: String?)] = [
            (prefix: "dispatch ", separator: " to "),
            (prefix: "have ", separator: " run "),
            (prefix: "ask ", separator: " to ")
        ]
        for pattern in dispatchPatterns {
            if lower.hasPrefix(pattern.prefix), let sep = pattern.separator,
               let sepRange = lower.range(of: sep, range: lower.index(lower.startIndex, offsetBy: pattern.prefix.count)..<lower.endIndex) {
                let afterPrefix = cleaned.index(cleaned.startIndex, offsetBy: pattern.prefix.count)
                let sepStart = cleaned.index(cleaned.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: sepRange.lowerBound))
                let sepEnd = cleaned.index(cleaned.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: sepRange.upperBound))
                let first = String(cleaned[afterPrefix..<sepStart]).trimmingCharacters(in: .whitespacesAndNewlines)
                let second = String(cleaned[sepEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if pattern.prefix == "dispatch " {
                    let hint = installedAgentNames[second.lowercased()] ?? second.lowercased()
                    return .dispatchMission(prompt: first, runtimeHint: hint)
                } else {
                    // "have Codex run X" / "ask Codex to X"
                    let hint = installedAgentNames[first.lowercased()] ?? first.lowercased()
                    return .dispatchMission(prompt: second, runtimeHint: hint)
                }
            }
        }

        // Default: if we're in a thread, reply in it; otherwise fall through to Hermes.
        if let agentURI = currentThreadAgentURI {
            _ = agentURI
            return .sendMessageToCurrentThread(text: cleaned)
        }
        return .fallbackToHermes(text: cleaned)
    }
}
