import SwiftUI

// MARK: - QuotaArcDial
//
// Twin concentric rings used by SubscriptionCard. The outer ring tracks the
// longer-horizon bucket (typically 7d/30d/weekly); the inner ring tracks the
// shorter-horizon bucket (typically 5h/24h). The center renders the dominant
// window's remaining percent in a large monospaced caption, with a small
// secondary label underneath.
//
// Both rings animate from 0 → actual on first appearance. If a bucket is
// unavailable the corresponding ring renders dashed + muted instead of a flat
// "zero" which would misread as "fully exhausted".

struct QuotaArcDial: View {
    let outer: ProviderQuotaBucket?
    let inner: ProviderQuotaBucket?
    let provider: AgentProvider
    var diameter: CGFloat = 140

    @State private var animateProgress = false

    private var theme: ProviderTheme { ProviderTheme.theme(for: provider) }

    private var dominantBucket: ProviderQuotaBucket? {
        outer ?? inner
    }

    private var dominantRemainingFraction: Double {
        guard let b = dominantBucket else { return 0 }
        return remainingFraction(for: b)
    }

    private var outerLabel: String {
        switch outer?.windowKind {
        case .weekly, .rollingDays: return "7d"
        case .monthly: return "30d"
        case .daily: return "24h"
        case .rollingHours: return "5h"
        case .lifetime: return "Lifetime"
        case .custom, nil: return outer?.label ?? "—"
        }
    }

    private var innerLabel: String {
        switch inner?.windowKind {
        case .rollingHours: return "5h"
        case .daily: return "24h"
        case .weekly, .rollingDays: return "7d"
        case .monthly: return "30d"
        case .lifetime: return "Lifetime"
        case .custom, nil: return inner?.label ?? "—"
        }
    }

    var body: some View {
        ZStack {
            outerTrack
            outerFill
            outerPaceMarker
            innerTrack
            innerFill
            innerPaceMarker
            centerLabel
        }
        .frame(width: diameter, height: diameter)
        .onAppear {
            guard !animateProgress else { return }
            withAnimation(.easeOut(duration: 0.55).delay(0.05)) {
                animateProgress = true
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Rings

    private var outerTrack: some View {
        Circle()
            .stroke(
                DesignSystem.Colors.surfaceElevated.opacity(0.85),
                style: StrokeStyle(lineWidth: 8, lineCap: .round)
            )
            .padding(2)
    }

    @ViewBuilder
    private var outerFill: some View {
        if let outer {
            let fraction = remainingFraction(for: outer)
            let progress = animateProgress ? fraction : 0
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    pressureGradient(for: fraction, color: theme.primaryColor, accent: theme.accentColor),
                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                )
                .padding(2)
                .rotationEffect(.degrees(-90))
                .shadow(color: pressureColor(for: fraction).opacity(0.22), radius: 6, y: 0)
        } else {
            Circle()
                .stroke(
                    theme.primaryColor.opacity(0.15),
                    style: StrokeStyle(lineWidth: 8, dash: [4, 6])
                )
                .padding(2)
        }
    }

    private var innerTrack: some View {
        Circle()
            .stroke(
                DesignSystem.Colors.surfaceElevated.opacity(0.85),
                style: StrokeStyle(lineWidth: 6, lineCap: .round)
            )
            .padding(20)
    }

    @ViewBuilder
    private var innerFill: some View {
        if let inner {
            let fraction = remainingFraction(for: inner)
            let progress = animateProgress ? fraction : 0
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    pressureGradient(for: fraction, color: theme.accentColor, accent: theme.primaryColor),
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )
                .padding(20)
                .rotationEffect(.degrees(-90))
                .shadow(color: pressureColor(for: fraction).opacity(0.20), radius: 4, y: 0)
        } else {
            Circle()
                .stroke(
                    theme.accentColor.opacity(0.12),
                    style: StrokeStyle(lineWidth: 6, dash: [3, 5])
                )
                .padding(20)
        }
    }

    // MARK: - Pace markers
    //
    // Sit on the centerline of each ring stroke, at the angle marking
    // where the fill edge SHOULD be by now if usage is to last the full
    // window. Renders nothing for buckets without a pace signal
    // (lifetime / custom / missing resetsAt).

    @ViewBuilder
    private var outerPaceMarker: some View {
        if let outer, animateProgress {
            PaceArcMarker(
                pace: outer.idealPace(),
                tint: theme.primaryColor,
                ringInset: 2,
                lineWidth: 8
            )
        }
    }

    @ViewBuilder
    private var innerPaceMarker: some View {
        if let inner, animateProgress {
            PaceArcMarker(
                pace: inner.idealPace(),
                tint: theme.accentColor,
                ringInset: 20,
                lineWidth: 6
            )
        }
    }

    // MARK: - Center

    private var centerLabel: some View {
        VStack(spacing: 2) {
            Text(centerText)
                .font(.system(size: 30, weight: .bold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(centerForeground)
                .contentTransition(.numericText())
                .animation(DesignSystem.Animation.gentle, value: centerText)

            Text(centerSubtitle)
                .font(DesignSystem.Typography.monoTiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
    }

    private var centerText: String {
        guard dominantBucket != nil else { return "—" }
        let pct = Int((dominantRemainingFraction * 100).rounded())
        return "\(pct)%"
    }

    private var centerSubtitle: String {
        guard dominantBucket != nil else { return "no signal" }
        return "left in \(outerLabel == "—" ? innerLabel : outerLabel)"
    }

    private var centerForeground: AnyShapeStyle {
        guard dominantBucket != nil else {
            return AnyShapeStyle(DesignSystem.Colors.textMuted)
        }
        return AnyShapeStyle(theme.gradient)
    }

    // MARK: - Pressure helpers

    private func remainingFraction(for bucket: ProviderQuotaBucket) -> Double {
        if let pct = bucket.remainingPercent {
            return min(max(pct / 100, 0), 1)
        }
        return min(max(1 - bucket.progressFraction, 0), 1)
    }

    private func pressureColor(for remaining: Double) -> Color {
        switch remaining {
        case 0.75...: return theme.primaryColor
        case 0.50..<0.75: return theme.primaryColor.opacity(0.78)
        case 0.25..<0.50: return DesignSystem.Colors.amber
        default: return DesignSystem.Colors.warning
        }
    }

    private func pressureGradient(
        for remaining: Double,
        color: Color,
        accent: Color
    ) -> LinearGradient {
        switch remaining {
        case 0.75...:
            return LinearGradient(
                colors: [color, accent],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case 0.50..<0.75:
            return LinearGradient(
                colors: [color.opacity(0.78), accent.opacity(0.62)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case 0.25..<0.50:
            return LinearGradient(
                colors: [color.opacity(0.55), DesignSystem.Colors.amber],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        default:
            return LinearGradient(
                colors: [DesignSystem.Colors.amber, DesignSystem.Colors.warning],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var accessibilityLabel: String {
        var parts: [String] = ["\(provider.displayName) quota"]
        if let outer {
            parts.append("\(outerLabel): \(outer.remainingText) remaining")
        }
        if let inner {
            parts.append("\(innerLabel): \(inner.remainingText) remaining")
        }
        return parts.joined(separator: ", ")
    }
}

#if DEBUG
#Preview("Quota arc — both rings, healthy") {
    let weekly = ProviderQuotaBucket(
        key: "w", label: "Weekly", windowKind: .weekly,
        usedValue: 25, limitValue: 100, remainingValue: 75, usedPercent: 25,
        resetsAt: Date().addingTimeInterval(60 * 60 * 24 * 3),
        unit: .percent, isEstimated: false
    )
    let hourly = ProviderQuotaBucket(
        key: "h", label: "5h", windowKind: .rollingHours,
        usedValue: 40, limitValue: 100, remainingValue: 60, usedPercent: 40,
        resetsAt: Date().addingTimeInterval(60 * 30),
        unit: .percent, isEstimated: false
    )
    return QuotaArcDial(outer: weekly, inner: hourly, provider: .claudeCode)
        .padding(24)
        .background(DesignSystem.Colors.background)
}

#Preview("Quota arc — near edge") {
    let weekly = ProviderQuotaBucket(
        key: "w", label: "Weekly", windowKind: .weekly,
        usedValue: 88, limitValue: 100, remainingValue: 12, usedPercent: 88,
        resetsAt: Date().addingTimeInterval(60 * 60 * 24),
        unit: .percent, isEstimated: false
    )
    return QuotaArcDial(outer: weekly, inner: nil, provider: .factory)
        .padding(24)
        .background(DesignSystem.Colors.background)
}
#endif
