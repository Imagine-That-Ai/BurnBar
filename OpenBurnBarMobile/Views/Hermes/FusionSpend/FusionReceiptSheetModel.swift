import Foundation
import OpenBurnBarCore
import OSLog

// MARK: - Fusion Receipt Sheet Model (iOS)
//
// The state behind `FusionReceiptSheet` — the end-of-session receipt for one
// Elder Wand fusion run. It reconciles two independent signals:
//
//   1. The per-sub-call spend (`FusionSessionSpend` — panel members, judge,
//      synthesis), summed into the session total shown on the foil hero.
//   2. The authoritative `fusion_searches` quota ring, read from the
//      `users/{uid}/quota_snapshots/openburnbar_elder_wand_fusion` snapshot.
//
// ── iOS HONESTY CONSTRAINT (read before changing the data flow) ────────────
//
// iOS fusion runs do NOT execute on this device: the Mac daemon gateway runs
// `ElderWandFusionOrchestrator` (panel + judge), and the answer streams back
// over the iroh relay. Today the relay forwards only the synthesized text and
// aggregate token usage — it does NOT forward the per-sub-call ledger lines
// (each carries the daemon's `parentRequestID` / stage token, and that field is
// dropped before it reaches the client). So on iOS there is, as of this writing,
// NO local per-sub-call token spend for a just-finished run.
//
// Rather than fabricate a breakdown, the model renders in one of two honest
// modes, chosen by whether a `FusionSessionSpend` was supplied:
//
//   • `.itemized`  — a real `FusionSessionSpend` exists (every line item, the
//     multiplier, the total). This is the path that lights up automatically the
//     day the relay forwards per-sub-call spend: build the session with
//     `FusionSpendAggregator.newestSession(from:)` over the forwarded rows and
//     pass it to `init(session:…)`. The view does not change.
//   • `.quotaOnly` — no per-sub-call spend is available. The receipt still shows
//     the authoritative `fusion_searches` ring (the one number the server is
//     fully truthful about on iOS) plus a clear "detailed token breakdown shows
//     on your Mac" note. No invented totals, no estimated line items.
//
// ── parentRequestID assumption (matches the locked spine) ──────────────────
//
// The daemon mints `elderwand-<UUID>` as the run's `parentRequestID`, but that
// id is never sent to the client over SSE — the client mints its own session
// id. So when the line-item path is wired, the modal keys on the NEWEST
// `elderwand-` group at synthesis completion
// (`FusionSpendAggregator.newestSession`). That is correct for the serialized
// real-world case (one fusion at a time, modal fires the instant the run
// finishes); see the note on `FusionSpendAggregator.newestSession`.

private let fusionReceiptLogger = Logger(
    subsystem: "com.openburnbar.mobile",
    category: "FusionReceiptSheetModel"
)

@Observable
@MainActor
final class FusionReceiptSheetModel {

    /// How much of the receipt we can show truthfully for this run.
    enum Mode: Equatable {
        /// A real per-sub-call breakdown is available — render the itemized
        /// receipt with the summed total and multiplier.
        case itemized
        /// No per-sub-call spend reached this device — render the authoritative
        /// quota ring plus the "breakdown is on your Mac" note.
        case quotaOnly
    }

    /// The lifecycle of the authoritative `fusion_searches` quota read, kept
    /// distinct so a Firestore read error is never mistaken for "no searches
    /// used". `.empty` is the genuine zero/none case (a successful read with no
    /// fusion snapshot yet); `.failed` is a read error the view surfaces with a
    /// Retry affordance — matching the macOS modal's `.failed` honesty.
    enum QuotaLoadState: Equatable {
        case loading
        case loaded(ProviderQuotaBucket)
        case empty
        case failed
    }

    /// The itemized spend for the just-finished run, or `nil` when only the
    /// quota signal is available on this device today. When this is non-nil the
    /// view automatically renders every line item — no UI change is needed when
    /// relay spend-forwarding lands.
    private(set) var session: FusionSessionSpend?

    /// The authoritative `fusion_searches` quota read state. Drives the ring:
    /// `.loaded` shows the bucket, `.loading` shows a spinner, `.empty` shows the
    /// genuine "no searches used yet" copy, and `.failed` shows an error with a
    /// Retry affordance — never silently rendering "0 used" on a read error.
    private(set) var quotaLoadState: QuotaLoadState = .loading

    /// The loaded bucket, when the read succeeded and a snapshot exists. `nil` in
    /// every other state (`.loading` / `.empty` / `.failed`).
    var fusionBucket: ProviderQuotaBucket? {
        if case .loaded(let bucket) = quotaLoadState { return bucket }
        return nil
    }

    /// True while the quota snapshot is being fetched.
    var isLoadingQuota: Bool {
        if case .loading = quotaLoadState { return true }
        return false
    }

    /// True when the authoritative quota read failed — the view surfaces an
    /// error with Retry rather than an honest-looking "0 used".
    var quotaLoadFailed: Bool {
        if case .failed = quotaLoadState { return true }
        return false
    }

    private let firestore: FirestoreRepository

    /// The fusion quota snapshot the Functions writer publishes. Matched on the
    /// stable `sourceId` the writer sets ("elder-wand-fusion") with the document
    /// id ("openburnbar_elder_wand_fusion") as a fallback, so a future provider
    /// rename does not silently blank the ring.
    nonisolated private static let fusionSnapshotSourceID = "elder-wand-fusion"
    nonisolated private static let fusionSnapshotDocID = "openburnbar_elder_wand_fusion"

    /// Designated init.
    ///
    /// - Parameters:
    ///   - session: the itemized spend for the run, when available. Pass `nil`
    ///     for the quota-only path (today's iOS reality).
    ///   - firestore: the repository used for the authoritative single-snapshot
    ///     quota read. Injectable for previews/tests.
    init(
        session: FusionSessionSpend? = nil,
        firestore: FirestoreRepository = FirestoreRepository()
    ) {
        self.session = session
        self.firestore = firestore
    }

    /// The chosen render mode for this run.
    var mode: Mode {
        session == nil ? .quotaOnly : .itemized
    }

    /// The line items to render (empty in quota-only mode).
    var lineItems: [FusionSubCallSpend] {
        session?.lineItems ?? []
    }

    /// The session total — the SUM of the recorded sub-call costs. `nil` in
    /// quota-only mode (we never invent a total).
    var totalCost: Double? {
        session?.totalCost
    }

    /// The "cost of certainty" multiplier, when a positive solo baseline exists.
    /// `nil` when unavailable so the view omits the line rather than dividing by
    /// zero.
    var costMultiplier: Double? {
        session?.costMultiplier
    }

    /// Whether the session total is an exact (non-estimated) figure. `true`
    /// vacuously in quota-only mode (there is no total to qualify), so the
    /// estimate caption is driven by `showsEstimateCaption`.
    var isExactTotal: Bool {
        session?.aggregateConfidence.isExact ?? true
    }

    /// Whether to show the "≈ estimated" caption under the total. Only in the
    /// itemized mode, and only when at least one sub-call was an estimate.
    var showsEstimateCaption: Bool {
        guard let session else { return false }
        return session.aggregateConfidence.isExact == false
    }

    /// The number of models that contributed to the run (panel + judge +
    /// synthesis), for the headline subtitle. `nil` in quota-only mode.
    var contributingModelCount: Int? {
        guard let session else { return nil }
        return session.lineItems.count
    }

    // MARK: - Quota loading

    /// Fetch the authoritative `fusion_searches` bucket. Resolves into one of
    /// three terminal states so the view never lies: `.loaded(bucket)` on a
    /// successful read with a snapshot, `.empty` on a successful read with no
    /// fusion snapshot yet (genuinely "no searches used"), and `.failed` on a
    /// read error (the view shows Retry, never "0 used"). Safe to call from
    /// `.task` and re-callable as a Retry handler.
    ///
    /// Reads through `FirestoreRepository.fetchQuotaSnapshots()`, which returns
    /// the raw decoded snapshots WITHOUT the display-signal filter `QuotaStore`
    /// applies — `QuotaStore`'s filter drops the `openburnbar` fusion provider
    /// because it is not a routable quota-signal provider, so we deliberately
    /// read the snapshot directly here, matching the Functions writer.
    func loadQuota() async {
        quotaLoadState = .loading
        do {
            let snapshots = try await firestore.fetchQuotaSnapshots()
            if let bucket = Self.fusionBucket(in: snapshots) {
                quotaLoadState = .loaded(bucket)
            } else {
                quotaLoadState = .empty
            }
        } catch {
            fusionReceiptLogger.warning(
                "Fusion quota snapshot fetch failed: \(error.localizedDescription, privacy: .public)"
            )
            quotaLoadState = .failed
        }
    }

    /// Select the Elder Wand fusion search bucket from a set of raw quota
    /// snapshots. Static + `nonisolated` so it is unit-testable without a
    /// Firestore round-trip.
    nonisolated static func fusionBucket(in snapshots: [ProviderQuotaSnapshot]) -> ProviderQuotaBucket? {
        let fusionSnapshot = snapshots.first { snapshot in
            snapshot.sourceID == fusionSnapshotSourceID || snapshot.id == fusionSnapshotDocID
        }
        guard let fusionSnapshot else { return nil }
        // Reconcile a rolled-over month to its fresh window so a new billing
        // period shows 0 used / full remaining (same chokepoint every other
        // quota surface uses). Prefer the named search bucket; fall back to the
        // snapshot's first bucket if the writer ever renames it.
        let reconciled = fusionSnapshot.buckets.map { $0.reconcilingElapsedWindow() }
        return reconciled.first { $0.name.localizedCaseInsensitiveContains("search") }
            ?? reconciled.first
    }
}
