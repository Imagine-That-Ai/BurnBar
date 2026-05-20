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

struct PulseHeroBurnCard: View {
    let total: RollupTotals?
    let trailingTotal: RollupTotals?
    let dailyPoints: [RollupDailyPoint]
    let liveUsages: [TokenUsage]
    let topProvider: AgentProvider?
    let displayMode: UsageDisplayMode
    var scope: PulseTimelineScope = .day
    var now: Date = Date()

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
        .background(heroDepthGlow.allowsHitTesting(false))
        .overlay(alignment: .topTrailing) {
            providerHalo
        }
        .shadow(color: accentColor.opacity(colorScheme == .dark ? 0.20 : 0.14),
                radius: 28, x: 0, y: 14)
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
                    .font(.system(size: 13, weight: .bold))
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

    private var footerRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "flame.fill")
                .foregroundStyle(MobileTheme.amber)
                .font(.system(size: 12, weight: .bold))
                .symbolEffect(.pulse, options: .repeating)
            Text("Streaming live from your Mac")
                .font(MobileTheme.Typography.tiny)
                .foregroundStyle(MobileTheme.Colors.textMuted)
            Spacer()
            if let total, total.requests > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 12, weight: .semibold))
                    Text("\(total.requests)")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
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
        switch displayMode {
        case .currency:
            if let rate = PulseBurnRate.dollarsPerMinute(usages: liveUsages, now: now) {
                BurnVelocityPill(
                    icon: "dollarsign",
                    text: rate < 0.01 ? "<$0.01/min" : String(format: "$%.2f/min", rate),
                    accent: accentColor
                )
                .transition(.scale.combined(with: .opacity))
            }
        case .tokens:
            if let rate = PulseBurnRate.tokensPerMinute(usages: liveUsages, now: now) {
                BurnVelocityPill(
                    icon: "number",
                    text: "\(rate.formatAsTokenVolume())/min",
                    accent: accentColor
                )
                .transition(.scale.combined(with: .opacity))
            }
        }
    }

    // MARK: - Provider Halo

    @ViewBuilder
    private var providerHalo: some View {
        if let topProvider {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                MobileTheme.Colors.primary(for: topProvider).opacity(0.55),
                                MobileTheme.Colors.accent(for: topProvider).opacity(0.18),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: 80
                        )
                    )
                    .frame(width: 150, height: 150)
                    .blur(radius: 18)
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)

                ProviderAuroraAvatar(provider: topProvider, size: 56)
                    .motionParallax(intensity: 8)
            }
            .padding(MobileTheme.Spacing.md)
            .accessibilityHidden(true)
        }
    }

    // MARK: - Hero Depth Glow

    private var heroDepthGlow: some View {
        RoundedRectangle(cornerRadius: AuroraDesign.Shape.heroCorner + 8, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        accentColor.opacity(colorScheme == .dark ? 0.18 : 0.10),
                        MobileTheme.amber.opacity(colorScheme == .dark ? 0.10 : 0.06),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .blur(radius: 26)
            .padding(-14)
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

// MARK: - Burn Velocity Pill

private struct BurnVelocityPill: View {
    let icon: String
    let text: String
    let accent: Color
    @State private var breathing = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .heavy))
            Text(text)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .foregroundStyle(accent)
        .background(
            Capsule()
                .fill(accent.opacity(breathing ? 0.22 : 0.14))
        )
        .overlay(
            Capsule()
                .stroke(accent.opacity(0.4), lineWidth: 0.6)
        )
        .shadow(color: accent.opacity(0.3), radius: breathing ? 8 : 4)
        .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: breathing)
        .onAppear { breathing = true }
        .accessibilityLabel("Live burn rate: \(text)")
    }
}
