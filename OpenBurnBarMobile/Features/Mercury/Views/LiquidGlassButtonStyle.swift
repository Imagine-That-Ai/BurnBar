import SwiftUI

/// Specular shine sweep view that provides a high-fidelity diagonal gloss shimmer.
struct ShimmerSweepView: View {
    let accent: Color
    @State private var offset: CGFloat = -1.5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            LinearGradient(
                colors: [
                    Color.clear,
                    Color.white.opacity(0.0),
                    Color.white.opacity(0.35),
                    Color.white.opacity(0.0),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .scaleEffect(3.0)
            .offset(x: offset * width)
            .mask(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .onAppear {
                if !reduceMotion {
                    withAnimation(.linear(duration: 3.2).repeatForever(autoreverses: false)) {
                        offset = 1.5
                    }
                }
            }
        }
    }
}

/// Liquid-glass button style used by `MercuryActionStack`. Lifted out of
/// `MercuryLiveSheet.swift` (where it lived inline) and extended with an
/// `accent: Color` so the user's chosen palette tints the press state and
/// shimmer border. Adds support for the togglable SOTA Premium UX.
struct LiquidGlassButtonStyle: ButtonStyle {
    let isEnabled: Bool
    var accent: Color = .blue
    var usePremiumSOTAUX: Bool = false

    @AppStorage("usePremiumSOTAUX") private var globalUsePremiumSOTAUX: Bool = false
    @AppStorage(LiquidGlassTransparency.storageKey) private var rawGlassTransparency: Double = 0
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func makeBody(configuration: Configuration) -> some View {
        let activeSOTA = usePremiumSOTAUX || globalUsePremiumSOTAUX
        
        configuration.label
            .font(.system(size: 16, weight: .semibold, design: .rounded))
            .foregroundStyle(isEnabled ? .white : Color.white.opacity(0.4))
            .padding(.vertical, 16)
            .padding(.horizontal, 20)
            .background(
                ZStack {
                    if #available(iOS 26, *) {
                        // Native Liquid Glass: no material underneath — the
                        // accent gradient rides on top of pure glass as a wash.
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        accent.opacity(configuration.isPressed ? 0.45 : 0.28),
                                        accent.opacity(configuration.isPressed ? 0.28 : 0.10)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .opacity(isEnabled ? 1 : 0.3)
                            .liquidGlassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    } else {
                        let t = LiquidGlassTransparency.effective(rawGlassTransparency, reduceTransparency: reduceTransparency)
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .opacity(LiquidGlassTransparency.fallbackPlateOpacity(t))
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(.thickMaterial)
                            .opacity(LiquidGlassTransparency.frostScrimOpacity(t))

                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        accent.opacity(configuration.isPressed ? 0.45 : 0.28),
                                        accent.opacity(configuration.isPressed ? 0.28 : 0.10)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .opacity(isEnabled ? 1 : 0.3)
                    }

                    if isEnabled && activeSOTA {
                        ShimmerSweepView(accent: accent)
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                accent.opacity(isEnabled ? 0.55 : 0.18),
                                Color.white.opacity(isEnabled ? 0.18 : 0.06)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .overlay(
                // 3D Inner Bevel
                Group {
                    if activeSOTA {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                            .padding(1)
                            .mask(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
            )
            .shadow(
                color: accent.opacity(isEnabled ? (activeSOTA ? 0.25 : 0.18) : 0),
                radius: activeSOTA ? 18 : 14,
                x: 0,
                y: activeSOTA ? 10 : 8
            )
            .scaleEffect(configuration.isPressed ? (activeSOTA ? 0.94 : 0.97) : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: activeSOTA ? 0.55 : 0.65), value: configuration.isPressed)
            .contentShape(Rectangle())
            .onChange(of: configuration.isPressed) { _, newValue in
                if newValue && isEnabled && activeSOTA {
                    #if canImport(UIKit)
                    let generator = UIImpactFeedbackGenerator(style: .light)
                    generator.impactOccurred()
                    #endif
                }
            }
    }
}
