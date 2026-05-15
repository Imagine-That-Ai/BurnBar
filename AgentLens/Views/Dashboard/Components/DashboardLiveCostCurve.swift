import AppKit
import Charts
import SwiftUI
import OpenBurnBarCore

// MARK: - Dashboard Live Cost Curve (macOS)
//
// Cumulative cost / token curve that sits under the Dashboard hero stat row.
// Mirrors the iOS / Android `PulseLiveCostCurve` aesthetic — ember→amber→
// transparent area, brand-gradient stroke, pulsing "now" marker — adapted
// for the wider, denser macOS Dashboard plate.
//
// Inputs the macOS Dashboard already has on hand:
//   * `usages`   — `[TokenUsage]` for the current TimeRange window
//   * `unit`     — currency or tokens display mode
//   * `range`    — the active TimeRange so we know how to bucket
//   * `accent`   — provider-tinted color when there's a clear winner
//
// Renders an empty rail + caption when there's no activity yet so the card
// still feels alive rather than blank.

struct DashboardLiveCostCurve: View {

    enum Unit { case cost, tokens }
    enum Granularity { case minute, hour, day }

    let usages: [TokenUsage]
    let unit: Unit
    let granularity: Granularity
    let domain: ClosedRange<Date>
    var accent: Color = DesignSystem.Colors.ember
    var height: CGFloat = 132

    @State private var pulsePhase: CGFloat = 0
    @State private var sweepPhase: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let samples = buildSamples()
        let peak = samples.map(\.cumulative).max() ?? 0
        let isEmpty = peak <= 0.0001

        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                header(peak: peak, isEmpty: isEmpty)
                ZStack(alignment: .bottomLeading) {
                    chart(samples: samples, peak: peak)
                        .opacity(isEmpty ? 0.18 : 1.0)
                    if isEmpty { emptyOverlay }
                    timeAxisLabels
                        .padding(.top, height - 18)
                }
                .frame(height: height)
            }
            .padding(DesignSystem.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary(samples: samples))
        .onAppear { startAnimating() }
        .onChange(of: reduceMotion) { _, _ in startAnimating() }
    }

    // MARK: - Header

    private func header(peak: Double, isEmpty: Bool) -> some View {
        HStack(spacing: 10) {
            Text(headerLabel)
                .font(DesignSystem.Typography.tiny)
                .tracking(2)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .textCase(.uppercase)

            if isLive {
                LiveDot(color: DesignSystem.Colors.success)
            }

            Spacer()

            if !isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 10, weight: .bold))
                    Text(peakLabel(peak: peak))
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                }
                .foregroundStyle(accent)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(accent.opacity(0.16)))
                .overlay(Capsule().stroke(accent.opacity(0.4), lineWidth: 0.5))
            }
        }
    }

    private var headerLabel: String {
        let unitName = unit == .cost ? "Cost" : "Tokens"
        switch granularity {
        case .minute: return "Live · cumulative \(unitName) · last minute"
        case .hour:   return "Live · cumulative \(unitName) · last hour"
        case .day:    return "Today · cumulative \(unitName)"
        }
    }

    private var isLive: Bool { granularity != .day || Date() < domain.upperBound }

    private func peakLabel(peak: Double) -> String {
        switch unit {
        case .cost:   return peak.formatAsCost()
        case .tokens: return Int(peak).formatAsTokenVolume()
        }
    }

    // MARK: - Chart

    @ViewBuilder
    private func chart(samples: [Sample], peak: Double) -> some View {
        let yMax = max(peak * 1.08, 0.0001)
        Chart {
            RuleMark(y: .value("zero", 0))
                .foregroundStyle(DesignSystem.Colors.textMuted.opacity(0.10))
                .lineStyle(StrokeStyle(lineWidth: 0.5))

            ForEach(samples) { sample in
                AreaMark(
                    x: .value("t", sample.time),
                    yStart: .value("base", 0.0),
                    yEnd: .value("cum", sample.cumulative)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            accent.opacity(colorScheme == .dark ? 0.55 : 0.45),
                            DesignSystem.Colors.amber.opacity(colorScheme == .dark ? 0.30 : 0.22),
                            DesignSystem.Colors.blaze.opacity(0.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }

            ForEach(samples) { sample in
                LineMark(
                    x: .value("t", sample.time),
                    y: .value("cum", sample.cumulative)
                )
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            DesignSystem.Colors.amber,
                            accent,
                            DesignSystem.Colors.ember
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .shadow(color: accent.opacity(0.35), radius: 6, x: 0, y: 4)
            }

            if let last = samples.last, last.cumulative > 0 {
                PointMark(
                    x: .value("t", last.time),
                    y: .value("cum", last.cumulative)
                )
                .symbol { NowDot(color: accent, phase: pulsePhase, reduceMotion: reduceMotion) }
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...yMax)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartPlotStyle { plot in
            plot.background(
                LinearGradient(
                    colors: [accent.opacity(0.02), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }

    // MARK: - Empty Overlay

    private var emptyOverlay: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Path { path in
                    let y = geo.size.height * 0.78
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geo.size.width, y: y))
                }
                .stroke(
                    LinearGradient(
                        colors: [
                            accent.opacity(0.25),
                            DesignSystem.Colors.amber.opacity(0.50),
                            accent.opacity(0.25)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: 1.5, dash: [4, 6])
                )

                LinearGradient(
                    colors: [Color.clear, accent.opacity(0.35), Color.clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: geo.size.width * 0.30)
                .frame(height: 24)
                .offset(x: (geo.size.width + 60) * sweepPhase - 30, y: geo.size.height * 0.78 - 12)
                .blur(radius: 8)
                .blendMode(.plusLighter)
                .opacity(reduceMotion ? 0 : 1)
            }
            .overlay(alignment: .center) {
                HStack(spacing: 6) {
                    Image(systemName: "waveform.path")
                        .font(.system(size: 11, weight: .semibold))
                    Text(emptyMessage)
                        .font(DesignSystem.Typography.tiny)
                        .fontWeight(.semibold)
                        .tracking(0.6)
                }
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(DesignSystem.Colors.surface.opacity(0.65)))
                .overlay(Capsule().stroke(accent.opacity(0.35), lineWidth: 0.5))
            }
        }
        .allowsHitTesting(false)
    }

    private var emptyMessage: String {
        switch granularity {
        case .minute: return "AWAITING THIS MINUTE'S BURN"
        case .hour:   return "AWAITING THIS HOUR'S BURN"
        case .day:    return "AWAITING TODAY'S FIRST BURN"
        }
    }

    // MARK: - Time-axis Labels

    private var timeAxisLabels: some View {
        let labels = axisLabels()
        return HStack(spacing: 0) {
            ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                Text(label)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textMuted.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .allowsHitTesting(false)
    }

    private func axisLabels() -> [String] {
        let formatter = DateFormatter()
        switch granularity {
        case .minute: formatter.dateFormat = "mm:ss"
        case .hour:   formatter.dateFormat = "h:mm a"
        case .day:    formatter.dateFormat = "ha"
        }
        let count = 6
        let interval = domain.upperBound.timeIntervalSince(domain.lowerBound) / Double(count - 1)
        return (0..<count).map { idx in
            let date = domain.lowerBound.addingTimeInterval(Double(idx) * interval)
            return formatter.string(from: date).lowercased()
        }
    }

    // MARK: - Samples

    fileprivate struct Sample: Identifiable {
        let id: Int
        let time: Date
        let cumulative: Double
    }

    private func buildSamples() -> [Sample] {
        let lower = domain.lowerBound
        let now = Date()
        let upper = min(now, domain.upperBound)
        guard upper > lower else { return [] }

        let bucketCount: Int
        switch granularity {
        case .minute: bucketCount = 24    // ~2.5s
        case .hour:   bucketCount = 30    // 2 min
        case .day:    bucketCount = 24    // hourly
        }
        let stride = upper.timeIntervalSince(lower) / Double(bucketCount)
        guard stride > 0 else { return [] }

        let relevant = usages
            .filter { domain.contains($0.startTime) && $0.startTime <= upper }
            .sorted { $0.startTime < $1.startTime }

        var samples: [Sample] = []
        samples.reserveCapacity(bucketCount + 1)
        samples.append(Sample(id: 0, time: lower, cumulative: 0))
        var cumulative: Double = 0
        var cursor = 0
        for i in 1...bucketCount {
            let edge = lower.addingTimeInterval(Double(i) * stride)
            while cursor < relevant.count, relevant[cursor].startTime <= edge {
                cumulative += value(for: relevant[cursor])
                cursor += 1
            }
            samples.append(Sample(id: i, time: edge, cumulative: cumulative))
        }
        return samples
    }

    private func value(for usage: TokenUsage) -> Double {
        switch unit {
        case .cost:   return max(0, usage.cost)
        case .tokens: return Double(max(0, usage.totalTokens))
        }
    }

    // MARK: - Motion

    private func startAnimating() {
        guard !reduceMotion else { pulsePhase = 0; sweepPhase = 0; return }
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
            pulsePhase = 1
        }
        withAnimation(.linear(duration: 4.2).repeatForever(autoreverses: false)) {
            sweepPhase = 1
        }
    }

    // MARK: - Accessibility

    private func accessibilitySummary(samples: [Sample]) -> String {
        let total = samples.last?.cumulative ?? 0
        let formatted: String
        switch unit {
        case .cost:   formatted = total.formatAsCost()
        case .tokens: formatted = Int(total).formatAsTokenVolume()
        }
        return "Live cumulative \(unit == .cost ? "cost" : "tokens"): \(formatted)"
    }
}

// MARK: - Now Dot (macOS)

private struct NowDot: View {
    let color: Color
    let phase: CGFloat
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.18))
                .frame(width: 28, height: 28)
                .scaleEffect(reduceMotion ? 1.0 : (1.0 + 0.25 * phase))
                .opacity(reduceMotion ? 0.55 : (1.0 - 0.5 * phase))
                .blur(radius: 6)
            Circle()
                .fill(color.opacity(0.30))
                .frame(width: 14, height: 14)
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.7), radius: 4)
        }
    }
}

// MARK: - Live Dot (header chip)

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
