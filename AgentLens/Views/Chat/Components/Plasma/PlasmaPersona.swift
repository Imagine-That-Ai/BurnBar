import SwiftUI

// MARK: - Personas
//
// The mascot orb's cast, transcribed from the brand asset's `PERSONAS` table.
// A persona is a *voice*, not a model and not an agent: it prefixes the system
// prompt so the same model answers in a chosen register.
//
// This type is pure data with no SwiftUI or AppKit dependency beyond `Color`,
// so the roster, the prompt composition and the seat rules are all testable
// without rendering anything.

/// How a persona's eyes are drawn. The asset ships five implementations and
/// names five more; all ten are drawn here, because a persona whose eyes fall
/// back to generic dots is a persona the user cannot tell apart at 52pt.
enum PlasmaEyeStyle: String, CaseIterable, Codable, Sendable {
    case sunglasses
    case glasses
    case sparkle
    case eyelash
    case halflid
    case fierce
    case squint
    case serene
    case slit
    case eyeliner
}

/// One member of the cast.
struct PlasmaPersona: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    /// Used in the accessible label and the seat list, never as the only signal.
    let symbol: String
    /// The identity colour, straight from the asset.
    let color: Color
    /// The gradient's dark inner stop.
    let coreColor: Color
    /// `radial-gradient(circle at 35% 35%, lit 0%, color 45%, deep 75%, transparent 100%)`
    let litColor: Color
    let deepColor: Color
    let eyeStyle: PlasmaEyeStyle
    let eyeColor: Color
    /// The catchlight — the speck of reflected light that makes an eye look wet
    /// rather than painted.
    let eyeCatch: Color
    let tagline: String
    let skills: [String]
    /// The line prefixed to the system prompt when this persona is active.
    let voicePrompt: String

    /// The orb's body gradient, sampled at the asset's stops.
    var gradient: Gradient {
        Gradient(stops: [
            .init(color: litColor, location: 0),
            .init(color: color, location: 0.45),
            .init(color: deepColor, location: 0.75),
            .init(color: deepColor.opacity(0), location: 1)
        ])
    }

    /// The asset's `drop-shadow` glow colour.
    var glow: Color { color }
}

// MARK: Roster

extension PlasmaPersona {
    /// The ten authored personas, in the asset's order.
    static let all: [PlasmaPersona] = [
        PlasmaPersona(
            id: "bad-boi",
            name: "Bad Boi",
            symbol: "🏍️",
            color: Color(hex: "e11d48"),
            coreColor: Color(hex: "9f1239"),
            litColor: Color(hex: "fca5a5"),
            deepColor: Color(hex: "881337"),
            eyeStyle: .sunglasses,
            eyeColor: Color(hex: "18181b"),
            eyeCatch: Color(hex: "ffffff"),
            tagline: "Breaks the rules, ships fast, questions corporate dogma.",
            skills: ["rapid-deployment", "exploit-hunting", "cli-automation", "perf-hacking", "ruthless-refactor"],
            voicePrompt: """
                [PERSONA: BAD BOI (🏍️)] You are Bad Boi. Speak with edgy confidence, sharp wit, \
                and casual mastery. Cut corporate bureaucracy, skip preamble fluff, use direct CLI \
                commands, and ship blazingly fast working code. Question timid architectural \
                choices and propose bold, efficient alternatives.
                """
        ),
        PlasmaPersona(
            id: "nice-girl",
            name: "Nice Girl",
            symbol: "🌸",
            color: Color(hex: "f472b6"),
            coreColor: Color(hex: "db2777"),
            litColor: Color(hex: "ffb6c1"),
            deepColor: Color(hex: "9d174d"),
            eyeStyle: .sparkle,
            eyeColor: Color(hex: "831843"),
            eyeCatch: Color(hex: "fbcfe8"),
            tagline: "Unconditionally supportive, cheerful, accessible & clean UX.",
            skills: ["a11y-debugging", "frontend-design", "user-empathy", "unit-testing", "clean-documentation"],
            voicePrompt: "[PERSONA: NICE GIRL (🌸)] You are Nice Girl. Be wonderfully encouraging, cheerful, and detail-oriented. Emphasize accessibility (a11y), clean self-documenting code, delightful user experience, and thorough error explanations. Celebrate user wins with positive vibes!"
        ),
        PlasmaPersona(
            id: "smoker",
            name: "The Smoker",
            symbol: "🚬",
            color: Color(hex: "94a3b8"),
            coreColor: Color(hex: "475569"),
            litColor: Color(hex: "e2e8f0"),
            deepColor: Color(hex: "334155"),
            eyeStyle: .halflid,
            eyeColor: Color(hex: "1e293b"),
            eyeCatch: Color(hex: "fdba74"),
            tagline: "Seen it all since C++98. Nonchalant, rock-solid stability.",
            skills: ["memory-leak-debugging", "c-native-assets", "system-architecture", "database-integrity", "unix-philosophy"],
            voicePrompt: "[PERSONA: THE SMOKER (🚬)] You are The Smoker. Speak in calm, concise, weathered sentences with dry pragmatic wisdom. Reject unproven hype; focus on rock-solid Unix stability, zero memory leaks, minimal dependencies, and battle-tested architecture."
        ),
        PlasmaPersona(
            id: "nerd",
            name: "The Nerd",
            symbol: "🤓",
            color: Color(hex: "10b981"),
            coreColor: Color(hex: "047857"),
            litColor: Color(hex: "a7f3d0"),
            deepColor: Color(hex: "064e3b"),
            eyeStyle: .glasses,
            eyeColor: Color(hex: "022c22"),
            eyeCatch: Color(hex: "ecfdf5"),
            tagline: "Pedantic type theory, formal verification, Big-O purist.",
            skills: ["static-analysis", "type-systems", "big-o-optimization", "ast-manipulation", "formal-verification"],
            voicePrompt: "[PERSONA: THE NERD (🤓)] You are The Nerd. Be delightfully pedantic, obsessed with type correctness, algebraic data types, asymptotic complexity (Big-O), memory cache efficiency, and compiler guarantees. Explain the formal theoretical reasoning behind your code."
        ),
        PlasmaPersona(
            id: "jock",
            name: "The Jock",
            symbol: "⚡",
            color: Color(hex: "f59e0b"),
            coreColor: Color(hex: "b45309"),
            litColor: Color(hex: "fde68a"),
            deepColor: Color(hex: "78350f"),
            eyeStyle: .fierce,
            eyeColor: Color(hex: "451a03"),
            eyeCatch: Color(hex: "fffbeb"),
            tagline: "High-octane sprint energy, crushes bottlenecks & latency.",
            skills: ["high-throughput-concurrency", "gpu-acceleration", "load-testing", "cache-pumping", "benchmark-crushing"],
            voicePrompt: "[PERSONA: THE JOCK (⚡)] You are The Jock. Bring massive locker-room hype and energy! Treat coding sprints as championship sets. Obsess over crushing latency, boosting FPS/throughput, multi-threading, and lifting heavy performance bottlenecks. Let's get these gains!"
        ),
        PlasmaPersona(
            id: "asshole",
            name: "The Asshole",
            symbol: "💀",
            color: Color(hex: "ef4444"),
            coreColor: Color(hex: "7f1d1d"),
            litColor: Color(hex: "fca5a5"),
            deepColor: Color(hex: "450a0a"),
            eyeStyle: .squint,
            eyeColor: Color(hex: "450a0a"),
            eyeCatch: Color(hex: "fee2e2"),
            tagline: "Brutally honest code roasts. Zero sugarcoating.",
            skills: ["diligence-swarm", "tech-debt-demolition", "security-auditing", "spaghetti-cleanup", "code-roasting"],
            voicePrompt: "[PERSONA: THE ASSHOLE (💀)] You are The Asshole. Roast sloppy code, boilerplate, and bad design with razor-sharp sarcasm and zero sugarcoating. Follow up every roast with an unmistakably superior, flawless, minimal rewrite that proves your point."
        ),
        PlasmaPersona(
            id: "barbie",
            name: "Barbie Diva",
            symbol: "💖",
            color: Color(hex: "ec4899"),
            coreColor: Color(hex: "be185d"),
            litColor: Color(hex: "fbcfe8"),
            deepColor: Color(hex: "831843"),
            eyeStyle: .eyelash,
            eyeColor: Color(hex: "500724"),
            eyeCatch: Color(hex: "fdf2f8"),
            tagline: "Fabulous runway aesthetics, liquid glass, perfect typography.",
            skills: ["frontend-design", "modern-web-guidance", "liquid-glass-caustics", "typography-hierarchy", "micro-animations"],
            voicePrompt: "[PERSONA: BARBIE DIVA (💖)] You are Barbie Diva. Bring fabulous high-fashion energy! Demand drop-dead gorgeous visual aesthetics: liquid glass caustics, luxurious typographic hierarchy, silky micro-animations, and pixel-perfect responsiveness. Make every UI runway-ready!"
        ),
        PlasmaPersona(
            id: "monk",
            name: "Zen Monk",
            symbol: "🧘",
            color: Color(hex: "06b6d4"),
            coreColor: Color(hex: "0e7490"),
            litColor: Color(hex: "a5f3fc"),
            deepColor: Color(hex: "164e63"),
            eyeStyle: .serene,
            eyeColor: Color(hex: "083344"),
            eyeCatch: Color(hex: "ecfeff"),
            tagline: "Minimalism, inner peace, deletes more code than writes.",
            skills: ["codebase-pruning", "dependency-elimination", "minimalist-architecture", "cognitive-simplicity", "single-responsibility"],
            voicePrompt: "[PERSONA: ZEN MONK (🧘)] You are Zen Monk. Speak with serene calm and minimalist clarity. Guide the user toward radical subtraction: delete unused code, eliminate external bloat, and achieve simplicity and inner peace in software design."
        ),
        PlasmaPersona(
            id: "cat",
            name: "Hacker Cat",
            symbol: "🐾",
            color: Color(hex: "84cc16"),
            coreColor: Color(hex: "4d7c0f"),
            litColor: Color(hex: "d9f99d"),
            deepColor: Color(hex: "365314"),
            eyeStyle: .slit,
            eyeColor: Color(hex: "1a2e05"),
            eyeCatch: Color(hex: "f7fee7"),
            tagline: "Curious exploit hunter, moves fast, knocks bugs off tables.",
            skills: ["reverse-engineering", "ast-hacking", "network-sniffing", "stealth-scripting", "edge-case-hunting"],
            voicePrompt: "[PERSONA: HACKER CAT (🐾)] You are Hacker Cat. Be playful, curious, and clever (purr occasionally at neat hacks *purrs*). Sneak around complicated blockers, exploit quirky undocumented features, and knock stubborn bugs off the table with agile code."
        ),
        PlasmaPersona(
            id: "goth",
            name: "Goth Doom",
            symbol: "🖤",
            color: Color(hex: "8b5cf6"),
            coreColor: Color(hex: "5b21b6"),
            litColor: Color(hex: "ddd6fe"),
            deepColor: Color(hex: "2e1065"),
            eyeStyle: .eyeliner,
            eyeColor: Color(hex: "1e1b4b"),
            eyeCatch: Color(hex: "f5f3ff"),
            tagline: "Existential dread coder. Everything decays, build resiliently.",
            skills: ["chaos-engineering", "crashlytics-defense", "graceful-degradation", "error-resilience", "immutable-audit-logs"],
            voicePrompt: "[PERSONA: GOTH DOOM (🖤)] You are Goth Doom. Speak with darkwave atmospheric poetry and existential melancholy. Acknowledge that all systems trend toward entropy and rot; build ultra-resilient error boundaries, crash recovery systems, and graceful fallback modes."
        )
    ]

    static func persona(id: String) -> PlasmaPersona? {
        all.first { $0.id == id }
    }
}

// MARK: - Seats

/// A named seat the user can switch between: a persona plus the label they gave
/// it. The asset calls these "Grok Bot seats"; here they are the user's own
/// roster, so a workspace can keep "Reviewer" on The Asshole and "Docs" on Nice
/// Girl without re-picking a persona every time.
struct PlasmaSeat: Identifiable, Equatable, Codable, Sendable {
    let id: String
    var label: String
    var personaID: String
    /// Seats the user made themselves are removable; the four shipped ones are
    /// not, so the roster can never become empty.
    var isBuiltIn: Bool

    var persona: PlasmaPersona {
        PlasmaPersona.persona(id: personaID) ?? PlasmaPersona.all[0]
    }
}

extension PlasmaSeat {
    /// A seat name is a row label in a 288pt popover, so it is bounded at the
    /// model rather than at the text field: the cap then also holds for a
    /// roster restored from a hand-edited defaults blob.
    static let labelLimit = 48

    /// Custom seats the roster will hold. The picker is a scrolling list of
    /// identities a person switches between, not a database; past a couple of
    /// dozen the list stops being scannable and the choice stops being quick.
    static let customSeatLimit = 24

    /// Trims and clamps a user-typed label, falling back to `fallback` when
    /// nothing is left.
    static func normalizedLabel(_ label: String, fallback: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        guard trimmed.count > labelLimit else { return trimmed }
        return String(trimmed.prefix(labelLimit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The asset's four `BASE_PROFILES`, keeping its persona pairings.
    static let builtIn: [PlasmaSeat] = [
        PlasmaSeat(id: "seat-a", label: "Seat A", personaID: "nerd", isBuiltIn: true),
        PlasmaSeat(id: "seat-b", label: "Seat B", personaID: "nice-girl", isBuiltIn: true),
        PlasmaSeat(id: "seat-c", label: "Seat C", personaID: "smoker", isBuiltIn: true),
        PlasmaSeat(id: "seat-d", label: "Seat D", personaID: "bad-boi", isBuiltIn: true)
    ]

    /// Seat "off": no persona prefix, the agent's own default voice.
    static let neutralID = "__plasma_no_persona"
}

// MARK: - Prompt composition

enum PlasmaPersonaPrompt {
    /// Prefixes `base` with the persona's voice line.
    ///
    /// The persona goes *first* so the model reads the register before the
    /// task, and the two are separated by a blank line so a persona can never
    /// run into the first instruction of the real prompt. An empty base returns
    /// the voice alone rather than a prompt with trailing whitespace.
    static func compose(voice persona: PlasmaPersona?, base: String) -> String {
        guard let persona else { return base }
        let trimmedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBase.isEmpty else { return persona.voicePrompt }
        return "\(persona.voicePrompt)\n\n\(trimmedBase)"
    }

    /// Which voice wins when a seat persona and a desktop pet are both live.
    ///
    /// The pet does. It is a deliberate, momentary act performed at the pet
    /// bubble, while the seat persona is ambient configuration, and stacking
    /// two contradictory register instructions reads worse than either alone.
    ///
    /// Extracted from the send path so the rule is testable: inline in
    /// `ChatSessionController+SearchSend` it was reachable only by building a
    /// whole controller and a whole turn.
    static func resolveVoice(seat: PlasmaPersona?, hasActivePetVoice: Bool) -> PlasmaPersona? {
        hasActivePetVoice ? nil : seat
    }
}
