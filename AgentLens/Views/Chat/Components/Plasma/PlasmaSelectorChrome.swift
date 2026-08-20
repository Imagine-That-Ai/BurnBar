import AppKit
import SwiftUI

// MARK: - Plasma chrome
//
// The view layer of the "Liquid Plasma Floating Selectors" brand asset: the
// living orb, the ghostly liquid-glass bubble, the floating pill rows, the back
// pill and the step header. Everything here is domain-free, so the same chrome
// can dress a second ladder later without dragging chat state along.
//
// TWO DELIBERATE DEPARTURES FROM THE ASSET
//
// 1. **Idle is still.** The asset morphs its orbs forever. Chat chrome is
//    furniture that sits on screen all day beside a transcript someone is
//    reading, so the trigger orb holds a still silhouette until it is hovered,
//    open, or the agent is actually answering. Inside the bubble — a transient
//    surface the user opened on purpose — everything breathes. Full delight at
//    the moment of interaction, zero idle GPU wake-ups.
// 2. **Brand colour comes from the app, not the asset.** The asset ships a
//    fixed slate/cyan palette. Here every glow is the real identity already in
//    the app: `ChatBackendID.sigilTint` per agent, `DesignSystem.Colors`
//    `.primary(for:)` per provider, `.colorForModel` per model. Same living
//    form, honest colour.

// MARK: - Shading

enum PlasmaShade {
    /// A darker sibling of `color`, used for the orb's deep core.
    static func deep(_ color: Color, fraction: CGFloat = 0.42) -> Color {
        blended(color, with: .black, fraction: fraction)
    }

    /// A brighter sibling of `color`, used for the specular highlight so a
    /// near-black identity tint (Warp, xAI) still reads as a lit sphere.
    static func lit(_ color: Color, fraction: CGFloat = 0.72) -> Color {
        blended(color, with: .white, fraction: fraction)
    }

    /// A halo's opacity for the current theme.
    ///
    /// A wide, soft halo that reads as *light* against a dark surface reads as
    /// a smudge against a white one: the blur is identical, but on white there
    /// is no headroom above the background left for it to glow into. Every
    /// halo in these selectors is attenuated by the same factor rather than
    /// each surface choosing its own, so the persona orb and the model orb
    /// cannot drift apart as either is retuned.
    static func halo(_ darkOpacity: Double, in colorScheme: ColorScheme) -> Double {
        colorScheme == .dark ? darkOpacity : darkOpacity * 0.64
    }

    private static func blended(_ color: Color, with other: NSColor, fraction: CGFloat) -> Color {
        guard let base = NSColor(color).usingColorSpace(.sRGB),
              let target = other.usingColorSpace(.sRGB),
              let mixed = base.blended(withFraction: fraction, of: target) else {
            return color
        }
        return Color(nsColor: mixed)
    }
}

// MARK: - Living plasma orb

/// A single amorphous, self-lit plasma orb with iOS Liquid Glass aesthetics.
struct PlasmaOrb<Content: View>: View {
    var tint: Color
    var size: CGFloat
    var motion: PlasmaBlobMotion = .orbSecondary
    /// Drives both the silhouette morph and the aura breath. Ignored when
    /// `tick` is supplied, because then the surface's clock is already saying
    /// whether motion is running.
    var isAnimating: Bool = true
    /// A frame handed down from an enclosing ``PlasmaClock``. Supply it whenever
    /// more than one orb is on screen: a constellation of twelve orbs each
    /// owning a private `TimelineView` is twelve display-link wake-ups and
    /// twelve invalidations per frame for one picture.
    var tick: PlasmaTick?
    /// Dimmed, deflated presentation for an agent that cannot answer right now.
    var isDormant: Bool = false
    /// Displaces this orb along its loop, in turns. A field of orbs sharing one
    /// clock would pulse in unison and read as a grid; walking the phase per
    /// orb is what makes the terrarium look alive.
    var phaseOffset: CGFloat = 0
    @ViewBuilder var content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private var animates: Bool { isAnimating && !reduceMotion }

    var body: some View {
        // Resolved before the clock, not inside it. The sphere and the aura
        // both paint this gradient, and each build runs three `PlasmaShade`
        // blends through AppKit colour-space conversion — six per orb, which at
        // 30fps across a field of orbs is pure waste for a value that only
        // changes when the tint does. Same reasoning for `content()`: a
        // provider logo re-resolves its asset candidates on every call.
        let paint = gradient
        let mark = content()
        return Group {
            if let tick {
                pose(tick, paint: paint, mark: mark)
            } else {
                PlasmaClock(isRunning: animates) { ownTick in
                    pose(ownTick, paint: paint, mark: mark)
                }
            }
        }
        .frame(width: size, height: size)
        .opacity(isDormant ? 0.45 : 1)
        .saturation(isDormant ? 0.25 : 1)
    }

    @ViewBuilder
    private func pose(_ tick: PlasmaTick, paint: RadialGradient, mark: Content) -> some View {
        let blob = tick.isAnimating ? motion.state(at: tick.date, phaseOffset: phaseOffset) : .still
        let breath = tick.isAnimating ? Self.breath(at: tick.date, phaseOffset: phaseOffset) : 0
        let offset = motion.translation(blob, renderedSize: size)

        ZStack {
            ZStack {
                aura(breath: breath, paint: paint)
                sphere(blob: blob, paint: paint)
            }
            .frame(width: size, height: size)
            .scaleEffect(x: blob.scaleWidth, y: blob.scaleHeight)
            .rotationEffect(.degrees(blob.rotationDegrees))

            // The plasma spins; the mark inside it does not. A tumbling
            // provider logo reads as a bug, not as life.
            PlasmaEmissiveMark(size: size, isDimmed: isDormant) { mark }
        }
        .frame(width: size, height: size)
        .offset(x: offset.width, y: offset.height)
    }

    /// iOS Liquid Glass Sphere:
    /// Ultra-smooth radial depth, 1px top specular highlight arc, and ambient refraction.
    private func sphere(blob: PlasmaBlobState, paint: RadialGradient) -> some View {
        PlasmaBlobShape(radii: blob.radii)
            .fill(paint)
            .overlay {
                // Liquid Glass inner reflection: crisp top specular highlight & bottom bounce
                PlasmaBlobShape(radii: blob.radii)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.75),
                                .white.opacity(0.25),
                                .clear,
                                .black.opacity(0.20)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.0
                    )
            }
            .overlay {
                // Top-left glossy meniscus reflection
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.white.opacity(0.40), .white.opacity(0)],
                            center: .center,
                            startRadius: 0,
                            endRadius: size * 0.35
                        )
                    )
                    .frame(width: size * 0.55, height: size * 0.35)
                    .offset(x: -size * 0.12, y: -size * 0.18)
                    .allowsHitTesting(false)
            }
            .shadow(color: tint.opacity(isDormant ? 0.10 : 0.45), radius: size * 0.25, y: size * 0.10)
            .shadow(color: .black.opacity(0.20), radius: size * 0.15, y: size * 0.08)
    }

    /// Serene ambient liquid aura glow — soft and calm.
    private func aura(breath: CGFloat, paint: RadialGradient) -> some View {
        Circle()
            .fill(paint)
            // Fixed radius on purpose. Breathing the blur re-runs an offscreen
            // pass every frame; breathing scale and opacity is free, and at
            // ±0.06·size the two are indistinguishable.
            .blur(radius: size * 0.19)
            .scaleEffect(0.98 + 0.08 * breath)
            .opacity((auraBase + 0.10 * breath) * (isDormant ? 0.2 : 1))
            .allowsHitTesting(false)
    }

    private var auraBase: Double { PlasmaShade.halo(0.60, in: colorScheme) }

    private var gradient: RadialGradient {
        RadialGradient(
            gradient: Gradient(stops: [
                .init(color: PlasmaShade.lit(tint, fraction: 0.55), location: 0),
                .init(color: tint, location: 0.50),
                .init(color: PlasmaShade.deep(tint, fraction: 0.40), location: 0.85),
                .init(color: PlasmaShade.deep(tint, fraction: 0.60).opacity(0.85), location: 1)
            ]),
            center: UnitPoint(x: 0.35, y: 0.32),
            startRadius: 0,
            endRadius: size * 0.65
        )
    }

    /// The aura's breath, `0…1…0`.
    ///
    /// Slower than the core's 4s `plasmaGlowBreath`: the aura is a wide soft
    /// halo, and matching the core's tempo made the whole orb pump. Eleven
    /// seconds reads as breathing rather than pulsing.
    static func breath(at date: Date, phaseOffset: CGFloat = 0) -> CGFloat {
        let phase = plasmaPhase(at: date, duration: plasmaAuraBreathPeriod) + phaseOffset
        return PlasmaBlobMotion.easeInOut(plasmaTriangle(phase))
    }
}

extension PlasmaOrb where Content == EmptyView {
    init(
        tint: Color,
        size: CGFloat,
        motion: PlasmaBlobMotion = .orbSecondary,
        isAnimating: Bool = true,
        tick: PlasmaTick? = nil,
        isDormant: Bool = false,
        phaseOffset: CGFloat = 0
    ) {
        self.init(
            tint: tint,
            size: size,
            motion: motion,
            isAnimating: isAnimating,
            tick: tick,
            isDormant: isDormant,
            phaseOffset: phaseOffset
        ) { EmptyView() }
    }
}

// MARK: - Emissive mark

/// A brand mark lit *from inside* the glass.
///
/// The asset's orbs do not paste their logo on top of the sphere — the mark
/// sits in the plasma and glows with it, which is what stops a 52pt orb reading
/// as a sticker with an icon on it. The asset gets this from a `filter:
/// drop-shadow()` stack in the mark's own colour.
///
/// The translation is a blurred copy of the mark's *own pixels* composited
/// underneath it, so every logo blooms in its own hue with no per-brand colour
/// table to keep in sync: the flame glows orange, the bolt blue, and a brand
/// that reskins its asset reskins its glow with it.
struct PlasmaEmissiveMark<Mark: View>: View {
    /// The host orb's diameter. The bloom is a fraction of it, so one mark
    /// renders correctly in a 52pt constellation orb and a 24pt trigger.
    var size: CGFloat
    /// Drops the bloom entirely for an orb that is dormant or impaired — a
    /// glowing mark on a dimmed orb would announce exactly the wrong state.
    var isDimmed: Bool = false
    @ViewBuilder var mark: () -> Mark

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Built once and drawn twice. `mark()` re-resolves a provider logo's
        // asset candidates on every call, and this view is rebuilt on every
        // tick of the host's clock.
        let built = mark()
        return ZStack {
            built
                .blur(radius: size * 0.09)
                .opacity(isDimmed ? 0 : bloomOpacity)
                .blendMode(colorScheme == .dark ? .plusLighter : .normal)
            built
        }
        .allowsHitTesting(false)
    }

    /// Additive light is only additive where there is room above the backdrop
    /// to add to. On a light surface `plusLighter` drives the bloom straight to
    /// white and eats the logo it is supposed to be lighting, so light mode
    /// composites a softer halo normally instead.
    private var bloomOpacity: Double { colorScheme == .dark ? 0.85 : 0.40 }
}

// MARK: - Ghostly liquid glass bubble

/// The billowing container the ladder lives in.
struct PlasmaGhostBubble<Content: View>: View {
    var isAnimating: Bool = true
    /// Tints the rim and the wash with the active agent's identity, so the
    /// bubble belongs to whoever is answering.
    var tint: Color
    @ViewBuilder var content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private var animates: Bool { isAnimating && !reduceMotion }

    var body: some View {
        // Built once, outside the clock. `content()` here is an entire ladder;
        // re-invoking it on every tick would rebuild the provider catalog 30
        // times a second to draw a list that has not changed. The morph only
        // needs to re-wrap an already-built view value.
        let built = content()
        return PlasmaClock(isRunning: animates) { tick in
            let blob = tick.isAnimating ? PlasmaBlobMotion.bubble.state(at: tick.date) : .still
            let shape = PlasmaBlobShape(radii: blob.radii, cornerCap: 30)

            built
                .background {
                    shape
                        .fill(.ultraThinMaterial)
                        .overlay { shape.fill(wash) }
                        .shadow(color: .black.opacity(colorScheme == .dark ? 0.6 : 0.22), radius: 26, y: 12)
                }
                .overlay {
                    // Specular glass rim: lit along the top-leading edge,
                    // shadowed along the bottom-trailing one.
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [
                                .white.opacity(colorScheme == .dark ? 0.42 : 0.85),
                                tint.opacity(0.32),
                                .black.opacity(colorScheme == .dark ? 0.35 : 0.12)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.5
                    )
                    .mercuryShimmer(active: animates)
                }
                .clipShape(shape)
                .scaleEffect(x: blob.scaleWidth, y: blob.scaleHeight)
                .rotationEffect(.degrees(blob.rotationDegrees))
                .offset(y: blob.translation.height)
        }
    }

    private var wash: RadialGradient {
        RadialGradient(
            gradient: Gradient(colors: [
                DesignSystem.Colors.surfaceElevated.opacity(colorScheme == .dark ? 0.88 : 0.94),
                DesignSystem.Colors.surface.opacity(colorScheme == .dark ? 0.94 : 0.97),
                DesignSystem.Colors.background.opacity(colorScheme == .dark ? 0.97 : 0.99)
            ]),
            center: UnitPoint(x: 0.25, y: 0.20),
            startRadius: 0,
            endRadius: 420
        )
    }
}

// MARK: - Ladder furniture

/// `STEP 2 · PROVIDERS ON CODEX` — the asset's uppercase tracking-wide eyebrow.
struct PlasmaStepHeader: View {
    var step: Int
    var title: String

    var body: some View {
        Text("STEP \(step) · \(title.uppercased())")
            .font(.system(size: 9.5, weight: .heavy, design: .rounded))
            .tracking(0.9)
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .accessibilityLabel("Step \(step), \(title)")
    }
}

/// `‹ Codex (change)` — walks the ladder back one rung.
struct PlasmaBackPill: View {
    var title: String
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 8, weight: .bold))
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundStyle(isHovering ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.14 : 0.07))
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(DesignSystem.Colors.border.opacity(isHovering ? 0.9 : 0.5), lineWidth: 1)
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(DesignSystem.Animation.hover, value: isHovering)
    }
}

/// A small uppercase tag: `12 models`, `Droid Core quota`, `✓ ACTIVE`.
struct PlasmaTag: View {
    enum Emphasis { case neutral, active, muted }

    var text: String
    var emphasis: Emphasis = .neutral
    var tint: Color = DesignSystem.Colors.ember

    var body: some View {
        Text(text)
            .font(.system(size: 8.5, weight: .heavy, design: .rounded))
            .tracking(0.3)
            .foregroundStyle(foreground)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background {
                Capsule(style: .continuous).fill(background)
            }
            .overlay {
                if emphasis == .active {
                    Capsule(style: .continuous).strokeBorder(tint.opacity(0.55), lineWidth: 1)
                }
            }
            .lineLimit(1)
            .fixedSize()
    }

    private var foreground: Color {
        switch emphasis {
        case .neutral: return DesignSystem.Colors.textSecondary
        // Not the tint. Eight-and-a-half point heavy text over a 20% wash of
        // its own colour is the Containment Law's exact prohibition, and
        // `48E054` / `00E5FF` / `F97316` miss 3:1 on the light surface. The
        // capsule fill and stroke still carry the identity.
        case .active: return DesignSystem.Colors.textPrimary
        case .muted: return DesignSystem.Colors.textMuted
        }
    }

    private var background: Color {
        switch emphasis {
        case .neutral: return Color.primary.opacity(0.07)
        case .active: return tint.opacity(0.20)
        case .muted: return .clear
        }
    }
}

/// One floating liquid glass pill in the ladder with authentic Apple iOS styling.
struct PlasmaGlassRow<Leading: View, Trailing: View>: View {
    var title: String
    var subtitle: String?
    var tint: Color
    var isActive: Bool = false
    var isDisabled: Bool = false
    var action: () -> Void
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private var isLive: Bool { !isDisabled }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                leading()
                    .frame(width: 28, height: 28)
                    .shadow(color: tint.opacity(isDisabled ? 0 : 0.40), radius: 6, y: 2)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(titleColor)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        trailing()
                    }
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(fill)
            }
            .overlay {
                // iOS Liquid Glass specular rim
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                .white.opacity(isHovering ? (colorScheme == .dark ? 0.35 : 0.70) : (isActive ? 0.45 : 0.12)),
                                tint.opacity(isActive ? 0.40 : (isHovering ? 0.25 : 0.05)),
                                .black.opacity(colorScheme == .dark ? 0.25 : 0.05)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.0
                    )
            }
            .overlay(alignment: .leading) {
                // The active rung keeps an elegant 3pt identity pill bar
                if isActive {
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.white.opacity(0.8), tint],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 3.5)
                        .padding(.vertical, 7)
                        .padding(.leading, 3)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .offset(y: isHovering && isLive && !reduceMotion ? -0.8 : 0)
            .scaleEffect(isHovering && isLive && !reduceMotion ? 1.008 : 1, anchor: .center)
            .shadow(color: isHovering && isLive ? tint.opacity(0.18) : .clear, radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { isHovering = $0 && isLive }
        .animation(DesignSystem.Animation.hover, value: isHovering)
        .accessibilityLabel(
            plasmaChoiceAccessibilityLabel(
                title: title,
                subtitle: subtitle,
                isActive: isActive,
                isDisabled: isDisabled
            )
        )
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    private var titleColor: Color {
        if isDisabled { return DesignSystem.Colors.textMuted }
        return DesignSystem.Colors.textPrimary
    }

    private var fill: Color {
        if isActive { return tint.opacity(isHovering ? 0.24 : 0.16) }
        return Color.primary.opacity(isHovering && isLive ? 0.08 : 0.03)
    }
}

/// Both bodies read a choice out loud the same way, so a VoiceOver user hears
/// the identical sentence whether the ladder is drawn as orbs or as pills.
func plasmaChoiceAccessibilityLabel(
    title: String,
    subtitle: String?,
    isActive: Bool,
    isDisabled: Bool
) -> String {
    var parts = [title]
    if let subtitle, !subtitle.isEmpty { parts.append(subtitle) }
    if isActive { parts.append("selected") }
    if isDisabled { parts.append("unavailable") }
    return parts.joined(separator: ", ")
}

extension PlasmaGlassRow where Trailing == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        tint: Color,
        isActive: Bool = false,
        isDisabled: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder leading: @escaping () -> Leading
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            tint: tint,
            isActive: isActive,
            isDisabled: isDisabled,
            action: action,
            leading: leading,
            trailing: { EmptyView() }
        )
    }
}

// MARK: - One choice, two presentations

/// A single selectable thing on any rung of the ladder, carrying its own
/// action.
///
/// The bubble draws its body either as floating orbs or as pill rows, and both
/// read this one list. Deriving the rung twice — once per presentation — is how
/// the two modes silently drifted apart, so the derivation lives in one place
/// and the presentations are dumb.
struct PlasmaChoice: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let tint: Color
    /// Set on the agent rung: draws the agent's own mark rather than a provider
    /// logo, and pairs with `presence`.
    let backend: ChatBackendID?
    let presence: AgentPresence?
    /// Resolves a provider logo when there is no `backend` and no `iconName`.
    let providerID: String?
    /// An SF Symbol that outranks both, for synthetic rows ("Automatic", the
    /// empty-state call to action).
    let iconName: String?
    /// A short count or qualifier the pill body shows beside the title.
    let badge: String?
    let isActive: Bool
    let isDisabled: Bool
    /// Selecting this descends a rung rather than committing a model, so the
    /// pill body earns a chevron.
    let leadsDeeper: Bool
    let action: () -> Void

    init(
        id: String,
        title: String,
        subtitle: String? = nil,
        tint: Color,
        backend: ChatBackendID? = nil,
        presence: AgentPresence? = nil,
        providerID: String? = nil,
        iconName: String? = nil,
        badge: String? = nil,
        isActive: Bool = false,
        isDisabled: Bool = false,
        leadsDeeper: Bool = false,
        action: @escaping () -> Void
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.tint = tint
        self.backend = backend
        self.presence = presence
        self.providerID = providerID
        self.iconName = iconName
        self.badge = badge
        self.isActive = isActive
        self.isDisabled = isDisabled
        self.leadsDeeper = leadsDeeper
        self.action = action
    }

}

/// The glyph at the heart of a choice — agent mark, provider logo, or symbol.
struct PlasmaChoiceMark: View {
    let choice: PlasmaChoice
    var size: CGFloat

    var body: some View {
        if let backend = choice.backend {
            AgentMark(backend: backend, size: size)
        } else if let iconName = choice.iconName {
            Image(systemName: iconName)
                .font(.system(size: size * 0.62, weight: .semibold))
                .foregroundStyle(choice.tint)
        } else if let providerID = choice.providerID, !providerID.isEmpty {
            ProxyProviderLogoView(
                catalogProviderID: providerID,
                providerName: choice.title,
                size: size
            )
        } else {
            Circle()
                .fill(choice.tint.opacity(0.55))
                .frame(width: size * 0.4, height: size * 0.4)
        }
    }
}
