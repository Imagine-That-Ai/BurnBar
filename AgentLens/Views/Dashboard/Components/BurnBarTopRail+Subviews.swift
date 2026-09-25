import AppKit
import OpenBurnBarAnalytics
import OpenBurnBarCore
import SwiftUI

// MARK: - Primitives

struct BurnRailDivider: View {
    var body: some View {
        Rectangle()
            .fill(DesignSystem.Colors.border.opacity(0.5))
            .frame(width: 1, height: 16)
            .opacity(0.8)
    }
}

struct BurnRailLivePulseDot: View {
    let isLive: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(DesignSystem.Colors.ember.opacity(0.35))
                .frame(width: 18, height: 18)
                .opacity(isLive ? 0.28 : 0)
            Circle()
                .fill(isLive ? DesignSystem.Colors.ember : DesignSystem.Colors.textMuted)
                .frame(width: 7, height: 7)
                .shadow(color: DesignSystem.Colors.ember.opacity(isLive ? 0.65 : 0),
                        radius: 4, y: 0)
        }
        .frame(width: 18, height: 18)
    }
}

struct BurnRailDeltaChip: View {
    let percent: Double

    var body: some View {
        let isUp = percent >= 0
        HStack(spacing: 2) {
            Image(systemName: isUp ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                .font(.system(size: 7, weight: .bold))
            Text(String(format: "%.1f%%", abs(percent)))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .monospacedDigit()
        }
        .foregroundStyle(isUp ? DesignSystem.Colors.amber : DesignSystem.Colors.success)
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(
            Capsule().fill((isUp ? DesignSystem.Colors.amber : DesignSystem.Colors.success)
                .opacity(0.12))
        )
    }
}

struct BurnRailSparkline: View {
    let samples: [Double]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                sparkPath(in: geo.size, closed: true)
                    .fill(
                        LinearGradient(
                            colors: [
                                DesignSystem.Colors.ember.opacity(0.35),
                                DesignSystem.Colors.ember.opacity(0.0)
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                sparkPath(in: geo.size, closed: false)
                    .stroke(
                        DesignSystem.Colors.primaryGradient,
                        style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round)
                    )
                if let last = samples.last {
                    let x = geo.size.width
                    let y = geo.size.height * (1 - CGFloat(clamp(last)))
                    Circle()
                        .fill(DesignSystem.Colors.ember)
                        .frame(width: 3, height: 3)
                        .position(x: x - 1.5, y: y)
                        .shadow(color: DesignSystem.Colors.ember.opacity(0.8), radius: 2)
                }
            }
        }
    }

    private func sparkPath(in size: CGSize, closed: Bool) -> Path {
        guard samples.count > 1 else { return Path() }
        let step = size.width / CGFloat(samples.count - 1)
        var path = Path()
        for (i, v) in samples.enumerated() {
            let x = CGFloat(i) * step
            let y = size.height * (1 - CGFloat(clamp(v)))
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        if closed {
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.addLine(to: CGPoint(x: 0, y: size.height))
            path.closeSubpath()
        }
        return path
    }

    private func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
}

struct BurnRailGhostIconButton: View {
    let symbol: String
    let help: String
    var spinning: Bool = false
    let action: () -> Void
    @State private var hover = false
    @State private var pressTrigger = 0

    var body: some View {
        Button {
            pressTrigger &+= 1
            action()
        } label: {
            symbolView
                .frame(width: 26, height: 22)
                .background(
                    Capsule(style: .continuous)
                        .fill(hover ? DesignSystem.Colors.ember.opacity(0.10) : Color.clear)
                )
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hover = $0 }
        .animation(DesignSystem.Animation.hover, value: hover)
    }

    @ViewBuilder
    private var symbolView: some View {
        if #available(macOS 14.0, *) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(
                    hover
                        ? DesignSystem.Colors.textPrimary
                        : DesignSystem.Colors.textSecondary
                )
                .rotationEffect(.degrees(0))
                .symbolEffect(.bounce, value: pressTrigger)
        } else {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(
                    hover
                        ? DesignSystem.Colors.textPrimary
                        : DesignSystem.Colors.textSecondary
                )
                .rotationEffect(.degrees(0))
        }
    }
}

struct BurnRailCapsuleDivider: View {
    var body: some View {
        Rectangle()
            .fill(DesignSystem.Colors.border.opacity(0.35))
            .frame(width: 0.5, height: 14)
    }
}

// MARK: - Sparkline data helper

enum BurnRailSparklineBuilder {
    /// Bucket usage rows into N normalized samples (0...1) across the given range.
    /// If `range` is nil (All Time), uses the min/max of the rows themselves.
    static func buildSamples(
        from usages: [TokenUsage],
        range: ClosedRange<Date>?,
        displayMode: UsageDisplayMode = .tokens,
        bucketCount: Int = 24,
        now: Date = Date()
    ) -> [Double] {
        guard !usages.isEmpty else { return Array(repeating: 0, count: bucketCount) }
        let lower: Date
        let upper: Date
        if let r = range {
            lower = r.lowerBound
            // Current ranges such as Today may extend to midnight. The rail is
            // a live history, so reserve the right edge for this instant—not
            // hours of future empty buckets that make active work look dead.
            upper = min(r.upperBound, now)
        } else {
            let times = usages.map(\.startTime)
            lower = times.min() ?? Date()
            // All Time still ends at now so the visual grammar stays stable:
            // oldest work at the left, the present at the right.
            upper = now
        }
        var buckets = Array(repeating: 0.0, count: bucketCount)
        for usage in usages {
            let amount = displayMode == .currency ? usage.cost : Double(usage.totalTokens)
            let slice = UsageWindowAttribution.allocate(
                amount: amount,
                start: usage.startTime,
                end: usage.endTime,
                windowStart: lower,
                windowEnd: upper,
                bucketCount: bucketCount
            )
            for index in buckets.indices where slice.indices.contains(index) {
                buckets[index] += slice[index]
            }
        }
        let maxVal = buckets.max() ?? 0
        guard maxVal > 0 else { return buckets.map { _ in 0 } }
        return buckets.map { $0 / maxVal }
    }

}
