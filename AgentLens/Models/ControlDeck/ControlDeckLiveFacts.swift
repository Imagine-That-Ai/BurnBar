import Foundation
import OpenBurnBarCore

// MARK: - Control Deck Live Facts
//
// The four asynchronous tiles read state from four different subsystems — a
// daemon over a Unix socket, a loopback HTTP gateway, an in-memory operating
// snapshot, and Firestore. What they render, though, is one sentence each.
//
// That sentence is derived here, in pure value types over explicitly supplied
// readings: no store lookups, no `Date()` unless it is passed in, no view
// dependencies. Two reasons, both load-bearing:
//
//   1. **The honest-state rule is testable.** "A tile renders one live fact,
//      never a blank and never a fake number" is only a slogan until a test can
//      construct a cold machine, a dead analyst, or a signed-out account and
//      assert what the tile says. `ControlDeckRegistryTests` does exactly that.
//   2. **The degraded strings are the product.** A rule-based inbox brief and an
//      LLM-written one look identical on screen; the difference lives in one
//      telemetry field. Deriving that difference in a pure function is how it
//      stops being invisible.
//
// Every headline here also respects the 28-character budget from the design:
// at four columns a tile is roughly 274pt and the headline is `lineLimit(1)`.

// MARK: - AI Inbox

/// What the AI Inbox tile knows, derived from the daemon's own config and tick
/// telemetry plus the local unread count.
struct InboxDeckFacts: Equatable, Sendable {

    /// Whether the last substantive tick actually reached a model — the
    /// difference between an analyst brief and the deterministic fallback.
    ///
    /// This is the fact the surface has historically hidden: a tick that fails
    /// to reach its model still writes items, still renders a brief, and still
    /// looks successful. `llmCalls == 0` while the egress mode allows model
    /// calls is the signature of the analyst falling back to rules.
    enum Analyst: Equatable, Sendable {
        /// The loop has never produced a substantive tick.
        case neverRan
        /// Every recent tick skipped — nothing had changed. Cheap and correct.
        case idle
        /// The last substantive tick called a model.
        case healthy(calls: Int)
        /// Egress is `off`, so rules are the design, not a failure.
        case ruleBasedByDesign
        /// Egress allows model calls and the tick made none: the analyst could
        /// not run and the brief you are reading came from the rule engine.
        case couldNotRun
        /// The tick failed outright, in the daemon's own words.
        case failed(String)

        var label: String {
            switch self {
            case .neverRan: return "No checks yet"
            case .idle: return "Idle · nothing changed"
            case .healthy(let calls): return "Analyst ran · \(calls) call\(calls == 1 ? "" : "s")"
            case .ruleBasedByDesign: return "Rule-based (egress off)"
            case .couldNotRun: return "Analyst could not run"
            case .failed(let reason): return "Failed — \(reason.prefix(40))"
            }
        }

        /// True when the tile should wear the attention plate. A dead analyst
        /// is not an error the user can see anywhere else in the app.
        var isAlarming: Bool {
            switch self {
            case .couldNotRun, .failed: return true
            case .neverRan, .idle, .healthy, .ruleBasedByDesign: return false
            }
        }
    }

    let headline: String
    let analyst: Analyst
    /// "92% of the last 24 checks found nothing to do" — the honest answer to
    /// "is this thing burning money in the background?".
    let skipSummary: String
    let egressLabel: String
    let isEnabled: Bool
    let isReachable: Bool

    init(
        unreadCount: Int?,
        config: BurnBarInboxConfig?,
        runs: [BurnBarInboxRunTelemetry],
        todaySpendUSD: Double?,
        unavailableReason: String?
    ) {
        isReachable = unavailableReason == nil && config != nil
        isEnabled = config?.enabled ?? false

        // Nil is not zero. The unread count is a local read that has simply not
        // landed yet; showing "0 unread" would read as "all caught up".
        let unreadLabel: String? = unreadCount.map { "\($0) unread" }

        if let unavailableReason, unavailableReason.isEmpty == false {
            // Never blank: the count is a local SQLite read and survives a dead
            // daemon, so the tile keeps showing it and says what is missing.
            headline = unreadLabel.map { "\($0) · daemon offline" } ?? "Daemon not reachable"
            analyst = .neverRan
            skipSummary = ""
            egressLabel = "Unknown"
            return
        }

        guard let config else {
            headline = unreadLabel.map { "\($0) · loading…" } ?? "Reading the inbox…"
            analyst = .neverRan
            skipSummary = ""
            egressLabel = "Unknown"
            return
        }

        let spend = todaySpendUSD ?? runs.reduce(0.0) { $0 + $1.costUSD }
        let budgetLabel = "\(spend.formatAsCost()) of \(config.dailyBudgetUSD.formatAsCost())"
        headline = unreadLabel.map { "\($0) · \(budgetLabel)" } ?? budgetLabel
        analyst = Self.analystState(runs: runs, egressMode: config.egressMode)
        skipSummary = Self.skipSummary(runs: runs)
        egressLabel = Self.egressLabel(config.egressMode)
    }

    /// The last tick that actually did work decides the verdict; skipped ticks
    /// are noise for this question and only matter when there is nothing else.
    private static func analystState(
        runs: [BurnBarInboxRunTelemetry],
        egressMode: BurnBarInboxEgressMode
    ) -> Analyst {
        guard runs.isEmpty == false else { return .neverRan }

        // `inboxRuns` returns most-recent-first, but sort defensively rather
        // than trusting wire order for a verdict this load-bearing.
        let ordered = runs.sorted { $0.startedAt > $1.startedAt }

        if let newest = ordered.first, newest.gateResult == .failed {
            return .failed(newest.error ?? "no reason given")
        }

        let substantive = ordered.first {
            switch $0.gateResult {
            case .localChanged, .remotePhase, .forced: return true
            case .skippedUnchanged, .skippedDisabled, .failed: return false
            }
        }

        guard let substantive else { return .idle }
        if substantive.llmCalls > 0 { return .healthy(calls: substantive.llmCalls) }
        return egressMode.allowsModelCalls ? .couldNotRun : .ruleBasedByDesign
    }

    private static func skipSummary(runs: [BurnBarInboxRunTelemetry]) -> String {
        guard runs.isEmpty == false else { return "" }
        let skipped = runs.filter {
            $0.gateResult == .skippedUnchanged || $0.gateResult == .skippedDisabled
        }.count
        let percent = Int((Double(skipped) / Double(runs.count) * 100).rounded())
        return "\(percent)% of \(runs.count) checks idle"
    }

    private static func egressLabel(_ mode: BurnBarInboxEgressMode) -> String {
        switch mode {
        case .off: return "Egress off"
        case .local: return "Local models only"
        case .cloud: return "Cloud models"
        }
    }
}

// MARK: - Model Router

/// What the Model Router tile knows about the local OpenAI-compatible gateway.
struct RouterDeckFacts: Equatable, Sendable {

    /// The result of one loopback probe of `/v1/models`. Never taken on a cold
    /// visit while the gateway is off: an off gateway has nothing to answer
    /// with, and probing it would only manufacture a scary error string.
    enum Probe: Equatable, Sendable {
        case served(advertised: Int, total: Int)
        case failed(String)
    }

    /// The security posture chip. The token itself is never rendered, echoed,
    /// or copied — only whether one is being enforced.
    enum AuthPosture: Equatable, Sendable {
        case tokenEnforced
        case loopbackOpen
        case tokenIssuedAtLaunch

        var label: String {
            switch self {
            case .tokenEnforced: return "Token enforced"
            case .loopbackOpen: return "Loopback open"
            case .tokenIssuedAtLaunch: return "Token set at launch"
            }
        }

        /// Loopback-without-a-token is the one posture that costs money if it
        /// is wrong: any same-host process can spend the user's provider
        /// credits through the gateway.
        var isAlarming: Bool { self == .loopbackOpen }
    }

    let headline: String
    let endpoint: String
    let posture: AuthPosture
    let isEnabled: Bool
    let servedModelCount: Int?

    init(
        enabled: Bool,
        host: String,
        port: Int,
        tokenConfigured: Bool,
        allowsUnauthenticatedLoopback: Bool,
        probe: Probe?
    ) {
        let resolvedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "127.0.0.1" : host
        let resolvedPort = port > 0 ? port : 8317
        endpoint = "http://\(resolvedHost):\(resolvedPort)/v1"
        isEnabled = enabled

        posture = {
            if allowsUnauthenticatedLoopback { return .loopbackOpen }
            return tokenConfigured ? .tokenEnforced : .tokenIssuedAtLaunch
        }()

        guard enabled else {
            // `.off` never blanks: the port it *would* serve on is the reason
            // to turn it on, and it is what the user has to paste elsewhere.
            headline = "Gateway off · port \(resolvedPort)"
            servedModelCount = nil
            return
        }

        switch probe {
        case .served(let advertised, let total):
            headline = "\(advertised) of \(total) models served"
            servedModelCount = advertised
        case .failed:
            headline = "Gateway not answering"
            servedModelCount = nil
        case nil:
            headline = "Gateway on · port \(resolvedPort)"
            servedModelCount = nil
        }
    }
}

// MARK: - The Wand

/// What The Wand tile knows: the tier ceiling on fan-out, and how many casts
/// are in the air right now.
struct WandDeckFacts: Equatable, Sendable {
    let headline: String
    let ceiling: Int
    let casting: Int
    let awaitingApproval: Int
    let blocked: Int
    let tierLabel: String
    let burnLabel: String

    init(
        tier: CloudTier,
        casting: Int,
        awaitingApproval: Int,
        blocked: Int,
        totalMissions: Int,
        burnUSD: Double
    ) {
        ceiling = WandFanOut.maxParallel(for: tier)
        self.casting = casting
        self.awaitingApproval = awaitingApproval
        self.blocked = blocked
        tierLabel = tier == .none ? "Free tier" : tier.displayName
        burnLabel = burnUSD > 0 ? "\(burnUSD.formatAsCost()) cast" : "No cast spend"

        let workers = "\(ceiling) worker\(ceiling == 1 ? "" : "s")"
        if casting > 0 {
            headline = "\(workers) · \(casting) casting"
        } else if totalMissions == 0 {
            headline = "\(workers) · nothing cast"
        } else {
            headline = "\(workers) · idle"
        }
    }
}

// MARK: - Memory MCP

/// What the Memory MCP tile knows. Every unavailable branch is written out,
/// because "handle the empty state" is exactly where a spec rots: an
/// unconfigured Mac, a signed-out account, and a Free-tier member are three
/// different sentences and the tile must say which one is true.
struct MCPDeckFacts: Equatable, Sendable {

    /// One completed roster read. Deliberately a value: the tile holds no
    /// Firestore listener, so this is a stamped reading and it says when.
    struct Reading: Equatable, Sendable {
        let activeCount: Int
        let revokedCount: Int
        let lastUsedAt: Date?
        let checkedAt: Date
    }

    enum Availability: Equatable, Sendable {
        case ready
        case cloudNotConfigured
        case signedOut
        case tierLocked
        case failed(String)

        var reason: String? {
            switch self {
            case .ready: return nil
            case .cloudNotConfigured: return "Cloud is not configured on this Mac"
            case .signedOut: return "Sign in to view connected MCP clients"
            case .tierLocked: return "Hosted Remote MCP needs Cloud Pro"
            case .failed(let message): return message
            }
        }
    }

    let headline: String
    let availability: Availability
    let endpoint: String
    let checkedLabel: String
    let connectedCount: Int?

    /// The public hosted endpoint, verbatim from
    /// `CloudStoreSettingsView.swift:1366`. Not a secret, and the whole point of
    /// the feature is that you paste it into another agent.
    static let hostedEndpoint = "https://mcp.burnbar.ai/mcp"

    init(
        cloudConfigured: Bool,
        signedIn: Bool,
        tierUnlocked: Bool,
        reading: Reading?,
        errorMessage: String?,
        now: Date = Date()
    ) {
        endpoint = Self.hostedEndpoint

        availability = {
            if cloudConfigured == false { return .cloudNotConfigured }
            if signedIn == false { return .signedOut }
            if let errorMessage, errorMessage.isEmpty == false { return .failed(errorMessage) }
            if tierUnlocked == false { return .tierLocked }
            return .ready
        }()

        switch availability {
        case .cloudNotConfigured:
            headline = "Cloud not configured"
            connectedCount = nil
            checkedLabel = ""
        case .signedOut:
            headline = "Not signed in"
            connectedCount = nil
            checkedLabel = ""
        case .tierLocked:
            headline = "Hosted MCP needs Pro"
            connectedCount = nil
            checkedLabel = ""
        case .failed:
            headline = reading.map { "\($0.activeCount) connected · stale" } ?? "Could not read clients"
            connectedCount = reading?.activeCount
            checkedLabel = ""
        case .ready:
            guard let reading else {
                // Honest, and not a fake zero: nothing has been read yet
                // because reading costs a cloud round trip and the deck does
                // not spend one without being asked.
                headline = "Signed in · not checked"
                connectedCount = nil
                checkedLabel = ""
                return
            }
            connectedCount = reading.activeCount
            checkedLabel = Self.relative(reading.checkedAt, now: now)
            if reading.activeCount == 0 {
                headline = "No agents connected"
            } else if let lastUsedAt = reading.lastUsedAt {
                headline = "\(reading.activeCount) connected · \(Self.relative(lastUsedAt, now: now))"
            } else {
                headline = "\(reading.activeCount) connected · unused"
            }
        }
    }

    private static func relative(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
