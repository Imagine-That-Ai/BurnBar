import Foundation

// MARK: - Fleet liveness
//
// The honest data model behind the Home rail's fleet panel.
//
// The core mistake this file exists to prevent is a single `state` enum.
// Liveness has **two orthogonal axes** — *can we observe this agent at all*,
// and *what did we actually observe, and when*. Collapsing them is exactly how
// a panel ends up rendering "idle" for an agent it never watched.
//
// Three deliberate absences, and they are the whole design:
//
//   1. **There is no `.idle`.** Not at any stage. The word never appears in the
//      panel. Absence of a write is not evidence of idleness — the agent may be
//      thinking, blocked on a tool, or sitting on a permission prompt, all of
//      which write nothing.
//   2. **`.workingHere` is the only case that may say "running"**, and it is fed
//      only by `AgentPresenceModel`, which sees chat panes inside this app. A
//      Claude Code in Terminal cannot reach it.
//   3. **There is no `.awaitingUser`.** No such state exists anywhere in the
//      codebase; the only thing wearing the name (`MissionConsoleActiveTile`'s
//      `.awaitingApproval`) sits behind an approve action that is a no-op.
//
// This is the `docs/PROVIDERS.md` exact/estimated/unavailable discipline,
// applied to liveness instead of quota.

/// Where a liveness claim came from. Rendered in tooltips and the panel footer
/// so a row can always answer "how do you know that?".
enum FleetEvidenceSource: Equatable, Sendable {
    /// This app is driving the turn in one of its own chat panes. The only
    /// source permitted to claim an agent is running *right now*.
    case appChatController
    /// Claude Code's statusline snapshot changed on disk.
    case statuslineSnapshot
    /// A provider session-log file was written. Carries the provider-relative
    /// path so the row can name the project.
    case sessionLogWrite(String)
    /// A process latch file exists. The only case where *existence* is a
    /// liveness claim rather than an activity timestamp — currently Junie's
    /// `~/.junie/processes/*.json`.
    case processLatch(String)
    /// A parsed usage row. Real, but only as fresh as the scan cadence, which
    /// floors at 60s (600s with the Pixel Clock enabled).
    case parsedUsageRow

    /// Whether this source can report activity as it happens, rather than as of
    /// the last scan. Drives the panel's footer honesty line.
    var isRealTime: Bool {
        switch self {
        case .appChatController, .statuslineSnapshot, .sessionLogWrite, .processLatch:
            return true
        case .parsedUsageRow:
            return false
        }
    }

    /// Short phrase for a tooltip: "how do you know?"
    var explanation: String {
        switch self {
        case .appChatController:
            return "This app is running the turn."
        case .statuslineSnapshot:
            return "Claude Code wrote its status line."
        case .sessionLogWrite(let path):
            return "Session log changed: \(path)"
        case .processLatch(let path):
            return "Process latch present: \(path)"
        case .parsedUsageRow:
            return "From parsed usage, as of the last scan."
        }
    }
}

/// What we can honestly say about one agent.
enum FleetLiveness: Equatable, Sendable {
    /// Running in one of this app's own chat panes. `location` is the pane
    /// label ("Tab 2"), when known.
    case workingHere(AgentPresence, location: String?)
    /// Observed writing at `at`, recently enough to count as active.
    case wroteRecently(at: Date, source: FleetEvidenceSource)
    /// Last observed at `since`, longer ago than `activeWindow`. **Not** idle —
    /// just unobserved since then.
    case quietSince(Date, source: FleetEvidenceSource)
    /// Installed and reachable, but never observed working. Distinct from
    /// `unobservable`: we *could* see it, we just haven't yet.
    case standingBy
    /// Structurally unable to run: needs auth, out of quota, not installed,
    /// gateway unreachable.
    case blocked(AgentPresence)
    /// We cannot see this agent at all. The honest default, and the value any
    /// unknown must degrade to — never `standingBy`, and never `quietSince`.
    case unobservable(reason: String)

    /// Whether this row should read as active in the panel's count.
    var isActive: Bool {
        switch self {
        case .workingHere(let presence, _):
            switch presence {
            case .streaming, .thinking: return true
            default: return false
            }
        case .wroteRecently: return true
        case .quietSince, .standingBy, .blocked, .unobservable: return false
        }
    }

    /// The evidence behind this claim, when there is any.
    var source: FleetEvidenceSource? {
        switch self {
        case .workingHere: return .appChatController
        case .wroteRecently(_, let source), .quietSince(_, let source): return source
        case .standingBy, .blocked, .unobservable: return nil
        }
    }
}

// MARK: - Windows

/// The staleness ladder. Every value here is user-visible, so it lives in one
/// place rather than scattered through view code.
enum FleetWindow {
    /// Within this of a write, a row reads "wrote 12s ago" with a filled dot.
    static let active: TimeInterval = 90
    /// Within this, a row reads "quiet 6m" with a hollow dot. Beyond it, the
    /// same phrasing with a coarser timestamp.
    ///
    /// Note there is deliberately **no** threshold beyond which a row flips to
    /// a word like "idle". There is no such word.
    static let recent: TimeInterval = 15 * 60
    /// Below this age, a `wroteRecently` row may pulse. Kept short so a panel
    /// left open all day is still most of the time.
    static let pulse: TimeInterval = 15
}

// MARK: - Row

/// One agent's row in the fleet panel.
struct FleetAgentRow: Identifiable, Equatable, Sendable {
    let provider: AgentProvider
    /// The chat backend this provider maps to, when it has one. Non-nil rows
    /// can reach `.workingHere`; nil rows never can.
    let backend: ChatBackendID?
    let liveness: FleetLiveness
    /// Project or workspace this agent was last seen in, when known.
    let context: String?

    var id: String { provider.rawValue }
}

// MARK: - Resolver

/// Turns raw evidence into a `FleetLiveness`, with an injected clock so every
/// classification test runs on fixed dates with zero sleeping — the shape
/// `AgentPresenceResolver.resolve(_:now:)` already uses.
enum FleetLivenessResolver {

    /// Everything known about one agent at one instant.
    struct Evidence: Equatable, Sendable {
        /// Presence from this app's own chat panes, when the provider has a
        /// backend and that backend is configured.
        var presence: AgentPresence?
        /// Pane label for the in-app turn ("Tab 2").
        var location: String?
        /// The most recent observed write, from a watcher or a parsed row.
        var lastWrite: (date: Date, source: FleetEvidenceSource)?
        /// Set when we structurally cannot observe this agent — sandboxed
        /// build, watcher not armed, display asleep. Wins over everything
        /// except a live in-app turn, which is observable by definition.
        var unobservableReason: String?

        static func == (lhs: Evidence, rhs: Evidence) -> Bool {
            lhs.presence == rhs.presence
                && lhs.location == rhs.location
                && lhs.lastWrite?.date == rhs.lastWrite?.date
                && lhs.lastWrite?.source == rhs.lastWrite?.source
                && lhs.unobservableReason == rhs.unobservableReason
        }
    }

    /// Resolve one agent's liveness.
    ///
    /// Precedence, and the reasoning for it:
    ///
    ///   1. **A live in-app turn wins outright.** It is the only direct
    ///      observation we have, and it stays true even in a sandboxed build.
    ///   2. **Blocked states beat activity evidence**, because "needs sign-in"
    ///      is more actionable than "wrote 4 minutes ago" and stays true until
    ///      the user does something about it.
    ///   3. **`unobservableReason` beats stale writes.** A timestamp from
    ///      before the display slept must not be rendered as if it were
    ///      current — that is precisely the failure this whole model exists to
    ///      prevent.
    ///   4. Writes classify by age against `FleetWindow`.
    ///   5. Everything left over is `.unobservable`, **never** `.standingBy`.
    ///      `standingBy` is reserved for an agent we are actively watching and
    ///      have simply not seen yet.
    static func resolve(_ evidence: Evidence, now: Date = Date()) -> FleetLiveness {
        if let presence = evidence.presence {
            switch presence {
            case .streaming, .thinking:
                return .workingHere(presence, location: evidence.location)
            case .needsAuth, .exhausted, .notInstalled, .offline, .error:
                return .blocked(presence)
            case .ready:
                break
            }
        }

        if let reason = evidence.unobservableReason {
            return .unobservable(reason: reason)
        }

        if let write = evidence.lastWrite {
            // Parsed usage is accounting, not an observed write. Gateway
            // rows, API buckets, and scan imports all carry a timestamp, and
            // lighting the row as "wrote 11s ago" is how MiMo/OpenAI/DeepSeek
            // look busy when nothing produced a session file.
            if case .parsedUsageRow = write.source {
                return .quietSince(write.date, source: write.source)
            }
            let age = now.timeIntervalSince(write.date)
            // A clock that jumped backwards (NTP correction, timezone edit)
            // must not read as a write from the future.
            guard age >= 0 else {
                return .wroteRecently(at: write.date, source: write.source)
            }
            if age <= FleetWindow.active {
                return .wroteRecently(at: write.date, source: write.source)
            }
            return .quietSince(write.date, source: write.source)
        }

        // A configured, reachable agent we are watching but have never seen
        // write. Only reachable when presence said `.ready` — i.e. the app
        // knows the backend is installed and the gateway answered.
        if evidence.presence == .ready {
            return .standingBy
        }

        return .unobservable(reason: "Not watched")
    }
}
