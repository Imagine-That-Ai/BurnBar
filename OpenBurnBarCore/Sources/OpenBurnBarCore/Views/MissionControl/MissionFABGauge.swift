import SwiftUI

// MARK: - Mission FAB Gauge
//
// The "living gauge" face of the Mission Control FAB. NOT a button itself —
// just the rendered shape. Platform hosts (macOS `MissionFAB`,
// iOS `MobileMissionFAB`) wrap this in their own chrome (drag affordance,
// hover popover, ambient glow, etc.).
//
// What it shows:
//   • Outer ring  — burn-rate arc, sweeps from 0 → 1 of the day's burn budget.
//                   Color tinted by health (amber default, ember when blocked,
//                   hermesAureate when approval pending, success when only
//                   completed missions remain, textMuted when idle).
//   • Perimeter ticks — one short tick per currently-in-flight mission,
//                       distributed evenly around the perimeter; missions in
//                       awaiting-approval phase glow aureate.
//   • Center glyph — swaps by dominant state:
//                       idle → "compass.drawing"
//                       running → "sparkles"
//                       approval → "hand.raised.fill"
//                       blocked → "exclamationmark.triangle.fill"
//                       completed → "checkmark.seal.fill"
//   • Live mono — at the bottom of the gauge: today's burn-per-hour, mono
//                 monospaced. Auto-hidden in `compact` size.
//
// The gauge is deliberately static in normal dashboard use. It can stay visible
// all day, so it must not keep SwiftUI's render loop alive while idle.

public struct MissionFABGauge: View {
    public enum Size {
        case compact   // 44pt — peek / inline
        case standard  // 56pt — FAB default
        case hero      // 84pt — console hero / preview

        var diameter: CGFloat {
            switch self {
            case .compact:  return 44
            case .standard: return 56
            case .hero:     return 84
            }
        }

        var ringThickness: CGFloat {
            switch self {
            case .compact:  return 3.5
            case .standard: return 4.5
            case .hero:     return 6.5
            }
        }

        var tickLength: CGFloat {
            switch self {
            case .compact:  return 5
            case .standard: return 6
            case .hero:     return 9
            }
        }

        var glyphSize: CGFloat {
            switch self {
            case .compact:  return 16
            case .standard: return 21
            case .hero:     return 30
            }
        }
    }

    public struct Configuration: Equatable {
        public var size: Size
        public var activeMissionCount: Int
        public var approvalPendingCount: Int
        public var blockedCount: Int
        public var hasCompletedSinceLastOpen: Bool
        public var burnSweep: Double  // 0..1 — fraction of the day's burn budget
        public var burnPerHourUSD: Double
        public var macOnline: Bool
        /// A short honest snippet of what the agent is doing right now.
        /// Shown inside the gauge face when live missions are active.
        public var liveSnippet: String?

        public init(
            size: Size,
            activeMissionCount: Int,
            approvalPendingCount: Int,
            blockedCount: Int,
            hasCompletedSinceLastOpen: Bool,
            burnSweep: Double,
            burnPerHourUSD: Double,
            macOnline: Bool,
            liveSnippet: String? = nil
        ) {
            self.size = size
            self.activeMissionCount = activeMissionCount
            self.approvalPendingCount = approvalPendingCount
            self.blockedCount = blockedCount
            self.hasCompletedSinceLastOpen = hasCompletedSinceLastOpen
            self.burnSweep = min(max(burnSweep, 0), 1)
            self.burnPerHourUSD = burnPerHourUSD
            self.macOnline = macOnline
            self.liveSnippet = liveSnippet
        }

        public static let idle = Configuration(
            size: .standard,
            activeMissionCount: 0,
            approvalPendingCount: 0,
            blockedCount: 0,
            hasCompletedSinceLastOpen: false,
            burnSweep: 0,
            burnPerHourUSD: 0,
            macOnline: true
        )
    }

    public let configuration: Configuration

    public init(configuration: Configuration) { self.configuration = configuration }

    public var body: some View {
        ZStack {
            // Track ring
            Circle()
                .stroke(
                    UnifiedDesignSystem.Colors.borderSubtle.opacity(0.45),
                    lineWidth: configuration.size.ringThickness
                )

            // Burn-rate arc
            Circle()
                .trim(from: 0, to: configuration.burnSweep)
                .stroke(
                    primaryArcColor,
                    style: StrokeStyle(
                        lineWidth: configuration.size.ringThickness,
                        lineCap: .round
                    )
                )
                .rotationEffect(.degrees(-90))
                .animation(UnifiedDesignSystem.Animation.gentle, value: configuration.burnSweep)

            // Per-mission perimeter ticks
            tickGeometry

            // Center: live snippet when active, otherwise glyph
            if let snippet = configuration.liveSnippet, configuration.activeMissionCount > 0 {
                GeometryReader { proxy in
                    let width = proxy.size.width * 0.72
                    Text(snippet)
                        .font(.system(size: max(7, configuration.size.glyphSize * 0.36), weight: .medium, design: .monospaced))
                        .foregroundStyle(primaryArcColor)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(width: width)
                        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                        .opacity(0.86)
                }
                .frame(width: configuration.size.diameter, height: configuration.size.diameter)
            } else {
                Image(systemName: glyphName)
                    .font(.system(size: configuration.size.glyphSize, weight: .semibold))
                    .foregroundStyle(glyphForeground)
            }

            // Tiny mono burn-rate readout (hero only)
            if configuration.size == .hero {
                VStack {
                    Spacer()
                    Text(MissionConsoleFormatting.cost(configuration.burnPerHourUSD, precise: configuration.burnPerHourUSD < 1))
                        .font(UnifiedDesignSystem.Typography.monoTiny)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                        .padding(.bottom, 2)
                }
            }
        }
        .frame(width: configuration.size.diameter, height: configuration.size.diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: Geometry

    private var tickGeometry: some View {
        GeometryReader { proxy in
            let count = max(1, min(configuration.activeMissionCount, 12))
            let radius = (proxy.size.width / 2) - configuration.size.ringThickness - 1
            ZStack {
                ForEach(0..<count, id: \.self) { idx in
                    Capsule()
                        .fill(tickColor(for: idx))
                        .frame(width: 2, height: configuration.size.tickLength)
                        .offset(y: -radius - configuration.size.tickLength / 2 + 1)
                        .rotationEffect(.degrees(Double(idx) * (360.0 / Double(count))))
                        .opacity(configuration.activeMissionCount == 0 ? 0 : 1)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .allowsHitTesting(false)
    }

    private func tickColor(for index: Int) -> Color {
        // First N ticks (up to approvalPendingCount) glow aureate; next M (blocked)
        // glow ember; remainder use the burn-arc tint.
        if index < configuration.approvalPendingCount {
            return UnifiedDesignSystem.Colors.hermesAureate
        }
        if index < configuration.approvalPendingCount + configuration.blockedCount {
            return UnifiedDesignSystem.Colors.ember
        }
        return primaryArcColor
    }

    // MARK: Colors / glyph

    private var primaryArcColor: Color {
        if !configuration.macOnline { return UnifiedDesignSystem.Colors.textMuted }
        if configuration.blockedCount > 0 { return UnifiedDesignSystem.Colors.ember }
        if configuration.approvalPendingCount > 0 { return UnifiedDesignSystem.Colors.hermesAureate }
        if configuration.activeMissionCount > 0 { return UnifiedDesignSystem.Colors.amber }
        if configuration.hasCompletedSinceLastOpen { return UnifiedDesignSystem.Colors.success }
        return UnifiedDesignSystem.Colors.textMuted
    }

    private var glyphName: String {
        if !configuration.macOnline { return "wifi.exclamationmark" }
        if configuration.approvalPendingCount > 0 { return "hand.raised.fill" }
        if configuration.blockedCount > 0 { return "exclamationmark.triangle.fill" }
        if configuration.activeMissionCount > 0 { return "sparkles" }
        if configuration.hasCompletedSinceLastOpen { return "checkmark.seal.fill" }
        return "compass.drawing"
    }

    private var glyphForeground: AnyShapeStyle {
        if configuration.activeMissionCount > 0 && configuration.blockedCount == 0 && configuration.approvalPendingCount == 0 {
            return AnyShapeStyle(UnifiedDesignSystem.primaryGradient)
        }
        if configuration.approvalPendingCount > 0 {
            return AnyShapeStyle(UnifiedDesignSystem.mercuryGradient)
        }
        if configuration.blockedCount > 0 {
            return AnyShapeStyle(UnifiedDesignSystem.Colors.ember)
        }
        if configuration.hasCompletedSinceLastOpen {
            return AnyShapeStyle(UnifiedDesignSystem.Colors.success)
        }
        return AnyShapeStyle(UnifiedDesignSystem.Colors.textSecondary)
    }

    // MARK: Accessibility

    private var accessibilityLabel: String {
        if !configuration.macOnline { return "Mission Control. Mac offline." }
        if configuration.approvalPendingCount > 0 {
            return "Mission Control. \(configuration.approvalPendingCount) approval pending. \(configuration.activeMissionCount) active."
        }
        if configuration.blockedCount > 0 {
            return "Mission Control. \(configuration.blockedCount) blocked. \(configuration.activeMissionCount) active."
        }
        if configuration.activeMissionCount > 0 {
            return "Mission Control. \(configuration.activeMissionCount) missions in flight."
        }
        if configuration.hasCompletedSinceLastOpen {
            return "Mission Control. Recent missions completed."
        }
        return "Mission Control. Idle. Tap to compose."
    }
}

#if DEBUG
struct MissionFABGauge_Previews: PreviewProvider {
    static var previews: some View {
        HStack(spacing: 24) {
            MissionFABGauge(configuration: .idle)
            MissionFABGauge(configuration: MissionFABGauge.Configuration(
                size: .standard,
                activeMissionCount: 3,
                approvalPendingCount: 0,
                blockedCount: 0,
                hasCompletedSinceLastOpen: false,
                burnSweep: 0.42,
                burnPerHourUSD: 0.83,
                macOnline: true
            ))
            MissionFABGauge(configuration: MissionFABGauge.Configuration(
                size: .standard,
                activeMissionCount: 4,
                approvalPendingCount: 1,
                blockedCount: 0,
                hasCompletedSinceLastOpen: false,
                burnSweep: 0.68,
                burnPerHourUSD: 2.10,
                macOnline: true
            ))
            MissionFABGauge(configuration: MissionFABGauge.Configuration(
                size: .standard,
                activeMissionCount: 2,
                approvalPendingCount: 0,
                blockedCount: 1,
                hasCompletedSinceLastOpen: false,
                burnSweep: 0.51,
                burnPerHourUSD: 1.20,
                macOnline: true
            ))
            MissionFABGauge(configuration: MissionFABGauge.Configuration(
                size: .hero,
                activeMissionCount: 6,
                approvalPendingCount: 2,
                blockedCount: 1,
                hasCompletedSinceLastOpen: true,
                burnSweep: 0.74,
                burnPerHourUSD: 3.45,
                macOnline: true
            ))
        }
        .padding(40)
        .background(UnifiedDesignSystem.Colors.background)
        .previewLayout(.sizeThatFits)
    }
}
#endif
