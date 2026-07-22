import SwiftUI

// MARK: - Cooking Loader
//
// A playful, dancing eggs-and-bacon skillet that replaces the mining pickaxe
// loader when the app is in Cooking mode. The whole skillet bounces and sways
// to a gentle spring rhythm — like breakfast dancing in the pan.

public struct CookingLoader: View {
    public typealias Style = MiningPickLoader.Style

    public let style: Style
    public let label: String?
    public let tint: Color?

    public init(_ style: Style = .panel, label: String? = nil, tint: Color? = nil) {
        self.style = style
        self.label = label
        self.tint = tint
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bouncePhase: CGFloat = 0

    private var size: CGFloat {
        switch style {
        case .inline: return 24
        case .panel:  return 60
        case .hero:   return 100
        }
    }

    private var labelFont: Font {
        switch style {
        case .inline: return .system(size: 11, weight: .medium, design: .rounded)
        case .panel:  return .system(size: 13, weight: .medium, design: .rounded)
        case .hero:   return .system(size: 16, weight: .semibold, design: .rounded)
        }
    }

    private var spacing: CGFloat {
        switch style {
        case .inline: return 4
        case .panel:  return 10
        case .hero:   return 14
        }
    }

    public var body: some View {
        VStack(spacing: spacing) {
            icon
            if let label, !label.isEmpty {
                Text(label)
                    .font(labelFont)
                    .foregroundStyle(tint ?? .secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label ?? "Loading")
        .accessibilityAddTraits(.updatesFrequently)
    }

    @ViewBuilder
    private var icon: some View {
        if reduceMotion {
            staticIcon
        } else {
            dancingIcon
        }
    }

    private var staticIcon: some View {
        Image("CookingIconSkillet", bundle: .main)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .opacity(0.92)
    }

    private var dancingIcon: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: false)) { context in
            let phase = dancingPhase(at: context.date)
            let bounce = bounceOffset(phase)
            let sway = swayRotation(phase)
            let squash = squashScale(phase)

            Image("CookingIconSkillet", bundle: .main)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .offset(y: bounce)
                .rotationEffect(.degrees(sway), anchor: .center)
                .scaleEffect(squash, anchor: .center)
        }
        .frame(width: size, height: size)
    }

    // MARK: - Animation curves
    //
    // A single 1.6s loop with overlapping sine waves:
    //   - Bounce: primary vertical hop
    //   - Sway: gentle rotation like a pan rocking on the stove
    //   - Squash: slight stretch on the way up, squash on landing

    private func dancingPhase(at date: Date) -> Double {
        let period: TimeInterval = 1.6
        let t = date.timeIntervalSinceReferenceDate
        return (t.truncatingRemainder(dividingBy: period)) / period
    }

    /// Vertical bounce: egg-like hop, up then settle.
    private func bounceOffset(_ p: Double) -> CGFloat {
        let s = sin(p * .pi * 2)
        // Sharper upward arc, softer landing
        let shaped = s > 0 ? pow(s, 0.7) : -pow(abs(s), 1.4) * 0.3
        return -CGFloat(shaped) * size * 0.12
    }

    /// Gentle rocking sway, offset so it lags the bounce slightly.
    private func swayRotation(_ p: Double) -> Double {
        let lagged = (p + 0.15).truncatingRemainder(dividingBy: 1.0)
        return sin(lagged * .pi * 2) * 5.0
    }

    /// Squash-stretch: taller at apex, squatter at bottom.
    private func squashScale(_ p: Double) -> CGFloat {
        let s = sin(p * .pi * 2)
        // SwiftUI scaleEffect is uniform; we use offset + rotation for character
        return CGFloat(1.0 + s * 0.04)
    }
}

// MARK: - Mode-Aware Loader

public struct ModeAwareLoader: View {
    public let style: MiningPickLoader.Style
    public let label: String?
    public let tint: Color?

    @Environment(\.uiMode) private var uiMode

    public init(_ style: MiningPickLoader.Style = .panel, label: String? = nil, tint: Color? = nil) {
        self.style = style
        self.label = label
        self.tint = tint
    }

    public var body: some View {
        switch uiMode {
        case .cooking:
            CookingLoader(style, label: label, tint: tint)
        case .standard:
            MiningPickLoader(style, label: label, tint: tint)
        }
    }
}

#if DEBUG
#Preview("Cooking loader styles") {
    VStack(spacing: 36) {
        CookingLoader(.inline)
        CookingLoader(.panel, label: "Sizzling…")
        CookingLoader(.hero, label: "Breakfast is almost ready…")
    }
    .padding(40)
}
#endif
