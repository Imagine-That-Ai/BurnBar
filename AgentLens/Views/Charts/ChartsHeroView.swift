import SwiftUI
import OpenBurnBarCore

// MARK: - Charts Hero
//
// The gallery's opening wall: one full-width glass band that tells the story
// of the selected window before a single chart is read — an oversized metric
// counter in the active palette mood, an editorial one-liner drawn from the
// data, and a row of stat chips. The backdrop is a static arrangement of
// blurred color blooms (no timers, no Canvas) so the page can stay open all
// day at zero idle cost, exactly like the ChartKit renderers below it.

/// The editorial one-liner under the hero counter. Pure string logic over the
/// snapshot — prioritized so the most interesting fact wins, deterministic so
/// it is unit-testable.
enum ChartsHeroCopy {

    static func line(for snapshot: ChartsSnapshot, metric: ChartsPrimaryMetric) -> String {
        if snapshot.isEmpty {
            return "This window is quiet — run an agent and the gallery draws itself."
        }
        // 1. The rhythm fact is the most human: when you actually burn.
        if let weekday = snapshot.peakWeekdayIndex, let hour = snapshot.peakHour {
            return "Your furnace hour: \(weekdayNames[weekday]) around \(hourText(hour))."
        }
        // 2. Momentum, in the active metric's voice.
        let trend = metric == .cost ? snapshot.burnTrendPercent : snapshot.tokenTrendPercent
        if let trend, abs(trend) >= 15 {
            let direction = trend > 0 ? "building" : "cooling"
            let magnitude = abs(trend).formatted(.number.precision(.fractionLength(0)))
            return "Momentum is \(direction) — the second half of this window ran \(magnitude)% "
                + (trend > 0 ? "over" : "under") + " the first."
        }
        // 3. Cache is the feel-good line item (cost voice only).
        if metric == .cost, snapshot.cacheSavingsEstimate >= 1 {
            return "Prompt caching quietly paid rent: ≈\(snapshot.cacheSavingsEstimate.formatAsCost()) saved."
        }
        // 4. Where the month is heading.
        let forecast = metric == .cost ? snapshot.forecast : snapshot.tokenForecast
        if let forecast {
            return "On the current pace, the month lands near \(metric.format(forecast.projectedMonthEndSpend))."
        }
        return "Every request you've made, drawn to scale."
    }

    private static let weekdayNames = ["Sundays", "Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays"]

    private static func hourText(_ hour: Int) -> String {
        switch hour {
        case 0: return "12am"
        case 12: return "12pm"
        case ..<12: return "\(hour)am"
        default: return "\(hour - 12)pm"
        }
    }
}

struct ChartsHeroView<Controls: View>: View {
    let snapshot: ChartsSnapshot
    let appearance: ChartsAppearance
    @ViewBuilder var controls: Controls

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private var metric: ChartsPrimaryMetric { appearance.primaryMetric }
    private var mood: ChartsPaletteMood { appearance.paletteMood }

    /// The hero counter's value in the active metric.
    private var primaryValue: Double {
        metric == .cost ? snapshot.totalCost : Double(snapshot.totalTokens)
    }

    private var trendPercent: Double? {
        metric == .cost ? snapshot.burnTrendPercent : snapshot.tokenTrendPercent
    }

    var body: some View {
        ZStack {
            blooms
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                HStack(alignment: .top, spacing: DesignSystem.Spacing.lg) {
                    headline
                    Spacer(minLength: DesignSystem.Spacing.lg)
                    controls
                }
                statChips
            }
            .padding(DesignSystem.Spacing.xl)
        }
        .chartGlassCard(cornerRadius: DesignSystem.Radius.xl)
        .accessibilityElement(children: .contain)
    }

    // MARK: Backdrop blooms

    /// Three static, heavily blurred color blooms in the active mood — the
    /// gallery's wallpaper. Clipped inside the card's corner radius.
    private var blooms: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Circle()
                    .fill(mood.color(for: .burn).opacity(colorScheme == .dark ? 0.30 : 0.22))
                    .frame(width: size.width * 0.55, height: size.width * 0.55)
                    .blur(radius: 70)
                    .position(x: size.width * 0.08, y: -size.height * 0.25)
                Circle()
                    .fill(mood.color(for: .mix).opacity(colorScheme == .dark ? 0.26 : 0.18))
                    .frame(width: size.width * 0.45, height: size.width * 0.45)
                    .blur(radius: 80)
                    .position(x: size.width * 0.62, y: size.height * 1.15)
                Circle()
                    .fill(mood.color(for: .rhythm).opacity(colorScheme == .dark ? 0.18 : 0.12))
                    .frame(width: size.width * 0.38, height: size.width * 0.38)
                    .blur(radius: 90)
                    .position(x: size.width * 1.02, y: size.height * 0.1)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.xl, style: .continuous))
        .allowsHitTesting(false)
    }

    // MARK: Headline

    private var headline: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text(snapshot.timeRange.displayName.uppercased())
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(1.6)
                .foregroundStyle(DesignSystem.Colors.textMuted)

            HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.md) {
                Text(metric.format(primaryValue))
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(
                        LinearGradient(
                            colors: mood.swatch,
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .contentTransition(.numericText(value: primaryValue))
                    .animation(reduceMotion ? nil : DesignSystem.Animation.gentle, value: primaryValue)

                if let trend = trendPercent {
                    trendBadge(trend)
                }
            }

            Text(ChartsHeroCopy.line(for: snapshot, metric: metric))
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
    }

    private func trendBadge(_ percent: Double) -> some View {
        let rising = percent > 0
        let tint = rising ? DesignSystem.Colors.amber : DesignSystem.Colors.success
        return HStack(spacing: 4) {
            Image(systemName: rising ? "arrow.up.right" : "arrow.down.right")
                .font(.system(size: 10, weight: .bold))
            Text(abs(percent).formatted(.number.precision(.fractionLength(0))) + "%")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(tint.opacity(0.14)))
        .help("Second half of this window vs the first, in \(metric.displayName.lowercased())")
    }

    // MARK: Stat chips

    private var statChips: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            // The counter speaks the primary metric; the first chip carries
            // the other one so both units are always on screen.
            if metric == .cost {
                chip(label: "Tokens", value: snapshot.totalTokens.formatAsTokenVolume(), slot: .mix)
            } else {
                chip(label: "Cost", value: snapshot.totalCost.formatAsCost(), slot: .mix)
            }
            chip(label: "Sessions", value: "\(snapshot.sessionCount)", slot: .rhythm)
            chip(
                label: "Cache saved",
                value: snapshot.cacheSavingsEstimate >= 0.005
                    ? "≈" + snapshot.cacheSavingsEstimate.formatAsCost()
                    : "—",
                slot: .cache
            )
            chip(label: "Top provider", value: topProviderText, slot: .delta)
        }
    }

    private var topProviderText: String {
        guard let top = snapshot.providerShares.first, snapshot.totalCost > 0 else { return "—" }
        let share = Int((top.cost / snapshot.totalCost * 100).rounded())
        return "\(top.provider.displayName) \(share)%"
    }

    private func chip(label: String, value: String, slot: ChartsAccentSlot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(1.0)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background {
            let shape = RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
            ZStack {
                shape.fill(DesignSystem.Colors.surface.opacity(colorScheme == .dark ? 0.55 : 0.65))
                shape.fill(mood.color(for: slot).opacity(colorScheme == .dark ? 0.07 : 0.05))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(mood.color(for: slot).opacity(0.25), lineWidth: 0.75)
        )
        .accessibilityElement(children: .combine)
    }
}
