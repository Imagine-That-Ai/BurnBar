import Foundation

// MARK: - PetChatFallback

/// The deterministic, dependency-free chat floor for the desktop companion
/// (PLAN C6). A faithful Swift port of the web `@imaginethat/petcore`
/// `chatFallback` / `museFallback`: when the active ``ChatBackendID`` throws,
/// is offline, or the user has no CLI/gateway configured, the bubble routes
/// here so chat **never hard-fails**.
///
/// Determinism is the contract: the same conversation in always produces the
/// same reply out, so it reads as intentional (a real front-desk guide) rather
/// than random, and it is unit-testable. ``stream(history:)`` yields the reply
/// word-by-word so the local path *streams* at the same cadence as a cloud
/// backend — the bubble fills identically whether the brain or the floor talks.
///
/// Pure value type, `Sendable`: no host coupling, safe to call off the main
/// actor. The host (``PetChatController``) shows a visible "answering locally"
/// beat (`react`/`alert`) before consuming the stream so the switch to the
/// floor is legible to the user (PLAN C6).
enum PetChatFallback {

    /// The four hero worlds the studio builds in (mirrors the web `WorldId`).
    enum WorldID: String, Sendable, CaseIterable {
        case aurora, mesh, flow, constellation
    }

    /// The site-guide intents the pet can answer at the front desk.
    enum Intent: String, Sendable {
        case greeting
        case whatWeDo
        case pricingBand
        case startABrief
        case world
    }

    /// A resolved local reply: the prose plus how it was routed (for tests).
    struct Reply: Sendable, Equatable {
        var text: String
        var intent: Intent
        /// The matched world when `intent == .world`, else `nil`.
        var world: WorldID?
    }

    /// One turn of conversation the floor reasons over. Mirrors the web
    /// `ChatTurn`; the host adapts ``ChatMessageRecord`` into this minimal shape
    /// so the floor never depends on the heavyweight chat models.
    struct Turn: Sendable, Equatable {
        enum Role: String, Sendable { case user, assistant, system }
        var role: Role
        var text: String

        init(role: Role, text: String) {
            self.role = role
            self.text = text
        }
    }

    // MARK: World routing (same signal table as the web museFallback)

    private struct WorldSignal {
        let world: WorldID
        let reason: String
        let keywords: [String]
    }

    private static let worldSignals: [WorldSignal] = [
        WorldSignal(
            world: .aurora,
            reason: "it wants soft, luminous light that bleeds and breathes",
            keywords: [
                "calm", "wellness", "health", "meditat", "dream", "ethereal", "soft",
                "ambient", "music", "sleep", "aura", "glow", "spa", "serene", "northern"
            ]
        ),
        WorldSignal(
            world: .mesh,
            reason: "it wants faceted, crystalline structure with iridescent depth",
            keywords: [
                "fintech", "finance", "data", "dashboard", "enterprise", "crypto",
                "analytics", "premium", "luxury", "architect", "3d", "spatial", "geometry",
                "precision", "engineering", "hardware"
            ]
        ),
        WorldSignal(
            world: .flow,
            reason: "it wants flowing, calligraphic motion — ink in water",
            keywords: [
                "story", "narrative", "editorial", "writing", "art", "portfolio", "fashion",
                "creative", "agency", "brand", "magazine", "poetry", "craft", "studio",
                "design", "elegant"
            ]
        ),
        WorldSignal(
            world: .constellation,
            reason: "it wants a swarm of points that assemble into meaning",
            keywords: [
                "community", "network", "social", "ai", "agent", "swarm", "developer",
                "platform", "connect", "map", "graph", "collaborat", "team", "startup",
                "saas", "tool"
            ]
        )
    ]

    /// Default when nothing matches — constellation is the house default world.
    private static var defaultWorld: WorldSignal { worldSignals[worldSignals.count - 1] }

    private static func pickWorld(_ text: String) -> WorldSignal {
        let lower = text.lowercased()
        for sig in worldSignals where sig.keywords.contains(where: { lower.contains($0) }) {
            return sig
        }
        return defaultWorld
    }

    // MARK: Site-guide intents (the front-desk questions)

    private struct IntentSignal {
        let intent: Intent
        let keywords: [String]
    }

    /// Intent keyword table; first matching intent (in order) wins.
    private static let intentSignals: [IntentSignal] = [
        IntentSignal(intent: .greeting,
                     keywords: ["hello", "hi ", "hey", "yo ", "howdy", "good morning", "good evening", "what's up", "whats up"]),
        IntentSignal(intent: .pricingBand,
                     keywords: ["price", "pricing", "cost", "how much", "budget", "quote", "rate", "afford", "$"]),
        IntentSignal(intent: .startABrief,
                     keywords: ["start", "begin", "brief", "hire", "work with", "get started", "kick off", "kickoff", "commission", "engage"]),
        IntentSignal(intent: .whatWeDo,
                     keywords: ["what do you", "who are you", "what is this", "what's this", "about", "services", "what can you", "help me with"])
    ]

    private static func intentReply(_ intent: Intent) -> String {
        switch intent {
        case .greeting:
            return "Hey — I'm the studio's guide. Tell me the site you're dreaming up and I'll imagine it with you, or ask what we do."
        case .whatWeDo:
            return "We're Imagine That: a small studio that builds bespoke, motion-rich sites in one of four signature worlds. You describe the idea; we shape the art direction, the motion language, and a fast, accessible build around it."
        case .pricingBand:
            return "Most commissions land in three bands — a focused one-page from the low five figures, a full bespoke site in the mid five figures, and an ongoing partnership beyond that. The exact number follows the scope; tell me the idea and I'll point you to a band."
        case .startABrief:
            return "Love it — let's start a brief. Describe the project in a sentence or two (what it's for, the feeling you want), and I'll draft a concept and the world it belongs in."
        case .world:
            return "" // world replies are composed in `worldReply`.
        }
    }

    // MARK: Routing

    /// The latest user message in a history (the turn we're answering).
    private static func latestUserText(_ history: [Turn]) -> String {
        for turn in history.reversed() where turn.role == .user { return turn.text }
        return ""
    }

    private static func matchIntent(_ text: String) -> Intent? {
        let lower = " \(text.lowercased()) "
        for sig in intentSignals where sig.keywords.contains(where: { lower.contains($0) }) {
            return sig.intent
        }
        return nil
    }

    private static func worldReply(_ text: String) -> Reply {
        let sig = pickWorld(text)
        let prose =
            "That belongs in our \(sig.world.rawValue) world — \(sig.reason). " +
            "We'd shape it with a small motion language of its own, pointer-reactive type and imagery, " +
            "and a fast, accessible build that keeps the same voice throughout. Want me to draft a full brief?"
        return Reply(text: prose, intent: .world, world: sig.world)
    }

    /// Route the latest user turn to a deterministic local reply: a site-guide
    /// intent if one keyword-matches, else the four-world placement. Pure — same
    /// history in, identical reply out.
    static func reply(history: [Turn]) -> Reply {
        let text = latestUserText(history).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return Reply(text: intentReply(.greeting), intent: .greeting, world: nil)
        }
        if let intent = matchIntent(text) {
            return Reply(text: intentReply(intent), intent: intent, world: nil)
        }
        return worldReply(text)
    }

    /// The bare reply string for simple call sites.
    static func replyText(history: [Turn]) -> String {
        reply(history: history).text
    }

    // MARK: Persona floor (BurnBar in-character)

    /// When the active pet carries BurnBar persona voice-lines (enter/work/cheer/
    /// exit, parsed from its petdef `agent.voiceLines`), the floor answers IN
    /// CHARACTER and on BurnBar's own domain (tokens/spend/agents) rather than the
    /// studio site-guide above. Deterministic: same message → same line, so it
    /// reads as intentional and stays unit-testable.
    static func personaReplyText(history: [Turn], lines: [String: [String]]) -> String {
        let text = latestUserText(history).trimmingCharacters(in: .whitespacesAndNewlines)
        let phase = personaPhase(for: text)
        let pool = lines[phase] ?? lines["work"] ?? lines.values.first(where: { !$0.isEmpty }) ?? []
        guard !pool.isEmpty else { return "" }
        return pool[stableIndex(text, modulo: pool.count)]
    }

    /// Map the latest user turn to a persona phase: a greeting perks the pet
    /// (`enter`), praise makes it `cheer`, a farewell/dismissal sends it off
    /// (`exit`), and anything else is treated as a working request (`work`).
    private static func personaPhase(for text: String) -> String {
        if text.isEmpty { return "enter" }
        let t = " \(text.lowercased()) "
        let greet = [" hi ", " hey ", " hello ", " yo ", " sup ", " morning ", " howdy "]
        let praise = ["thank", "thanks", " nice", " great", "awesome", " love", "good job", "well done", "amazing", "perfect", " cool", "nailed", "🔥", "🙌"]
        let bye = [" bye", "goodbye", "see you", " later", "go away", " leave", "shut up", " stop ", " quiet", " shoo"]
        if greet.contains(where: { t.contains($0) }) { return "enter" }
        if praise.contains(where: { t.contains($0) }) { return "cheer" }
        if bye.contains(where: { t.contains($0) }) { return "exit" }
        return "work"
    }

    /// A tiny deterministic (djb2) index so the same message always picks the same
    /// line — no Foundation `Hasher` randomization, so it's stable across launches.
    private static func stableIndex(_ text: String, modulo n: Int) -> Int {
        guard n > 0 else { return 0 }
        // Unsigned djb2 so the wrapping arithmetic can never produce a value that
        // traps under abs (abs(Int.min) crashes); the modulo stays in range.
        var h: UInt64 = 5381
        for b in text.utf8 { h = (h &* 33) &+ UInt64(b) }
        return Int(h % UInt64(n))
    }

    // MARK: Streaming

    /// Stream the local reply word-by-word so the floor path *streams* like a
    /// cloud backend. Yields each whitespace-delimited token with its trailing
    /// whitespace preserved, in stable order, so concatenation reproduces the
    /// reply exactly. The `delay` paces the cadence; pass `0` in tests to pin
    /// only the token order (the contract), not wall-clock timing.
    static func stream(
        history: [Turn],
        lines: [String: [String]]? = nil,
        perTokenDelay delay: Duration = .milliseconds(38)
    ) -> AsyncStream<String> {
        // Prefer the pet's BurnBar persona lines when present; only fall back to the
        // generic guide when a pet has no voice-lines at all.
        let resolved: String
        if let lines, !lines.isEmpty {
            let line = personaReplyText(history: history, lines: lines)
            resolved = line.isEmpty ? reply(history: history).text : line
        } else {
            resolved = reply(history: history).text
        }
        let tokens = tokenize(resolved)
        return AsyncStream { continuation in
            let task = Task {
                for tok in tokens {
                    if Task.isCancelled { break }
                    if delay > .zero { try? await Task.sleep(for: delay) }
                    continuation.yield(tok)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Split on whitespace but KEEP each token's trailing whitespace so the
    /// concatenation reproduces the source string exactly (mirrors the web
    /// `/\S+\s*/g`). Stable and deterministic.
    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inTrailingSpace = false
        for ch in text {
            if ch.isWhitespace {
                current.append(ch)
                inTrailingSpace = true
            } else {
                if inTrailingSpace {
                    // A non-space after trailing space starts a new token.
                    tokens.append(current)
                    current = ""
                    inTrailingSpace = false
                }
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
