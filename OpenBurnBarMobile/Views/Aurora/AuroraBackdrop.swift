import SwiftUI
import OpenBurnBarCore

// MARK: - Aurora Backdrop
//
// Cinematic, parallax-driven backdrop that replaces `EmberSurfaceBackground`
// for every primary surface in the iOS app.
//
// Layers (bottom to top):
//   1. Base gradient (mode-aware)
//   2. iOS 26 MeshGradient (12 anchor points, ember/amber/blaze/whimsy)
//      → fallback to radial orbs on iOS 17/18
//   3. Static "aurora ribbon" along the top edge
//   4. Subtle ember particles (drift only when motion allowed)
//   5. Optional vignette
//
// Honors Reduce Motion (no infinite anims) and Reduce Transparency (drops blur).

struct AuroraBackdrop: View {
    var density: AuroraDensity = .full
    var colorDriver: SwarmColorDriver?
    var visibility: MobileBackgroundVisibility?
    var allowsWebsiteBackground: Bool = true

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.motionStore) private var motion
    @Environment(\.mobileBackgroundVisibility) private var inheritedVisibility
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.uiMode) private var uiMode

    /// Wall-clock anchor for the mesh drift. Reset whenever the animation
    /// (re)starts so the drift always begins from its resting phase, matching
    /// the retired `withAnimation` driver.
    @State private var driftStart = Date()
    @State private var isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled

    @AppStorage("useWebsiteBackground") private var useWebsiteBackground: Bool = false
    @AppStorage(AppSkin.storageKey) private var appSkin: AppSkin = .aurora

    enum AuroraDensity {
        case full       // Pulse / Burn / Hermes / You hero
        case subtle     // Sheets, secondary surfaces
        case minimal    // Sign in, onboarding (use existing ember backdrop instead)
    }

    var body: some View {
        ZStack {
            if appSkin == .editorial {
                // Editorial / Paper skin: the light dot-crest — provider logos
                // drifting from coloured dots on paper, like app.burnbar.ai.
                // `WebsiteBackgroundView` renders the paper + transparent swarm
                // itself when the editorial skin is active.
                WebsiteBackgroundView(
                    accent: MobileTheme.ember,
                    colorDriver: colorDriver,
                    visibility: effectiveVisibility
                )
            } else if uiMode == .cooking {
                VisibilityAwareEmberSurfaceBackground()
            } else if allowsWebsiteBackground && useWebsiteBackground {
                WebsiteBackgroundView(
                    accent: MobileTheme.ember,
                    colorDriver: colorDriver,
                    visibility: effectiveVisibility
                )
            } else {
                baseGradient
                    .ignoresSafeArea()

                if shouldRenderDecorativeLayers {
                    meshLayer
                        .ignoresSafeArea()
                        .blendMode(.plusLighter)

                    ribbonLayer
                        .frame(maxWidth: .infinity)
                        .frame(height: 220)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .ignoresSafeArea()
                        .blendMode(.plusLighter)

                    if shouldRenderParticles {
                        particleLayer
                            .ignoresSafeArea()
                            .allowsHitTesting(false)
                    }
                }

                vignette
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
        .onAppear { startAnimating() }
        .onChange(of: reduceMotion) { _, _ in startAnimating() }
        .onChange(of: scenePhase) { _, _ in startAnimating() }
        .onChange(of: effectiveVisibility) { _, _ in startAnimating() }
        .onChange(of: isLowPowerModeEnabled) { _, _ in startAnimating() }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name.NSProcessInfoPowerStateDidChange)) { _ in
            isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }

    // MARK: - Base

    private var effectiveVisibility: MobileBackgroundVisibility {
        let requested = visibility ?? defaultVisibilityForDensity
        return requested.constrained(by: inheritedVisibility)
    }

    private var defaultVisibilityForDensity: MobileBackgroundVisibility {
        switch density {
        case .full:
            return .prominent
        case .subtle:
            return .subtle
        case .minimal:
            return .obscured
        }
    }

    private var shouldAnimate: Bool {
        shouldRenderLocalAurora
            && scenePhase == .active
            && !reduceMotion
            && !isLowPowerModeEnabled
            && effectiveVisibility == .prominent
    }

    private var shouldRenderLocalAurora: Bool {
        uiMode != .cooking && !(allowsWebsiteBackground && useWebsiteBackground)
    }

    private var shouldRenderDecorativeLayers: Bool {
        !reduceTransparency
            && effectiveVisibility != .hidden
            && effectiveVisibility != .obscured
    }

    private var shouldRenderParticles: Bool {
        density == .full && shouldAnimate
    }

    private var layerOpacity: Double {
        if effectiveVisibility == .subtle || density == .subtle {
            return 0.55
        }
        return 1.0
    }

    private var baseGradient: some View {
        LinearGradient(
            colors: colorScheme == .dark
                ? [
                    MobileTheme.background,
                    MobileTheme.background,
                    MobileTheme.surface
                ]
                : [
                    Color(hex: "F4EFE7"),
                    Color(hex: "EFE7DC"),
                    Color(hex: "ECE3D6")
                ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Mesh Layer (iOS 18+) / Orb Fallback

    /// Drives the drift at a capped 24Hz instead of letting `withAnimation`
    /// interpolate the mesh at native refresh (up to 120Hz): every phase
    /// change re-renders the full-screen `MeshGradient` + 36pt blur, and the
    /// drift moves sub-pixel per frame, so the extra frames were pure GPU cost.
    private var meshLayer: some View {
        TimelineView(.animation(
            minimumInterval: AuroraDesign.Motion.auroraDriftFrameInterval,
            paused: !shouldAnimate
        )) { context in
            // Zero the phase while paused — `paused:` alone freezes the last value.
            meshContent(
                phase: shouldAnimate
                    ? Self.driftPhase(elapsed: context.date.timeIntervalSince(driftStart))
                    : 0
            )
        }
    }

    @ViewBuilder
    private func meshContent(phase: CGFloat) -> some View {
        if #available(iOS 18.0, *) {
            AuroraMeshGradient(
                phase: phase,
                tilt: shouldAnimate ? motion.tilt : .zero,
                colorScheme: colorScheme
            )
            .opacity(layerOpacity)
        } else {
            AuroraOrbFallback(phase: phase, colorScheme: colorScheme)
                .opacity(layerOpacity)
        }
    }

    // MARK: - Aurora Ribbon

    private var ribbonLayer: some View {
        // Intentionally static: `Canvas` closures are not animatable, and the
        // old `withAnimation` ribbon drive shifted the sine term by a full 2π —
        // phase 0 and phase 1 render identical pixels — so the ribbon has
        // always been static. Animating it for real would be a visible change.
        AuroraRibbon(phase: 0, colorScheme: colorScheme)
            .opacity(density == .full ? 0.55 : 0.35)
    }

    // MARK: - Particles

    private var particleLayer: some View {
        ZStack {
            ForEach(0..<8) { index in
                AuroraEmberParticle(index: index, reduceMotion: !shouldAnimate)
            }
        }
    }

    // MARK: - Vignette

    private var vignette: some View {
        RadialGradient(
            colors: [
                Color.clear,
                colorScheme == .dark
                    ? Color.black.opacity(0.32)
                    : Color(hex: "1C2014").opacity(0.10)
            ],
            center: .center,
            startRadius: 80,
            endRadius: 600
        )
    }

    // MARK: - Animation Driver

    private func startAnimating() {
        // While idle the timeline is paused and `meshLayer` pins the phase to 0,
        // mirroring the old `phase = 0` reset.
        guard shouldAnimate else { return }
        driftStart = Date()
    }

    /// Triangle wave reproducing the retired
    /// `Animation.linear(duration: 18).repeatForever(autoreverses: true)` drive:
    /// 0 → 1 over the first leg, back to 0 over the next, forever.
    /// `nonisolated` + internal so tests can pin the parity curve.
    nonisolated static func driftPhase(elapsed: TimeInterval) -> CGFloat {
        guard elapsed > 0 else { return 0 }
        let leg = AuroraDesign.Motion.auroraDriftDuration
        let cycle = elapsed.truncatingRemainder(dividingBy: leg * 2) / leg
        return CGFloat(cycle <= 1 ? cycle : 2 - cycle)
    }
}

struct VisibilityAwareEmberSurfaceBackground: View {
    var respectsReduceTransparency: Bool = true

    @Environment(\.mobileBackgroundVisibility) private var backgroundVisibility
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        EmberSurfaceBackground(
            respectsReduceTransparency: respectsReduceTransparency,
            rendersEffects: MobileDecorativeRenderPolicy.allowsLiveEffects(
                visibility: backgroundVisibility,
                scenePhaseActive: scenePhase == .active
            )
        )
    }
}

// MARK: - Aurora Mesh Gradient (iOS 18+)

@available(iOS 18.0, *)
private struct AuroraMeshGradient: View {
    let phase: CGFloat
    let tilt: CGSize
    let colorScheme: ColorScheme

    var body: some View {
        let drift = CGFloat(0.06) * phase
        let tiltX = Float(tilt.width) * 0.04
        let tiltY = Float(tilt.height) * 0.04

        // 4×4 grid of mesh points, anchored at corners + interior eddies.
        let points: [SIMD2<Float>] = [
            SIMD2<Float>(0.0, 0.0), SIMD2<Float>(0.34 + tiltX, 0.04 + tiltY),
            SIMD2<Float>(0.66 - tiltX, 0.10 - tiltY), SIMD2<Float>(1.0, 0.0),

            SIMD2<Float>(0.02 + tiltX, 0.32 + Float(drift) + tiltY),
            SIMD2<Float>(0.40, 0.30 - Float(drift) - tiltY),
            SIMD2<Float>(0.65, 0.34 + tiltY),
            SIMD2<Float>(0.98 - tiltX, 0.30 - tiltY),

            SIMD2<Float>(0.0, 0.66 - Float(drift) + tiltY),
            SIMD2<Float>(0.32, 0.62 + Float(drift) - tiltY),
            SIMD2<Float>(0.68, 0.66 + Float(drift) + tiltY),
            SIMD2<Float>(1.0, 0.62 - Float(drift) - tiltY),

            SIMD2<Float>(0.0, 1.0), SIMD2<Float>(0.34, 1.0),
            SIMD2<Float>(0.66, 1.0), SIMD2<Float>(1.0, 1.0)
        ]

        let palette: [Color] = colorScheme == .dark
            ? darkPalette
            : lightPalette

        return MeshGradient(
            width: 4,
            height: 4,
            points: points,
            colors: palette,
            background: .clear,
            smoothsColors: true
        )
        .blur(radius: 36)
        .opacity(0.95)
    }

    // MARK: - Palettes (16 colors each — match the 16 mesh points)

    private var darkPalette: [Color] {
        let ember = MobileTheme.ember
        let amber = MobileTheme.amber
        let blaze = MobileTheme.blaze
        let whim  = MobileTheme.whimsy
        let bg    = Color(hex: "0E0D0B")
        return [
            bg, bg, bg, bg,
            bg, ember.opacity(0.55), amber.opacity(0.40), bg,
            bg, blaze.opacity(0.30), whim.opacity(0.22), bg,
            bg, bg, bg, bg
        ]
    }

    private var lightPalette: [Color] {
        let ember = MobileTheme.ember
        let amber = MobileTheme.amber
        let blaze = MobileTheme.blaze
        let whim  = MobileTheme.whimsy
        let bg    = Color(hex: "EDF0E5")
        return [
            bg, bg, bg, bg,
            bg, ember.opacity(0.20), amber.opacity(0.16), bg,
            bg, blaze.opacity(0.12), whim.opacity(0.10), bg,
            bg, bg, bg, bg
        ]
    }
}

// MARK: - Orb Fallback (iOS 17)

private struct AuroraOrbFallback: View {
    let phase: CGFloat
    let colorScheme: ColorScheme

    var body: some View {
        ZStack {
            orb(color: MobileTheme.ember,
                size: 460,
                blur: 70,
                offset: CGSize(width: -100 + phase * 40, height: -200 + phase * 24))
            orb(color: MobileTheme.amber,
                size: 420,
                blur: 80,
                offset: CGSize(width: 120 - phase * 28, height: 240 - phase * 30))
            orb(color: MobileTheme.blaze,
                size: 380,
                blur: 90,
                offset: CGSize(width: -60 + phase * 18, height: 140 - phase * 22))
        }
    }

    private func orb(color: Color, size: CGFloat, blur: CGFloat, offset: CGSize) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        color.opacity(colorScheme == .dark ? 0.55 : 0.20),
                        Color.clear
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: size * 0.5
                )
            )
            .frame(width: size, height: size)
            .blur(radius: blur)
            .offset(offset)
    }
}

// MARK: - Aurora Ribbon

private struct AuroraRibbon: View {
    let phase: CGFloat
    let colorScheme: ColorScheme

    var body: some View {
        Canvas { context, size in
            let amplitude: CGFloat = 24
            let frequency: CGFloat = .pi * 2
            let segments = 36
            var path = Path()
            for i in 0...segments {
                let x = CGFloat(i) / CGFloat(segments) * size.width
                let progress = CGFloat(i) / CGFloat(segments)
                let y = size.height * 0.35 + sin(progress * frequency + phase * .pi * 2) * amplitude
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            // Mirror for ribbon thickness
            for i in stride(from: segments, through: 0, by: -1) {
                let x = CGFloat(i) / CGFloat(segments) * size.width
                let progress = CGFloat(i) / CGFloat(segments)
                let y = size.height * 0.35 + sin(progress * frequency + phase * .pi * 2) * amplitude + 38
                path.addLine(to: CGPoint(x: x, y: y))
            }
            path.closeSubpath()

            context.addFilter(.blur(radius: 28))
            context.drawLayer { layer in
                layer.fill(
                    path,
                    with: .linearGradient(
                        Gradient(colors: [
                            MobileTheme.ember.opacity(colorScheme == .dark ? 0.45 : 0.20),
                            MobileTheme.amber.opacity(colorScheme == .dark ? 0.30 : 0.14),
                            MobileTheme.hermesMercury.opacity(colorScheme == .dark ? 0.18 : 0.08)
                        ]),
                        startPoint: CGPoint.zero,
                        endPoint: CGPoint(x: size.width, y: size.height)
                    )
                )
            }
        }
    }
}

// MARK: - Ember Particle

private struct AuroraEmberParticle: View {
    let index: Int
    let reduceMotion: Bool

    @State private var rise: CGFloat = 0

    var body: some View {
        Circle()
            .fill(particleColor.opacity(0.4 + Double(index % 3) * 0.18))
            .frame(width: size, height: size)
            .blur(radius: blur)
            .offset(x: startX, y: startY - rise)
            .opacity(0.5)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(
                    .easeInOut(duration: 5 + Double(index) * 0.7)
                        .repeatForever(autoreverses: true)
                        .delay(Double(index) * 0.4)
                ) {
                    rise = 28 + CGFloat(index) * 6
                }
            }
    }

    private var particleColor: Color {
        let palette: [Color] = [MobileTheme.ember, MobileTheme.amber, MobileTheme.blaze, .white]
        return palette[index % palette.count]
    }

    private var size: CGFloat { 3 + CGFloat(index % 4) * 1.4 }
    private var blur: CGFloat { CGFloat(index % 3) * 1.2 }
    private var startX: CGFloat { -130 + CGFloat(index) * 38 }
    private var startY: CGFloat { 220 + CGFloat(index % 3) * 36 }
}

// MARK: - Preview

#Preview {
    AuroraBackdrop()
}
