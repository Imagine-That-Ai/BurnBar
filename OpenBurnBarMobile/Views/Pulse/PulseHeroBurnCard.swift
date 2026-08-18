import SwiftUI
import OpenBurnBarCore

// MARK: - Pulse Hero Burn Card
//
// The marquee card on the Pulse home. Wraps:
//   * Big rolling burn metric with a brand gradient
//   * Live cost curve (Swift Charts) under the metric
//   * Burn-rate "$/min" velocity pill that breathes when live
//   * Delta pill comparing the window vs the trailing average
//   * Provider-tinted aurora halo behind the top-right provider avatar
//
// The hero is intentionally taller than other Pulse cards — it sets the
// emotional tone for the rest of the feed.
//
// The hero also OWNS the 1Hz live clock: the per-second tick lives in a
// pausable `TimelineView` here so it only re-evaluates this subtree, never
// the rest of the Pulse feed (docs/architecture/macos-performance.md §5).

/// 13pt rounded bold — the numeric voice shared by the call count and the
/// burn-rate pill. Scales with Dynamic Type like the rest of the hero.
private let heroPillNumeral = MobileScaledFont.system(
    size: 13,
    weight: .bold,
    design: .rounded,
    relativeTo: .caption
)

struct PulseHeroBurnCard: View {
    let rollupTotals: [RollupWindowKey: RollupTotals]
    let dailyPoints: [RollupDailyPoint]
    let liveUsages: [TokenUsage]
    let topProvider: AgentProvider?
    let displayMode: UsageDisplayMode
    var scope: PulseTimelineScope = .day
    /// Mirrors `PulseView.shouldRunLivePulseClock` — freezes the tick while
    /// the CloudStore sheet is up or the render policy disallows live effects.
    var clockPaused: Bool = false

    var body: some View {
        // `.animation(minimumInterval:paused:)` rather than `.periodic`
        // because periodic schedules cannot pause.
        TimelineView(.animation(minimumInterval: 1.0, paused: clockPaused)) { context in
            let metrics = PulseWindowMetricBuilder.metrics(
                scope: scope,
                rollupTotals: rollupTotals,
                liveUsages: liveUsages,
                now: context.date
            )
            PulseHeroBurnCardContent(
                total: metrics.total,
                trailingTotal: metrics.trailingTotal,
                dailyPoints: dailyPoints,
                liveUsages: liveUsages,
                topProvider: topProvider,
                displayMode: displayMode,
                scope: scope,
                now: context.date
            )
        }
    }
}

private struct PulseHeroBurnCardContent: View {
    let total: RollupTotals?
    let trailingTotal: RollupTotals?
    let dailyPoints: [RollupDailyPoint]
    let liveUsages: [TokenUsage]
    let topProvider: AgentProvider?
    let displayMode: UsageDisplayMode
    var scope: PulseTimelineScope = .day
    var now = Date()

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        AuroraGlassCard(
            variant: .hero,
            cornerRadius: AuroraDesign.Shape.heroCorner,
            padding: AuroraDesign.Layout.heroPadding
        ) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                topRow
                metricRow
                deltaRow
                costCurve
                footerRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background {
            PulseHeroDepthGlow(
                accent: accentColor,
                darkMode: colorScheme == .dark
            )
            .allowsHitTesting(false)
        }
        .overlay(alignment: .topTrailing) {
            providerHalo
        }
        .shadow(color: accentColor.opacity(colorScheme == .dark ? 0.20 : 0.14),
                radius: 28, x: 0, y: 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            MobileAccessibilityLabelPolicy.heroBurn(
                displayMode: displayMode == .currency ? "currency" : "tokens",
                heroText: heroValueText,
                liveRate: heroLiveRateText
            )
        )
    }

    // MARK: - Top Row

    private var topRow: some View {
        HStack(spacing: 8) {
            Text(scope.headerLabel)
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.semibold)
                .tracking(2)
                .foregroundStyle(MobileTheme.Colors.textMuted)
            if scope == .minute || scope == .hour || scope == .day {
                LiveDot(color: MobileTheme.success)
            }
            Spacer()
            burnRatePill
                .padding(.trailing, topProvider == nil ? 0 : 64)
        }
    }

    // MARK: - Metric Row

    private var metricRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Burn".uppercased())
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.semibold)
                .tracking(1.4)
                .foregroundStyle(MobileTheme.Colors.textMuted)

            Text(heroValueText)
                .font(AuroraDesign.Typography.displayHero)
                .fontDesign(.rounded)
                .foregroundStyle(MobileTheme.primaryGradient)
                .contentTransition(.numericText(value: heroValueNumeric))
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .shadow(color: MobileTheme.ember.opacity(0.35), radius: 12, y: 6)

            Text(heroSubtitleText)
                .font(MobileTheme.Typography.body)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .contentTransition(.numericText())
        }
    }

    // MARK: - Delta Row

    @ViewBuilder
    private var deltaRow: some View {
        if let trailingTotal, let total {
            let divisor: Double = scope == .week ? 7.0 : (scope == .month ? 30.0 : 7.0)
            let avg = trailingTotal.costUsd / divisor
            let pct = avg > 0 ? ((total.costUsd - avg) / avg) * 100 : 0
            let isAhead = pct >= 0
            HStack(spacing: 6) {
                Image(systemName: isAhead ? "arrow.up.right" : "arrow.down.right")
                    .font(MobileScaledFont.system(size: 13, weight: .bold))
                Text(String(format: "%@ %.0f%%", isAhead ? "Ahead of" : "Below", abs(pct)) + " your \(trailingLabel) average")
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(isAhead ? MobileTheme.amber : MobileTheme.success)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill((isAhead ? MobileTheme.amber : MobileTheme.success).opacity(0.14))
            )
            .overlay(
                Capsule()
                    .stroke((isAhead ? MobileTheme.amber : MobileTheme.success).opacity(0.35), lineWidth: 0.5)
            )
        }
    }

    // MARK: - Live Cost Curve

    private var costCurve: some View {
        PulseLiveCostCurve(
            usages: liveUsages,
            dailyPoints: dailyPoints,
            scope: scope,
            displayMode: displayMode,
            now: now,
            accent: accentColor
        )
    }

    // MARK: - Footer Row

    /// Whether usage has actually arrived recently. The footer used to claim
    /// "Streaming live from your Mac" unconditionally — including on a device
    /// that had never received a single byte — which pointed users away from
    /// real sync problems.
    private var liveFeedIsActive: Bool {
        liveUsages.contains { now.timeIntervalSince($0.endTime) < 10 * 60 }
    }

    private var footerStatusText: String {
        if liveFeedIsActive { return "Streaming live from your Mac" }
        if let total, total.requests > 0 { return "Synced from your Mac" }
        return "Waiting for your Mac — open OpenBurnBar on the Mac to sync"
    }

    private var footerRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "flame.fill")
                .foregroundStyle(liveFeedIsActive ? MobileTheme.amber : MobileTheme.Colors.textMuted)
                .font(MobileScaledFont.system(size: 12, weight: .bold))
                .symbolEffect(.pulse, options: .repeating, isActive: liveFeedIsActive)
            Text(footerStatusText)
                .font(MobileTheme.Typography.tiny)
                .foregroundStyle(MobileTheme.Colors.textMuted)
            Spacer()
            if let total, total.requests > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "waveform.path.ecg")
                        .font(MobileScaledFont.system(size: 12, weight: .semibold))
                    Text("\(total.requests)")
                        .font(heroPillNumeral)
                        .contentTransition(.numericText())
                    Text("calls")
                        .font(MobileTheme.Typography.tiny)
                        .fontWeight(.medium)
                }
                .foregroundStyle(MobileTheme.Colors.textMuted)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(MobileTheme.Colors.surface.opacity(0.65)))
                .overlay(Capsule().stroke(MobileTheme.Colors.borderSubtle.opacity(0.5), lineWidth: 0.5))
            }
        }
    }

    // MARK: - Burn-rate Pill

    @ViewBuilder
    private var burnRatePill: some View {
        if let text = heroLiveRateText {
            BurnVelocityPill(
                icon: displayMode == .currency ? "dollarsign" : "number",
                text: text,
                accent: accentColor
            )
            .transition(.scale.combined(with: .opacity))
        }
    }

    // MARK: - Provider Halo

    @ViewBuilder
    private var providerHalo: some View {
        if let topProvider {
            ZStack {
                // Pre-shaped glow: the gradient's smooth falloff replaces
                // the old `.blur(18)` pass (the halo was already a
                // RadialGradient — the blur was redundant smoothing that
                // cost a full offscreen render per frame). The 186pt circle
                // covers the blur's former bleed while the inner 150pt
                // frame keeps the layout footprint — and the avatar's
                // position — unchanged.
                Circle()
                    .fill(
                        RadialGradient(
                            gradient: Gradient(stops: PulseHeroGlow.providerHaloStops(
                                primary: MobileTheme.Colors.primary(for: topProvider),
                                accent: MobileTheme.Colors.accent(for: topProvider)
                            )),
                            center: .center,
                            startRadius: 0,
                            endRadius: 93
                        )
                    )
                    .frame(width: 186, height: 186)
                    .frame(width: 150, height: 150)
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)

                ProviderAuroraAvatar(provider: topProvider, size: 56, glassInCard: true)
                    .motionParallax(intensity: 8)
            }
            .padding(MobileTheme.Spacing.md)
            .accessibilityHidden(true)
        }
    }

    // MARK: - Derived

    private var accentColor: Color {
        guard let topProvider else { return MobileTheme.ember }
        return MobileTheme.Colors.primary(for: topProvider)
    }

    private var trailingLabel: String {
        switch scope {
        case .minute, .hour, .day: return "7-day"
        case .week:                return "30-day"
        case .month:               return "90-day"
        }
    }

    private var heroLiveRateText: String? {
        switch displayMode {
        case .currency:
            guard let rate = PulseBurnRate.dollarsPerMinute(usages: liveUsages, now: now) else { return nil }
            return rate < 0.01 ? "<$0.01/min" : String(format: "$%.2f/min", rate)
        case .tokens:
            guard let rate = PulseBurnRate.tokensPerMinute(usages: liveUsages, now: now) else { return nil }
            return "\(rate.formatAsTokenVolume())/min"
        }
    }

    private var heroValueText: String {
        guard let total else { return "—" }
        switch displayMode {
        case .currency: return total.costUsd.formatAsCost()
        case .tokens:   return total.tokens.formatAsTokenVolume()
        }
    }

    /// Numeric value used to drive `contentTransition(.numericText(value:))`
    /// so the hero number tweens smoothly between live ticks.
    private var heroValueNumeric: Double {
        guard let total else { return 0 }
        switch displayMode {
        case .currency: return total.costUsd
        case .tokens:   return Double(total.tokens)
        }
    }

    private var heroSubtitleText: String {
        guard let total else { return "Tap to begin" }
        switch displayMode {
        case .currency: return "\(total.tokens.formatAsTokenVolume()) tokens · \(total.requests) requests"
        case .tokens:   return "\(total.costUsd.formatAsCost()) · \(total.requests) requests"
        }
    }
}

// MARK: - Hero Depth Glow

/// The hero's depth gradient is decorative and must remain inside the card's
/// proposed bounds. Extending it with negative padding paints into adjacent
/// Pulse controls and creates a visible horizontal color seam.
struct PulseHeroDepthGlow: View {
    let accent: Color
    let darkMode: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: AuroraDesign.Shape.heroCorner, style: .continuous)
            .fill(
                EllipticalGradient(
                    gradient: Gradient(stops: PulseHeroGlow.depthGlowStops(
                        accent: accent,
                        amber: MobileTheme.amber,
                        darkMode: darkMode
                    )),
                    center: UnitPoint(x: 0.5, y: 0.15),
                    startRadiusFraction: 0,
                    endRadiusFraction: 1.0
                )
            )
    }
}

// MARK: - Live Dot

private struct LiveDot: View {
    let color: Color
    @State private var pulsing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.35))
                .frame(width: 14, height: 14)
                .scaleEffect(pulsing ? 1.5 : 0.85)
                .opacity(pulsing ? 0.0 : 0.6)
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .shadow(color: color.opacity(0.7), radius: 3)
        }
        .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: pulsing)
        .onAppear { pulsing = true }
        .accessibilityHidden(true)
    }
}

// MARK: - Hero Glow Stops

/// Gradient stop tables for the hero's pre-shaped glows. The smooth
/// multi-stop falloffs approximate the Gaussian tails of the `.blur(18)` /
/// `.blur(26)` passes they replaced (perf finding ios-013) — keep the
/// locations strictly increasing and the terminal stop fully clear, or
/// hard edges reappear. Static + pure so the no-blur contract is
/// unit-testable.
enum PulseHeroGlow {
    static func providerHaloStops(primary: Color, accent: Color) -> [Gradient.Stop] {
        [
            .init(color: primary.opacity(0.50), location: 0.0),
            .init(color: primary.opacity(0.34), location: 0.30),
            .init(color: accent.opacity(0.16), location: 0.58),
            .init(color: accent.opacity(0.05), location: 0.82),
            .init(color: .clear, location: 1.0)
        ]
    }

    static func depthGlowStops(accent: Color, amber: Color, darkMode: Bool) -> [Gradient.Stop] {
        [
            .init(color: accent.opacity(darkMode ? 0.18 : 0.10), location: 0.0),
            .init(color: amber.opacity(darkMode ? 0.10 : 0.06), location: 0.45),
            .init(color: amber.opacity(darkMode ? 0.04 : 0.02), location: 0.75),
            .init(color: .clear, location: 0.97)
        ]
    }

}

// MARK: - Burn Velocity Pill

private struct BurnVelocityPill: View {
    let icon: String
    let text: String
    let accent: Color
    @State private var breathing = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(MobileScaledFont.system(size: 12, weight: .heavy))
            Text(text)
                .font(heroPillNumeral)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .foregroundStyle(accent)
        .background(
            Capsule()
                .fill(accent.opacity(breathing ? 0.22 : 0.14))
        )
        .background(
            // Breathing halo: a constant-radius pre-blurred capsule whose
            // OPACITY animates (free on the render server, raster cached)
            // replaces the old animated shadow radius (4⇄8), which forced a
            // shadow re-blur every frame for the card's lifetime.
            Capsule()
                .fill(accent.opacity(0.3))
                .blur(radius: 7)
                .opacity(breathing ? 1.0 : 0.0)
        )
        .overlay(
            Capsule()
                .stroke(accent.opacity(0.4), lineWidth: 0.6)
        )
        .shadow(color: accent.opacity(0.3), radius: 4)
        .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: breathing)
        .onAppear { breathing = true }
        .accessibilityLabel("Live burn rate: \(text)")
    }
}
