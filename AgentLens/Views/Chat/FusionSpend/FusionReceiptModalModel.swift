import Foundation
import OpenBurnBarCore

// MARK: - Fusion Receipt Modal Model
//
// The source object behind `FusionReceiptModal` — the macOS end-of-session
// receipt for one Elder Wand model-fusion run. Given the just-finished signal
// (a fresh client-minted token), it:
//
//   1. reads the daemon usage ledger over the Unix socket
//      (`OpenBurnBarDaemonSocketClient.recentUsage(at:limit:)`), which is the
//      ONLY app read path that preserves `parentRequestID` — it is dropped on
//      SQLite import;
//   2. maps each `BurnBarUsageEvent` to a flat `FusionUsageRow`, parsing the
//      stage label from the recorded idempotency key when the read path carries
//      it, and otherwise inferring the stage from order/role within the run;
//   3. runs `FusionSpendAggregator.newestSession(from:)` to fold the rows into
//      one itemized `FusionSessionSpend`;
//   4. surfaces the period `fusion_searches` quota bucket for the receipt's ring.
//
// WHY "NEWEST" SESSION, NOT A THREADED ID:
// The daemon mints `parentRequestID = elderwand-<UUID>` server-side and stamps
// every panel/judge/synthesis sub-call with it, but that id is NOT sent back to
// the client over SSE — the client mints its OWN session token. So the modal
// cannot key on the daemon id; it keys on the NEWEST `elderwand-` group at
// synthesis completion. This is exactly correct for the serialized real-world
// case (one fusion at a time, the modal fires the instant a run completes). If
// concurrent fusion runs ever land in the same ledger window, the newest-by-
// completion heuristic still resolves to the run that just finished.
//
// Token discipline: `recentUsage` is a blocking socket round-trip, so the load
// runs OFF the main actor through the daemon manager's `@Sendable` dependency
// closure; only the observable-state writes hop back to the main actor.

@Observable
@MainActor
final class FusionReceiptModalModel {

    /// Where the load is in its lifecycle, so the modal can show a spinner,
    /// the receipt, an empty/duress state, or a read error honestly.
    enum LoadState: Equatable {
        case idle
        case loading
        /// The run resolved to a session (which may itself be a partial/duress
        /// run when synthesis never recorded — the view inspects `synthesisItem`).
        case loaded
        /// No `elderwand-` rows were found in the ledger window — nothing to show.
        case empty
        /// The ledger read failed (socket down, decode error). Carries a short
        /// human-readable reason for the view.
        case failed(String)
    }

    // MARK: Observable state

    /// The just-finished fusion run, folded from the ledger. `nil` until the
    /// load resolves (or when the window held no fusion rows).
    private(set) var session: FusionSessionSpend?

    /// The period `fusion_searches` quota bucket (used / limit / remaining) for
    /// the receipt ring. `nil` when no snapshot is available — the view then
    /// omits the ring rather than inventing a cap. The displayed limit is
    /// already `min(monthlyCap, included + purchased)`; this object never
    /// re-derives a cap from the subscription tier.
    private(set) var quotaBucket: ProviderQuotaBucket?

    /// Month-to-date token total for the models that appear in this run, so the
    /// receipt can footnote "these models cost N tokens this month". Summed from
    /// the same ledger read, restricted to the current calendar month.
    private(set) var monthToDateModelTokens: Int = 0

    private(set) var loadState: LoadState = .idle

    // MARK: Seams (injected so the view layer compiles and tests standalone)

    /// Off-main ledger read. Defaults to the live daemon manager's `@Sendable`
    /// dependency closure, resolved against the daemon socket URL. Injectable so
    /// tests and previews can feed deterministic rows without a running daemon.
    private let loadUsageEvents: @Sendable (_ limit: Int) async throws -> [BurnBarUsageEvent]

    /// The period `fusion_searches` quota bucket source. The live default reads
    /// `users/{uid}/quota_snapshots/openburnbar_elder_wand_fusion` via
    /// `FusionSearchQuotaReader` and maps its hosted-searches bucket; it returns
    /// `nil` (and the view omits the ring) when no snapshot or uid is available.
    /// Resolved on the main actor alongside the session.
    private let loadQuotaBucket: @MainActor () async -> ProviderQuotaBucket?

    /// How many ledger rows to pull. A fusion run is at most ~10 sub-calls
    /// (8 panel + judge + synthesis); a generous window keeps the newest run
    /// fully captured even when a few normal completions interleave.
    private let usageReadLimit: Int

    // MARK: Init

    /// Live initializer — binds to the running daemon manager. The socket URL
    /// and the `@Sendable` read closure are captured on the main actor here so
    /// the actual round-trip can run off-main.
    init(
        daemonManager: OpenBurnBarDaemonManager = .shared,
        usageReadLimit: Int = 40,
        quotaBucketProvider: @escaping @MainActor () async -> ProviderQuotaBucket? = { await FusionSearchQuotaReader.fetchBucket() }
    ) {
        let socketURL = daemonManager.paths.socketURL
        let request = daemonManager.dependencies.requestRecentUsage
        self.loadUsageEvents = { limit in
            // `requestRecentUsage` is a blocking, throwing socket call; hop off
            // the main actor so the modal's load never stalls the UI.
            try await Task.detached(priority: .userInitiated) {
                try request(socketURL, limit)
            }.value
        }
        self.loadQuotaBucket = quotaBucketProvider
        self.usageReadLimit = usageReadLimit
    }

    /// Test / preview initializer — feed rows and a bucket directly.
    init(
        usageReadLimit: Int = 40,
        loadUsageEvents: @escaping @Sendable (_ limit: Int) async throws -> [BurnBarUsageEvent],
        quotaBucketProvider: @escaping @MainActor () async -> ProviderQuotaBucket? = { nil }
    ) {
        self.loadUsageEvents = loadUsageEvents
        self.loadQuotaBucket = quotaBucketProvider
        self.usageReadLimit = usageReadLimit
    }

    // MARK: Load

    /// Resolve the newest fusion run from the ledger and read the period quota.
    /// Idempotent: safe to call again (e.g. on a manual refresh) — it always
    /// re-reads and re-folds.
    func load() async {
        loadState = .loading

        let events: [BurnBarUsageEvent]
        do {
            events = try await loadUsageEvents(usageReadLimit)
        } catch is CancellationError {
            // The modal was dismissed mid-load; leave state untouched.
            return
        } catch {
            loadState = .failed(Self.readErrorMessage(error))
            return
        }

        let rows = Self.rows(from: events)
        let newest = FusionSpendAggregator.newestSession(from: rows)

        session = newest
        quotaBucket = await loadQuotaBucket()
        monthToDateModelTokens = Self.monthToDateTokens(
            for: newest,
            from: rows,
            now: Date()
        )

        loadState = newest == nil ? .empty : .loaded
    }

    // MARK: - Row projection (pure, testable)

    /// Project recorded usage events into the flat rows the aggregator folds.
    ///
    /// `BurnBarUsageEvent` carries `parentRequestID` (preserved on the daemon
    /// read path) but NOT the idempotency key, so the per-event stage label is
    /// unavailable from the contract type alone. We therefore group the fusion
    /// rows by `parentRequestID` and INFER the stage from order/role within each
    /// run — the same ordering the orchestrator records sub-calls in:
    /// panel members first (recorded earliest), then the judge, then the single
    /// synthesis (recorded last, and the originating model — its row is the solo
    /// baseline). `FusionStage.parse` re-reads the inferred label downstream, so
    /// the inference is expressed as the label string the aggregator expects.
    static func rows(from events: [BurnBarUsageEvent]) -> [FusionUsageRow] {
        // Index each fusion event's position within its run so we can hand the
        // aggregator a synthetic stage label when no recorded one exists.
        var byParent: [String: [BurnBarUsageEvent]] = [:]
        for event in events where event.parentRequestID?.hasPrefix(FusionUsageRow.fusionParentPrefix) == true {
            byParent[event.parentRequestID!, default: []].append(event)
        }

        var inferredStage: [ObjectIdentifierKey: String] = [:]
        for (_, runEvents) in byParent {
            // Stable order: earliest-recorded first. Ties (same instant) fall back
            // to model id so the inference is deterministic across reads.
            let ordered = runEvents.sorted { lhs, rhs in
                lhs.recordedAt != rhs.recordedAt
                    ? lhs.recordedAt < rhs.recordedAt
                    : lhs.modelID < rhs.modelID
            }
            // The LAST sub-call is the synthesis (the originating model running
            // once over the judged panel); the second-to-last, when present, is
            // the judge; everything before is a panel member, indexed by order.
            let count = ordered.count
            for (offset, event) in ordered.enumerated() {
                let label: String
                if offset == count - 1 {
                    label = "synthesis"
                } else if offset == count - 2, count >= 3 {
                    label = "judge"
                } else {
                    label = "panel[\(offset)]"
                }
                inferredStage[ObjectIdentifierKey(event)] = label
            }
        }

        return events.map { event in
            // Prefer a recorded stage label if a future read path ever carries
            // one on the event; today the contract type does not, so fall back
            // to the inferred order/role label for fusion rows (nil for normal).
            let stageLabel: String?
            if event.parentRequestID?.hasPrefix(FusionUsageRow.fusionParentPrefix) == true {
                stageLabel = inferredStage[ObjectIdentifierKey(event)]
            } else {
                stageLabel = nil
            }
            return FusionUsageRow(event: event, stageLabel: stageLabel)
        }
    }

    /// Sum the current-calendar-month tokens for every model that appears in
    /// `session`, across both fusion and normal rows — the receipt's
    /// "month-to-date" footnote. Returns 0 when there is no session.
    static func monthToDateTokens(
        for session: FusionSessionSpend?,
        from rows: [FusionUsageRow],
        now: Date,
        calendar: Calendar = .current
    ) -> Int {
        guard let session else { return 0 }
        let models = Set(session.lineItems.map(\.modelID))
        guard !models.isEmpty else { return 0 }
        let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? now
        return rows.reduce(0) { running, row in
            guard models.contains(row.modelID), row.recordedAt >= monthStart else { return running }
            return running + row.totalTokens
        }
    }

    // MARK: - Helpers

    private static func readErrorMessage(_ error: Error) -> String {
        let raw = error.localizedDescription
        return raw.isEmpty ? "Could not read the usage ledger." : raw
    }
}

// MARK: - Identity key

/// A `Hashable` wrapper keying a dictionary by an event's identity within one
/// `rows(from:)` pass. `BurnBarUsageEvent` is a value type (no stable id), so we
/// key on a structural digest that is unique within a single read window — the
/// recorded instant plus the model and parent — which suffices because the
/// inference dictionary is local to one `rows(from:)` call.
private struct ObjectIdentifierKey: Hashable {
    let recordedAt: Date
    let modelID: String
    let parentRequestID: String?
    let inputTokens: Int
    let outputTokens: Int

    init(_ event: BurnBarUsageEvent) {
        self.recordedAt = event.recordedAt
        self.modelID = event.modelID
        self.parentRequestID = event.parentRequestID
        self.inputTokens = event.inputTokens
        self.outputTokens = event.outputTokens
    }
}
