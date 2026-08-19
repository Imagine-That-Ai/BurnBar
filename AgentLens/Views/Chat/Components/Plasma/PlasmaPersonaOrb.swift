import SwiftUI

// MARK: - The mascot orb
//
// The asset's left-hand orb: a living plasma sphere with a *face*. It picks
// which persona voice the agent answers in.
//
// The face is the reason this control exists. A dropdown reading "Analyst" is
// a word; an orb that looks back at you, glances around while it waits and
// blinks on its own schedule is a character, and the character is what makes a
// persona feel like a choice rather than a setting. All ten eye styles are
// drawn (`PlasmaPersonaFace`), so the ten personas are distinguishable at 52pt
// without reading a label — which is the whole test for a mascot.

struct PlasmaPersonaOrb: View {
    var seat: PlasmaSeat?
    var roster: [PlasmaSeat]
    var size: CGFloat = 34
    /// Bubbles rise out of the orb while the agent is composing an answer.
    var isThinking: Bool
    var onSelect: (PlasmaSeat?) -> Void
    var onCreate: (String, String) -> Void
    var onDelete: (String) -> Void

    @State private var isOpen = false
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Idle is still. This orb sits beside a transcript all day; it earns motion
    /// by being hovered, opened, or by the agent actually working.
    private var animates: Bool { (isHovering || isOpen || isThinking) && !reduceMotion }

    var body: some View {
        Button { isOpen.toggle() } label: {
            PlasmaClock(isRunning: animates) { tick in
                ZStack {
                    orb(tick: tick)
                    if isThinking {
                        PlasmaThinkingEmitter(tint: tint, orbSize: size, tick: tick)
                    }
                }
                .frame(width: size, height: size)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(helpText)
        .accessibilityLabel("Persona")
        .accessibilityValue(seat?.label ?? "None")
        .accessibilityHint("Choose the voice this agent answers in")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            PlasmaPersonaPicker(
                roster: roster,
                selectedSeatID: seat?.id,
                onSelect: { picked in
                    onSelect(picked)
                    isOpen = false
                },
                onCreate: onCreate,
                onDelete: onDelete
            )
        }
    }

    private var persona: PlasmaPersona? { seat?.persona }
    private var tint: Color { persona?.color ?? DesignSystem.Colors.textMuted }

    private var helpText: String {
        guard let persona else { return "No persona · the agent uses its own voice" }
        return "\(persona.name) · \(persona.tagline)"
    }

    @ViewBuilder
    private func orb(tick: PlasmaTick) -> some View {
        let blob = tick.isAnimating ? PlasmaBlobMotion.orbPrimary.state(at: tick.date) : .still
        let glow = tick.isAnimating ? PlasmaGlowBreath.state(at: tick.date) : .still
        let offset = PlasmaBlobMotion.orbPrimary.translation(blob, renderedSize: size)
        let shape = PlasmaBlobShape(radii: blob.radii)

        ZStack {
            // `filter: drop-shadow(0 0 14px glow) drop-shadow(0 0 28px glow)`.
            Circle()
                .fill(tint)
                .blur(radius: size * 0.30)
                .scaleEffect(glow.scale)
                .opacity(Double(glow.opacity) * (persona == nil ? 0.25 : 0.55))

            shape
                .fill(fill)
                .overlay {
                    // `.pure-plasma-core-glow` rides `plasmaGlowBreath`. CSS
                    // brightens it with `filter: brightness()`, which has no
                    // SwiftUI equal that composites correctly through a
                    // material; an additive white veil at the same amplitude is
                    // the honest translation.
                    shape.fill(.white.opacity(Double(glow.emissiveOpacity) * 0.55))
                        .blendMode(.plusLighter)
                }
                .overlay {
                    // `inset 0 -3px 6px rgba(0,0,0,0.6)` — the weight that
                    // stops the orb reading as a flat sticker.
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.62), .clear, .black.opacity(0.34)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                }
                .overlay { face(tick: tick) }
                .shadow(color: tint.opacity(0.5), radius: size * 0.24, y: size * 0.08)
        }
        .frame(width: size, height: size)
        .scaleEffect(x: blob.scaleWidth, y: blob.scaleHeight)
        .rotationEffect(.degrees(blob.rotationDegrees))
        .offset(x: offset.width, y: offset.height)
        .scaleEffect(isHovering ? 1.10 : 1)
        .animation(DesignSystem.Animation.hover, value: isHovering)
    }

    private var fill: RadialGradient {
        guard let persona else {
            return RadialGradient(
                gradient: Gradient(colors: [
                    DesignSystem.Colors.surfaceElevated,
                    DesignSystem.Colors.surface
                ]),
                center: UnitPoint(x: 0.35, y: 0.30),
                startRadius: 0,
                endRadius: size * 0.7
            )
        }
        return RadialGradient(
            gradient: persona.gradient,
            center: UnitPoint(x: 0.35, y: 0.30),
            startRadius: 0,
            endRadius: size * 0.7
        )
    }

    @ViewBuilder
    private func face(tick: PlasmaTick) -> some View {
        if let persona {
            // Driven by the orb's clock, not a clock of its own. The eyes run
            // their own *tracks* — a 5s glance and a 5.9s blink, chosen not to
            // divide into each other so the face never settles into a loop the
            // eye can predict — but they share the orb's timeline, so a resting
            // orb costs nothing and a live one blinks.
            let glance = tick.isAnimating ? PlasmaEyeMotion.glance(at: tick.date) : .zero
            let blink = tick.isAnimating ? PlasmaEyeMotion.blinkScaleY(at: tick.date) : 1
            PlasmaPersonaFace(
                persona: persona,
                width: size * 0.52,
                // The glance offsets are authored against a 52pt orb.
                glance: CGSize(width: glance.width * size / 52, height: glance.height * size / 52),
                blinkScaleY: blink
            )
        } else {
            Image(systemName: "person.crop.circle.dashed")
                .font(.system(size: size * 0.42, weight: .light))
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
    }
}

// MARK: - Thinking bubbles

/// The asset's `riseAndPopBubble1…3`: three droplets that rise out of the orb
/// and pop while the agent composes.
///
/// This replaces a spinner with something that says the same thing and belongs
/// to the character: the orb is *working*, visibly, in its own idiom.
struct PlasmaThinkingEmitter: View {
    var tint: Color
    var orbSize: CGFloat
    var tick: PlasmaTick

    var body: some View {
        ZStack {
            ForEach(Array(PlasmaThinkingBubble.all.enumerated()), id: \.offset) { index, bubble in
                let state = tick.isAnimating ? bubble.state(at: tick.date) : .hidden
                Circle()
                    .fill(tint.opacity(0.55))
                    .overlay { Circle().strokeBorder(.white.opacity(0.5), lineWidth: 0.5) }
                    .frame(width: bubble.diameter, height: bubble.diameter)
                    .scaleEffect(state.scale)
                    .opacity(state.opacity)
                    .offset(
                        x: state.offset.width + CGFloat(index - 1) * 4,
                        y: state.offset.height - orbSize * 0.42
                    )
            }
        }
        .allowsHitTesting(false)
    }
}
