import SwiftUI

// MARK: - Ember Surface Background

/// Reusable ember backdrop used across Dashboard, Quota, Activity, and Account.
/// Adaptive: rich warm gradient + drifting ember particles in dark mode;
/// botanical cream wash + drifting fern particles in light mode.
public struct EmberSurfaceBackground: View {
    public let respectsReduceTransparency: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var animate = false

    public init(respectsReduceTransparency: Bool = true) {
        self.respectsReduceTransparency = respectsReduceTransparency
    }

    public var body: some View {
        ZStack {
            baseGradient

            if shouldShowEffects {
                orbs
                particles
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) {
                animate = true
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Base Gradient

    private var baseGradient: some View {
        LinearGradient(
            colors: colorScheme == .dark
                ? [UnifiedDesignSystem.Colors.background, UnifiedDesignSystem.Colors.background, UnifiedDesignSystem.Colors.surface]
                : [Color(hex: "FAF5F2"), Color(hex: "F5EDE8"), Color(hex: "F0E5DE")],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Orbs

    private var orbs: some View {
        ZStack {
            emberOrb(
                color: colorScheme == .dark
                    ? UnifiedDesignSystem.Colors.ember.opacity(0.55)
                    : UnifiedDesignSystem.Colors.ember.opacity(0.18),
                size: 460,
                blur: 60,
                offsetA: CGSize(width: -80, height: -220),
                offsetB: CGSize(width: -120, height: -180)
            )
            emberOrb(
                color: colorScheme == .dark
                    ? UnifiedDesignSystem.Colors.amber.opacity(0.45)
                    : UnifiedDesignSystem.Colors.amber.opacity(0.14),
                size: 420,
                blur: 70,
                offsetA: CGSize(width: 100, height: 260),
                offsetB: CGSize(width: 140, height: 220)
            )
            emberOrb(
                color: colorScheme == .dark
                    ? UnifiedDesignSystem.Colors.blaze.opacity(0.25)
                    : UnifiedDesignSystem.Colors.blaze.opacity(0.10),
                size: 380,
                blur: 80,
                offsetA: CGSize(width: -60, height: 120),
                offsetB: CGSize(width: -100, height: 160)
            )
        }
    }

    @ViewBuilder
    private func emberOrb(color: Color,
                          size: CGFloat,
                          blur: CGFloat,
                          offsetA: CGSize,
                          offsetB: CGSize) -> some View {
        let offset = (animate && !reduceMotion) ? offsetB : offsetA
        Circle()
            .fill(
                RadialGradient(
                    colors: [color, .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: size * 0.48
                )
            )
            .frame(width: size, height: size)
            .blur(radius: blur)
            .offset(offset)
    }

    // MARK: - Particles

    private var particles: some View {
        ZStack {
            ForEach(0..<8) { index in
                EmberParticle(
                    index: index,
                    animate: animate,
                    reduceMotion: reduceMotion
                )
            }
        }
    }

    // MARK: - Conditions

    private var shouldShowEffects: Bool {
        if respectsReduceTransparency && reduceTransparency { return false }
        return true
    }
}

// MARK: - Ember Particle

private struct EmberParticle: View {
    let index: Int
    let animate: Bool
    let reduceMotion: Bool

    @State private var particleOffset: CGFloat = 0

    var body: some View {
        Circle()
            .fill(
                color.opacity(0.4 + Double(index % 3) * 0.15)
            )
            .frame(width: size, height: size)
            .blur(radius: blur)
            .offset(
                x: startX + (animate && !reduceMotion ? driftX : 0),
                y: startY + (animate && !reduceMotion ? driftY : 0) - particleOffset
            )
            .opacity(animate && !reduceMotion ? 0.3 : 0.6)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(
                    .easeInOut(duration: 4 + Double(index) * 0.7)
                    .repeatForever(autoreverses: true)
                    .delay(Double(index) * 0.4)
                ) {
                    particleOffset = 30 + CGFloat(index) * 8
                }
            }
    }

    private var color: Color {
        let colors: [Color] = [
            UnifiedDesignSystem.Colors.ember,
            UnifiedDesignSystem.Colors.amber,
            UnifiedDesignSystem.Colors.blaze,
            Color.white
        ]
        return colors[index % colors.count]
    }

    private var size: CGFloat { 3 + CGFloat(index % 4) * 1.5 }
    private var blur: CGFloat { CGFloat(index % 3) * 1.5 }
    private var startX: CGFloat { -120 + CGFloat(index) * 35 }
    private var startY: CGFloat { 180 + CGFloat(index % 3) * 40 }
    private var driftX: CGFloat { CGFloat(index % 2 == 0 ? 20 : -15) }
    private var driftY: CGFloat { CGFloat(index % 2 == 0 ? -30 : 20) }
}

// MARK: - Preview

#Preview {
    ZStack {
        EmberSurfaceBackground()
        Text("Content")
            .font(.title)
            .foregroundStyle(.primary)
    }
}
