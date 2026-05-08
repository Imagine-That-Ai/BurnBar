import SwiftUI

// MARK: - Aurora Glass Card
//
// Hero glass surface used by every primary card in the iOS rebuild. Wraps
// `LiquidGlassFallback` and adds:
//   - Specular highlight band that drifts with motion parallax
//   - Press feedback (scale + brightness lift)
//   - Optional luminous edge sheen
//
// `interactive: true` enables hover/tap feedback (default off to keep the
// composing view in charge of gestures).

struct AuroraGlassCard<Content: View>: View {

    let variant: AuroraGlassVariant
    let cornerRadius: CGFloat
    let interactive: Bool
    let padding: CGFloat
    @ViewBuilder let content: () -> Content

    @State private var isPressed = false
    @State private var isHovered = false

    @Environment(\.motionStore) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    init(
        variant: AuroraGlassVariant = .standard,
        cornerRadius: CGFloat = AuroraDesign.Shape.standardCorner,
        interactive: Bool = false,
        padding: CGFloat = MobileTheme.Spacing.lg,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.variant = variant
        self.cornerRadius = cornerRadius
        self.interactive = interactive
        self.padding = padding
        self.content = content
    }

    var body: some View {
        content()
            .padding(padding)
            .background(specularBackground)
            .auroraGlass(variant, cornerRadius: cornerRadius)
            .scaleEffect(isPressed ? 0.985 : (isHovered ? 1.012 : 1.0))
            .brightness(isPressed ? 0.04 : 0.0)
            .animation(AuroraDesign.Motion.cardPress, value: isPressed)
            .animation(AuroraDesign.Motion.cardHover, value: isHovered)
            .onHover { hovering in
                guard interactive else { return }
                isHovered = hovering
            }
            .allowsHitTesting(true)
    }

    // MARK: - Specular Highlight
    //
    // On iOS 26, `.glassEffect()` already paints its own specular sheen so we
    // skip the manual layer entirely — stacking both produced visible bands
    // across cards. On iOS 17/18 the manual layer is the only sheen we get,
    // but we keep it well below the level that bands across stacked cards.

    @ViewBuilder
    private var specularBackground: some View {
        if #available(iOS 26.0, *) {
            EmptyView()
        } else {
            specularLayer
        }
    }

    private var specularLayer: some View {
        // Drifts with parallax — anchors highlight to top-left and offsets
        // it by the device tilt vector. Range ±40pt.
        AuroraDesign.Gradients.specular
            .frame(height: 80)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .offset(
                x: reduceMotion ? -8 : motion.tilt.width * 28,
                y: reduceMotion ? -6 : motion.tilt.height * 18
            )
            .blendMode(.plusLighter)
            .opacity(specularOpacity)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .allowsHitTesting(false)
    }

    private var specularOpacity: Double {
        switch variant {
        case .hero:    return colorScheme == .dark ? 0.22 : 0.16
        case .urgent, .success: return 0.14
        case .hermes:  return 0.18
        default:       return colorScheme == .dark ? 0.12 : 0.10
        }
    }

}

// MARK: - Preview

#Preview {
    ZStack {
        AuroraBackdrop()
        VStack(spacing: 16) {
            AuroraGlassCard(variant: .hero, cornerRadius: 22) {
                Text("Hero card")
                    .font(AuroraDesign.Typography.displayHero)
                    .foregroundStyle(.white)
            }
            AuroraGlassCard(variant: .standard, interactive: true) {
                Text("Standard interactive")
                    .foregroundStyle(.white)
            }
            AuroraGlassCard(variant: .urgent) {
                Text("Urgent variant")
                    .foregroundStyle(.white)
            }
        }
        .padding()
    }
}
