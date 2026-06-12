import SwiftUI
import Charts
import OpenBurnBarCore

// MARK: - Leaderboard math (pure, testable)

/// Pure ranking/normalization helpers for the leaderboard view, factored out
/// so they can be unit-tested without a SwiftUI host.
enum BurnLeaderboardMath {
    /// The spend value for a provider in the active display mode.
    static func value(_ p: RollupProviderSummary, displayMode: UsageDisplayMode) -> Double {
        displayMode == .currency ? (p.totalCost ?? 0) : Double(p.totalTokens)
    }

    /// Providers with non-zero spend, sorted highest-first.
    static func ranked(_ providers: [RollupProviderSummary], displayMode: UsageDisplayMode) -> [RollupProviderSummary] {
        providers
            .filter { value($0, displayMode: displayMode) > 0 }
            .sorted { value($0, displayMode: displayMode) > value($1, displayMode: displayMode) }
    }

    /// A 0...1 bar fraction, clamped, safe against a zero/negative max.
    static func fraction(value: Double, max: Double) -> Double {
        guard max > 0 else { return 0 }
        return Swift.max(0, Swift.min(1, value / max))
    }
}

// MARK: - Burn View Styles
//
// The four alternate Burn-tab visualizations the user can pick from (the
// fifth, `.cards`, stays inline in `BurnView`). Each body is a standalone,
// decoupled `View` that receives exactly the data it needs so it can be
// previewed and reasoned about in isolation. The shared header (fleet score,
// urgent banner, period/mode chips) and the switcher live in `BurnView`.

// MARK: - View Switcher

/// Horizontally scrollable segmented control that drives `BurnLayoutStyle`,
/// styled to match the Burn tab's period chips. On iOS 26 the chips ride on
/// a passive Liquid Glass capsule rail (mirroring `AuroraChipRail`); earlier
/// systems keep the original bare chip row byte-identical.
struct BurnLayoutSwitcher: View {
    @Binding var selection: BurnLayoutStyle

    /// Content insets inside the rail. The iOS 26 glass capsule needs
    /// breathing room around the chips; iOS 17–25 keeps the original 2pt.
    private var railInsetH: CGFloat {
        if #available(iOS 26, *) { return MobileTheme.Spacing.md } else { return 2 }
    }

    private var railInsetV: CGFloat {
        if #available(iOS 26, *) { return MobileTheme.Spacing.xs } else { return 2 }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(BurnLayoutStyle.allCases) { style in
                    let isSelected = style == selection
                    Button {
                        withAnimation(AuroraDesign.Motion.auroraSnap) {
                            selection = style
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: style.systemImage)
                                .font(.system(size: 12, weight: .bold))
                            Text(style.label)
                                .font(MobileTheme.Typography.caption)
                                .fontWeight(.semibold)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .foregroundStyle(isSelected ? MobileTheme.ember : MobileTheme.Colors.textSecondary)
                        .background(
                            Capsule()
                                .fill(isSelected ? MobileTheme.ember.opacity(0.16) : Color.clear)
                        )
                        .overlay(
                            Capsule()
                                .stroke(
                                    isSelected ? MobileTheme.ember.opacity(0.45)
                                               : MobileTheme.Colors.border.opacity(0.4),
                                    lineWidth: 0.5
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(style.accessibilityLabel)
                    .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
                }
            }
            .padding(.horizontal, railInsetH)
            .padding(.vertical, railInsetV)
        }
        .background {
            // Glass rail like AuroraChipRail: the rail is a passive container
            // (the chips inside are the tappable elements), so it gets plain —
            // not interactive — glass, applied after the content padding so
            // the capsule encloses the padded bounds. Clear fill only: the
            // glass must sample the Aurora backdrop behind it, never a
            // material. iOS 17–25 renders no rail, exactly as before.
            if #available(iOS 26, *) {
                Capsule(style: .continuous)
                    .fill(Color.clear)
                    .liquidGlassEffect(.regular, in: Capsule(style: .continuous))
            }
        }
    }
}

// MARK: - Constellation Body

/// Cinematic orbital ring cluster — reuses the existing `QuotaRingsConstellation`.
struct BurnConstellationBody: View {
    let items: [QuotaRingsConstellation.Item]
    let onSelect: (String) -> Void

    var body: some View {
        AuroraGlassCard(variant: .hero, cornerRadius: AuroraDesign.Shape.heroCorner) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
                AuroraSection(
                    "Quota constellation",
                    subtitle: "Tap a ring to drill into a provider",
                    accent: MobileTheme.amber
                )
                if items.isEmpty {
                    AuroraStatePane(
                        kind: .empty,
                        icon: "circle.grid.cross",
                        title: "No quota signal yet",
                        message: "Link a provider to populate the constellation."
                    )
                    .frame(height: 220)
                } else {
                    QuotaRingsConstellation(items: items) { item in
                        onSelect(item.providerKey)
                    }
                    .frame(minHeight: 260)
                    .chartEntrance()
                }
            }
        }
    }
}

// MARK: - Gauge Grid Body

/// Dense adaptive grid of compact provider gauge tiles — great for scanning
/// many providers at a glance.
struct BurnGaugeGridBody: View {
    let items: [QuotaRingsConstellation.Item]
    let onSelect: (String) -> Void

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12)]

    var body: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: AuroraDesign.Shape.heroCorner) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
                AuroraSection(
                    "Quota gauges",
                    subtitle: "Most pressured first",
                    accent: MobileTheme.ember
                )
                if items.isEmpty {
                    AuroraStatePane(
                        kind: .empty,
                        icon: "square.grid.2x2",
                        title: "No connected providers",
                        message: "Link a provider to populate the grid."
                    )
                    .frame(minHeight: 180)
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(items) { item in
                            Button {
                                onSelect(item.providerKey)
                                HapticBus.sheetOpen()
                            } label: {
                                BurnGaugeTile(item: item)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(item.label), \(Int((item.pressureRemaining * 100).rounded())) percent remaining")
                        }
                    }
                    .chartEntrance()
                }
            }
        }
    }
}

/// A single gauge tile: ring + logo + provider name + percent.
private struct BurnGaugeTile: View {
    let item: QuotaRingsConstellation.Item

    private var primary: Color { MobileTheme.Colors.primary(for: item.provider) }

    private var statusColor: Color {
        let p = item.pressureRemaining
        if p < 0.25 { return MobileTheme.error }
        if p < 0.5 { return MobileTheme.warning }
        return MobileTheme.success
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(primary.opacity(0.16), lineWidth: 5)
                    .frame(width: 60, height: 60)
                Circle()
                    .trim(from: 0, to: CGFloat(max(0, min(1, item.pressureRemaining))))
                    .stroke(primary, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 60, height: 60)
                    .shadow(color: primary.opacity(0.5), radius: 6)
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 40, height: 40)
                    .overlay(Circle().stroke(primary.opacity(0.35), lineWidth: 0.5))
                UnifiedProviderLogoView(provider: item.provider, size: 24, useFallbackColor: false)
            }
            Text(item.label)
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.semibold)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("\(Int((item.pressureRemaining * 100).rounded()))%")
                .font(MobileTheme.Typography.caption)
                .fontWeight(.bold)
                .foregroundStyle(statusColor)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(MobileTheme.Colors.surfaceElevated.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(primary.opacity(0.18), lineWidth: 0.5)
        )
    }
}

// MARK: - Leaderboard Body

/// Providers ranked by spend for the selected window/mode, with bold bars
/// normalized to the top spender.
struct BurnLeaderboardBody: View {
    let providers: [RollupProviderSummary]
    let quotaItems: [QuotaRingsConstellation.Item]
    let displayMode: UsageDisplayMode
    let windowLabel: String
    let onSelect: (String) -> Void

    /// Quota pressure + key keyed by AgentProvider for joining dashboard rows
    /// back to quota snapshots.
    private var itemByProvider: [AgentProvider: QuotaRingsConstellation.Item] {
        Dictionary(quotaItems.map { ($0.provider, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func value(_ p: RollupProviderSummary) -> Double {
        BurnLeaderboardMath.value(p, displayMode: displayMode)
    }

    private func amountLabel(_ p: RollupProviderSummary) -> String {
        displayMode == .currency ? (p.totalCost ?? 0).formatAsCost() : p.totalTokens.formatAsTokens()
    }

    private var ranked: [RollupProviderSummary] {
        BurnLeaderboardMath.ranked(providers, displayMode: displayMode)
    }

    private var maxValue: Double {
        Swift.max(ranked.map(value).max() ?? 1, 0.0001)
    }

    var body: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: AuroraDesign.Shape.heroCorner) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
                AuroraSection(
                    "Spend leaderboard",
                    subtitle: "\(windowLabel) · by \(displayMode == .currency ? "cost" : "tokens")",
                    accent: MobileTheme.amber
                )
                if ranked.isEmpty {
                    AuroraStatePane(
                        kind: .empty,
                        icon: "chart.bar",
                        title: "No spend in this window",
                        message: "Usage will appear here once your agents start burning."
                    )
                    .frame(minHeight: 160)
                } else {
                    VStack(spacing: 10) {
                        ForEach(ranked.indices, id: \.self) { index in
                            leaderRow(rank: index + 1, provider: ranked[index])
                        }
                    }
                    .chartEntrance()
                }
            }
        }
    }

    @ViewBuilder
    private func leaderRow(rank: Int, provider p: RollupProviderSummary) -> some View {
        let agent = AgentProvider.fromProviderID(p.providerID) ?? AgentProvider.fromPersistedToken(p.provider)
        let item = agent.flatMap { itemByProvider[$0] }
        let fraction = CGFloat(BurnLeaderboardMath.fraction(value: value(p), max: maxValue))
        let barColor = agent.map { MobileTheme.Colors.primary(for: $0) } ?? MobileTheme.ember

        Button {
            if let key = item?.providerKey {
                onSelect(key)
                HapticBus.sheetOpen()
            }
        } label: {
            HStack(spacing: 12) {
                Text("\(rank)")
                    .font(MobileTheme.Typography.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                    .frame(width: 18, alignment: .center)
                    .monospacedDigit()

                if let agent {
                    UnifiedProviderLogoView(provider: agent, size: 24, useFallbackColor: false)
                        .frame(width: 28, height: 28)
                }

                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(agent?.displayName ?? p.provider)
                            .font(MobileTheme.Typography.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(amountLabel(p))
                            .font(MobileTheme.Typography.caption)
                            .fontWeight(.bold)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                            .monospacedDigit()
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(barColor.opacity(0.14))
                                .frame(height: 8)
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [barColor, barColor.opacity(0.65)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: max(8, geo.size.width * fraction), height: 8)
                                .shadow(color: barColor.opacity(0.4), radius: 4, y: 1)
                        }
                    }
                    .frame(height: 8)
                }

                if let pct = item.map({ Int(($0.pressureRemaining * 100).rounded()) }) {
                    Text("\(pct)%")
                        .font(MobileTheme.Typography.tiny)
                        .fontWeight(.semibold)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                        .monospacedDigit()
                        .frame(width: 34, alignment: .trailing)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Rank \(rank), \(agent?.displayName ?? p.provider), \(amountLabel(p)) this window")
    }
}

// MARK: - Timeline Body

/// Per-provider burn over the selected window — a sparkline + window total
/// for each provider, sourced from the same `TrendDataDigest` the Pulse
/// Atlas card uses.
struct BurnTimelineBody: View {
    let digest: TrendDataDigest
    let quotaItems: [QuotaRingsConstellation.Item]
    let displayMode: UsageDisplayMode
    let onSelect: (String) -> Void

    private var itemByProvider: [AgentProvider: QuotaRingsConstellation.Item] {
        Dictionary(quotaItems.map { ($0.provider, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Ordered sparkline points for a provider key across the digest's days.
    private func series(for key: String) -> [Sparkline.Point] {
        digest.daily.enumerated().map { (offset, day) in
            Sparkline.Point(id: offset, value: day.perProvider[key] ?? 0)
        }
    }

    private var rows: [TrendDataDigest.ProviderSlice] {
        digest.providers.filter { $0.costUsd > 0 || $0.tokens > 0 }
    }

    var body: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: AuroraDesign.Shape.heroCorner) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
                AuroraSection(
                    "Burn trends",
                    subtitle: "\(digest.windowDescription) · per provider",
                    accent: MobileTheme.ember
                )
                if rows.isEmpty || digest.daily.count < 2 {
                    AuroraStatePane(
                        kind: .empty,
                        icon: "chart.xyaxis.line",
                        title: "Not enough history yet",
                        message: "Daily burn trends appear once there are at least two days of usage."
                    )
                    .frame(minHeight: 160)
                } else {
                    VStack(spacing: 12) {
                        ForEach(rows, id: \.providerKey) { slice in
                            timelineRow(slice)
                        }
                    }
                    .chartEntrance()
                }
            }
        }
    }

    @ViewBuilder
    private func timelineRow(_ slice: TrendDataDigest.ProviderSlice) -> some View {
        let agent = AgentProvider.fromPersistedToken(slice.providerKey)
            ?? AgentProvider.fromProviderID(ProviderID(rawValue: slice.providerKey))
        let item = agent.flatMap { itemByProvider[$0] }
        let points = series(for: slice.providerKey)
        let accent = agent.map { MobileTheme.Colors.primary(for: $0) } ?? MobileTheme.ember
        let total = displayMode == .currency ? slice.costUsd.formatAsCost() : slice.tokens.formatAsTokens()

        Button {
            if let key = item?.providerKey {
                onSelect(key)
                HapticBus.sheetOpen()
            }
        } label: {
            HStack(spacing: 12) {
                if let agent {
                    UnifiedProviderLogoView(provider: agent, size: 26, useFallbackColor: false)
                        .frame(width: 30, height: 30)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent?.displayName ?? slice.providerKey)
                        .font(MobileTheme.Typography.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                        .lineLimit(1)
                    Text(total)
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                        .monospacedDigit()
                }
                .frame(width: 96, alignment: .leading)

                Sparkline(points: points, accent: accent)
                    .frame(height: 38)
                    .frame(maxWidth: .infinity)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(agent?.displayName ?? slice.providerKey), \(total) over \(digest.windowDescription)")
    }
}

/// A compact filled line sparkline.
private struct Sparkline: View {
    struct Point: Identifiable { let id: Int; let value: Double }
    let points: [Point]
    let accent: Color

    var body: some View {
        Chart(points) { p in
            AreaMark(
                x: .value("Day", p.id),
                y: .value("Burn", p.value)
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [accent.opacity(0.35), accent.opacity(0.02)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .interpolationMethod(.catmullRom)

            LineMark(
                x: .value("Day", p.id),
                y: .value("Burn", p.value)
            )
            .foregroundStyle(accent)
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .interpolationMethod(.catmullRom)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: .automatic(includesZero: true))
    }
}
