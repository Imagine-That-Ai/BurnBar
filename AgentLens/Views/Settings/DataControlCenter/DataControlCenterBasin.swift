import SwiftUI
import OpenBurnBarCore

// MARK: - The Basin (mercury swirl)
//
// A live `TimelineView(.animation)` + `Canvas` rendering of a slowly swirling
// pool of mercury — the visual metaphor for the user's data resting under the
// vault. The fill height tracks `sealedFraction` (how much of the user's data
// is sealed: zero-access + end-to-end), so as more data becomes E2E-sealed the
// basin fills with bright mercury.
//
// Swirl cadence comes from the design token `motionSwirlSeconds` (PensieveTokens),
// so the basin's rhythm matches the website's Pensieve hero. Mercury colors come
// from the Pensieve mercury tokens via `PensieveTheme`. Honors
// `accessibilityReduceMotion` by freezing the swirl at a representative phase.

struct DataBasinView: View {
    /// 0…1 — how full the basin sits (sealed data fraction).
    var fill: Double
    /// Sealed bytes formatted for the overlaid label (optional caption).
    var caption: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Swirl period in seconds, sourced from the Pensieve motion token.
    private var swirlSeconds: Double {
        Double(PensieveTokens.motionSwirlSeconds) ?? 18
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            let phase = swirlPhase(at: timeline.date)
            ZStack {
                basinShell
                Canvas { context, size in
                    drawMercury(in: context, size: size, phase: phase)
                }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .allowsHitTesting(false)
                basinRim
                if let caption {
                    captionOverlay(caption)
                }
            }
        }
        .frame(height: 168)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Data basin")
        .accessibilityValue("\(Int((fill * 100).rounded())) percent of your data is sealed")
    }

    private func swirlPhase(at date: Date) -> Double {
        guard reduceMotion == false else { return 0.35 }
        let t = date.timeIntervalSinceReferenceDate
        return (t.truncatingRemainder(dividingBy: swirlSeconds)) / swirlSeconds
    }

    // MARK: Shell + rim

    private var basinShell: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(reduceTransparency ? AnyShapeStyle(DesignSystem.Colors.surface) : AnyShapeStyle(.ultraThinMaterial))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        RadialGradient(
                            colors: [
                                PensieveTheme.mercuryDeep.opacity(0.22),
                                Color.clear
                            ],
                            center: .bottom,
                            startRadius: 0,
                            endRadius: 220
                        )
                    )
            )
    }

    private var basinRim: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .stroke(
                LinearGradient(
                    colors: [
                        PensieveTheme.mercuryBright.opacity(0.55),
                        PensieveTheme.mercuryDeep.opacity(0.30)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 0.8
            )
    }

    private func captionOverlay(_ caption: String) -> some View {
        VStack {
            Spacer()
            HStack {
                Text(caption)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(PensieveTheme.mercuryBright)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.black.opacity(0.22)))
                Spacer()
            }
            .padding(12)
        }
    }

    // MARK: Mercury Canvas

    private func drawMercury(in context: GraphicsContext, size: CGSize, phase: Double) {
        let clamped = max(0, min(1, fill))
        // Surface line sits at (1 - fill) from the top; never quite full so the
        // meniscus reads as liquid.
        let surfaceY = size.height * (1 - clamped * 0.92) - 6

        // Two offset sine waves give a swirling meniscus.
        let body = mercuryPath(width: size.width, height: size.height, surfaceY: surfaceY, phase: phase)

        context.fill(
            body,
            with: .linearGradient(
                Gradient(colors: [
                    PensieveTheme.mercuryBright.opacity(0.92),
                    PensieveTheme.mercuryCore.opacity(0.80),
                    PensieveTheme.mercuryDeep.opacity(0.66)
                ]),
                startPoint: CGPoint(x: size.width / 2, y: surfaceY),
                endPoint: CGPoint(x: size.width / 2, y: size.height)
            )
        )

        // Specular sheen drifting across the surface — a thin bright band.
        var sheen = context
        sheen.addFilter(.blur(radius: 6))
        let sheenPath = sheenBand(width: size.width, surfaceY: surfaceY, phase: phase)
        sheen.fill(sheenPath, with: .color(PensieveTheme.mercuryBright.opacity(0.45)))

        // A few drifting beads of mercury near the surface.
        for index in 0..<5 {
            let drift = (phase + Double(index) / 5).truncatingRemainder(dividingBy: 1)
            let x = drift * size.width
            let bob = sin((phase + Double(index)) * .pi * 2) * 4
            let y = surfaceY + 14 + bob + Double(index) * 6
            let radius = 2.5 + Double(index % 3)
            let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: rect), with: .color(PensieveTheme.mercuryBright.opacity(0.5)))
        }
    }

    private func mercuryPath(width: CGFloat, height: CGFloat, surfaceY: CGFloat, phase: Double) -> Path {
        var path = Path()
        let amplitude: CGFloat = 7
        let steps = 48
        path.move(to: CGPoint(x: 0, y: height))
        path.addLine(to: CGPoint(x: 0, y: surfaceY))
        for step in 0...steps {
            let progress = CGFloat(step) / CGFloat(steps)
            let x = progress * width
            let wave1 = sin(progress * .pi * 2 + CGFloat(phase) * .pi * 2) * amplitude
            let wave2 = sin(progress * .pi * 3 - CGFloat(phase) * .pi * 2) * (amplitude * 0.5)
            path.addLine(to: CGPoint(x: x, y: surfaceY + wave1 + wave2))
        }
        path.addLine(to: CGPoint(x: width, y: height))
        path.closeSubpath()
        return path
    }

    private func sheenBand(width: CGFloat, surfaceY: CGFloat, phase: Double) -> Path {
        let bandWidth = width * 0.35
        let x = (CGFloat(phase) * (width + bandWidth)) - bandWidth
        return Path(roundedRect: CGRect(x: x, y: surfaceY + 2, width: bandWidth, height: 5), cornerRadius: 2.5)
    }
}
