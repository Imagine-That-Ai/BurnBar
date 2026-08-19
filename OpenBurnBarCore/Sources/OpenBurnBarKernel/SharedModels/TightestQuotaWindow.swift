import Foundation

// MARK: - Tightest Quota Window
//
// The product's one number: across every agent the user pays for, which window
// is closest to running out, and when does it come back?
//
// No vendor can render this sentence — putting a competitor's meter beside your
// own is commercially impossible for them — so it is the one number that is
// structurally ours. It is derived in exactly one place and read by the menu
// bar, the first-run reveal, the quota workspace, the widget and the iOS Live
// Activity, so those five surfaces can never disagree about what "tightest"
// means.
//
// HONESTY CONTRACT — the whole reason this type exists:
//
//   `tightest(across:)` returns nil when nothing carries a REAL percentage.
//   It never estimates, never interpolates, never falls back to a token count
//   dressed up as a percent. A cold install with no provider credentials has
//   no plan caps to divide by, so it genuinely has no percentage — and the UI
//   is expected to show something else true (spend, sessions) rather than a
//   fabricated ring. `QuotaRefreshActor` already refuses to invent buckets;
//   this refuses to invent a winner among them.

public struct TightestQuotaWindow: Equatable, Sendable {
    /// Display name of the provider that owns this window ("Claude Code").
    public let providerDisplayName: String
    public let providerID: ProviderID?
    /// Account label when the user runs more than one account on this provider.
    public let accountLabel: String?
    /// Human label for the window itself ("weekly", "5-hour window").
    public let windowLabel: String
    /// 0...100, always real — see the honesty contract above.
    public let remainingPercent: Double
    /// When this window rolls over. Nil when the provider reports a balance
    /// with no scheduled reset (a credit pool rather than a rolling window).
    public let resetsAt: Date?
    /// True when the provider's own fidelity is `.estimated`. The UI must
    /// render this visibly — a dagger, a word — never silently.
    public let isEstimated: Bool
    /// How many providers carried a real percentage in this derivation. The
    /// reveal says "across 4 agents" from this, so the claim is always counted
    /// rather than asserted.
    public let comparedProviderCount: Int

    public init(
        providerDisplayName: String,
        providerID: ProviderID? = nil,
        accountLabel: String? = nil,
        windowLabel: String,
        remainingPercent: Double,
        resetsAt: Date?,
        isEstimated: Bool,
        comparedProviderCount: Int
    ) {
        self.providerDisplayName = providerDisplayName
        self.providerID = providerID
        self.accountLabel = accountLabel
        self.windowLabel = windowLabel
        self.remainingPercent = remainingPercent
        self.resetsAt = resetsAt
        self.isEstimated = isEstimated
        self.comparedProviderCount = comparedProviderCount
    }

    /// Pressure bands. Deliberately coarse: three states a person can feel at a
    /// glance in a 22pt menu bar slot, not a continuous gradient nobody reads.
    public enum Pressure: String, Sendable {
        /// Plenty of room.
        case comfortable
        /// Worth knowing before starting something expensive.
        case tightening
        /// The wall is close.
        case critical
    }

    public var pressure: Pressure {
        switch remainingPercent {
        case ..<15: .critical
        case ..<40: .tightening
        default: .comfortable
        }
    }

    /// Whole percent for display. Floored, never rounded up: showing 39% when
    /// 38.6 remains is the safe direction to be wrong in.
    public var displayPercent: Int {
        Int(remainingPercent.rounded(.down))
    }

    // MARK: - Derivation

    /// The tightest real window across every supplied snapshot.
    ///
    /// Selection: lowest remaining percent wins; ties break to the window that
    /// resets soonest (the one that constrains you first), and a window with a
    /// known reset beats one without. Buckets with no real percentage are
    /// excluded entirely rather than sorted to the end — a provider we cannot
    /// measure must not be able to win a comparison about measurement.
    public static func tightest(
        across snapshots: [ProviderQuotaSnapshot],
        asOf now: Date = Date()
    ) -> TightestQuotaWindow? {
        var best: (window: TightestQuotaWindow, resetsAt: Date?)?
        var providersWithRealSignal: Set<String> = []

        for snapshot in snapshots {
            let candidates = snapshot
                .displayableQuotaBuckets(relativeTo: now)
                .filter { $0.remainingPercent != nil }
            guard candidates.isEmpty == false else { continue }
            providersWithRealSignal.insert(snapshot.provider)

            for bucket in candidates {
                guard let percent = bucket.remainingPercent else { continue }
                let candidate = TightestQuotaWindow(
                    providerDisplayName: snapshot.provider,
                    providerID: snapshot.providerID,
                    accountLabel: snapshot.accountLabel,
                    windowLabel: bucket.label,
                    remainingPercent: percent,
                    resetsAt: bucket.resetsAt,
                    // `isEstimated` is the authoritative per-bucket fidelity
                    // flag. A `.low`/`.stale` snapshot is also not something to
                    // present as exact, so it flows into the same dagger.
                    isEstimated: bucket.isEstimated
                        || snapshot.confidence == .low
                        || snapshot.confidence == .stale,
                    comparedProviderCount: 0
                )

                guard let current = best else {
                    best = (candidate, bucket.resetsAt)
                    continue
                }
                if isTighter(candidate, than: current.window, candidateReset: bucket.resetsAt, incumbentReset: current.resetsAt) {
                    best = (candidate, bucket.resetsAt)
                }
            }
        }

        guard let winner = best?.window else { return nil }
        return TightestQuotaWindow(
            providerDisplayName: winner.providerDisplayName,
            providerID: winner.providerID,
            accountLabel: winner.accountLabel,
            windowLabel: winner.windowLabel,
            remainingPercent: winner.remainingPercent,
            resetsAt: winner.resetsAt,
            isEstimated: winner.isEstimated,
            comparedProviderCount: providersWithRealSignal.count
        )
    }

    private static func isTighter(
        _ candidate: TightestQuotaWindow,
        than incumbent: TightestQuotaWindow,
        candidateReset: Date?,
        incumbentReset: Date?
    ) -> Bool {
        if candidate.remainingPercent != incumbent.remainingPercent {
            return candidate.remainingPercent < incumbent.remainingPercent
        }
        // Equal pressure: the one that resets sooner is the one that actually
        // constrains the next hour of work.
        switch (candidateReset, incumbentReset) {
        case let (candidateDate?, incumbentDate?):
            return candidateDate < incumbentDate
        case (.some, .none):
            return true
        default:
            return false
        }
    }
}
