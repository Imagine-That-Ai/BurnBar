import Charts
import SwiftUI
import OpenBurnBarCore

// MARK: - Pulse Live Cost Curve
//
// Cinematic cumulative cost curve that lives directly under the Pulse hero
// metric. Renders a proper Swift Chart with:
//   * Bucketed cumulative cost (or tokens) across the selected timeline
//   * Ember → amber → transparent area fill with brand-tinted stroke
//   * Pulsing "now" marker at the trailing edge
//   * Soft baseline rail + minimal time-of-day tick labels
//   * Empty state — flat dashed rail with a one-liner
//
// Accuracy: when the scope is minute / hour / day we bucket `TokenUsage`
// records by their `startTime`; for week / month we use `RollupDailyPoint`
// (already a per-day cost from the cloud rollup).

struct PulseLiveCostCurve: View {

    let usages: [TokenUsage]
    let dailyPoints: [RollupDailyPoint]
    let scope: PulseTimelineScope
    let displayMode: UsageDisplayMode
    let now: Date
    var accent: Color
    var height: CGFloat = 112

    @State private var pulsePhase: CGFloat = 0
    @State private var sweepPhase: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    // MARK: - Sample Model

    fileprivate struct Sample: Identifiable, Equatable {
        let id: Int
        let time: Date
        let cumulative: Double
        let increment: Double
    }

    var body: some View {
        let domain = currentDomain
        let samples = buildSamples(domain: domain)
        let peak = samples.map(\.cumulative).max() ?? 0
        let isEmpty = peak <= 0.0001

        ZStack(alignment: .bottomLeading) {
            chart(samples: samples, domain: domain, peak: peak)
                .opacity(isEmpty ? 0.15 : 1.0)

            if isEmpty {
                emptyOverlay(domain: domain)
            }

            timeAxisLabels(domain: domain)
                .padding(.top, height - 14)
        }
        .frame(height: height)
        .padding(.top, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary(samples: samples))
        .onAppear { startAnimating() }
        .onChange(of: reduceMotion) { _, _ in startAnimating() }
    }

    // MARK: - Chart

    @ViewBuilder
    private func chart(samples: [Sample], domain: ClosedRange<Date>, peak: Double) -> some View {
        let yMax = max(peak * 1.08, 0.0001)
        Chart {
            // Baseline gridline at 0
            RuleMark(y: .value("zero", 0))
                .foregroundStyle(MobileTheme.Colors.textMuted.opacity(0.10))
                .lineStyle(StrokeStyle(lineWidth: 0.5))

            // Area fill under the curve
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
                            MobileTheme.amber.opacity(colorScheme == .dark ? 0.30 : 0.22),
                            MobileTheme.blaze.opacity(0.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }

            // Top stroke line — brand gradient
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
                            MobileTheme.amber,
                            accent,
                            MobileTheme.ember
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .shadow(color: accent.opacity(0.35), radius: 6, x: 0, y: 4)
            }

            // "Now" marker at the trailing edge (only when there's data)
            if let last = samples.last, last.cumulative > 0 {
                PointMark(
                    x: .value("t", last.time),
                    y: .value("cum", last.cumulative)
                )
                .symbol {
                    NowDot(color: accent, phase: pulsePhase, reduceMotion: reduceMotion)
                }
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...yMax)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartPlotStyle { plot in
            plot.background(
                LinearGradient(
                    colors: [
                        accent.opacity(0.02),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }

    // MARK: - Empty Overlay

    @ViewBuilder
    private func emptyOverlay(domain: ClosedRange<Date>) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Sweeping shimmer baseline
                Path { path in
                    let y = geo.size.height * 0.78
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geo.size.width, y: y))
                }
                .stroke(
                    LinearGradient(
                        colors: [
                            accent.opacity(0.25),
                            MobileTheme.amber.opacity(0.50),
                            accent.opacity(0.25)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: 1.5, dash: [4, 6])
                )

                // Sweeping highlight blob
                LinearGradient(
                    colors: [
                        Color.clear,
                        accent.opacity(0.35),
                        Color.clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: geo.size.width * 0.30)
                .frame(height: 22)
                .offset(x: (geo.size.width + 60) * sweepPhase - 30,
                        y: geo.size.height * 0.78 - 11)
                .blur(radius: 8)
                .blendMode(.plusLighter)
                .opacity(reduceMotion ? 0.0 : 1.0)
            }
            .overlay(alignment: .center) {
                HStack(spacing: 6) {
                    Image(systemName: "waveform.path")
                        .font(.system(size: 11, weight: .semibold))
                    Text(emptyMessage)
                        .font(MobileTheme.Typography.tiny)
                        .fontWeight(.semibold)
                        .tracking(0.6)
                }
                .foregroundStyle(MobileTheme.Colors.textMuted)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(MobileTheme.Colors.surface.opacity(0.65))
                )
                .overlay(
                    Capsule().stroke(accent.opacity(0.35), lineWidth: 0.5)
                )
            }
        }
        .allowsHitTesting(false)
    }

    private var emptyMessage: String {
        switch scope {
        case .minute: return "AWAITING THIS MINUTE'S BURN"
        case .hour:   return "AWAITING THIS HOUR'S BURN"
        case .day:    return "NO BURN IN LAST 24H"
        case .week:   return "NO DATA THIS WEEK YET"
        case .month:  return "NO DATA THIS MONTH YET"
        }
    }

    // MARK: - Time Axis Labels

    @ViewBuilder
    private func timeAxisLabels(domain: ClosedRange<Date>) -> some View {
        let labels = axisTickLabels(domain: domain)
        HStack(spacing: 0) {
            ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                Text(label)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(MobileTheme.Colors.textMuted.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .allowsHitTesting(false)
    }

    private func axisTickLabels(domain: ClosedRange<Date>) -> [String] {
        let formatter = DateFormatter()
        switch scope {
        case .minute:
            formatter.dateFormat = "mm:ss"
        case .hour:
            formatter.dateFormat = "h:mm a"
        case .day:
            formatter.dateFormat = "ha"
        case .week, .month:
            formatter.dateFormat = "M/d"
        }
        let count = 4
        let interval = domain.upperBound.timeIntervalSince(domain.lowerBound) / Double(count - 1)
        return (0..<count).map { idx -> String in
            let date = domain.lowerBound.addingTimeInterval(Double(idx) * interval)
            return formatter.string(from: date).lowercased()
        }
    }

    // MARK: - Domain + Samples

    private var currentDomain: ClosedRange<Date> {
        switch scope {
        case .minute:
            return now.addingTimeInterval(-60)...now
        case .hour:
            return now.addingTimeInterval(-3_600)...now
        case .day:
            return now.addingTimeInterval(-86_400)...now
        case .week:
            let weekAgo = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: now)) ?? now
            return weekAgo...now
        case .month:
            let monthAgo = Calendar.current.date(byAdding: .day, value: -29, to: Calendar.current.startOfDay(for: now)) ?? now
            return monthAgo...now
        }
    }

    fileprivate func buildSamples(domain: ClosedRange<Date>) -> [Sample] {
        switch scope {
        case .minute, .hour, .day:
            return buildLiveSamples(domain: domain)
        case .week, .month:
            return buildAggregateSamples(domain: domain)
        }
    }

    private func buildLiveSamples(domain: ClosedRange<Date>) -> [Sample] {
        // Build N+1 bucket boundaries across the live domain (clamped to `now`
        // on the right edge so the curve stops at the present moment rather
        // than racing ahead to a future end-of-day).
        let bucketCount: Int
        let upper: Date
        switch scope {
        case .minute:
            bucketCount = 24       // 2.5s per bucket
            upper = now
        case .hour:
            bucketCount = 30       // 2 min per bucket
            upper = now
        case .day:
            bucketCount = 24       // hourly
            upper = now
        default:
            bucketCount = 24
            upper = now
        }
        let lower = domain.lowerBound
        guard upper > lower else { return [] }
        let stride = upper.timeIntervalSince(lower) / Double(bucketCount)
        guard stride > 0 else { return [] }

        // Filter + sort relevant usages once.
        let relevant = usages
            .filter { domain.contains(eventDate(for: $0)) }
            .sorted { eventDate(for: $0) < eventDate(for: $1) }

        var samples: [Sample] = []
        samples.reserveCapacity(bucketCount + 1)
        var cumulative: Double = 0
        var cursorIdx = 0
        var lastCumulative: Double = 0

        // Anchor a starting sample at the domain lower bound for a clean curve.
        samples.append(Sample(id: 0, time: lower, cumulative: 0, increment: 0))

        for bucketIdx in 1...bucketCount {
            let bucketEnd = lower.addingTimeInterval(Double(bucketIdx) * stride)
            while cursorIdx < relevant.count, eventDate(for: relevant[cursorIdx]) <= bucketEnd {
                cumulative += metricValue(for: relevant[cursorIdx])
                cursorIdx += 1
            }
            let increment = cumulative - lastCumulative
            lastCumulative = cumulative
            samples.append(Sample(id: bucketIdx, time: bucketEnd, cumulative: cumulative, increment: increment))
        }
        return samples
    }

    private func buildAggregateSamples(domain: ClosedRange<Date>) -> [Sample] {
        let cal = Calendar.current
        let filtered = dailyPoints
            .filter { cal.startOfDay(for: $0.date) >= cal.startOfDay(for: domain.lowerBound) }
            .sorted { $0.date < $1.date }
        var cumulative: Double = 0
        var out: [Sample] = []
        out.append(Sample(id: 0, time: domain.lowerBound, cumulative: 0, increment: 0))
        for (idx, point) in filtered.enumerated() {
            let increment = point.value
            cumulative += increment
            out.append(Sample(id: idx + 1, time: point.date, cumulative: cumulative, increment: increment))
        }
        return out
    }

    private func metricValue(for usage: TokenUsage) -> Double {
        switch displayMode {
        case .currency: return max(0, usage.costUSD)
        case .tokens:   return Double(max(0, usage.totalTokens))
        }
    }

    private func eventDate(for usage: TokenUsage) -> Date {
        max(usage.startTime, usage.endTime)
    }

    // MARK: - Animation

    private func startAnimating() {
        guard !reduceMotion else {
            pulsePhase = 0
            sweepPhase = 0
            return
        }
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
            pulsePhase = 1
        }
        withAnimation(.linear(duration: 4.2).repeatForever(autoreverses: false)) {
            sweepPhase = 1
        }
    }

    // MARK: - Accessibility

    private func accessibilitySummary(samples: [Sample]) -> String {
        let value = samples.last?.cumulative ?? 0
        let formatted: String
        switch displayMode {
        case .currency: formatted = value.formatAsCost()
        case .tokens:   formatted = Int(value).formatAsTokenVolume()
        }
        let unit = scope.headerLabel.lowercased()
        return "\(unit) cumulative \(displayMode == .currency ? "cost" : "tokens"): \(formatted)"
    }
}

// MARK: - Now Dot

private struct NowDot: View {
    let color: Color
    let phase: CGFloat
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.18))
                .frame(width: 26, height: 26)
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

// MARK: - Burn Rate Helper (used by hero card velocity pill)

enum PulseBurnRate {
    /// Recent dollar-per-minute rate computed from the last 5 minutes of
    /// `usages`. Returns `nil` if there's no recent activity to estimate from.
    static func dollarsPerMinute(usages: [TokenUsage], now: Date = Date()) -> Double? {
        let windowStart = now.addingTimeInterval(-5 * 60)
        let cost = usages
            .filter { $0.startTime >= windowStart && $0.startTime <= now }
            .reduce(0.0) { $0 + max(0, $1.costUSD) }
        guard cost > 0 else { return nil }
        return cost / 5.0
    }

    static func tokensPerMinute(usages: [TokenUsage], now: Date = Date()) -> Int? {
        let windowStart = now.addingTimeInterval(-5 * 60)
        let tokens = usages
            .filter { $0.startTime >= windowStart && $0.startTime <= now }
            .reduce(0) { $0 + max(0, $1.totalTokens) }
        guard tokens > 0 else { return nil }
        return tokens / 5
    }
}
