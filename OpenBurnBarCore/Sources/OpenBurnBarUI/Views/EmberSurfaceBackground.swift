import SwiftUI

// MARK: - Ember Surface Background

/// Reusable ember backdrop used across Dashboard, Quota, Activity, and Account.
/// Adaptive: rich warm gradient + drifting ember particles in dark mode;
/// botanical cream wash + drifting fern particles in light mode.
/// In Cooking Mode: beautiful vanilla/chocolate stove glow + drifting steam curves & simmer bubbles.
public struct EmberSurfaceBackground: View {
    public let respectsReduceTransparency: Bool
    public let rendersEffects: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.uiMode) private var uiMode
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var animate = false

    public init(respectsReduceTransparency: Bool = true, rendersEffects: Bool = true) {
        self.respectsReduceTransparency = respectsReduceTransparency
        self.rendersEffects = rendersEffects
    }

    public var body: some View {
        ZStack {
            baseGradient

            if shouldShowEffects {
                orbs
                particles
            }
        }
        .onAppear { syncAnimationState() }
        .onChange(of: reduceMotion) { _, _ in syncAnimationState() }
        .onChange(of: reduceTransparency) { _, _ in syncAnimationState() }
        .onChange(of: scenePhase) { _, _ in syncAnimationState() }
        .onChange(of: rendersEffects) { _, _ in syncAnimationState() }
        .accessibilityHidden(true)
    }

    // MARK: - Base Gradient

    private var baseGradient: some View {
        let theme = UIModeTheme(mode: uiMode)
        let colors: [Color]
        if colorScheme == .dark {
            colors = [theme.background, theme.background, theme.surface]
        } else if uiMode == .cooking {
            colors = [theme.background, theme.background, theme.surface]
        } else {
            colors = [Color(hex: "FAF5F2"), Color(hex: "F5EDE8"), Color(hex: "F0E5DE")]
        }

        return LinearGradient(
            colors: colors,
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Orbs

    private var orbs: some View {
        let theme = UIModeTheme(mode: uiMode)
        let isCooking = uiMode == .cooking
        let isDark = colorScheme == .dark

        let primaryOpacity = isDark ? (isCooking ? 0.35 : 0.55) : (isCooking ? 0.12 : 0.18)
        let secondaryOpacity = isDark ? (isCooking ? 0.25 : 0.45) : (isCooking ? 0.08 : 0.14)
        let tertiaryOpacity = isDark ? (isCooking ? 0.15 : 0.25) : (isCooking ? 0.06 : 0.10)

        return ZStack {
            emberOrb(
                color: theme.primaryAccent.opacity(primaryOpacity),
                size: 460,
                blur: 60,
                offsetA: CGSize(width: -80, height: -220),
                offsetB: CGSize(width: -120, height: -180)
            )
            emberOrb(
                color: theme.secondaryAccent.opacity(secondaryOpacity),
                size: 420,
                blur: 70,
                offsetA: CGSize(width: 100, height: 260),
                offsetB: CGSize(width: 140, height: 220)
            )
            emberOrb(
                color: theme.tertiaryAccent.opacity(tertiaryOpacity),
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
            if uiMode == .cooking {
                ForEach(0..<6, id: \.self) { index in
                    SteamParticle(
                        index: index,
                        animate: animate,
                        reduceMotion: reduceMotion
                    )
                }
                ForEach(0..<8, id: \.self) { index in
                    SimmerBubbleParticle(
                        index: index,
                        animate: animate,
                        reduceMotion: reduceMotion
                    )
                }
            } else {
                ForEach(0..<8, id: \.self) { index in
                    EmberParticle(
                        index: index,
                        animate: animate,
                        reduceMotion: reduceMotion
                    )
                }
            }
        }
    }

    // MARK: - Conditions

    private var shouldShowEffects: Bool {
        if respectsReduceTransparency && reduceTransparency { return false }
        return rendersEffects && scenePhase == .active
    }

    private var shouldAnimateEffects: Bool {
        shouldShowEffects && !reduceMotion
    }

    private func syncAnimationState() {
        guard shouldAnimateEffects else {
            animate = false
            return
        }
        guard !animate else { return }
        withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) {
            animate = true
        }
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
                    .easeInOut(duration: 4.0 + Double(index) * 0.7)
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

// MARK: - Cooking Particles

private struct SteamWaveShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.minY),
            control1: CGPoint(x: rect.midX - 12, y: rect.maxY - rect.height * 0.35),
            control2: CGPoint(x: rect.midX + 12, y: rect.maxY - rect.height * 0.65)
        )
        return path
    }
}

private struct SteamParticle: View {
    let index: Int
    let animate: Bool
    let reduceMotion: Bool

    @State private var offset: CGFloat = 0
    @State private var sway: CGFloat = 0

    var body: some View {
        SteamWaveShape()
            .stroke(
                LinearGradient(
                    colors: [
                        Color(hex: "FF2A85").opacity(0.0), // Swirling pitaya purée bottom
                        Color(hex: "FF2A85").opacity(0.22),
                        Color(hex: "FFA500").opacity(0.18), // Mango swirl body
                        Color(hex: "39FF14").opacity(0.12), // Lime swirl top
                        Color(hex: "39FF14").opacity(0.0)
                    ],
                    startPoint: .bottom,
                    endPoint: .top
                ),
                style: StrokeStyle(lineWidth: 3.5, lineCap: .round)
            )
            .frame(width: 40, height: 160)
            .offset(
                x: startX + (animate && !reduceMotion ? sway : 0),
                y: startY - (animate && !reduceMotion ? offset : 0)
            )
            .opacity(animate && !reduceMotion ? 0.35 : 0.6)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(
                    .linear(duration: 8.0 + Double(index) * 1.5)
                    .repeatForever(autoreverses: false)
                    .delay(Double(index) * 0.7)
                ) {
                    offset = 260
                }
                withAnimation(
                    .easeInOut(duration: 3.0 + Double(index) * 0.6)
                    .repeatForever(autoreverses: true)
                ) {
                    sway = 20
                }
            }
    }

    private var startX: CGFloat { -120 + CGFloat(index) * 55 }
    private var startY: CGFloat { 280 + CGFloat(index % 2) * 40 }
}

private struct SimmerBubbleParticle: View {
    let index: Int
    let animate: Bool
    let reduceMotion: Bool

    @State private var offset: CGFloat = 0
    @State private var scale: CGFloat = 0.3
    @State private var opacity: Double = 0.0

    private var bubbleColor: Color {
        let colors = [
            Color(hex: "FF2A85"), // Pitaya Pink
            Color(hex: "FFA500"), // Mango Orange
            Color(hex: "39FF14"), // Electric Lime
            Color(hex: "00F5FF"), // Kiwi Turquoise
            Color(hex: "FF1493")  // Cherry Pink
        ]
        return colors[index % colors.count]
    }

    var body: some View {
        Circle()
            .stroke(bubbleColor.opacity(opacity * 0.65), lineWidth: 1.2)
            .background(Circle().fill(bubbleColor.opacity(opacity * 0.18)))
            .frame(width: size, height: size)
            .scaleEffect(scale)
            .offset(
                x: startX,
                y: startY - (animate && !reduceMotion ? offset : 0)
            )
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(
                    .easeOut(duration: 5.0 + Double(index) * 1.2)
                    .repeatForever(autoreverses: false)
                    .delay(Double(index) * 0.6)
                ) {
                    offset = 200 + CGFloat(index) * 12
                    scale = 1.3
                }
                withAnimation(
                    .easeInOut(duration: 2.5)
                    .repeatForever(autoreverses: true)
                    .delay(Double(index) * 0.6)
                ) {
                    opacity = 0.75
                }
            }
    }

    private var size: CGFloat { 6 + CGFloat(index % 3) * 3 }
    private var startX: CGFloat { -110 + CGFloat(index) * 32 }
    private var startY: CGFloat { 220 + CGFloat(index % 3) * 20 }
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
