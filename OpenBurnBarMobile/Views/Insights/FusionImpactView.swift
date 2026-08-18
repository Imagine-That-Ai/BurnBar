import SwiftUI
import Charts
import OpenBurnBarCore

// MARK: - Fusion Impact View
//
// The standing "Fusion impact" screen — a Budget Center sibling in the Insights
// tab that shows what The Elder Wand (model-fusion router) has spent. It mirrors
// `BudgetCenterView`'s visual idiom verbatim (AuroraGlassCard hero, Circle().trim
// hero ring, GeometryReader/Capsule progress bars, MobileTheme tokens, and the
// `.staggeredEntrance` cascade) and earns one real Swift Charts comparison where
// it pays its way — the fusion-vs-normal split as a `BarMark` chart.
//
// ── iOS DATA HONESTY ──────────────────────────────────────────────────────────
// Two independent signals drive this screen, with very different fidelity:
//
//  1. The fusion-search QUOTA METER (used / included / cap) is AUTHORITATIVE and
//     real. It comes exclusively from the Firestore document
//     `users/{uid}/quota_snapshots/openburnbar_elder_wand_fusion`, written by the
//     `performElderWandHostedSearch` Cloud Function. Its single bucket carries
//     `used`, `limit` (already `min(monthlyCap, included + purchased)` — we never
//     re-derive it from tier), and `remaining`. NOTE: the shared `QuotaStore`
//     filters this snapshot OUT of its published `snapshots` (the synthetic
//     `openburnbar` providerID is not a `quotaSignalProvider`, so
//     `filteringToDisplayableQuotaSignal` drops it). We therefore read the RAW
//     `FirestoreRepository.fetchQuotaSnapshots()` list and locate the fusion
//     snapshot by its stable doc id / account id ourselves.
//
//  2. The fusion-vs-normal TOKEN COMPARISON is NOT available on iOS today. The
//     `parentRequestID` (`elderwand-…`) that distinguishes a fusion sub-call from
//     a normal request survives only in the daemon read paths on the Mac; it is
//     never written to the iOS Firestore `UsageRollupDoc`, so iOS cannot
//     SQL-partition fusion vs normal spend locally. We model that comparison
//     behind an injectable `FusionImpactDataSource.fusionVsNormalTotals()` that
//     returns `nil` until a read path carries the fusion attribution. When it is
//     `nil`, the comparison renders in a quota-focused state with a clear note
//     that detailed token attribution shows on the Mac; when a future rollup
//     field lights it up, the same view renders the live `BarMark` chart and the
//     per-model contribution breakdown with no further wiring.

// MARK: - Fusion search quota (authoritative)

/// The fusion-search hosted quota meter, projected from the
/// `openburnbar_elder_wand_fusion` quota snapshot bucket. `limit` is the
/// server-resolved `min(monthlyCap, included + purchased)` — already final, so
/// the UI never re-derives it from the membership tier.
struct FusionSearchQuota: Equatable, Sendable {
    let used: Double
    let limit: Double
    let remaining: Double
    let resetsAtLabel: String?
    let isStale: Bool

    /// Used fraction `0…1`, clamped. `0` when there is no positive limit so an
    /// unconfigured meter renders empty rather than full.
    var usedFraction: Double {
        guard limit > 0 else { return 0 }
        return min(max(used / limit, 0), 1)
    }

    var remainingInt: Int { Int(remaining.rounded()) }
    var usedInt: Int { Int(used.rounded()) }
    var limitInt: Int { Int(limit.rounded()) }
}

// MARK: - Data source

/// The injectable seam behind `FusionImpactView`. Splits the two signals by
/// fidelity: the quota meter is real and always available to a signed-in member;
/// the token comparison is `nil` until an iOS read path carries fusion
/// attribution (see the header note).
@MainActor
protocol FusionImpactDataSource: AnyObject {
    /// The authoritative fusion-search quota meter, or `nil` when no fusion
    /// snapshot exists yet (the member has never run a hosted Fusion search).
    ///
    /// Throws when the underlying read FAILS (e.g. a Firestore error). The view
    /// keeps that distinct from a successful `nil` so a read error never renders
    /// as "no searches used" — it shows an error with Retry instead.
    func fusionSearchQuota() async throws -> FusionSearchQuota?

    /// Fusion-vs-normal token/cost totals over the standing window, or `nil`
    /// when iOS cannot attribute fusion spend (the case today). The view renders
    /// a quota-focused state and an honest note when this is `nil`.
    func fusionVsNormalTotals() async -> FusionVsNormalTotals?
}

/// Production data source. Reads the RAW (unfiltered) quota-snapshot list so the
/// synthetic-provider fusion snapshot — which the shared `QuotaStore` drops —
/// survives, and locates it by its stable doc id / account id / bucket name.
///
/// `fusionVsNormalTotals()` defaults to `nil` until the iOS `UsageRollupDoc`
/// carries a fusion attribution field; the injectable `totalsProvider` closure
/// lets a future build supply it without touching the view.
@MainActor
final class FirestoreFusionImpactDataSource: FusionImpactDataSource {

    /// The canonical fusion-search quota-snapshot document id.
    nonisolated static let fusionSnapshotDocID = "openburnbar_elder_wand_fusion"
    /// The account id stamped on the fusion snapshot by the Cloud Function.
    nonisolated static let fusionAccountID = "elder-wand-fusion"

    private let fetchSnapshots: () async throws -> [ProviderQuotaSnapshot]
    private let totalsProvider: () async -> FusionVsNormalTotals?

    init(
        fetchSnapshots: @escaping () async throws -> [ProviderQuotaSnapshot] = {
            try await FirestoreRepository.shared.fetchQuotaSnapshots()
        },
        totalsProvider: @escaping () async -> FusionVsNormalTotals? = { nil }
    ) {
        self.fetchSnapshots = fetchSnapshots
        self.totalsProvider = totalsProvider
    }

    func fusionSearchQuota() async throws -> FusionSearchQuota? {
        // Let a read error propagate so the view distinguishes "failed to load"
        // from a successful "no fusion snapshot yet"; only the latter is `nil`.
        let snapshots = try await fetchSnapshots()
        guard let snapshot = Self.fusionSnapshot(in: snapshots) else { return nil }
        // The fusion snapshot carries exactly one bucket; prefer the explicit
        // searches bucket, falling back to the first if the name ever drifts.
        let bucket = snapshot.buckets.first { $0.name.localizedCaseInsensitiveContains("search") }
            ?? snapshot.buckets.first
        guard let bucket else { return nil }
        return FusionSearchQuota(
            used: bucket.used,
            limit: bucket.limit,
            remaining: bucket.remaining,
            resetsAtLabel: bucket.resetsAtCombinedLabel,
            isStale: snapshot.isStale()
        )
    }

    func fusionVsNormalTotals() async -> FusionVsNormalTotals? {
        await totalsProvider()
    }

    /// Locate the fusion snapshot among the raw list. Matches on the stable doc
    /// id, then the stamped account id, then the bucket name — any one is enough,
    /// so a writer-side rename of one field does not lose the meter.
    nonisolated static func fusionSnapshot(in snapshots: [ProviderQuotaSnapshot]) -> ProviderQuotaSnapshot? {
        snapshots.first { snapshot in
            snapshot.id == fusionSnapshotDocID
                || snapshot.accountID == fusionAccountID
                || snapshot.sourceID == fusionAccountID
                || snapshot.buckets.contains { $0.name.localizedCaseInsensitiveContains("elder wand") }
        }
    }
}

// MARK: - Fusion Impact View

struct FusionImpactView: View {
    let dataSource: FusionImpactDataSource

    @Environment(\.cloudSubscriptionStore) private var cloudStore

    /// The fusion-search quota lifecycle. Kept distinct so a failed read renders
    /// an error with Retry rather than the "no searches used yet" empty state.
    @State private var quotaState: QuotaState = .loading
    @State private var totals: FusionVsNormalTotals?
    @State private var animateRing = false

    /// The authoritative quota meter's read lifecycle. `.empty` is the genuine
    /// "never ran a hosted search" case; `.failed` is a read error the hero
    /// surfaces with Retry — never as "0 used".
    enum QuotaState: Equatable {
        case loading
        case loaded(FusionSearchQuota)
        case empty
        case failed
    }

    private var quota: FusionSearchQuota? {
        if case .loaded(let quota) = quotaState { return quota }
        return nil
    }

    /// Default production init — the screen owns a Firestore-backed data source.
    init(dataSource: FusionImpactDataSource = FirestoreFusionImpactDataSource()) {
        self.dataSource = dataSource
    }

    var body: some View {
        ZStack {
            ScrollView {
                VStack(spacing: MobileTheme.Spacing.lg) {
                    FusionQuotaHeroCard(
                        state: quotaState,
                        animateRing: animateRing,
                        retry: { Task { await loadData() } }
                    )
                    .padding(.horizontal, AuroraDesign.Layout.cardInset)
                    .staggeredEntrance(delay: 0.05)

                    FusionVsNormalSection(totals: totals)
                        .padding(.horizontal, AuroraDesign.Layout.cardInset)
                        .staggeredEntrance(delay: 0.10)

                    FusionContributionSection(totals: totals)
                        .padding(.horizontal, AuroraDesign.Layout.cardInset)
                        .staggeredEntrance(delay: 0.15)

                    FusionTopUpSection(store: cloudStore, remaining: quota?.remainingInt)
                        .padding(.horizontal, AuroraDesign.Layout.cardInset)
                        .staggeredEntrance(delay: 0.20)
                }
                .padding(.top, MobileTheme.Spacing.sm)
                .padding(.bottom, MobileTheme.Spacing.xxl * 2) // avoid tab overlap
            }
            .refreshable {
                HapticBus.refreshStarted()
                await loadData()
                HapticBus.refreshFinished()
            }

            if quotaState == .loading {
                ProgressView()
                    .tint(MobileTheme.ember)
                    .scaleEffect(1.2)
            }
        }
        .task {
            await loadData()
            withAnimation(.spring(response: 0.8, dampingFraction: 0.7)) {
                animateRing = true
            }
        }
    }

    private func loadData() async {
        quotaState = .loading
        do {
            if let loadedQuota = try await dataSource.fusionSearchQuota() {
                quotaState = .loaded(loadedQuota)
            } else {
                quotaState = .empty
            }
        } catch {
            quotaState = .failed
        }
        totals = await dataSource.fusionVsNormalTotals()
    }
}

// MARK: - Hero quota ring

/// The fusion-search quota meter as an Apple-Watch-style hero ring — mirrors
/// `BudgetCenterView.heroCard`. The donut renders via `SectorMark` on iOS 17+
/// and falls back to the same `Circle().trim` ring the Budget hero uses below.
private struct FusionQuotaHeroCard: View {
    let state: FusionImpactView.QuotaState
    let animateRing: Bool
    let retry: () -> Void

    @ScaledMetric(relativeTo: .largeTitle) private var ringDiameter: CGFloat = 120

    /// The loaded quota, when present. `nil` in `.loading` / `.empty` / `.failed`.
    private var quota: FusionSearchQuota? {
        if case .loaded(let quota) = state { return quota }
        return nil
    }

    private var usedFraction: Double { quota?.usedFraction ?? 0 }

    private var statusColor: Color {
        if usedFraction >= 1.0 { return MobileTheme.error }
        if usedFraction >= 0.8 { return MobileTheme.warning }
        if usedFraction >= 0.5 { return MobileTheme.amber }
        return MobileTheme.success
    }

    private var ringGradient: LinearGradient {
        if usedFraction >= 1.0 {
            return LinearGradient(colors: [MobileTheme.error, MobileTheme.ember], startPoint: .top, endPoint: .bottom)
        }
        if usedFraction >= 0.8 {
            return LinearGradient(colors: [MobileTheme.warning, MobileTheme.amber], startPoint: .top, endPoint: .bottom)
        }
        if usedFraction >= 0.5 {
            return LinearGradient(colors: [MobileTheme.amber, .orange], startPoint: .top, endPoint: .bottom)
        }
        return LinearGradient(colors: [MobileTheme.success, .emerald], startPoint: .top, endPoint: .bottom)
    }

    private var statusText: String {
        guard quota != nil else { return "NO HOSTED SEARCHES YET" }
        if usedFraction >= 1.0 { return "ALLOWANCE EXHAUSTED" }
        if usedFraction >= 0.8 { return "RUNNING LOW" }
        if usedFraction >= 0.5 { return "HALFWAY THROUGH" }
        return "PLENTY REMAINING"
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    var body: some View {
        AuroraGlassCard(variant: .hero) {
            if isFailed {
                failedBody
            } else {
                loadedBody
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Elder Wand hosted searches")
        .accessibilityValue(accessibilityValue)
    }

    private var loadedBody: some View {
        VStack(spacing: MobileTheme.Spacing.md) {
            header
            HStack(spacing: 24) {
                ringView
                statColumn
                Spacer()
            }
            .padding(.vertical, 8)

            if let resetsAtLabel = quota?.resetsAtLabel {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .bold))
                    Text("Resets \(resetsAtLabel)")
                        .font(MobileTheme.Typography.tiny)
                    Spacer()
                }
                .foregroundStyle(MobileTheme.textMuted)
            }
        }
    }

    /// Distinct read-failure state — never the "no searches used" empty copy.
    /// Names the failure plainly and offers Retry, matching the Mac receipt
    /// modal's `.failed` honesty.
    private var failedBody: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ELDER WAND SEARCHES")
                        .font(MobileTheme.Typography.tiny)
                        .fontWeight(.semibold)
                        .tracking(1.5)
                        .foregroundStyle(MobileTheme.textMuted)
                    Text("ALLOWANCE UNAVAILABLE")
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .foregroundStyle(MobileTheme.warning)
                }
                Spacer()
                Image(systemName: "exclamationmark.icloud")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(MobileTheme.warning)
                    .accessibilityHidden(true)
            }

            Text("Couldn't load your hosted-search allowance. Check your connection and try again.")
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: retry) {
                Label("Retry", systemImage: "arrow.clockwise")
                    .font(MobileTheme.Typography.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .tint(MobileTheme.ember)
            .accessibilityHint("Reloads your hosted-search allowance")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("ELDER WAND SEARCHES")
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.semibold)
                    .tracking(1.5)
                    .foregroundStyle(MobileTheme.textMuted)

                Text(statusText)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .foregroundStyle(statusColor)
            }
            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .font(.caption)
                Text("FUSION")
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.bold)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(MobileTheme.whimsy.opacity(0.12))
            .foregroundStyle(MobileTheme.whimsy)
            .clipShape(Capsule())
        }
    }

    @ViewBuilder
    private var ringView: some View {
        if #available(iOS 17, *), quota != nil {
            FusionQuotaDonut(
                usedFraction: animateRing ? usedFraction : 0,
                statusColor: statusColor,
                diameter: ringDiameter
            )
            .frame(width: ringDiameter, height: ringDiameter)
            .overlay {
                VStack(spacing: 0) {
                    Text("\(Int((usedFraction * 100).rounded()))%")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(MobileTheme.textPrimary)
                        .contentTransition(.numericText())
                    Text("used")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.textMuted)
                }
            }
        } else {
            trimRing
        }
    }

    /// The exact `Circle().trim` hero ring `BudgetCenterView` uses — the iOS 16
    /// (and no-data) fallback for the donut.
    private var trimRing: some View {
        ZStack {
            Circle()
                .stroke(MobileTheme.borderSubtle.opacity(0.4), lineWidth: 14)
                .frame(width: ringDiameter, height: ringDiameter)

            Circle()
                .trim(from: 0.0, to: animateRing ? CGFloat(usedFraction) : 0.0)
                .stroke(ringGradient, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .frame(width: ringDiameter, height: ringDiameter)
                .rotationEffect(.degrees(-90))

            if usedFraction >= 1.0 {
                Circle()
                    .stroke(MobileTheme.error.opacity(0.3), lineWidth: 18)
                    .frame(width: ringDiameter, height: ringDiameter)
                    .scaleEffect(animateRing ? 1.08 : 1.0)
                    .animation(
                        .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                        value: animateRing
                    )
            }
        }
    }

    private var statColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(quota?.remainingInt ?? 0)")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(MobileTheme.textPrimary)
                    .contentTransition(.numericText())
                Text(" left")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.textMuted)
            }

            Text("\(quota?.usedInt ?? 0) of \(quota?.limitInt ?? 0) used this month")
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.textSecondary)

            if quota?.isStale == true {
                Text("estimate")
                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
                    .foregroundStyle(MobileTheme.textMuted)
            }
        }
    }

    private var accessibilityValue: String {
        if isFailed {
            return "Couldn't load your hosted-search allowance. Retry available."
        }
        guard let quota else { return "No hosted Fusion searches recorded yet" }
        return "\(quota.remainingInt) of \(quota.limitInt) hosted searches remaining this month"
    }
}

/// `SectorMark` donut for the hero ring (iOS 17+). Two slices — used and
/// remaining — so the legend stays implicit and the inner radius matches the
/// Budget hero ring's thickness.
@available(iOS 17, *)
private struct FusionQuotaDonut: View {
    let usedFraction: Double
    let statusColor: Color
    let diameter: CGFloat

    private struct Slice: Identifiable {
        let id: String
        let label: String
        let value: Double
        let color: Color
    }

    private var slices: [Slice] {
        let used = min(max(usedFraction, 0), 1)
        return [
            Slice(id: "used", label: "Used", value: used, color: statusColor),
            Slice(id: "remaining", label: "Remaining", value: 1 - used, color: MobileTheme.borderSubtle.opacity(0.4))
        ]
    }

    var body: some View {
        Chart(slices) { slice in
            SectorMark(
                angle: .value("Share", slice.value),
                innerRadius: .ratio(0.72),
                angularInset: slice.value > 0 ? 1.5 : 0
            )
            .foregroundStyle(slice.color)
            .cornerRadius(3)
        }
        .chartLegend(.hidden)
        .animation(.spring(response: 0.8, dampingFraction: 0.7), value: usedFraction)
    }
}

// MARK: - Fusion vs Normal comparison

/// The headline fusion-vs-normal split. When `totals` is available it renders a
/// real Swift Charts `BarMark` comparison (gated `#available(iOS 16)`); when it
/// is `nil` it renders the honest quota-focused empty state.
private struct FusionVsNormalSection: View {
    let totals: FusionVsNormalTotals?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("FUSION VS NORMAL")
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.semibold)
                .tracking(1.5)
                .foregroundStyle(MobileTheme.textMuted)

            if let totals, totals.totalCost > 0 {
                FusionVsNormalChartCard(totals: totals)
            } else {
                comparisonUnavailable
            }
        }
    }

    /// Honest empty state: iOS cannot attribute fusion vs normal token spend
    /// locally (no `parentRequestID` in the rollup), so we say so plainly and
    /// point at the Mac, where the daemon read path carries the attribution.
    private var comparisonUnavailable: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(MobileTheme.hermesMercury)
                Text("Detailed spend breakdown lives on your Mac")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(MobileTheme.textPrimary)
            }

            Text("Your hosted-search allowance above is exact. The fusion-vs-normal token split is attributed per request on the Mac menu bar app — iPhone shows the live quota here.")
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(MobileTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .fill(MobileTheme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                        .stroke(MobileTheme.borderSubtle.opacity(0.35), lineWidth: 0.5)
                )
        )
    }
}

/// The real Swift Charts comparison — a `BarMark` per category colored by
/// `foregroundStyle(by:)` so Charts emits the legend and accessibility for free.
private struct FusionVsNormalChartCard: View {
    let totals: FusionVsNormalTotals

    private struct Bar: Identifiable {
        let id: String
        let category: String
        let cost: Double
    }

    private var bars: [Bar] {
        [
            Bar(id: "fusion", category: "Fusion", cost: totals.fusionCost),
            Bar(id: "normal", category: "Normal", cost: totals.normalCost)
        ]
    }

    private var sharePercent: Int { Int((totals.fusionShareFraction * 100).rounded()) }

    /// The "≈ " prefix when any contributing row was an estimate, so the headline
    /// currency reads honestly without altering the number.
    private var estimatePrefix: String { totals.isEstimated ? "≈ " : "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fusion is \(sharePercent)% of spend")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(MobileTheme.textPrimary)
                    Text("\(estimatePrefix)$\(String(format: "%.2f", totals.fusionCost)) fusion · \(estimatePrefix)$\(String(format: "%.2f", totals.normalCost)) normal")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.textSecondary)
                }
                Spacer()
                if let perRun = totals.averageCostPerFusionRun {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(estimatePrefix)$\(String(format: "%.2f", perRun))")
                            .font(.system(.subheadline, design: .monospaced).weight(.bold))
                            .foregroundStyle(MobileTheme.whimsy)
                        Text("avg / run")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(MobileTheme.textMuted)
                    }
                }
            }

            comparisonChart
                .frame(height: 160)
                .chartEntrance()

            if totals.isEstimated {
                Text("Estimated — some providers report usage approximately.")
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("This total is estimated; some providers report usage approximately.")
            }
        }
        .padding(MobileTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .fill(MobileTheme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                        .stroke(MobileTheme.borderSubtle.opacity(0.35), lineWidth: 0.5)
                )
        )
    }

    /// The Fusion bar carries the warm Elder Wand ember gradient; Normal stays a
    /// quiet neutral so the eye lands on fusion.
    private static let fusionBarGradient = LinearGradient(
        colors: [Color(hex: "FFD56B"), Color(hex: "FF8A3D"), Color(hex: "F45B69")],
        startPoint: .top,
        endPoint: .bottom
    )
    private static let normalBarGradient = LinearGradient(
        colors: [MobileTheme.hermesMercury.opacity(0.8), MobileTheme.hermesMercury.opacity(0.45)],
        startPoint: .top,
        endPoint: .bottom
    )

    @ViewBuilder
    private var comparisonChart: some View {
        if #available(iOS 16, *) {
            Chart(bars) { bar in
                BarMark(
                    x: .value("Category", bar.category),
                    y: .value("Cost (USD)", bar.cost),
                    width: .fixed(48)
                )
                .foregroundStyle(by: .value("Category", bar.category))
                .annotation(position: .top, spacing: 4) {
                    Text("$\(String(format: "%.2f", bar.cost))")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(bar.category == "Fusion" ? Color(hex: "FF8A3D") : MobileTheme.textSecondary)
                }
                .cornerRadius(8)
                .accessibilityLabel("\(bar.category) spend")
                .accessibilityValue("$\(String(format: "%.2f", bar.cost))")
            }
            .chartForegroundStyleScale(
                domain: ["Fusion", "Normal"],
                range: [AnyShapeStyle(Self.fusionBarGradient), AnyShapeStyle(Self.normalBarGradient)]
            )
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks { _ in
                    AxisValueLabel()
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(MobileTheme.borderSubtle.opacity(0.6))
                    AxisValueLabel {
                        if let cost = value.as(Double.self) {
                            Text("$\(Int(cost))")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(MobileTheme.textMuted)
                        }
                    }
                }
            }
        } else {
            // iOS 15 fallback: the same two-category split as paired Capsule bars.
            FusionVsNormalBarsFallback(bars: bars.map { ($0.category, $0.cost) })
        }
    }
}

/// iOS 15 fallback for the comparison chart — paired Capsule bars normalized to
/// the larger of the two costs, matching the Budget Center progress-bar idiom.
private struct FusionVsNormalBarsFallback: View {
    let bars: [(category: String, cost: Double)]

    private var maxCost: Double { max(bars.map(\.cost).max() ?? 0, 0.0001) }

    var body: some View {
        VStack(spacing: 12) {
            ForEach(bars, id: \.category) { bar in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(bar.category)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(MobileTheme.textSecondary)
                        Spacer()
                        Text("$\(String(format: "%.2f", bar.cost))")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(MobileTheme.textPrimary)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(MobileTheme.borderSubtle.opacity(0.4))
                            Capsule()
                                .fill(bar.category == "Fusion" ? MobileTheme.whimsy : MobileTheme.hermesMercury)
                                .frame(width: geo.size.width * CGFloat(bar.cost / maxCost))
                        }
                    }
                    .frame(height: 8)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(bar.category) spend")
                .accessibilityValue("$\(String(format: "%.2f", bar.cost))")
            }
        }
    }
}

// MARK: - Per-model contribution

/// Per-model fusion contribution — Capsule progress bars (the Budget Center
/// idiom) one row per model, normalized to the costliest. Only renders when the
/// token comparison is available (it carries `fusionCostByModel`).
private struct FusionContributionSection: View {
    let totals: FusionVsNormalTotals?

    private struct ModelSpend: Identifiable {
        let id: String
        let modelID: String
        let cost: Double
    }

    private var models: [ModelSpend] {
        guard let totals else { return [] }
        return totals.fusionCostByModel
            .map { ModelSpend(id: $0.key, modelID: $0.key, cost: $0.value) }
            .sorted { $0.cost > $1.cost }
    }

    private var maxCost: Double { max(models.map(\.cost).max() ?? 0, 0.0001) }
    private var totalCost: Double { max(models.map(\.cost).reduce(0, +), 0.0001) }

    var body: some View {
        if !models.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("MODEL CONTRIBUTION")
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.semibold)
                    .tracking(1.5)
                    .foregroundStyle(MobileTheme.textMuted)

                VStack(spacing: 12) {
                    ForEach(models) { model in
                        contributionRow(model)
                    }
                }
                .padding(MobileTheme.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                        .fill(MobileTheme.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                                .stroke(MobileTheme.borderSubtle.opacity(0.35), lineWidth: 0.5)
                        )
                )
            }
        }
    }

    @ViewBuilder
    private func contributionRow(_ model: ModelSpend) -> some View {
        let color = MobileTheme.Colors.colorForModel(model.modelID)
        let percent = Int((model.cost / totalCost * 100).rounded())
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(model.modelID)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(MobileTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text("\(percent)%")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(MobileTheme.textMuted)
                Text("$\(String(format: "%.2f", model.cost))")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(MobileTheme.textPrimary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(MobileTheme.borderSubtle.opacity(0.4))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [color, color.opacity(0.6)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(6, geo.size.width * CGFloat(model.cost / maxCost)))
                        .shadow(color: color.opacity(0.35), radius: 3, y: 1)
                }
            }
            .frame(height: 7)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.modelID)
        .accessibilityValue("$\(String(format: "%.2f", model.cost)), \(percent) percent of fusion spend")
    }
}

// MARK: - Top-up affordance

/// The hosted-search top-up affordance. Surfaces the two Elder Wand search
/// consumables (`elderWandSearches100ProductID` / `searches500ProductID`) using
/// the same `store.displayPrice(for:)` + `store.purchase(productID:)` path as the
/// Cloud Store. Pro/Ultra members only — top-ups credit a Cloud Pro/Ultra month.
private struct FusionTopUpSection: View {
    let store: HostedQuotaSubscriptionStore?
    let remaining: Int?

    private var topUps: [OpenBurnBarStoreProduct] {
        [
            OpenBurnBarProductCatalog.product(for: OpenBurnBarProductCatalog.elderWandSearches100ProductID),
            OpenBurnBarProductCatalog.product(for: OpenBurnBarProductCatalog.elderWandSearches500ProductID)
        ].compactMap { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ADD MORE SEARCHES")
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.semibold)
                .tracking(1.5)
                .foregroundStyle(MobileTheme.textMuted)

            if let remaining, remaining <= 10 {
                Text("Running low — top up to keep Fusion searching the live web.")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 8) {
                ForEach(topUps) { topUp in
                    topUpRow(topUp)
                }
            }
        }
    }

    @ViewBuilder
    private func topUpRow(_ topUp: OpenBurnBarStoreProduct) -> some View {
        let price = store?.displayPrice(for: topUp) ?? MobileStoreEntitlementPolicy.unavailablePriceLabel
        let isPurchasing = store?.isPurchasing ?? false
        Button {
            guard let store else { return }
            HapticBus.primaryAction()
            Task { await store.purchase(productID: topUp.id) }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(MobileTheme.whimsy.opacity(0.12))
                        .frame(width: 38, height: 38)
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(MobileTheme.whimsy)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(topUp.cadence)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(MobileTheme.textPrimary)
                    Text(topUp.included)
                        .font(.caption2)
                        .foregroundStyle(MobileTheme.textSecondary)
                        .lineLimit(2)
                }

                Spacer()

                Text(price)
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(MobileTheme.primaryGradient))
            }
        }
        .buttonStyle(.plain)
        .disabled(store == nil || isPurchasing)
        .padding(MobileTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .fill(MobileTheme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                        .stroke(MobileTheme.borderSubtle.opacity(0.45), lineWidth: 1)
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(topUp.cadence), \(price)")
        .accessibilityHint("Adds hosted Fusion searches to this month")
    }
}
