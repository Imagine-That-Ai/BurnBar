import SwiftUI

// MARK: - Mascot face
//
// The eyes are the persona. At 52pt the tagline is invisible and the colour
// alone cannot separate ten characters, so the face has to carry the identity
// on its own — which is exactly what the asset's `renderPersonaEyesHtml` does.
//
// The asset implements five of its ten declared styles and lets the other five
// fall through to generic dots. Falling through would mean The Jock, The
// Asshole, Zen Monk, Hacker Cat and Goth Doom are indistinguishable in the one
// place the user actually looks, so all ten are drawn here. The five the asset
// authored are transcribed to its measurements; the five it named are drawn to
// the intent its names and colours describe.
//
// Everything is laid out in a canonical 22 × 14 box and scaled, so one face
// renders correctly in a 52pt orb, a 38pt seat row and an 18pt inline chip.

struct PlasmaPersonaFace: View {
    let persona: PlasmaPersona
    /// Width of the eye cluster in points.
    var width: CGFloat
    /// `@keyframes eyeGlance` offset, in the asset's authoring units.
    var glance: CGSize = .zero
    /// `@keyframes eyeBlink` lid squash.
    var blinkScaleY: CGFloat = 1

    private static let designWidth: CGFloat = 22
    private static let designHeight: CGFloat = 14

    private var scale: CGFloat { width / Self.designWidth }

    var body: some View {
        eyes
            .frame(width: Self.designWidth, height: Self.designHeight)
            // The lid closes over the eye, so the squash has to happen before
            // the cluster is displaced by the glance — otherwise a blink at the
            // edge of a glance shears instead of shutting.
            .scaleEffect(y: blinkScaleY, anchor: .center)
            .offset(x: glance.width, y: glance.height)
            .scaleEffect(scale)
            .frame(width: width, height: Self.designHeight * scale)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var eyes: some View {
        switch persona.eyeStyle {
        case .sunglasses: sunglasses
        case .glasses: glasses
        case .sparkle: sparkle(lashes: 1)
        case .eyelash: sparkle(lashes: 3)
        case .halflid: halflid
        case .fierce: fierce
        case .squint: squint
        case .serene: serene
        case .slit: slit
        case .eyeliner: eyeliner
        }
    }

    // MARK: Authored by the asset

    /// Bad Boi. A single dark visor with two lenses and a bridge, lit along the
    /// top edge so it reads as glass rather than a hole.
    private var sunglasses: some View {
        HStack(spacing: 3) {
            lens
            Rectangle()
                .fill(Color(hex: "a1a1aa"))
                .frame(width: 2, height: 1)
            lens
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(hex: "09090b"))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(.white.opacity(0.2), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.6), radius: 2.5, y: 2)
        }
    }

    private var lens: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Color(hex: "18181b"))
            .frame(width: 6, height: 5)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color(hex: "71717a"))
                    .frame(height: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
    }

    /// The Nerd. Wire rims with a bright lens wash and a small hard pupil.
    private var glasses: some View {
        HStack(spacing: 2.5) {
            wireRim
            Rectangle().fill(.black).frame(width: 2, height: 1)
            wireRim
        }
    }

    private var wireRim: some View {
        Circle()
            .fill(.white.opacity(0.4))
            .overlay { Circle().strokeBorder(.black, lineWidth: 1.2) }
            .overlay {
                Circle()
                    .fill(persona.eyeColor)
                    .frame(width: 2.5, height: 2.5)
            }
            .frame(width: 7, height: 7)
    }

    /// Nice Girl (one lash) and Barbie Diva (a full fan). Tall oval eyes with a
    /// catchlight high on the outer edge.
    private func sparkle(lashes: Int) -> some View {
        HStack(spacing: 4) {
            lashEye(lashes: lashes, mirrored: true)
            lashEye(lashes: lashes, mirrored: false)
        }
    }

    private func lashEye(lashes: Int, mirrored: Bool) -> some View {
        Ellipse()
            .fill(persona.eyeColor)
            .frame(width: 6.5, height: 9.5)
            .overlay(alignment: .top) {
                // The lashes fan from the outer corner, which is what gives the
                // eye its direction — both eyes lashed inward would read cross-
                // eyed.
                HStack(spacing: 1) {
                    ForEach(0..<max(1, lashes), id: \.self) { index in
                        Capsule()
                            .fill(persona.eyeColor)
                            .frame(width: 3, height: 1)
                            .rotationEffect(.degrees(-30 + Double(index) * 18))
                    }
                }
                .offset(y: -1.5)
                .scaleEffect(x: mirrored ? -1 : 1)
            }
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(persona.eyeCatch)
                    .frame(width: 2.5, height: 2.5)
                    .padding(1)
            }
    }

    /// The Smoker. Lids down to half-mast, and the cigarette ember he is never
    /// without.
    private var halflid: some View {
        HStack(spacing: 4) {
            lidEye
            lidEye
        }
        .overlay(alignment: .trailing) {
            Capsule()
                .fill(Color(hex: "fdba74"))
                .frame(width: 5, height: 1.5)
                .shadow(color: Color(hex: "ea580c"), radius: 4)
                .offset(x: 5, y: 1)
        }
    }

    private var lidEye: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 7,
            bottomTrailingRadius: 7,
            topTrailingRadius: 0,
            style: .continuous
        )
        .fill(persona.eyeColor)
        .frame(width: 7, height: 5)
        .overlay(alignment: .bottomTrailing) {
            Circle()
                .fill(persona.eyeCatch)
                .frame(width: 2.5, height: 2.5)
                .padding(1)
        }
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 7,
                bottomTrailingRadius: 7,
                topTrailingRadius: 0,
                style: .continuous
            )
        )
    }

    // MARK: Named by the asset, drawn here

    /// The Jock. Heavy brows driving down toward the nose over compact eyes —
    /// the universal shorthand for effort.
    private var fierce: some View {
        HStack(spacing: 4) {
            browEye(browAngle: 18)
            browEye(browAngle: -18)
        }
    }

    private func browEye(browAngle: Double) -> some View {
        VStack(spacing: 1) {
            Capsule()
                .fill(persona.eyeColor)
                .frame(width: 7.5, height: 1.8)
                .rotationEffect(.degrees(browAngle))
            Ellipse()
                .fill(persona.eyeColor)
                .frame(width: 6, height: 5.5)
                .overlay(alignment: .top) {
                    Circle()
                        .fill(persona.eyeCatch)
                        .frame(width: 2, height: 2)
                        .padding(.top, 0.8)
                }
        }
    }

    /// The Asshole. Flat, narrow, unimpressed.
    private var squint: some View {
        HStack(spacing: 4) {
            squintEye
            squintEye
        }
    }

    private var squintEye: some View {
        Capsule()
            .fill(persona.eyeColor)
            .frame(width: 7.5, height: 3)
            .overlay(alignment: .leading) {
                Circle()
                    .fill(persona.eyeCatch)
                    .frame(width: 1.8, height: 1.8)
                    .padding(.leading, 1.2)
            }
    }

    /// Zen Monk. Eyes closed in contentment — two upward arcs, the only face in
    /// the cast that is not looking at you.
    private var serene: some View {
        HStack(spacing: 4) {
            SereneArc()
                .stroke(persona.eyeColor, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                .frame(width: 7, height: 4)
            SereneArc()
                .stroke(persona.eyeColor, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                .frame(width: 7, height: 4)
        }
    }

    /// Hacker Cat. Round eyes with vertical slit pupils that widen on interest.
    private var slit: some View {
        HStack(spacing: 4) {
            slitEye
            slitEye
        }
    }

    private var slitEye: some View {
        Circle()
            .fill(persona.eyeCatch)
            .frame(width: 7, height: 7)
            .overlay {
                Capsule()
                    .fill(persona.eyeColor)
                    .frame(width: 2, height: 6)
            }
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(.white.opacity(0.9))
                    .frame(width: 1.6, height: 1.6)
                    .padding(1)
            }
    }

    /// Goth Doom. Almond eyes with a winged flick off the outer corner.
    private var eyeliner: some View {
        HStack(spacing: 4) {
            wingedEye(mirrored: true)
            wingedEye(mirrored: false)
        }
    }

    private func wingedEye(mirrored: Bool) -> some View {
        Ellipse()
            .fill(persona.eyeColor)
            .frame(width: 6.5, height: 8)
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(persona.eyeCatch)
                    .frame(width: 2, height: 2)
                    .padding(1)
            }
            .overlay(alignment: .topTrailing) {
                Capsule()
                    .fill(persona.eyeColor)
                    .frame(width: 4.5, height: 1.4)
                    .rotationEffect(.degrees(-28))
                    .offset(x: 2.6, y: -0.6)
            }
            .scaleEffect(x: mirrored ? -1 : 1)
    }
}

/// A shallow upward arc — a closed, smiling eye.
private struct SereneArc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.6)
        )
        return path
    }
}
