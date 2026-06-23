import Foundation

// MARK: - Logical states

/// The one animation-state vocabulary shared across both renderers and both
/// kinds (PLAN §2 "Animation states"). These are the logical names the behavior
/// graph emits; `atlas2d.states` / `model3d.clips` key off the **same** names.
enum PetLogicalState: String, Codable, Hashable, Sendable, CaseIterable {
    case idle
    case wander
    case drag
    case listen
    case think
    case speak
    case sleep
    case react
}

// MARK: - Behavior triggers

/// The `when` guards a transition can fire on. JSON values are the lowerCamel
/// strings used in the shared schema (`cooldownElapsed`, `cursorNear`, …).
/// Unknown strings round-trip through ``other(_:)`` so a newer petdef never
/// fails to decode on an older desktop build.
enum PetBehaviorTrigger: Hashable, Sendable {
    /// The wander/ambient cooldown has elapsed (time-driven, weighted).
    case cooldownElapsed
    /// The cursor entered the pet's proximity radius.
    case cursorNear
    /// A low-probability "special" beat (rare cheer, etc.).
    case special
    /// Chat input focused → the pet should perk to `listen`.
    case inputFocused
    /// Send pressed → stream pending.
    case sendPressed
    /// First stream token arrived.
    case streamStart
    /// Stream tokens are arriving.
    case streamToken
    /// A result landed successfully.
    case resultLanded
    /// The deterministic local-persona fallback fired.
    case fallbackFired
    /// Long idle / display asleep.
    case idleElapsed
    /// Any future guard, preserved verbatim.
    case other(String)

    var rawValue: String {
        switch self {
        case .cooldownElapsed: return "cooldownElapsed"
        case .cursorNear: return "cursorNear"
        case .special: return "special"
        case .inputFocused: return "inputFocused"
        case .sendPressed: return "sendPressed"
        case .streamStart: return "streamStart"
        case .streamToken: return "streamToken"
        case .resultLanded: return "resultLanded"
        case .fallbackFired: return "fallbackFired"
        case .idleElapsed: return "idleElapsed"
        case .other(let s): return s
        }
    }

    init(rawValue: String) {
        switch rawValue {
        case "cooldownElapsed": self = .cooldownElapsed
        case "cursorNear": self = .cursorNear
        case "special": self = .special
        case "inputFocused": self = .inputFocused
        case "sendPressed": self = .sendPressed
        case "streamStart": self = .streamStart
        case "streamToken": self = .streamToken
        case "resultLanded": self = .resultLanded
        case "fallbackFired": self = .fallbackFired
        case "idleElapsed": self = .idleElapsed
        default: self = .other(rawValue)
        }
    }
}

extension PetBehaviorTrigger: Codable {
    init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

// MARK: - Behavior graph (JSON-serialisable, XState-shaped)

/// The `behavior` block of a `petdef.json`: an initial node plus a flat list of
/// weighted transitions. Both the TS and Swift interpreters read this identical
/// JSON; only the host action implementation differs.
struct PetBehaviorGraph: Codable, Hashable, Sendable {
    var initial: String
    var transitions: [Transition]

    struct Transition: Codable, Hashable, Sendable {
        var from: String
        var to: String
        var when: PetBehaviorTrigger
        /// Selection weight among equally-eligible transitions. Defaults to `1`.
        var weight: Int?

        var effectiveWeight: Int { max(weight ?? 1, 0) }
    }

    /// Transitions leaving `state` that match `trigger`.
    func transitions(from state: String, on trigger: PetBehaviorTrigger) -> [Transition] {
        transitions.filter { $0.from == state && $0.when == trigger }
    }

    /// All distinct triggers that can fire from `state` (for the time-driven tick).
    func triggers(from state: String) -> [PetBehaviorTrigger] {
        var seen = Set<String>()
        var ordered: [PetBehaviorTrigger] = []
        for t in transitions where t.from == state {
            if seen.insert(t.when.rawValue).inserted { ordered.append(t.when) }
        }
        return ordered
    }
}

// MARK: - Seeded RNG (deterministic, portable)

/// Mulberry32 — the same tiny, well-distributed 32-bit generator used by the
/// TS core's seeded RNG, so a shared seed reproduces an identical transition
/// sequence across the TS golden vectors and this Swift port (PLAN C3).
struct Mulberry32: RandomNumberGenerator, Sendable {
    private var state: UInt32

    init(seed: UInt32) {
        self.state = seed
    }

    /// One 32-bit step. Matches the canonical mulberry32 reference.
    mutating func nextUInt32() -> UInt32 {
        state = state &+ 0x6D2B_79F5
        var z = state
        z = (z ^ (z >> 15)) &* (z | 1)
        z ^= z &+ ((z ^ (z >> 7)) &* (z | 61))
        return z ^ (z >> 14)
    }

    /// `RandomNumberGenerator` conformance: assemble a 64-bit value from two
    /// 32-bit steps (low word first), so callers using the stdlib API stay
    /// deterministic too.
    mutating func next() -> UInt64 {
        let lo = UInt64(nextUInt32())
        let hi = UInt64(nextUInt32())
        return (hi << 32) | lo
    }

    /// Float in `[0, 1)`, matching the TS `next() / 2**32` convention.
    mutating func nextUnit() -> Double {
        Double(nextUInt32()) / 4_294_967_296.0
    }
}

// MARK: - Behavior interpreter

/// Pure, deterministic interpreter over a ``PetBehaviorGraph``. Holds the current
/// logical state and advances it by feeding triggers; among equally-eligible
/// transitions it picks one by weighted draw from an injected seeded RNG.
///
/// This is a value type with no host coupling — the renderer/controller observes
/// `current` and reacts. Determinism (same seed + same trigger stream → same
/// state sequence) is the contract verified against the TS golden vectors.
struct BehaviorInterpreter: Sendable {
    let graph: PetBehaviorGraph
    private(set) var current: String
    private var rng: Mulberry32

    init(graph: PetBehaviorGraph, seed: UInt32 = 1) {
        self.graph = graph
        self.current = graph.initial
        self.rng = Mulberry32(seed: seed)
    }

    /// Feed a trigger; if an eligible transition exists, move to its target and
    /// return the new state. Returns `nil` when no transition matches (the pet
    /// stays put).
    @discardableResult
    mutating func fire(_ trigger: PetBehaviorTrigger) -> String? {
        let candidates = graph.transitions(from: current, on: trigger)
        guard let chosen = pick(candidates) else { return nil }
        current = chosen.to
        return current
    }

    /// Weighted selection. With one candidate it's deterministic; with several it
    /// draws a point in `[0, totalWeight)` from the RNG and walks the cumulative
    /// weights — identical to the TS selection so golden vectors line up.
    private mutating func pick(_ candidates: [PetBehaviorGraph.Transition]) -> PetBehaviorGraph.Transition? {
        guard !candidates.isEmpty else { return nil }
        if candidates.count == 1 { return candidates[0] }
        let total = candidates.reduce(0) { $0 + $1.effectiveWeight }
        guard total > 0 else { return candidates[0] }
        var point = rng.nextUnit() * Double(total)
        for t in candidates {
            point -= Double(t.effectiveWeight)
            if point < 0 { return t }
        }
        return candidates[candidates.count - 1]
    }

    /// Map the current node string to a ``PetLogicalState`` when it is one of the
    /// canonical states (custom petdefs may use bespoke node names).
    var logicalState: PetLogicalState? { PetLogicalState(rawValue: current) }

    /// Reset to the graph's initial node and reseed (used on wake / restart).
    mutating func reset(seed: UInt32? = nil) {
        current = graph.initial
        if let seed { rng = Mulberry32(seed: seed) }
    }
}

// MARK: - Golden vector fixture shape

/// Decodes the optional Swift-compatible behavior golden vector fixture
/// (`packages/petcore/test/golden/behavior-swift.json`). Shape: a seed, the
/// graph, and the ordered trigger → expected-state pairs the TS interpreter
/// produced after conversion from the shared petcore export.
struct BehaviorGoldenVector: Codable, Sendable {
    var seed: UInt32
    var graph: PetBehaviorGraph
    var steps: [Step]

    struct Step: Codable, Sendable {
        var trigger: PetBehaviorTrigger
        /// Expected `current` after firing `trigger` (`nil` ⇒ no transition).
        var expected: String?
    }
}
