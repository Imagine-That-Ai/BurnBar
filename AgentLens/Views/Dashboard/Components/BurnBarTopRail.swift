import SwiftUI

// MARK: - BurnBarTopRail
//
// Redesigned dashboard top bar. Replaces the busy "Agents pill + filters +
// floating metric + three icons" arrangement with a single telemetry rail:
//
//   [ flame wordmark | view-mode underscore ]   [ range · unit ]   [ BURN hero | actions ]
//
// The burn metric is promoted from an afterthought badge to the bar's
// centerpiece — tabular monospace numerals, live pulse, 24h sparkline, delta.
// Everything else recedes so the data sings.
//
// Drop-in: build with sample data via the #Preview below, then bind the
// `BurnBarTopRail.Model` fields to your DashboardView state.

struct BurnBarTopRail: View {

    // MARK: Public API

    enum ViewMode: String, CaseIterable, Identifiable {
        case agents, models
        var id: String { rawValue }
        var label: String { rawValue.uppercased() }
    }

    enum Unit: String, CaseIterable, Identifiable {
        case tokens, cost, percent
        var id: String { rawValue }
        var glyph: String {
            switch self {
            case .tokens:  return "number"
            case .cost:    return "dollarsign"
            case .percent: return "percent"
            }
        }
        var label: String {
            switch self {
            case .tokens:  return "Tokens"
            case .cost:    return "Cost"
            case .percent: return "% of plan"
            }
        }
    }

    struct Model {
        var viewMode: ViewMode
        var range: String           // e.g. "Today", "Last 7d"
        var unit: Unit
        var headlineValue: String   // e.g. "1.79B" or "$284.12"
        var headlineSuffix: String? // e.g. "tok" or nil
        var deltaPercent: Double?   // signed; nil = no delta
        var sparkline: [Double]     // 24 normalized samples (0...1)
        var isLive: Bool
        var isScanning: Bool
    }

    // MARK: State bindings

    @Binding var viewMode: ViewMode
    @Binding var range: String
    @Binding var unit: Unit
    let model: Model
    let canGoBack: Bool

    var onBack: () -> Void = {}
    var onRangeTap: () -> Void = {}
    var onImport: () -> Void = {}
    var onRecount: () -> Void = {}
    var onSettings: () -> Void = {}

    // MARK: Body

    var body: some View {
        HStack(spacing: 14) {
            identityCluster
            Spacer(minLength: 12)
            filtersCluster
            Spacer(minLength: 12)
            telemetryCluster
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 56)
        .background(railBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DesignSystem.Colors.borderSubtle.opacity(0.6))
                .frame(height: 0.5)
        }
    }

    // MARK: Backgrounds

    private var railBackground: some View {
        ZStack {
            // Material first so vibrancy carries through.
            Rectangle().fill(.ultraThinMaterial)
            // Faint ember wash on the right side — anchors the hero zone.
            LinearGradient(
                colors: [
                    .clear,
                    DesignSystem.Colors.ember.opacity(0.025),
                    DesignSystem.Colors.blaze.opacity(0.035)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            // Hairline noise to kill banding in dark mode.
            Rectangle()
                .fill(Color.white.opacity(0.0125))
                .blendMode(.overlay)
        }
    }

    // MARK: - Zone 1 — Identity

    private var identityCluster: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(
                        canGoBack
                            ? DesignSystem.Colors.textSecondary
                            : DesignSystem.Colors.textMuted.opacity(0.4)
                    )
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canGoBack)
            .help(canGoBack ? "Back" : "")

            wordmark
            railDivider
            viewModeSegmented
        }
    }

    private var wordmark: some View {
        HStack(spacing: 7) {
            // Flame mark — minimal, single-color, no AI-slop gradient.
            Image(systemName: "flame.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.primaryGradient)

            Text("BURNBAR")
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .tracking(1.4)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
        }
    }

    private var viewModeSegmented: some View {
        HStack(spacing: 18) {
            ForEach(ViewMode.allCases) { mode in
                segmentedItem(mode)
            }
        }
    }

    private func segmentedItem(_ mode: ViewMode) -> some View {
        let active = viewMode == mode
        return Button {
            withAnimation(DesignSystem.Animation.standard) {
                viewMode = mode
            }
        } label: {
            VStack(spacing: 4) {
                Text(mode.label)
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .tracking(1.1)
                    .foregroundStyle(
                        active
                            ? DesignSystem.Colors.textPrimary
                            : DesignSystem.Colors.textSecondary.opacity(0.85)
                    )

                // Flame-gradient underscore for the active segment.
                // 2pt thick, full text width, animated in.
                Capsule()
                    .fill(active
                          ? AnyShapeStyle(DesignSystem.Colors.primaryGradient)
                          : AnyShapeStyle(Color.clear))
                    .frame(height: 2)
                    .opacity(active ? 1 : 0)
                    .animation(DesignSystem.Animation.snappy, value: active)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(active ? "" : "Switch to \(mode.label.capitalized)")
    }

    private var railDivider: some View {
        Rectangle()
            .fill(DesignSystem.Colors.border.opacity(0.5))
            .frame(width: 1, height: 16)
    }

    // MARK: - Zone 2 — Filters

    private var filtersCluster: some View {
        HStack(spacing: 8) {
            FilterChip(
                symbol: "calendar",
                label: model.range,
                trailing: "chevron.down",
                action: onRangeTap
            )

            UnitToggle(unit: $unit)
        }
    }

    // MARK: - Zone 3 — Telemetry (hero)

    private var telemetryCluster: some View {
        HStack(spacing: 12) {
            telemetryHero
            actionCapsule
        }
    }

    private var telemetryHero: some View {
        HStack(spacing: 12) {
            LivePulseDot(isLive: model.isLive)

            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text("BURN")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(1.3)
                        .foregroundStyle(DesignSystem.Colors.textMuted)

                    if let delta = model.deltaPercent {
                        DeltaChip(percent: delta)
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(model.headlineValue)
                        .font(.system(size: 17, weight: .bold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .contentTransition(.numericText())
                        .animation(DesignSystem.Animation.gentle, value: model.headlineValue)

                    if let suffix = model.headlineSuffix {
                        Text(suffix)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .baselineOffset(1)
                    }
                }
            }

            Sparkline(samples: model.sparkline)
                .frame(width: 64, height: 22)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(DesignSystem.Colors.border.opacity(0.45), lineWidth: 0.5)
        )
    }

    private var actionCapsule: some View {
        HStack(spacing: 0) {
            GhostIconButton(
                symbol: model.isScanning ? "arrow.triangle.2.circlepath" : "tray.and.arrow.down",
                help: "Import sessions from logs",
                spinning: model.isScanning,
                action: onImport
            )
            CapsuleDivider()
            GhostIconButton(
                symbol: "arrow.counterclockwise",
                help: "Recount totals",
                action: onRecount
            )
            CapsuleDivider()
            GhostIconButton(
                symbol: "gearshape",
                help: "Settings",
                action: onSettings
            )
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(DesignSystem.Colors.border.opacity(0.4), lineWidth: 0.5)
        )
    }
}

// MARK: - Filter chip (range)

private struct FilterChip: View {
    let symbol: String
    let label: String
    let trailing: String?
    let action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                if let trailing {
                    Image(systemName: trailing)
                        .font(.system(size: 8, weight: .bold))
                        .opacity(0.7)
                }
            }
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                    .fill(hover
                          ? DesignSystem.Colors.ember.opacity(0.08)
                          : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                    .stroke(DesignSystem.Colors.border.opacity(0.55), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(DesignSystem.Animation.hover, value: hover)
    }
}

// MARK: - Unit toggle (Tokens / Cost / %)

private struct UnitToggle: View {
    @Binding var unit: BurnBarTopRail.Unit

    var body: some View {
        HStack(spacing: 0) {
            ForEach(BurnBarTopRail.Unit.allCases) { u in
                segment(u)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .stroke(DesignSystem.Colors.border.opacity(0.5), lineWidth: 0.5)
        )
    }

    private func segment(_ u: BurnBarTopRail.Unit) -> some View {
        let active = unit == u
        return Button {
            withAnimation(DesignSystem.Animation.snappy) { unit = u }
        } label: {
            Image(systemName: u.glyph)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(
                    active
                        ? DesignSystem.Colors.textPrimary
                        : DesignSystem.Colors.textMuted
                )
                .frame(width: 24, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(active
                              ? AnyShapeStyle(DesignSystem.Colors.primaryGradient.opacity(0.18))
                              : AnyShapeStyle(Color.clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(active
                                ? DesignSystem.Colors.ember.opacity(0.35)
                                : Color.clear, lineWidth: 0.5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(u.label)
    }
}

// MARK: - Live pulse dot

private struct LivePulseDot: View {
    let isLive: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            // Outer halo
            Circle()
                .fill(DesignSystem.Colors.ember.opacity(0.35))
                .frame(width: 18, height: 18)
                .scaleEffect(pulse ? 1.0 : 0.5)
                .opacity(pulse ? 0 : 0.7)
            // Inner core
            Circle()
                .fill(isLive ? DesignSystem.Colors.ember : DesignSystem.Colors.textMuted)
                .frame(width: 7, height: 7)
                .shadow(color: DesignSystem.Colors.ember.opacity(isLive ? 0.65 : 0),
                        radius: 4, y: 0)
        }
        .frame(width: 18, height: 18)
        .onAppear {
            guard isLive else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }
}

// MARK: - Delta chip

private struct DeltaChip: View {
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

// MARK: - Sparkline

private struct Sparkline: View {
    let samples: [Double] // 0...1 normalized

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Filled area under the line
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
                // The line itself
                sparkPath(in: geo.size, closed: false)
                    .stroke(
                        DesignSystem.Colors.primaryGradient,
                        style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round)
                    )
                // Last-point dot
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
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
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

// MARK: - Ghost icon button (used inside the action capsule)

private struct GhostIconButton: View {
    let symbol: String
    let help: String
    var spinning: Bool = false
    let action: () -> Void

    @State private var hover = false
    @State private var spin = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(
                    hover
                        ? DesignSystem.Colors.textPrimary
                        : DesignSystem.Colors.textSecondary
                )
                .rotationEffect(.degrees(spinning && spin ? 360 : 0))
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(hover ? DesignSystem.Colors.ember.opacity(0.10) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hover = $0 }
        .animation(DesignSystem.Animation.hover, value: hover)
        .onChange(of: spinning) { _, newValue in
            if newValue {
                withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                    spin = true
                }
            } else {
                spin = false
            }
        }
    }
}

private struct CapsuleDivider: View {
    var body: some View {
        Rectangle()
            .fill(DesignSystem.Colors.border.opacity(0.35))
            .frame(width: 0.5, height: 14)
    }
}

// MARK: - Preview

#if DEBUG
private struct BurnBarTopRailPreviewHost: View {
    @State private var viewMode: BurnBarTopRail.ViewMode = .agents
    @State private var range: String = "Today"
    @State private var unit: BurnBarTopRail.Unit = .tokens
    @State private var scanning: Bool = false
    @State private var headline: String = "1.79"

    private var sparkSamples: [Double] {
        [0.12, 0.18, 0.14, 0.22, 0.31, 0.28, 0.41, 0.38,
         0.52, 0.49, 0.61, 0.58, 0.72, 0.66, 0.78, 0.74,
         0.81, 0.79, 0.86, 0.83, 0.91, 0.88, 0.95, 0.97]
    }

    var body: some View {
        VStack(spacing: 0) {
            BurnBarTopRail(
                viewMode: $viewMode,
                range: $range,
                unit: $unit,
                model: .init(
                    viewMode: viewMode,
                    range: range,
                    unit: unit,
                    headlineValue: "\(headline)B",
                    headlineSuffix: "tok",
                    deltaPercent: 4.2,
                    sparkline: sparkSamples,
                    isLive: true,
                    isScanning: scanning
                ),
                canGoBack: true,
                onBack: {},
                onRangeTap: {
                    range = (range == "Today") ? "Last 7d" : "Today"
                },
                onImport: {
                    scanning.toggle()
                },
                onRecount: {
                    headline = (headline == "1.79") ? "1.83" : "1.79"
                },
                onSettings: {}
            )

            // Fake content underneath so the bar's material reads correctly.
            ZStack {
                DesignSystem.Colors.background.ignoresSafeArea()
                Text("Dashboard content").foregroundStyle(.secondary)
            }
            .frame(height: 240)
        }
        .frame(width: 980)
    }
}

#Preview("BurnBar Top Rail — Dark") {
    BurnBarTopRailPreviewHost()
        .preferredColorScheme(.dark)
}

#Preview("BurnBar Top Rail — Light") {
    BurnBarTopRailPreviewHost()
        .preferredColorScheme(.light)
}
#endif
