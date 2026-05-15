import AppKit
import SwiftUI
import OpenBurnBarCore

// MARK: - Dashboard Live Cost Curve (macOS)
//
// Cumulative cost / token curve that sits under the Dashboard hero stat row.
// Mirrors the iOS / Android `PulseLiveCostCurve` aesthetic — ember→amber→
// transparent area, brand-gradient stroke, pulsing "now" marker — adapted
// for the wider, denser macOS Dashboard plate.
//
// Implementation note: this component draws via SwiftUI `Canvas` rather than
// `Charts` so it has zero dependency on layout intrinsics, renders at a
// guaranteed minimum height, and avoids any silent fall-through to a
// zero-sized chart when the parent stack is doing its own sizing.

struct DashboardLiveCostCurve: View {

    enum Unit { case cost, tokens }
    enum Granularity { case minute, hour, day }

    let usages: [TokenUsage]
    let unit: Unit
    let granularity: Granularity
    let domain: ClosedRange<Date>
    var accent: Color = DesignSystem.Colors.ember
    var height: CGFloat = 140

    @State private var pulsePhase: CGFloat = 0
    @State private var sweepPhase: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let samples = buildSamples()
        let peak = samples.map(\.cumulative).max() ?? 0
        let isEmpty = peak <= 0.0001

        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            header(peak: peak, isEmpty: isEmpty)

            ZStack(alignment: .topLeading) {
                CurveCanvas(
                    samples: samples,
                    peak: peak,
                    domain: domain,
                    accent: accent,
                    colorScheme: colorScheme,
                    pulsePhase: pulsePhase
                )

                if isEmpty {
                    EmptyOverlay(
                        accent: accent,
                        sweepPhase: sweepPhase,
                        reduceMotion: reduceMotion,
                        message: emptyMessage
                    )
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)

            timeAxisLabels
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.surface.opacity(colorScheme == .dark ? 0.45 : 0.55))
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                accent.opacity(colorScheme == .dark ? 0.16 : 0.08),
                                Color.clear,
                                DesignSystem.Colors.amber.opacity(colorScheme == .dark ? 0.08 : 0.04)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            accent.opacity(0.45),
                            DesignSystem.Colors.amber.opacity(0.25),
                            DesignSystem.Colors.blaze.opacity(0.20)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.75
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
        .shadow(color: accent.opacity(colorScheme == .dark ? 0.20 : 0.10), radius: 18, y: 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary(peak: peak))
        .onAppear { startAnimating() }
        .onChange(of: reduceMotion) { _, _ in startAnimating() }
    }

    // MARK: - Header

    @ViewBuilder
    private func header(peak: Double, isEmpty: Bool) -> some View {
        HStack(spacing: 10) {
            Text(headerLabel)
                .font(DesignSystem.Typography.tiny)
                .tracking(2)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .textCase(.uppercase)

            if isLive {
                LiveDotMac(color: DesignSystem.Colors.success)
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

    private var isLive: Bool { granularity == .minute || granularity == .hour || granularity == .day }

    private func peakLabel(peak: Double) -> String {
        switch unit {
        case .cost:   return peak.formatAsCost()
        case .tokens: return Int(peak).formatAsTokenVolume()
        }
    }

    // MARK: - Time-axis labels

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

    private var emptyMessage: String {
        switch granularity {
        case .minute: return "AWAITING THIS MINUTE'S BURN"
        case .hour:   return "AWAITING THIS HOUR'S BURN"
        case .day:    return "AWAITING TODAY'S FIRST BURN"
        }
    }

    // MARK: - Samples

    fileprivate struct Sample: Equatable {
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
        case .minute: bucketCount = 24
        case .hour:   bucketCount = 30
        case .day:    bucketCount = 24
        }
        let strideSec = upper.timeIntervalSince(lower) / Double(bucketCount)
        guard strideSec > 0 else { return [] }

        let relevant = usages
            .filter { $0.startTime >= lower && $0.startTime <= upper }
            .sorted { $0.startTime < $1.startTime }

        var samples: [Sample] = []
        samples.reserveCapacity(bucketCount + 1)
        samples.append(Sample(time: lower, cumulative: 0))
        var cumulative: Double = 0
        var cursor = 0
        for i in 1...bucketCount {
            let edge = lower.addingTimeInterval(Double(i) * strideSec)
            while cursor < relevant.count, relevant[cursor].startTime <= edge {
                cumulative += value(for: relevant[cursor])
                cursor += 1
            }
            samples.append(Sample(time: edge, cumulative: cumulative))
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

    private func accessibilitySummary(peak: Double) -> String {
        let formatted: String
        switch unit {
        case .cost:   formatted = peak.formatAsCost()
        case .tokens: formatted = Int(peak).formatAsTokenVolume()
        }
        return "Live cumulative \(unit == .cost ? "cost" : "tokens"): \(formatted)"
    }
}

// MARK: - Canvas curve

private struct CurveCanvas: View {
    let samples: [DashboardLiveCostCurve.Sample]
    let peak: Double
    let domain: ClosedRange<Date>
    let accent: Color
    let colorScheme: ColorScheme
    let pulsePhase: CGFloat

    var body: some View {
        Canvas { ctx, size in
            guard samples.count >= 2 else { return }
            let yMax = max(peak * 1.08, 0.0001)
            let total = max(domain.upperBound.timeIntervalSince(domain.lowerBound), 1)

            func xFor(_ t: Date) -> CGFloat {
                let f = t.timeIntervalSince(domain.lowerBound) / total
                return CGFloat(f) * size.width
            }
            func yFor(_ v: Double) -> CGFloat {
                let f = v / yMax
                return size.height - CGFloat(f) * size.height
            }

            // Baseline rule
            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: size.height - 0.5))
            baseline.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
            ctx.stroke(baseline, with: .color(DesignSystem.Colors.textMuted.opacity(0.10)), lineWidth: 0.5)

            // Build smoothed monotone path
            let points = samples.map { CGPoint(x: xFor($0.time), y: yFor($0.cumulative)) }
            let linePath = monotonePath(points)

            // Area fill underneath
            var area = Path()
            area.addPath(linePath)
            area.addLine(to: CGPoint(x: points.last!.x, y: size.height))
            area.addLine(to: CGPoint(x: points.first!.x, y: size.height))
            area.closeSubpath()

            ctx.fill(
                area,
                with: .linearGradient(
                    Gradient(colors: [
                        accent.opacity(colorScheme == .dark ? 0.55 : 0.42),
                        DesignSystem.Colors.amber.opacity(colorScheme == .dark ? 0.30 : 0.22),
                        DesignSystem.Colors.blaze.opacity(0.0)
                    ]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )

            // Soft glow stroke under the crisp stroke
            ctx.stroke(
                linePath,
                with: .color(accent.opacity(0.45)),
                style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)
            )

            // Brand gradient stroke on top
            ctx.stroke(
                linePath,
                with: .linearGradient(
                    Gradient(colors: [
                        DesignSystem.Colors.amber,
                        accent,
                        DesignSystem.Colors.ember
                    ]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: size.width, y: 0)
                ),
                style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
            )

            // "Now" marker — pulsing halo + solid dot
            if peak > 0, let last = points.last {
                let haloR = 14 + 6 * pulsePhase
                let halo = CGRect(x: last.x - haloR, y: last.y - haloR, width: haloR * 2, height: haloR * 2)
                ctx.fill(
                    Circle().path(in: halo),
                    with: .color(accent.opacity(Double(0.20 * (1 - 0.5 * pulsePhase))))
                )
                let inner = CGRect(x: last.x - 7, y: last.y - 7, width: 14, height: 14)
                ctx.fill(Circle().path(in: inner), with: .color(accent.opacity(0.30)))
                let dot = CGRect(x: last.x - 4, y: last.y - 4, width: 8, height: 8)
                ctx.fill(Circle().path(in: dot), with: .color(accent))
            }
        }
    }

    private func monotonePath(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard !points.isEmpty else { return path }
        path.move(to: points[0])
        if points.count == 1 { return path }
        if points.count == 2 { path.addLine(to: points[1]); return path }
        let n = points.count
        var tangents = [CGFloat](repeating: 0, count: n)
        for i in 0..<(n - 1) {
            let dx = points[i + 1].x - points[i].x
            let dy = points[i + 1].y - points[i].y
            tangents[i] = dx != 0 ? dy / dx : 0
        }
        tangents[n - 1] = tangents[n - 2]
        for i in 0..<(n - 1) {
            let p0 = points[i]
            let p1 = points[i + 1]
            let dx = (p1.x - p0.x) / 3
            let c1 = CGPoint(x: p0.x + dx, y: p0.y + dx * tangents[i])
            let c2 = CGPoint(x: p1.x - dx, y: p1.y - dx * tangents[i + 1])
            path.addCurve(to: p1, control1: c1, control2: c2)
        }
        return path
    }
}

// MARK: - Empty Overlay

private struct EmptyOverlay: View {
    let accent: Color
    let sweepPhase: CGFloat
    let reduceMotion: Bool
    let message: String

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Path { p in
                    let y = geo.size.height * 0.78
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: geo.size.width, y: y))
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

                if !reduceMotion {
                    LinearGradient(
                        colors: [Color.clear, accent.opacity(0.35), Color.clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.30)
                    .frame(height: 24)
                    .offset(
                        x: (geo.size.width + 60) * sweepPhase - 30,
                        y: geo.size.height * 0.78 - 12
                    )
                    .blur(radius: 8)
                    .blendMode(.plusLighter)
                }

                HStack(spacing: 6) {
                    Image(systemName: "waveform.path")
                        .font(.system(size: 11, weight: .semibold))
                    Text(message)
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
}

// MARK: - Live Dot

private struct LiveDotMac: View {
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
