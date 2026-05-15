import SwiftUI
import OpenBurnBarCore

// MARK: - Firefighter Helmet
//
// The Pro brand mark. A stylized firefighter helmet — three layers
// (back brim, dome, leather front shield) plus a flame insignia and a
// brass ridge along the top.
//
// Why a firefighter helmet? OpenBurnBar's vocabulary is fire (ember, amber,
// blaze, burn). The Cloud surface is where your fires are tended for you.
// A helmet ties the brand to the destination in one glance — and reads
// instantly as something to be earned, not a generic dot.
//
// Pure SwiftUI. Scales gracefully from 24pt (nav tray) to 96pt (hero).
// Honors `accessibilityReduceMotion` by freezing the flicker.

struct FirefighterHelmet: View {
    enum Size {
        case small   // 28pt — nav tray, list rows
        case medium  // 48pt — member row, store hero badge
        case large   // 96pt — destination hero

        var diameter: CGFloat {
            switch self {
            case .small:  return 28
            case .medium: return 48
            case .large:  return 96
            }
        }
    }

    var size: Size = .medium
    var glow: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var d: CGFloat { size.diameter }

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? .infinity : 1.0/30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let flicker = (sin(t * 2.1) + 1) / 2          // 0..1
            let highlightDrift = sin(t * 0.6) * 0.10      // -0.10..+0.10

            ZStack {
                if glow {
                    outerEmberGlow(intensity: 0.55 + flicker * 0.25)
                }

                // 1. Back brim — a flatter ellipse sitting below + slightly
                //    behind the dome. Defines the firefighter silhouette.
                backBrim

                // 2. The dome itself. Black/charcoal leather with a warm
                //    brass bevel + drifting top-left specular blob.
                dome(highlightDrift: highlightDrift)

                // 3. Brass ridge / comb along the centerline. Catches light.
                topRidge

                // 4. The front leather shield — heater-shape escutcheon with
                //    flame insignia. The hero detail.
                frontShield(flicker: flicker)
            }
            .frame(width: d * 1.55, height: d * 1.30)
            .accessibilityHidden(true)
        }
    }

    // MARK: - 1. Back brim

    private static let brimLeatherColors: [Color] = [
        Color(red: 0.18, green: 0.15, blue: 0.13),
        Color(red: 0.32, green: 0.26, blue: 0.20),
        Color(red: 0.10, green: 0.08, blue: 0.06)
    ]

    private var brimLeather: LinearGradient {
        LinearGradient(colors: Self.brimLeatherColors, startPoint: .top, endPoint: .bottom)
    }

    private var brimStroke: LinearGradient {
        LinearGradient(
            colors: [
                UnifiedDesignSystem.Colors.hermesAureate.opacity(0.85),
                UnifiedDesignSystem.Colors.amber.opacity(0.55),
                Color.black.opacity(0.6)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var backBrim: some View {
        let strokeWidth = max(0.6, d * 0.018)
        return Ellipse()
            .fill(brimLeather)
            .overlay(Ellipse().stroke(brimStroke, lineWidth: strokeWidth))
            .frame(width: d * 1.40, height: d * 0.46)
            .shadow(color: Color.black.opacity(0.55), radius: d * 0.05, y: d * 0.04)
            .offset(y: d * 0.30)
    }

    // MARK: - 2. Dome

    private static let domeLeatherColors: [Color] = [
        Color(red: 0.18, green: 0.12, blue: 0.10),
        Color(red: 0.07, green: 0.05, blue: 0.05),
        Color(red: 0.04, green: 0.03, blue: 0.03)
    ]

    private var domeBrassStroke: LinearGradient {
        LinearGradient(
            colors: [
                UnifiedDesignSystem.Colors.hermesAureate.opacity(0.95),
                UnifiedDesignSystem.Colors.amber.opacity(0.8),
                UnifiedDesignSystem.Colors.blaze.opacity(0.5)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func domeLeather(highlightDrift: Double) -> RadialGradient {
        RadialGradient(
            colors: Self.domeLeatherColors,
            center: UnitPoint(x: 0.42 + CGFloat(highlightDrift), y: 0.34),
            startRadius: d * 0.05,
            endRadius: d * 0.55
        )
    }

    private func dome(highlightDrift: Double) -> some View {
        let strokeWidth = max(0.8, d * 0.022)
        return ZStack {
            // Base — black leather with a warm sheen
            Circle().fill(domeLeather(highlightDrift: highlightDrift))
            // Brass rim
            Circle().stroke(domeBrassStroke, lineWidth: strokeWidth)
            // Specular highlight blob
            Circle()
                .fill(Color.white.opacity(0.32))
                .frame(width: d * 0.30, height: d * 0.18)
                .blur(radius: d * 0.05)
                .offset(x: -d * 0.20 + CGFloat(highlightDrift) * d * 0.3, y: -d * 0.22)
                .blendMode(.plusLighter)
            // Side-ridge glint
            Capsule()
                .fill(Color.white.opacity(0.18))
                .frame(width: d * 0.04, height: d * 0.18)
                .rotationEffect(.degrees(-22))
                .offset(x: d * 0.30, y: -d * 0.04)
                .blendMode(.plusLighter)
        }
        .frame(width: d, height: d)
    }

    // MARK: - 3. Top ridge / comb

    private var topRidgeBrass: LinearGradient {
        LinearGradient(
            colors: [
                UnifiedDesignSystem.Colors.hermesAureate,
                UnifiedDesignSystem.Colors.amber,
                UnifiedDesignSystem.Colors.hermesAureate
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var topRidge: some View {
        // A short brass comb that runs along the top center of the dome,
        // suggesting the fore-and-aft helmet comb.
        let height = max(1.4, d * 0.045)
        return Capsule(style: .continuous)
            .fill(topRidgeBrass)
            .frame(width: d * 0.70, height: height)
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.black.opacity(0.35), lineWidth: 0.4)
            )
            .shadow(color: UnifiedDesignSystem.Colors.amber.opacity(0.55), radius: d * 0.06)
            .offset(y: -d * 0.48)
    }

    // MARK: - 4. Front leather shield with flame

    private static let shieldLeatherColors: [Color] = [
        Color(red: 0.62, green: 0.10, blue: 0.10),
        Color(red: 0.42, green: 0.06, blue: 0.05),
        Color(red: 0.22, green: 0.02, blue: 0.02)
    ]

    private var shieldLeather: LinearGradient {
        LinearGradient(colors: Self.shieldLeatherColors, startPoint: .top, endPoint: .bottom)
    }

    private var shieldBrass: LinearGradient {
        LinearGradient(
            colors: [
                UnifiedDesignSystem.Colors.hermesAureate,
                UnifiedDesignSystem.Colors.amber,
                UnifiedDesignSystem.Colors.blaze.opacity(0.7)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var flameGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color.white,
                UnifiedDesignSystem.Colors.amber,
                UnifiedDesignSystem.Colors.blaze
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func frontShield(flicker: Double) -> some View {
        let shieldW = d * 0.62
        let shieldH = d * 0.74
        let strokeWidth = max(0.8, d * 0.025)
        return ZStack {
            HeaterShieldShape()
                .fill(shieldLeather)
                .overlay(
                    HeaterShieldShape().stroke(shieldBrass, lineWidth: strokeWidth)
                )
                .shadow(color: Color.black.opacity(0.7), radius: d * 0.04, y: d * 0.02)

            Rectangle()
                .fill(UnifiedDesignSystem.Colors.hermesAureate.opacity(0.45))
                .frame(width: shieldW * 0.78, height: max(0.5, d * 0.014))
                .offset(y: -shieldH * 0.22)

            Image(systemName: "flame.fill")
                .font(.system(size: d * 0.34, weight: .heavy))
                .foregroundStyle(flameGradient)
                .shadow(color: UnifiedDesignSystem.Colors.amber.opacity(0.6 + flicker * 0.4), radius: d * 0.06)
                .offset(y: d * 0.03)
        }
        .frame(width: shieldW, height: shieldH)
        .offset(y: d * 0.07)
    }

    // MARK: - Outer glow

    private func outerEmberGlow(intensity: Double) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        UnifiedDesignSystem.Colors.ember.opacity(0.35 * intensity),
                        UnifiedDesignSystem.Colors.amber.opacity(0.18 * intensity),
                        Color.clear
                    ],
                    center: .center,
                    startRadius: d * 0.30,
                    endRadius: d * 1.1
                )
            )
            .frame(width: d * 2.0, height: d * 2.0)
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
    }
}

// MARK: - Heater Shield Shape
//
// Classic heater-shape escutcheon: rounded shoulders at the top,
// tapering down to a single point at the bottom. The shape that all
// firefighter helmet leather shields share.

private struct HeaterShieldShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height
        p.move(to: CGPoint(x: w * 0.5, y: h))
        p.addCurve(
            to: CGPoint(x: 0, y: h * 0.35),
            control1: CGPoint(x: w * 0.18, y: h * 0.90),
            control2: CGPoint(x: 0, y: h * 0.58)
        )
        p.addCurve(
            to: CGPoint(x: w * 0.5, y: 0),
            control1: CGPoint(x: 0, y: h * 0.12),
            control2: CGPoint(x: w * 0.20, y: 0)
        )
        p.addCurve(
            to: CGPoint(x: w, y: h * 0.35),
            control1: CGPoint(x: w * 0.80, y: 0),
            control2: CGPoint(x: w, y: h * 0.12)
        )
        p.addCurve(
            to: CGPoint(x: w * 0.5, y: h),
            control1: CGPoint(x: w, y: h * 0.58),
            control2: CGPoint(x: w * 0.82, y: h * 0.90)
        )
        p.closeSubpath()
        return p
    }
}

// MARK: - Preview

#Preview("Firefighter Helmet — sizes") {
    ZStack {
        Color.black.ignoresSafeArea()
        HStack(spacing: 28) {
            FirefighterHelmet(size: .small)
            FirefighterHelmet(size: .medium)
            FirefighterHelmet(size: .large)
        }
    }
}

#Preview("Helmet on warm card") {
    ZStack {
        LinearGradient(
            colors: [
                UnifiedDesignSystem.Colors.ember.opacity(0.4),
                UnifiedDesignSystem.Colors.amber.opacity(0.3),
                UnifiedDesignSystem.Colors.blaze.opacity(0.25)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
        FirefighterHelmet(size: .large)
    }
}
