import Foundation
import Observation

// MARK: - Hermes Square Feature Flags
//
// Per-phase rollout flags for Hermes Square (plan §7). Each phase enables
// itself behind a flag so the legacy Assistants surface remains the default
// until the user (or a dogfood scheme) opts in.
//
// Persistence:
//   • iOS    — UserDefaults keys `square.feature.<name>`
//   • Android — DataStore keys `square.feature.<name>` (same shape)
//   • macOS  — UserDefaults (same key) — Mac listener honors the same flags
//     so the relay-side persona scoping and mission-group claim behaviour
//     ship in lockstep with the phone.
//
// Flags are deliberately explicit (not a registry) so dead flags get
// removed by the type checker rather than lingering as strings.

@MainActor
@Observable
public final class HermesSquareFeatureFlags {

    // MARK: Singleton

    public static let shared = HermesSquareFeatureFlags()

    // MARK: Flags

    /// Phase A — Foundations. Replaces `AssistantsTabRoot` with
    /// `HermesSquareRoot` (unified inbox + pinned grid + missions strip +
    /// federated search). No new dispatch flow yet.
    public var phaseA: Bool {
        didSet { persist(.phaseA, phaseA) }
    }

    /// Phase B — Dispatch + multi-agent. Composer queue, fan-out, persona
    /// scoping, approval inbox with class-based learning.
    public var phaseB: Bool {
        didSet { persist(.phaseB, phaseB) }
    }

    /// Phase C — Cards + marketplace. MCP-UI card rendering, mini-program
    /// host, manifest install, rollback service.
    public var phaseC: Bool {
        didSet { persist(.phaseC, phaseC) }
    }

    /// Phase D — Voice + iPad + cross-device. Voice command surface,
    /// iPad split-view, cross-device handoff, ambient briefing.
    public var phaseD: Bool {
        didSet { persist(.phaseD, phaseD) }
    }

    // MARK: Init

    private init() {
        let defaults = UserDefaults.standard
        self.phaseA = defaults.bool(forKey: Key.phaseA.rawValue)
        self.phaseB = defaults.bool(forKey: Key.phaseB.rawValue)
        self.phaseC = defaults.bool(forKey: Key.phaseC.rawValue)
        self.phaseD = defaults.bool(forKey: Key.phaseD.rawValue)
    }

    /// Test/preview seed: an instance with all flags off.
    public static func offline() -> HermesSquareFeatureFlags {
        let inst = HermesSquareFeatureFlags()
        inst.phaseA = false
        inst.phaseB = false
        inst.phaseC = false
        inst.phaseD = false
        return inst
    }

    /// Test/preview seed: an instance with phase A on (the common
    /// dogfooding state during Phase A rollout).
    public static func phaseAOnly() -> HermesSquareFeatureFlags {
        let inst = HermesSquareFeatureFlags.offline()
        inst.phaseA = true
        return inst
    }

    /// Helper for surfaces that want a single boolean: "is anything Hermes
    /// Square at all enabled?" — used by the iOS root router to decide
    /// whether to even load `HermesSquareRoot`.
    public var anyPhaseEnabled: Bool {
        phaseA || phaseB || phaseC || phaseD
    }

    // MARK: Keys

    public enum Key: String {
        case phaseA = "square.feature.phaseA"
        case phaseB = "square.feature.phaseB"
        case phaseC = "square.feature.phaseC"
        case phaseD = "square.feature.phaseD"
    }

    // MARK: Persistence

    private func persist(_ key: Key, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: key.rawValue)
    }

    /// Reset all flags to off — used by Settings → Reset Hermes Square.
    public func resetAll() {
        phaseA = false
        phaseB = false
        phaseC = false
        phaseD = false
    }
}
