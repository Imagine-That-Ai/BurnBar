import SwiftUI
import OpenBurnBarCore

// MARK: - Pulse Hero Burn Card
//
// The marquee card on the Pulse home. Massive rolling number, a sparkline
// trail behind it, currency/token mode toggle, and a delta pill comparing
// today vs the trailing 7-day daily average.

struct PulseHeroBurnCard: View {
    let total: RollupTotals?
    let trailingTotal: RollupTotals?
    let dailyPoints: [RollupDailyPoint]
    let topProvider: AgentProvider?
    @Binding var displayMode: UsageDisplayMode
    var scope: PulseTimelineScope = .day

    var body: some View {
        AuroraGlassCard(variant: .hero, cornerRadius: AuroraDesign.Shape.heroCorner, padding: AuroraDesign.Layout.heroPadding) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                topRow
                metric
                supportingRow
                deltaRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .topTrailing) {
            if let topProvider {
                ProviderAuroraAvatar(provider: topProvider, size: 56)
                    .padding(MobileTheme.Spacing.md)
                    .accessibilityHidden(true)
                    .motionParallax(intensity: 6)
            }
        }
    }

    // MARK: - Subviews

    private var topRow: some View {
        HStack {
            Text(scope.headerLabel)
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.semibold)
                .tracking(2)
                .foregroundStyle(MobileTheme.Colors.textMuted)
            if scope == .minute || scope == .hour || scope == .day {
                Circle()
                    .fill(MobileTheme.success)
                    .frame(width: 6, height: 6)
                    .modifier(BreathingPulse())
            }
            Spacer()
            modeToggle
        }
    }

    private var metric: some View {
        let trend = computedTrend()
        let sparkline = dailyPoints.map(\.value)
        return RollingMetric(
            label: "Burn",
            value: heroValueText,
            subtitle: heroSubtitleText,
            trend: trend,
            sparkline: sparkline,
            valueFont: AuroraDesign.Typography.displayHero
        )
    }

    private var supportingRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "flame.fill")
                .foregroundStyle(MobileTheme.amber)
                .font(.system(size: 12, weight: .bold))
                .symbolEffect(.pulse, options: .repeating)
            Text("Streaming live from your Mac")
                .font(MobileTheme.Typography.tiny)
                .foregroundStyle(MobileTheme.Colors.textMuted)
        }
    }

    @ViewBuilder
    private var deltaRow: some View {
        if let trailingTotal, let total {
            let divisor: Double = scope == .week ? 7.0 : (scope == .month ? 30.0 : 7.0)
            let avg = (trailingTotal.costUsd / divisor)
            let pct = avg > 0 ? ((total.costUsd - avg) / avg) * 100 : 0
            HStack(spacing: 6) {
                Image(systemName: pct >= 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.system(size: 11, weight: .bold))
                Text(String(format: "%@ %.0f%%", pct >= 0 ? "Ahead of" : "Below", abs(pct)) + " your \(trailingLabel) average")
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.semibold)
            }
            .foregroundStyle(pct >= 0 ? MobileTheme.amber : MobileTheme.success)
            .padding(.top, 2)
        }
    }

    private var trailingLabel: String {
        switch scope {
        case .minute, .hour, .day: return "7-day"
        case .week:                return "30-day"
        case .month:               return "90-day"
        }
    }

    private var modeToggle: some View {
        Button {
            withAnimation(AuroraDesign.Motion.auroraSnap) {
                displayMode = displayMode == .currency ? .tokens : .currency
            }
            HapticBus.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: displayMode == .currency ? "dollarsign" : "number")
                    .font(.system(size: 10, weight: .bold))
                Text(displayMode.label)
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(MobileTheme.ember)
            .background(
                Capsule().fill(MobileTheme.ember.opacity(0.18))
            )
            .overlay(
                Capsule().stroke(MobileTheme.ember.opacity(0.4), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Toggle currency or tokens")
    }

    // MARK: - Derivations

    private var heroValueText: String {
        guard let total else { return "—" }
        switch displayMode {
        case .currency: return total.costUsd.formatAsCost()
        case .tokens:   return total.tokens.formatAsTokenVolume()
        }
    }

    private var heroSubtitleText: String {
        guard let total else { return "Tap to begin" }
        switch displayMode {
        case .currency: return "\(total.tokens.formatAsTokenVolume()) tokens · \(total.requests) requests"
        case .tokens:   return "\(total.costUsd.formatAsCost()) · \(total.requests) requests"
        }
    }

    private func computedTrend() -> RollingMetric.Trend? {
        guard let total, let trailingTotal else { return nil }
        let avg = trailingTotal.costUsd / 7.0
        guard avg > 0 else { return nil }
        let delta = ((total.costUsd - avg) / avg) * 100
        let direction: RollingMetric.Trend.Direction = delta > 1 ? .up : (delta < -1 ? .down : .flat)
        return RollingMetric.Trend(deltaPercent: delta, direction: direction)
    }
}

// MARK: - Breathing Pulse

private struct BreathingPulse: ViewModifier {
    @State private var phase = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(phase ? 1.4 : 1.0)
            .opacity(phase ? 0.55 : 1.0)
            .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: phase)
            .onAppear { phase = true }
    }
}
