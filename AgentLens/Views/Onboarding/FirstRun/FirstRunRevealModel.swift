import Foundation
import OpenBurnBarKernel

// MARK: - First Run Reveal Model
//
// The 60 seconds. A stranger double-clicks the app and — with no account, no
// API key, and no OS permission prompt — watches it read what is already on
// their disk and hand back something true.
//
// The structural advantage this screen spends: `detectAvailableProviders()`
// already knows Claude Code, Codex and Cursor are here before the app finishes
// launching. Every competitor has to wait for the user to CREATE data. We only
// have to read it. That advantage is worth exactly one thing — the shortest
// honest path to a real number — and this model exists to protect it from
// wizards, tours, consent modals and pets.
//
// THE HERO DECISION (the honest half of the "two-beat reveal"):
//
// The original spec drew four vendors at four percentages at T+1.8s. That
// state is unreachable on a genuinely cold install, and for a good reason that
// is ours: the default `NoClaudeCredentialsReader` refuses to touch a third
// party's Keychain, so there is no plan cap to divide by, so there is no
// percentage yet. Rather than fake one or stall the screen waiting, the reveal
// picks its hero from what is actually true right now:
//
//   .quota — a real bucket exists  → the ring, the reset clock, the aha.
//   .spend — no bucket, real usage → dollars and sessions, plus an honest
//            promise that the percentage lands on the next agent run.
//   .empty — nothing at all        → the most reassuring screen in the product.
//
// So the two beats are structural, not timed: beat one is whatever is true at
// T+2s, and beat two arrives on its own when the statusline bridge fires
// (`ClaudeQuotaAdapter` installs it silently) or an API-backed provider
// resolves. A returning delight instead of a stalled spinner — and it is also
// the moment that earns the notification permission, because it arrives as
// news rather than as a prompt.

@MainActor
@Observable
final class FirstRunRevealModel {

    // MARK: Phase

    enum Phase: Equatable {
        /// Reading. `fraction` is real parse progress, never a fake timer.
        case scanning(fraction: Double)
        /// A real quota window exists. The best possible first sentence.
        case quota(TightestQuotaWindow, supporting: [SupportingRow])
        /// No window yet, but genuine usage. True, useful, and honest about
        /// what is still coming.
        case spend(SpendHero)
        /// Nothing on this Mac has burned a token.
        case empty(searchedPathCount: Int)
    }

    /// A secondary provider line under the hero.
    struct SupportingRow: Equatable, Identifiable {
        let providerDisplayName: String
        /// Nil renders as a word ("pool", "substantial"), never a fake percent.
        let remainingPercent: Double?
        let detail: String
        var id: String { providerDisplayName }
    }

    /// The cold-install hero: what they have actually spent, which is real on
    /// the very first pass because it comes from token counts on disk.
    struct SpendHero: Equatable {
        let monthToDateUSD: Double
        let sessionCount: Int
        let providerDisplayNames: [String]
        /// True when at least one provider is expected to produce a percentage
        /// once it next runs. Drives the promise line; suppressed when false so
        /// we never promise something that will not arrive.
        let expectsQuotaSignalSoon: Bool
    }

    // MARK: State

    private(set) var phase: Phase = .scanning(fraction: 0)
    /// Set once the reveal has been shown, so it can never re-present.
    private(set) var didReachTerminalPhase = false

    /// Hard ceiling on the scanning state. Past this we show the truest thing
    /// we have rather than spinning — a spinner that outlives its welcome is
    /// how a first run becomes an uninstall.
    static let degradeAfter: TimeInterval = 8.0

    private let searchedPathCount: Int
    private var startedAt: Date?

    init(searchedPathCount: Int) {
        self.searchedPathCount = searchedPathCount
    }

    // MARK: Ingestion

    /// Report real parse progress. Ignored once a terminal phase is reached.
    func reportProgress(fraction: Double) {
        guard didReachTerminalPhase == false else { return }
        phase = .scanning(fraction: min(max(fraction, 0), 1))
    }

    /// Feed the model everything currently known. Safe to call repeatedly as
    /// the scan resolves; it settles on the best available hero and stays
    /// there, so the screen can improve but never regress or flicker.
    func ingest(
        snapshots: [ProviderQuotaSnapshot],
        monthToDateUSD: Double,
        sessionCount: Int,
        detectedProviderDisplayNames: [String],
        now: Date = Date()
    ) {
        if let window = TightestQuotaWindow.tightest(across: snapshots, asOf: now) {
            phase = .quota(window, supporting: supportingRows(from: snapshots, excluding: window, now: now))
            didReachTerminalPhase = true
            return
        }

        // No real window. Usage is still real, so lead with it.
        if sessionCount > 0 || monthToDateUSD > 0 {
            phase = .spend(
                SpendHero(
                    monthToDateUSD: monthToDateUSD,
                    sessionCount: sessionCount,
                    providerDisplayNames: detectedProviderDisplayNames,
                    expectsQuotaSignalSoon: detectedProviderDisplayNames.isEmpty == false
                )
            )
            didReachTerminalPhase = true
            return
        }

        // Nothing yet — but keep scanning until the degrade timer says stop.
    }

    /// The 8-second ceiling fired with nothing terminal resolved.
    func degrade() {
        guard didReachTerminalPhase == false else { return }
        phase = .empty(searchedPathCount: searchedPathCount)
        didReachTerminalPhase = true
    }

    // MARK: Derivation

    private func supportingRows(
        from snapshots: [ProviderQuotaSnapshot],
        excluding hero: TightestQuotaWindow,
        now: Date
    ) -> [SupportingRow] {
        let rows = snapshots
            .filter { $0.provider != hero.providerDisplayName }
            .compactMap { snapshot -> SupportingRow? in
                let buckets = snapshot.displayableQuotaBuckets(relativeTo: now)
                guard buckets.isEmpty == false else { return nil }
                let tightest = buckets
                    .filter { $0.remainingPercent != nil }
                    .min { ($0.remainingPercent ?? 100) < ($1.remainingPercent ?? 100) }
                return SupportingRow(
                    providerDisplayName: snapshot.provider,
                    remainingPercent: tightest?.remainingPercent,
                    detail: tightest.map(Self.detailText) ?? "pool"
                )
            }
        // Three is the whole list. A fourth row turns a glance into reading.
        let ranked = rows.sorted { ($0.remainingPercent ?? 101) < ($1.remainingPercent ?? 101) }
        return Array(ranked.prefix(3))
    }

    private static func detailText(for bucket: ProviderQuotaBucket) -> String {
        guard let resetsAt = bucket.resetsAt else { return bucket.label }
        let interval = resetsAt.timeIntervalSinceNow
        guard interval > 0 else { return bucket.label }
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}
