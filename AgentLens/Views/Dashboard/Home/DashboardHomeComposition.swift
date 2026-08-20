import Foundation
import OpenBurnBarCore
import OpenBurnBarInboxModels
import OpenBurnBarKernel

// MARK: - Home composition
//
// `DashboardLayout` used to govern the Overview route only, which made the
// picker a lie for the ~90% of sessions that never leave Home: you chose
// "Cockpit" and Home stayed the same two-pane inbox. Either the picker means
// "how this app presents information to me" everywhere, or it is a backdrop
// picker wearing a layout's name.
//
// So the layout resolves into a **Home shell** as well. The mapping is pure and
// lives here rather than inside the view for the same reason
// `DashboardHomeRailMetrics` does: it is the part worth pinning with a test,
// and a `@State`-free function can be exercised without mounting a window.
//
// Each layout keeps its Overview thesis on Home, expressed against inbox items
// instead of spend:
//
//   Ledger   every row, in order          → the dense list, nothing above it
//   Focus    one thing, front and centre  → the single item that needs you
//   Bento    equal tiles, scan anywhere   → the priority board
//   Ask      ask first, results follow    → question box, items as context
//   Cockpit  instruments and alarms       → gauges + alarm panel over a list
//   Canvas   ambient, second screen       → an editorial headline, almost no chrome
//   Stream   what happened, newest first  → a timestamped river
//   Atlas    side by side, with deltas    → needs-you against everything else

/// How Home arranges itself.
///
/// Separate from `DashboardLayout` so a shell can be shared by two layouts (or
/// swapped underneath one) without touching a persisted raw value.
enum DashboardHomeShell: String, CaseIterable, Sendable {
    /// One ordered list, full width or with a reading pane. No hero.
    case ledger
    /// The single item that needs you, at headline size.
    case focus
    /// Priority columns of equal-weight cards.
    case bento
    /// A question box first; items are the context underneath it.
    case ask
    /// Gauges and alarm states over a compact list.
    case cockpit
    /// An editorial headline with the fewest elements of any shell.
    case canvas
    /// A timestamped river, newest first.
    case stream
    /// Needs-you against everything else, with the gap spelled out.
    case atlas
}

/// Everything Home needs to know about the active layout.
struct DashboardHomeComposition: Equatable, Sendable {
    let shell: DashboardHomeShell
    /// Which inbox presentation the shell embeds. Only read by shells that
    /// render `InboxView`; a bespoke shell owns its own rows.
    let inboxMode: DashboardHomeInboxMode
    /// Whether the fleet + quota rail belongs beside this shell by default.
    ///
    /// A default, never a lock: the user's collapse toggle still wins, exactly
    /// like the narrow band forcing the stub without writing the stored key.
    let prefersRail: Bool
    /// Whether the Reader/Triage/Board switcher is meaningful here.
    ///
    /// False for shells that are not a variation on the inbox list — showing a
    /// switcher whose options do nothing is worse than showing none.
    let honorsInboxMode: Bool

    static func resolve(layout: DashboardLayout) -> DashboardHomeComposition {
        switch layout {
        case .classic:
            return .init(shell: .ledger, inboxMode: .reader, prefersRail: true, honorsInboxMode: true)
        case .aurora:
            return .init(shell: .focus, inboxMode: .triage, prefersRail: false, honorsInboxMode: false)
        case .nebula:
            return .init(shell: .bento, inboxMode: .board, prefersRail: true, honorsInboxMode: false)
        case .constellation:
            return .init(shell: .ask, inboxMode: .triage, prefersRail: false, honorsInboxMode: false)
        case .cockpit:
            return .init(shell: .cockpit, inboxMode: .triage, prefersRail: true, honorsInboxMode: false)
        case .atelier:
            return .init(shell: .canvas, inboxMode: .triage, prefersRail: false, honorsInboxMode: false)
        case .stream:
            return .init(shell: .stream, inboxMode: .triage, prefersRail: true, honorsInboxMode: false)
        case .atlas:
            return .init(shell: .atlas, inboxMode: .triage, prefersRail: true, honorsInboxMode: false)
        }
    }
}

extension DashboardHomeComposition {
    /// Opt-in key for the shells whose thesis is *not* having a rail.
    ///
    /// Two keys rather than one because the two questions are different: "did you
    /// collapse the rail on a rail-forward shell" and "did you deliberately bring
    /// it back on an ambient one". Folding them together made hiding it on Ledger
    /// also hide it on Cockpit.
    static let ambientRailStorageKey = "dashboard.home.rail.ambientOptIn"

    /// Which key governs rail visibility here, and whether `true` means visible.
    var railPreference: (key: String, showsWhenTrue: Bool) {
        prefersRail
            ? (DashboardHomeRailMetrics.collapsedStorageKey, false)
            : (Self.ambientRailStorageKey, true)
    }

    /// Flips rail visibility for this shell.
    ///
    /// Shared by the header button and the ⌘⌥R shortcut so a keystroke and a
    /// click can never disagree about which key they are writing.
    func toggleRail(in defaults: UserDefaults = .standard) {
        let preference = railPreference
        defaults.set(defaults.bool(forKey: preference.key) == false, forKey: preference.key)
    }
}

// MARK: - Digest

/// The facts every Home shell reads, derived once from the inbox rows.
///
/// Each shell needs a different cut of the same list — Focus wants exactly one
/// item, Atlas wants two buckets, Stream wants days, Cockpit wants ratios. Doing
/// that derivation per shell meant four different definitions of "urgent". This
/// is the single definition, computed once per render pass.
///
/// It also carries the two widenings every shell was missing:
///
///   * `payload` — the half of each row (evidence, actions, metrics, verdict)
///     the list query already loads and Home used to discard.
///   * `signals` — the rest of the system (spend, quota, fleet, projects,
///     providers, harness split), so a shell is not restricted to one table.
///
/// Both are additive: `HomeInboxDigest(rows:)` still compiles and still means
/// exactly what it meant, with `signals` reading `.unavailable` rather than a
/// fabricated zero.
struct HomeInboxDigest: Equatable {
    struct Day: Equatable, Identifiable {
        let date: Date
        let rows: [ControlPlaneStore.AIInboxRow]
        var id: Date { date }
    }

    let rows: [ControlPlaneStore.AIInboxRow]
    let urgent: [ControlPlaneStore.AIInboxRow]
    let today: [ControlPlaneStore.AIInboxRow]
    let later: [ControlPlaneStore.AIInboxRow]
    /// Everything the rows carry beyond their titles. Derived from the same
    /// `rows` in the same initializer, so the two can never drift apart.
    let payload: HomeInboxPayloadDigest
    /// Everything Home knows that is *not* the inbox.
    let signals: HomeSignalDigest

    var total: Int { rows.count }
    var unreadCount: Int { rows.filter(\.isUnread).count }
    var attentionCount: Int { urgent.count + today.count }

    /// The one item Focus and Canvas lead with: highest priority, then unread,
    /// then most recently seen. `nil` when the inbox is genuinely clear, which
    /// is a state both shells render deliberately rather than as a blank.
    var lead: ControlPlaneStore.AIInboxRow? {
        rows.min { lhs, rhs in
            if lhs.summary.priority != rhs.summary.priority {
                return lhs.summary.priority < rhs.summary.priority
            }
            if lhs.isUnread != rhs.isUnread { return lhs.isUnread }
            return lhs.summary.lastSeenAt > rhs.summary.lastSeenAt
        }
    }

    /// Share of the list that needs a decision now, 0...1. Cockpit's load gauge.
    var attentionLoad: Double {
        guard total > 0 else { return 0 }
        return Double(attentionCount) / Double(total)
    }

    /// Share still unread, 0...1.
    var unreadShare: Double {
        guard total > 0 else { return 0 }
        return Double(unreadCount) / Double(total)
    }

    /// Kinds ranked by how many items carry them, with occurrence totals — the
    /// ladder Atlas ranks and Ask turns into suggestions.
    var kindRanking: [(kind: BurnBarInboxItemKind, count: Int, occurrences: Int)] {
        var counts: [BurnBarInboxItemKind: (count: Int, occurrences: Int)] = [:]
        for row in rows {
            var entry = counts[row.summary.kind] ?? (0, 0)
            entry.count += 1
            entry.occurrences += max(1, row.summary.occurrenceCount)
            counts[row.summary.kind] = entry
        }
        return counts
            .map { (kind: $0.key, count: $0.value.count, occurrences: $0.value.occurrences) }
            .sorted {
                $0.count == $1.count
                    ? $0.occurrences > $1.occurrences
                    : $0.count > $1.count
            }
    }

    /// Rows grouped into calendar days, newest day first, newest row first.
    ///
    /// Stream's only axis. Uses `lastSeenAt` rather than `firstSeenAt`: a
    /// recurring detector that fired again this morning belongs at the top of
    /// today, not buried under the day it was first noticed.
    func days(calendar: Calendar = .current) -> [Day] {
        let grouped = Dictionary(grouping: rows) {
            calendar.startOfDay(for: $0.summary.lastSeenAt)
        }
        return grouped
            .map { Day(date: $0.key, rows: $0.value.sorted { $0.summary.lastSeenAt > $1.summary.lastSeenAt }) }
            .sorted { $0.date > $1.date }
    }

    init(
        rows: [ControlPlaneStore.AIInboxRow],
        signals: HomeSignalDigest = .unavailable
    ) {
        self.rows = rows
        self.urgent = rows.filter { $0.summary.priority == .p1 }
        self.today = rows.filter { $0.summary.priority == .p2 }
        self.later = rows.filter { $0.summary.priority == .p3 || $0.summary.priority == .p4 }
        self.payload = HomeInboxPayloadDigest(rows: rows)
        self.signals = signals
    }
}

// MARK: - Inbox payload digest

/// The half of every inbox row Home used to load and throw away.
///
/// `ControlPlaneStore.fetchAIInboxRows` selects `payload_json` for every row, so
/// each `AIInboxRow` already carries its evidence citations, its declarative
/// actions, the deterministic detector metrics behind it, and the verifier's
/// verdict. Home read `summary.title` and dropped the rest — seven shells
/// rendering headlines over a payload that could have told them *why*, and what
/// to press.
///
/// Rolled up here, from the same rows, in the same initializer, so the rollup
/// can never disagree with the list it came from.
struct HomeInboxPayloadDigest: Equatable {

    /// One detector metric key, rolled up across every row that reported it.
    struct Metric: Equatable, Identifiable {
        let key: String
        /// How many rows reported this key.
        let rowCount: Int
        /// Sum across those rows — `nil` unless EVERY value parsed as a number.
        ///
        /// `BurnBarInboxItemPayload.metrics` is `[String: String]` precisely
        /// because some detector metrics are not numbers, so a partial sum
        /// would be a fabricated total rather than a smaller one.
        let total: Double?

        var id: String { key }
    }

    /// Every citation behind the open list, deduped by id, most recent first.
    let evidence: [BurnBarInboxEvidence]
    /// Every suggested next step, deduped by id, primary actions first.
    ///
    /// Actions are safe to surface anywhere: their `value` is always built in
    /// Swift from a real evidence record, never from model output.
    let actions: [BurnBarInboxAction]
    /// Detector metrics, ranked by how many rows reported them.
    let metrics: [Metric]
    /// How many rows carry each verifier verdict.
    ///
    /// Note `.unverified` is a real verdict — "a verifier ran and could not
    /// reach a conclusion" — and is distinct from `unverifiedRowCount`, which
    /// counts rows no verification pass ever touched.
    let verdictCounts: [BurnBarInboxVerification.Verdict: Int]
    /// Rows carrying no verification block at all.
    let unverifiedRowCount: Int
    /// Durable facts the inbox *proposed*. Nothing here is an applied memory;
    /// approval still happens through the quarantine flow.
    let memoryCandidateCount: Int

    static let empty = HomeInboxPayloadDigest(rows: [])

    /// Rows the verifier positively stood behind — `confirmed`, or the
    /// deterministic re-check that needed no model call at all.
    var corroboratedCount: Int {
        (verdictCounts[.confirmed] ?? 0) + (verdictCounts[.deterministic] ?? 0)
    }

    /// Rows a verifier actively knocked down. Worth showing: an inbox that
    /// refutes its own findings is more trustworthy, not less.
    var refutedCount: Int { verdictCounts[.refuted] ?? 0 }

    /// The one action Home can offer without asking which item you meant.
    var leadAction: BurnBarInboxAction? { actions.first }

    init(rows: [ControlPlaneStore.AIInboxRow]) {
        var evidence: [BurnBarInboxEvidence] = []
        var seenEvidence: Set<String> = []
        // Index-carrying so the primary-first sort stays deterministic:
        // `sorted(by:)` is not stable, and two primary actions from different
        // rows must not be able to swap places between renders.
        var rankedActions: [(index: Int, action: BurnBarInboxAction)] = []
        var seenActions: Set<String> = []
        var metricValues: [String: [String]] = [:]
        var verdicts: [BurnBarInboxVerification.Verdict: Int] = [:]
        var unverifiedRows = 0
        var memoryCandidates = 0

        for row in rows {
            let payload = row.payload
            for item in payload.evidence where seenEvidence.insert(item.id).inserted {
                evidence.append(item)
            }
            for action in payload.actions where seenActions.insert(action.id).inserted {
                rankedActions.append((rankedActions.count, action))
            }
            for (key, value) in payload.metrics {
                metricValues[key, default: []].append(value)
            }
            if let verification = payload.verification {
                verdicts[verification.verdict, default: 0] += 1
            } else {
                unverifiedRows += 1
            }
            memoryCandidates += payload.memoryCandidates.count
        }

        self.evidence = evidence.sorted(by: Self.isNewer)
        self.actions = rankedActions
            .sorted {
                $0.action.isPrimary == $1.action.isPrimary
                    ? $0.index < $1.index
                    : $0.action.isPrimary
            }
            .map(\.action)
        self.metrics = metricValues
            .map { key, values in
                let parsed = values.compactMap { Double($0) }
                return Metric(
                    key: key,
                    rowCount: values.count,
                    total: parsed.count == values.count ? parsed.reduce(0, +) : nil
                )
            }
            .sorted { $0.rowCount == $1.rowCount ? $0.key < $1.key : $0.rowCount > $1.rowCount }
        self.verdictCounts = verdicts
        self.unverifiedRowCount = unverifiedRows
        self.memoryCandidateCount = memoryCandidates
    }

    /// Newest citation first; undated citations sort last, then by id so the
    /// order is total rather than merely mostly-decided.
    private static func isNewer(_ lhs: BurnBarInboxEvidence, _ rhs: BurnBarInboxEvidence) -> Bool {
        switch (lhs.occurredAt, rhs.occurredAt) {
        case let (left?, right?):
            return left == right ? lhs.id < rhs.id : left > right
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            return lhs.id < rhs.id
        }
    }
}

// MARK: - System signals

/// One window of spend, as Home reads it.
///
/// Home never received this: `DashboardUsageViewModel` computes it for the
/// Overview route and the launch surface asked for none of it.
struct HomeSpendSignal: Equatable {
    let cost: Double
    let tokens: Int
    let sessionCount: Int
    /// How many providers actually spent inside the window.
    let activeProviderCount: Int
    /// Mean spend across the days that carry any usage at all — the baseline
    /// `DashboardUsageViewModel` already maintains, not one recomputed here.
    let rollingDailyAverage: Double
    /// Share of prompt tokens served from cache, 0...1. `nil` when nothing in
    /// the window reported a cache basis to divide by.
    let cacheHitRate: Double?

    /// This window against a typical day, as a signed fraction (`+0.4` is 40%
    /// above typical). `nil` when there is no baseline: a first run has no
    /// typical day, and must not be told it is infinitely over one.
    var deltaVsTypicalDay: Double? {
        guard rollingDailyAverage > 0 else { return nil }
        return cost / rollingDailyAverage - 1
    }

    /// Whether anything at all happened in the window. False is a real answer —
    /// a quiet day — and shells should say so rather than render an empty plate.
    var hasSpend: Bool { cost > 0 || tokens > 0 || sessionCount > 0 }
}

/// What Home can honestly say about headroom.
struct HomeQuotaSignal: Equatable {
    /// The tightest window across every provider.
    ///
    /// Derived by `TightestQuotaWindow.tightest(across:)` — the same call the
    /// menu bar, the first-run reveal, the quota workspace, the widget and the
    /// iOS Live Activity make — so Home cannot disagree with them about what
    /// "tightest" means. `nil` when nothing carries a real percentage, which is
    /// that type's honesty contract and not a bug to paper over.
    let tightest: TightestQuotaWindow?
    /// The tightest window *within* each provider that has one, tightest first.
    /// Exactly one entry per provider, so `providerDisplayName` identifies a row.
    let perProvider: [TightestQuotaWindow]
    /// Providers holding a snapshot that carries no real percentage anywhere.
    /// Counted, never folded into the measured set — an agent we cannot measure
    /// must not be able to win, or lose, a comparison about measurement.
    let unmeasuredProviderCount: Int

    var measuredProviderCount: Int { perProvider.count }

    /// Derives both cuts from one pass over the snapshots.
    static func derive(
        from snapshots: [ProviderQuotaSnapshot],
        asOf now: Date = Date()
    ) -> HomeQuotaSignal {
        var perProvider: [TightestQuotaWindow] = []
        var unmeasured = 0
        for snapshot in snapshots {
            // Running the shared derivation over a one-element array gives the
            // per-provider winner under exactly the fleet-wide rules, instead
            // of a second, subtly different definition of "tightest" here.
            if let window = TightestQuotaWindow.tightest(across: [snapshot], asOf: now) {
                perProvider.append(window)
            } else {
                unmeasured += 1
            }
        }
        return HomeQuotaSignal(
            tightest: TightestQuotaWindow.tightest(across: snapshots, asOf: now),
            perProvider: perProvider.sorted {
                $0.remainingPercent == $1.remainingPercent
                    ? $0.providerDisplayName < $1.providerDisplayName
                    : $0.remainingPercent < $1.remainingPercent
            },
            unmeasuredProviderCount: unmeasured
        )
    }
}

/// What Home can honestly say about the fleet.
///
/// A projection of `LiveFleetModel`, not a second opinion: it carries the rows
/// verbatim and only counts them, so the rail and a shell can never report a
/// different number of active agents.
struct HomeFleetSignal: Equatable {
    let rows: [FleetAgentRow]
    /// True when at least one real-time source is armed, so a shell can say
    /// "watched live" rather than "as of the last scan".
    let hasRealTimeCoverage: Bool
    /// When the parsed-usage snapshot was last rebuilt.
    let lastScanAt: Date?
    /// Set while the display slept and the watchers were torn down; every
    /// non-live timestamp is pre-sleep and must not read as current.
    let sleepGapReason: String?

    static let empty = HomeFleetSignal(
        rows: [],
        hasRealTimeCoverage: false,
        lastScanAt: nil,
        sleepGapReason: nil
    )

    var total: Int { rows.count }

    /// The same count the rail's header shows — `LiveFleetModel.activeCount`
    /// is this expression over the same rows.
    var activeCount: Int { rows.filter(\.liveness.isActive).count }

    /// Agents that structurally cannot run: needs auth, out of quota, not
    /// installed, gateway unreachable.
    var blockedCount: Int {
        rows.filter {
            if case .blocked = $0.liveness { return true }
            return false
        }
        .count
    }

    /// Agents we cannot see at all. Never rendered as "idle" — there is no such
    /// state, and absence of a write is not evidence of one.
    var unobservableCount: Int {
        rows.filter {
            if case .unobservable = $0.liveness { return true }
            return false
        }
        .count
    }

    /// Share of rows whose most recent evidence is real-time rather than a
    /// parsed row from the last scan, 0...1. Zero on an empty fleet.
    var realTimeCoverage: Double {
        guard total > 0 else { return 0 }
        return Double(rows.filter { $0.liveness.source?.isRealTime == true }.count) / Double(total)
    }
}

/// One project's slice of the window.
struct HomeProjectSignal: Equatable, Identifiable {
    let projectName: String
    let cost: Double
    let tokens: Int
    let sessionCount: Int
    /// Share of the window's total spend, 0...1.
    let costShare: Double
    /// True when any row feeding this project used estimated provenance.
    let isEstimated: Bool

    var id: String { projectName }

    static func rank(_ summaries: [ProjectSpendSummary], totalCost: Double) -> [HomeProjectSignal] {
        summaries
            .map { summary in
                HomeProjectSignal(
                    projectName: summary.projectName,
                    cost: summary.totalCost,
                    tokens: summary.totalTokens,
                    sessionCount: summary.sessionCount,
                    costShare: totalCost > 0 ? summary.totalCost / totalCost : 0,
                    isEstimated: summary.hasEstimatedContributions
                )
            }
            .sorted { $0.cost == $1.cost ? $0.projectName < $1.projectName : $0.cost > $1.cost }
    }
}

/// One provider's slice of the window.
struct HomeProviderSignal: Equatable, Identifiable {
    let provider: AgentProvider
    let cost: Double
    let tokens: Int
    let sessionCount: Int
    /// Share of the window's total spend, 0...1.
    let costShare: Double
    /// True when any row feeding this provider used estimated provenance —
    /// the dagger the `docs/PROVIDERS.md` discipline requires be visible.
    let isEstimated: Bool

    var id: String { provider.rawValue }

    static func rank(_ summaries: [ProviderSummary], totalCost: Double) -> [HomeProviderSignal] {
        summaries
            .map { summary in
                HomeProviderSignal(
                    provider: summary.provider,
                    cost: summary.totalCost,
                    tokens: summary.totalTokens,
                    sessionCount: summary.sessionCount,
                    costShare: totalCost > 0 ? summary.totalCost / totalCost : 0,
                    isEstimated: summary.hasEstimatedContributions
                )
            }
            .sorted { $0.cost == $1.cost ? $0.provider.rawValue < $1.provider.rawValue : $0.cost > $1.cost }
    }
}

/// Where the work actually ran — CLI, IDE, desktop app, service, automation.
///
/// `TokenUsage.executionSourceKind` has been stamped on every row since the v57
/// migration and no Home surface has ever read it, so "which harness is
/// spending this" was a question the launch screen could already answer and did
/// not ask.
struct HomeHarnessSignal: Equatable, Identifiable {
    let kind: UsageExecutionSourceKind
    let cost: Double
    /// Distinct sessions, not rows: one long session emitting fifty usage rows
    /// is one session, and counting rows would make chatty harnesses look busy.
    let sessionCount: Int
    /// Share of the window's total spend, 0...1.
    let costShare: Double

    var id: String { kind.rawValue }

    static func rank(_ usages: [TokenUsage]) -> [HomeHarnessSignal] {
        var costs: [UsageExecutionSourceKind: Double] = [:]
        var sessions: [UsageExecutionSourceKind: Set<String>] = [:]
        var total: Double = 0

        for usage in usages {
            costs[usage.executionSourceKind, default: 0] += usage.cost
            sessions[usage.executionSourceKind, default: []].insert(usage.sessionId)
            total += usage.cost
        }

        return costs
            .map { kind, cost in
                HomeHarnessSignal(
                    kind: kind,
                    cost: cost,
                    sessionCount: sessions[kind]?.count ?? 0,
                    costShare: total > 0 ? cost / total : 0
                )
            }
            .sorted { $0.cost == $1.cost ? $0.kind.rawValue < $1.kind.rawValue : $0.cost > $1.cost }
    }
}

// MARK: - System signal digest

/// Everything Home knows that is not the inbox, derived once per render pass.
///
/// The problem this exists to solve: every Home shell read exactly one
/// derivation — `HomeInboxDigest` — and that digest contained only AI-inbox
/// rows. Seven themes, one table. Widening the digest widens all seven at once,
/// because they all read the same value.
///
/// Same discipline as `HomeInboxDigest`: a pure `Equatable` value derived once
/// at the view level and handed down, so a shell stays a function of its
/// inputs and every figure in it can be pinned by a test without mounting a
/// window.
///
/// HONESTY: an unavailable source is `nil` or empty. Nothing here fabricates a
/// zero, and no field is ever filled in from a neighbouring one.
struct HomeSignalDigest: Equatable {
    /// Spend in the window Home reads. `nil` while the usage store is still
    /// doing its first scan and has produced nothing — "we cannot say yet" is a
    /// different sentence from "$0 today", and only one of them is true then.
    let spend: HomeSpendSignal?
    /// `nil` when no provider has published a snapshot at all. Present with a
    /// `nil` `tightest` when snapshots exist but none carries a real percentage.
    let quota: HomeQuotaSignal?
    let fleet: HomeFleetSignal
    /// Projects in the window, biggest spender first.
    let projects: [HomeProjectSignal]
    /// Providers in the window, biggest spender first.
    let providers: [HomeProviderSignal]
    /// The harness split, biggest spender first.
    let harness: [HomeHarnessSignal]

    /// The placeholder `HomeInboxDigest(rows:)` carries when no caller supplied
    /// sources — a plain inbox digest, exactly as before this widening. Every
    /// field reads unknown or empty; none of them reads zero.
    static let unavailable = HomeSignalDigest(
        spend: nil,
        quota: nil,
        fleet: .empty,
        projects: [],
        providers: [],
        harness: []
    )

    /// True when not one source produced anything. Distinct from "everything is
    /// zero": shells use it to choose between "nothing yet" and "a quiet day".
    var isUnavailable: Bool {
        spend == nil && quota == nil && fleet.total == 0
            && projects.isEmpty && providers.isEmpty && harness.isEmpty
    }

    /// Assembles the whole-system cut from the sources Home already holds.
    ///
    /// Takes plain values rather than a `DataStore` so the derivation is a pure
    /// function under test — the reason every figure below can be pinned.
    static func derive(
        window: DashboardUsageWindowSummary,
        rollingDailyAverage: Double,
        isScanning: Bool,
        quotaSnapshots: [ProviderQuotaSnapshot],
        fleet: HomeFleetSignal,
        asOf now: Date = Date()
    ) -> HomeSignalDigest {
        let windowHasRows = window.usages.isEmpty == false
            || window.sessionCount > 0
            || window.totalCost > 0
        let spend: HomeSpendSignal? = (windowHasRows || isScanning == false)
            ? HomeSpendSignal(
                cost: window.totalCost,
                tokens: window.totalTokens,
                sessionCount: window.sessionCount,
                activeProviderCount: window.activeProviderCount,
                rollingDailyAverage: rollingDailyAverage,
                cacheHitRate: window.cacheEfficiency.hitRate
            )
            : nil

        return HomeSignalDigest(
            spend: spend,
            quota: quotaSnapshots.isEmpty ? nil : .derive(from: quotaSnapshots, asOf: now),
            fleet: fleet,
            projects: HomeProjectSignal.rank(window.projectSpendSummaries, totalCost: window.totalCost),
            providers: HomeProviderSignal.rank(window.providerSummaries, totalCost: window.totalCost),
            harness: HomeHarnessSignal.rank(window.usages)
        )
    }
}
