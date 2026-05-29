import SwiftUI
import OpenBurnBarCore

// MARK: - Velocity Forecast Card
//
// Renders the projected end-of-day burn alongside a "day progress" gauge.
// Updates on a 60s timer so the projection nudges throughout the day.

struct VelocityForecastCard: View {
    let todayTotals: RollupTotals?
    let trailingTotals: RollupTotals?
    let displayMode: UsageDisplayMode
    /// Live usage events from the Pulse real-time listener. Used to compute
    /// local-day totals that supplement the UTC-based rollup so the forecast
    /// stays accurate across timezone boundaries and rebuild lag.
    var liveUsages: [TokenUsage] = []

    @Environment(\.mobileBackgroundVisibility) private var backgroundVisibility
    @Environment(\.scenePhase) private var scenePhase
    @State private var nowTick: Date = Date()

    var forecast: VelocityForecast? {
        // Compute live-day totals from usage events. The rollup "today"
        // document is keyed to the UTC date, which diverges from the user's
        // local calendar day (e.g. at 7 PM CDT the UTC date rolls over,
        // resetting the rollup to ~$0). We use the same rolling-24h window
        // the hero card uses so the forecast stays consistent with the big
        // burn number at the top of Pulse.
        let dayStart = nowTick.addingTimeInterval(-86_400)
        let localDayUsages = liveUsages.filter { usage in
            let attributedAt = max(usage.startTime, usage.endTime)
            return attributedAt >= dayStart && attributedAt <= nowTick
        }
        let liveCost = localDayUsages.reduce(0.0) { $0 + max(0, $1.costUSD) }
        let liveTokens = localDayUsages.reduce(0) { $0 + max(0, $1.totalTokens) }

        let rollupCost = todayTotals?.costUsd ?? 0
        let rollupTokens = todayTotals?.tokens ?? 0

        // Use whichever source has the higher value — the rollup may be
        // ahead when the live query window doesn't cover the full day,
        // and live data is ahead near UTC date boundaries or during
        // rebuild lag.
        let bestCost = max(rollupCost, liveCost)
        let bestTokens = max(rollupTokens, liveTokens)

        guard bestCost > 0 || bestTokens > 0 || (trailingTotals?.costUsd ?? 0) > 0 else {
            return nil
        }

        return VelocityForecaster.forecast(
            todayCost: bestCost,
            todayTokens: bestTokens,
            sevenDayCost: trailingTotals?.costUsd ?? 0,
            sevenDayTokens: trailingTotals?.tokens ?? 0,
            now: nowTick
        )
    }

    var body: some View {
        AuroraGlassCard(variant: paceVariant, cornerRadius: AuroraDesign.Shape.heroCorner) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                AuroraSection(
                    "End-of-day forecast",
                    subtitle: forecast?.pace.label ?? "Awaiting data",
                    accent: paceColor
                )

                HStack(spacing: MobileTheme.Spacing.lg) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("PROJECTED")
                            .font(MobileTheme.Typography.tiny)
                            .fontWeight(.semibold)
                            .tracking(2)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                        Text(projectedText)
                            .font(AuroraDesign.Typography.monoDisplay)
                            .foregroundStyle(MobileTheme.primaryGradient)
                            .contentTransition(.numericText())
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        if let forecast {
                            Label(forecast.pace.label, systemImage: forecast.pace.icon)
                                .font(MobileTheme.Typography.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(paceColor)
                        }
                    }
                    Spacer()
                    progressGauge
                        .frame(width: 88, height: 88)
                }
            }
        }
        .task(id: shouldRefreshForecastClock) { await runForecastClock() }
        .onChange(of: shouldRefreshForecastClock) { _, shouldRefresh in
            guard shouldRefresh else { return }
            nowTick = Date()
        }
    }

    // MARK: - Derived

    private var shouldRefreshForecastClock: Bool {
        MobileDecorativeRenderPolicy.allowsLiveEffects(
            visibility: backgroundVisibility,
            scenePhaseActive: scenePhase == .active
        )
    }

    private func runForecastClock() async {
        guard shouldRefreshForecastClock else { return }
        while !Task.isCancelled {
            await MainActor.run { nowTick = Date() }
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
    }

    private var projectedText: String {
        guard let forecast else { return "—" }
        switch displayMode {
        case .currency: return forecast.projectedCost.formatAsCost()
        case .tokens:   return forecast.projectedTokens.formatAsTokenVolume()
        }
    }

    private var paceVariant: AuroraGlassVariant {
        switch forecast?.pace {
        case .ahead: return .urgent
        case .below: return .success
        default:     return .standard
        }
    }

    private var paceColor: Color {
        switch forecast?.pace {
        case .ahead: return MobileTheme.warning
        case .below: return MobileTheme.success
        case .onTrack, .none: return MobileTheme.amber
        }
    }

    // MARK: - Gauge

    private var progressGauge: some View {
        let progress = CGFloat(forecast?.dayProgress ?? 0)
        return ZStack {
            Circle()
                .stroke(MobileTheme.Colors.border.opacity(0.3), lineWidth: 6)
            Circle()
                .trim(from: 0, to: max(0.02, progress))
                .stroke(
                    AngularGradient(
                        colors: [MobileTheme.amber, MobileTheme.ember, MobileTheme.amber],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: MobileTheme.amber.opacity(0.55), radius: 12)
            VStack(spacing: 2) {
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                Text("of day")
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
        }
    }
}
