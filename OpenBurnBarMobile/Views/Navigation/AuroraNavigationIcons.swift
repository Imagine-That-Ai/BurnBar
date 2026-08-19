import SwiftUI

// MARK: - Aurora Navigation Icons
//
// Five bespoke vector glyphs for the OpenBurnBar floating tab tray. Each
// icon is composed from primitive Path shapes (no SF Symbols) so we have
// full control over selection morph, gradient fills, and animation curves.
//
// Design rules per icon:
//   • A clean, evocative silhouette readable at 22pt and 28pt
//   • A muted at-rest treatment (single neutral stroke / fill)
//   • A rich selected treatment with the destination's accent gradient
//   • A characteristic flourish driven by `animatableData` so the
//     selection spring IS the click animation (no extra timers)
//
// Selection animations per icon:
//   • Pulse:   area under the curve fades in with a 3-stop ember gradient
//   • Burn:    inner hot core grows from the wick and glows
//   • Streams: three aurora ribbons phase-shift along their path
//   • Hermes:  twin wings spread outward and lift; orb radiates
//   • You:     a halo arc expands above the head

// MARK: - Destinations

enum AuroraNavDestination: String, Hashable, Identifiable, CaseIterable, Codable {
    case pulse
    case burn
    case insights
    case streams
    case hermes
    // The raw values ("inbox", "fleet") are the canonical cross-platform
    // destination ids from docs/mobile-parity/mobile-route-map.json — they
    // must match the Android routes and the `burnbar://` deep-link hosts.
    case inbox
    case fleet
    case you

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pulse:    return "Pulse"
        case .burn:     return "Burn"
        case .insights: return "Insights"
        case .streams:  return "Streams"
        // Plan 2: tab label flips to "Agents" but the enum case stays
        // `.hermes` so existing route strings, deep links, and persisted
        // selection values keep working.
        case .hermes:   return "Agents"
        case .inbox:    return "AI Inbox"
        case .fleet:    return "Fleet"
        case .you:      return "You"
        }
    }

    var trayLabel: String {
        switch self {
        case .pulse:    return "Pulse"
        case .burn:     return "Burn"
        case .insights: return "Insights"
        case .streams:  return "Streams"
        case .hermes:   return "Agents"
        case .inbox:    return "Inbox"
        case .fleet:    return "Fleet"
        case .you:      return "Store"
        }
    }

    /// Destinations offered by the tab-bar editor. `allCases` keeps the
    /// legacy order for default layouts; the editor sorts its add menu itself.
    static var defaultTrayOrder: [AuroraNavDestination] {
        [.pulse, .burn, .insights, .streams, .hermes, .you]
    }

    var accent: Color {
        switch self {
        case .pulse:    return MobileTheme.ember
        case .burn:     return MobileTheme.amber
        case .insights: return MobileTheme.whimsy
        case .streams:  return MobileTheme.whimsy
        case .hermes:   return MobileTheme.hermesAureate
        case .inbox:    return MobileTheme.amber
        case .fleet:    return MobileTheme.success
        case .you:      return MobileTheme.blaze
        }
    }

    var gradient: LinearGradient {
        switch self {
        case .pulse:
            return LinearGradient(
                colors: [MobileTheme.ember, MobileTheme.amber],
                startPoint: .leading,
                endPoint: .trailing
            )
        case .burn:
            return LinearGradient(
                colors: [MobileTheme.amber, MobileTheme.blaze],
                startPoint: .bottom,
                endPoint: .top
            )
        case .insights:
            return LinearGradient(
                colors: [MobileTheme.whimsy, MobileTheme.ember],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .streams:
            return LinearGradient(
                colors: [MobileTheme.whimsy, MobileTheme.whimsy.opacity(0.55)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .hermes:
            return MobileTheme.mercuryGradient
        case .inbox:
            return LinearGradient(
                colors: [MobileTheme.amber, MobileTheme.ember],
                startPoint: .top,
                endPoint: .bottom
            )
        case .fleet:
            return LinearGradient(
                colors: [MobileTheme.success, MobileTheme.whimsy],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .you:
            return LinearGradient(
                colors: [MobileTheme.blaze, MobileTheme.ember],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

// MARK: - Animated Icon View

struct AuroraNavIcon: View {
    let destination: AuroraNavDestination
    let size: CGFloat
    let isSelected: Bool
    let isPressed: Bool
    /// Optional photo URL for the `.you` tab. When provided, renders the
    /// signed-in user's avatar instead of the generic glyph.
    var userPhotoURL: URL?
    /// Display name used to derive initials when no photo is available.
    var userDisplayName: String?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var youHaloRotation: Double = 0

    /// Animation driver — 0 at rest, 1 when selected. Drives the
    /// `animatableData` of every shape so the spring on isSelected
    /// becomes the click animation for free.
    private var progress: CGFloat { isSelected ? 1.0 : 0.0 }

    /// Per-icon idle drivers for icons that benefit from a tiny ambient
    /// motion when selected (TV signal bars, robot eye blink). These are
    /// gated on `isSelected` and `reduceMotion` and use TimelineView so they
    /// don't drive view re-renders elsewhere.

    var body: some View {
        ZStack {
            if isSelected {
                iconGlow
                    .blur(radius: size * 0.22)
                    .opacity(0.55)
                    .scaleEffect(1.18)
            }

            iconContent
                .scaleEffect(isPressed ? 0.88 : (isSelected ? 1.06 : 1.0))
                .animation(
                    reduceMotion
                        ? .easeInOut(duration: 0.18)
                        : .spring(response: 0.36, dampingFraction: 0.70),
                    value: isSelected
                )
                .animation(.spring(response: 0.18, dampingFraction: 0.65), value: isPressed)
        }
        .frame(width: size, height: size)
        .accessibilityLabel(destination.label)
        .accessibilityHidden(true)
    }

    // MARK: Glow halo behind the selected icon

    @ViewBuilder
    private var iconGlow: some View {
        switch destination {
        case .pulse:
            VitalisLineShape()
                .stroke(
                    destination.accent.opacity(0.45),
                    style: StrokeStyle(lineWidth: size * 0.16, lineCap: .round, lineJoin: .round)
                )
        case .burn:
            IgnisOutlineShape()
                .fill(destination.accent.opacity(0.45))
        case .insights, .inbox, .fleet:
            Circle()
                .fill(destination.accent.opacity(0.45))
        case .streams:
            StreamsGlyphShape()
                .fill(destination.accent.opacity(0.45))
        case .hermes:
            HermesGlyphShape()
                .fill(destination.accent.opacity(0.45))
        case .you:
            YouGlyphShape()
                .fill(destination.accent.opacity(0.45))
        }
    }

    // MARK: Per-icon foreground rendering

    @ViewBuilder
    private var iconContent: some View {
        switch destination {
        case .pulse:    pulseIcon
        case .burn:     burnIcon
        case .insights: insightsIcon
        case .streams:  streamsIcon
        case .hermes:   hermesIcon
        case .inbox:    symbolIcon("tray.full.fill")
        case .fleet:    symbolIcon("point.3.connected.trianglepath.dotted")
        case .you:      youIcon
        }
    }

    private var insightsIcon: some View {
        symbolIcon("sparkles.tv.fill")
    }

    /// SF Symbol rendering path shared by the destinations that don't carry a
    /// bespoke vector glyph (Insights precedent). New tab kinds start here and
    /// can graduate to hand-drawn `Path` art later without changing call sites.
    private func symbolIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(
                isSelected ? destination.gradient : LinearGradient(
                    colors: [Color.secondary, Color.secondary.opacity(0.7)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
    }

    // MARK: 1. Pulse — heartbeat curve with a premium brand-gradient fill

    private var pulseIcon: some View {
        ZStack {
            // Area-under-curve fades in with a rich 4-stop ember→amber gradient
            // and a soft peak highlight. The transition combines opacity, a
            // slight upward scale (anchor: .bottom) so it appears to "fill in"
            // from the baseline, and a clipping mask handled implicitly by
            // the shape itself. A subtle white rim at the very top sells the
            // glassy specular finish.
            if isSelected {
                ZStack {
                    VitalisAreaShape()
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: MobileTheme.ember.opacity(0.85), location: 0.00),
                                    .init(color: MobileTheme.ember.opacity(0.55), location: 0.35),
                                    .init(color: MobileTheme.amber.opacity(0.32), location: 0.70),
                                    .init(color: Color.clear, location: 1.00)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    // Specular highlight that hugs the upper rim of the curve
                    // so the area reads as a translucent ribbon, not a wash.
                    VitalisAreaShape()
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: Color.white.opacity(0.42), location: 0.00),
                                    .init(color: Color.white.opacity(0.00), location: 0.18)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .blendMode(.plusLighter)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
            }
            VitalisLineShape()
                .stroke(
                    isSelected
                        ? AnyShapeStyle(destination.gradient)
                        : AnyShapeStyle(MobileTheme.Colors.textMuted.opacity(0.78)),
                    style: StrokeStyle(lineWidth: size * 0.085, lineCap: .round, lineJoin: .round)
                )
        }
    }

    // MARK: 2. Burn — Canvas-driven real fire (lit) + warm dormant ember

    @ViewBuilder
    private var burnIcon: some View {
        if isSelected {
            ZStack {
                // Wick anchors the flame at the base.
                IgnisWickShape()
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: "3A2A1E"), Color(hex: "1A1410")],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                // Real fire — Canvas particle simulation.
                LivingFireCanvas(size: size, reduceMotion: reduceMotion)
            }
        } else {
            DormantEmberFlame(size: size, reduceMotion: reduceMotion)
        }
    }

    // MARK: 3. Streams — vintage antenna TV with vibrant RGB color bars

    private var streamsIcon: some View {
        let strokeStyle: AnyShapeStyle = isSelected
            ? AnyShapeStyle(destination.gradient)
            : AnyShapeStyle(MobileTheme.Colors.textMuted.opacity(0.85))
        let bodyStroke = size * 0.075
        let detailStroke = size * 0.06

        return ZStack {
            // Antennae + tip knobs. When selected, antennae wiggle subtly.
            antennaeLayer(strokeStyle: strokeStyle, detailStroke: detailStroke)

            // Cabinet outline
            StreamsTVCabinetShape()
                .stroke(strokeStyle,
                        style: StrokeStyle(lineWidth: bodyStroke, lineCap: .round, lineJoin: .round))

            // Screen background. Off: dim slate. On: navy CRT base for the
            // color bars to layer on top of.
            StreamsTVScreenShape()
                .fill(
                    isSelected
                        ? AnyShapeStyle(
                            LinearGradient(
                                colors: [Color(hex: "0B0B1A"), Color(hex: "1A1430")],
                                startPoint: .top, endPoint: .bottom))
                        : AnyShapeStyle(MobileTheme.Colors.textMuted.opacity(0.18))
                )

            // Color test pattern — only on when selected. Reveal-mask is a
            // CRT power-on sweep clipped against the screen.
            if isSelected {
                streamsContent
                    .mask(
                        StreamsTVScanlineShape(progress: progress)
                            .fill(Color.white)
                    )
                    .mask(StreamsTVScreenShape())
            }

            // Bright scanline edge that hugs the sweep while it animates —
            // sells the CRT power-on flash. Fades after the sweep completes.
            StreamsTVScanlineEdgeShape(progress: progress)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.0), Color.white.opacity(0.95), Color.white.opacity(0.0)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    style: StrokeStyle(lineWidth: detailStroke * 0.7)
                )
                .opacity(isSelected ? max(0, 1 - progress) : 0)
                .blendMode(.plusLighter)
                .mask(StreamsTVScreenShape())

            // Specular curve on the screen glass — sells the CRT bulge.
            StreamsTVScreenGlossShape()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isSelected ? 0.30 : 0.15),
                            Color.white.opacity(0.0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .blendMode(.plusLighter)

            // Feet — same stroke color as cabinet, filled.
            StreamsTVFeetShape()
                .fill(strokeStyle)
        }
    }

    /// Animated screen content while selected — full SMPTE-style color
    /// bars + a scrolling channel-flip flicker. Wrapped in a TimelineView so
    /// the bars dance and the flicker scrolls without re-rendering the
    /// surrounding layout.
    @ViewBuilder
    private var streamsContent: some View {
        if reduceMotion || !isSelected {
            colorBars(phase: 0.5)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 20, paused: false)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let phase = CGFloat((t.truncatingRemainder(dividingBy: 2.4)) / 2.4)
                ZStack {
                    colorBars(phase: phase)
                    // Channel-flip flicker: a thin horizontal band that
                    // slides downward across the screen every cycle.
                    channelFlicker(phase: phase)
                }
            }
        }
    }

    private func colorBars(phase: CGFloat) -> some View {
        // SMPTE-inspired vertical bars in vivid CRT primaries. Each bar
        // breathes a tiny saturation modulation off-phase so the test
        // pattern feels alive instead of static.
        StreamsTVColorBarsShape()
            .fill(
                LinearGradient(
                    stops: [
                        .init(color: streamsColor("E8C46A", phase: phase, offset: 0.00), location: 0.00),
                        .init(color: streamsColor("E8C46A", phase: phase, offset: 0.00), location: 1.0 / 7),
                        .init(color: streamsColor("60D0D0", phase: phase, offset: 0.18), location: 1.0 / 7),
                        .init(color: streamsColor("60D0D0", phase: phase, offset: 0.18), location: 2.0 / 7),
                        .init(color: streamsColor("60D060", phase: phase, offset: 0.32), location: 2.0 / 7),
                        .init(color: streamsColor("60D060", phase: phase, offset: 0.32), location: 3.0 / 7),
                        .init(color: streamsColor("D060C8", phase: phase, offset: 0.46), location: 3.0 / 7),
                        .init(color: streamsColor("D060C8", phase: phase, offset: 0.46), location: 4.0 / 7),
                        .init(color: streamsColor("D85050", phase: phase, offset: 0.60), location: 4.0 / 7),
                        .init(color: streamsColor("D85050", phase: phase, offset: 0.60), location: 5.0 / 7),
                        .init(color: streamsColor("5070D0", phase: phase, offset: 0.74), location: 5.0 / 7),
                        .init(color: streamsColor("5070D0", phase: phase, offset: 0.74), location: 6.0 / 7),
                        .init(color: streamsColor("E0E0E0", phase: phase, offset: 0.88), location: 6.0 / 7),
                        .init(color: streamsColor("E0E0E0", phase: phase, offset: 0.88), location: 1.00)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
    }

    private func streamsColor(_ hex: String, phase: CGFloat, offset: CGFloat) -> Color {
        // Subtle ±10% lightness modulation per bar, off-phase per offset, so
        // the pattern shimmers without feeling glitchy.
        let pulse = 0.92 + 0.08 * sin((phase + offset) * .pi * 2)
        return Color(hex: hex).opacity(Double(pulse))
    }

    @ViewBuilder
    private func channelFlicker(phase: CGFloat) -> some View {
        GeometryReader { geo in
            let screen = StreamsTVMetrics.screen(in: geo.frame(in: .local))
            let bandH = screen.height * 0.16
            let travel = screen.height + bandH
            let y = screen.minY + (phase * travel) - bandH
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.0),
                            Color.white.opacity(0.55),
                            Color.white.opacity(0.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: screen.width, height: bandH)
                .position(x: screen.midX, y: y + bandH / 2)
                .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func antennaeLayer(strokeStyle: AnyShapeStyle, detailStroke: CGFloat) -> some View {
        if isSelected, !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 24, paused: false)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let wiggle = CGFloat(sin(t * 1.6)) * 0.5 + 0.5
                StreamsTVAntennaShape(lift: wiggle)
                    .stroke(strokeStyle,
                            style: StrokeStyle(lineWidth: detailStroke, lineCap: .round))
                StreamsTVAntennaTipsShape(lift: wiggle)
                    .fill(strokeStyle)
            }
        } else {
            StreamsTVAntennaShape(lift: progress)
                .stroke(strokeStyle,
                        style: StrokeStyle(lineWidth: detailStroke, lineCap: .round))
            StreamsTVAntennaTipsShape(lift: progress)
                .fill(isSelected
                      ? AnyShapeStyle(destination.gradient)
                      : AnyShapeStyle(MobileTheme.Colors.textMuted.opacity(0.85)))
        }
    }

    // MARK: 4. Hermes — friendly detailed robot with headphones + smile

    private var hermesIcon: some View {
        // Outline color tracks selection. Mercury gradient when on, calm
        // muted gray when off. Stroke width is tuned so the icon reads
        // crisp at 22pt (tray) and 28pt (sidebar).
        let outlineStyle: AnyShapeStyle = isSelected
            ? AnyShapeStyle(MobileTheme.mercuryGradient)
            : AnyShapeStyle(MobileTheme.Colors.textMuted.opacity(0.88))
        let bodyStroke = size * 0.07
        let detailStroke = size * 0.05

        return ZStack {
            // Antenna stalk
            HermesAntennaShape()
                .stroke(outlineStyle,
                        style: StrokeStyle(lineWidth: detailStroke, lineCap: .round))

            // Heart antenna tip — pulses when active. Halo behind it so it
            // reads as glowing light when on.
            ZStack {
                if isSelected {
                    HermesAntennaHeartShape(pulse: progress)
                        .fill(MobileTheme.ember.opacity(0.55))
                        .blur(radius: size * 0.06)
                        .scaleEffect(1.5 + progress * 0.3)
                }
                HermesAntennaHeartShape(pulse: progress)
                    .fill(isSelected
                          ? AnyShapeStyle(
                                LinearGradient(
                                    colors: [MobileTheme.ember, MobileTheme.amber],
                                    startPoint: .top,
                                    endPoint: .bottom))
                          : AnyShapeStyle(MobileTheme.Colors.textMuted.opacity(0.78)))
            }

            // Earcups (drawn before head so the head's outline rims them)
            HermesEarcupsShape()
                .fill(isSelected
                      ? AnyShapeStyle(
                          LinearGradient(
                              colors: [
                                  MobileTheme.Colors.surfaceElevated,
                                  MobileTheme.Colors.surface
                              ],
                              startPoint: .top, endPoint: .bottom))
                      : AnyShapeStyle(MobileTheme.Colors.textMuted.opacity(0.16)))
                .overlay(
                    HermesEarcupsShape()
                        .stroke(outlineStyle,
                                style: StrokeStyle(lineWidth: detailStroke, lineCap: .round))
                )

            // Helmet body — sheen fill + outline
            HermesHeadShape()
                .fill(
                    isSelected
                        ? AnyShapeStyle(
                            LinearGradient(
                                colors: [
                                    MobileTheme.Colors.surfaceElevated.opacity(0.95),
                                    MobileTheme.Colors.surface.opacity(0.70)
                                ],
                                startPoint: .top,
                                endPoint: .bottom))
                        : AnyShapeStyle(MobileTheme.Colors.surfaceElevated.opacity(0.18))
                )
                .overlay(
                    HermesHeadShape()
                        .stroke(outlineStyle,
                                style: StrokeStyle(lineWidth: bodyStroke, lineCap: .round, lineJoin: .round))
                )

            // Cheek blush — visible all the time but brighter when selected.
            HermesCheeksShape()
                .fill(
                    isSelected
                        ? AnyShapeStyle(MobileTheme.ember.opacity(0.55))
                        : AnyShapeStyle(MobileTheme.Colors.textMuted.opacity(0.28))
                )
                .blur(radius: isSelected ? size * 0.018 : 0)

            // Eye halo bloom — only when selected
            if isSelected {
                HermesEyesShape(glow: progress)
                    .fill(MobileTheme.ember.opacity(0.50))
                    .blur(radius: size * 0.08)
                    .scaleEffect(1.5)
            }

            // Eye pupils — coral radial gradient when on, muted when off.
            HermesEyesShape(glow: progress)
                .fill(
                    isSelected
                        ? AnyShapeStyle(
                            RadialGradient(
                                colors: [
                                    Color.white.opacity(0.95),
                                    MobileTheme.ember,
                                    MobileTheme.ember.opacity(0.85)
                                ],
                                center: .topLeading,
                                startRadius: 0,
                                endRadius: size * 0.13))
                        : AnyShapeStyle(MobileTheme.Colors.textPrimary.opacity(0.78))
                )

            // Eye smile arcs (under the pupils) — appear when active so the
            // robot reads as smiling with its eyes too.
            if isSelected {
                HermesEyeSmileShape()
                    .stroke(MobileTheme.ember.opacity(0.85),
                            style: StrokeStyle(lineWidth: detailStroke * 0.65, lineCap: .round))
                    .transition(.opacity.combined(with: .scale(scale: 0.7, anchor: .center)))
            }

            // Smile arc — wider when selected
            HermesSmileShape(open: progress)
                .stroke(outlineStyle,
                        style: StrokeStyle(lineWidth: detailStroke * 0.85, lineCap: .round))
        }
    }

    // MARK: 5. You — actual user avatar with a rotating brand halo

    private var youIcon: some View {
        let avatarDiameter = size * 0.84
        let ringInset: CGFloat = size * 0.06
        let ringDiameter = avatarDiameter + ringInset * 2

        return ZStack {
            // Outer rotating brand halo — rendered only when selected. Uses
            // an angular ember→amber→blaze gradient that spins gently. We
            // animate `youHaloRotation` with a `repeatForever` linear spin
            // started in `.onAppear`, gated by reduceMotion.
            if isSelected {
                Circle()
                    .stroke(
                        AngularGradient(
                            colors: [
                                MobileTheme.ember,
                                MobileTheme.amber,
                                MobileTheme.blaze,
                                MobileTheme.ember.opacity(0.0),
                                MobileTheme.ember
                            ],
                            center: .center
                        ),
                        lineWidth: max(1.4, size * 0.06)
                    )
                    .frame(width: ringDiameter, height: ringDiameter)
                    .rotationEffect(.degrees(youHaloRotation))
                    .shadow(color: MobileTheme.ember.opacity(0.5), radius: size * 0.18)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    .onAppear { startYouHalo() }
                    .onDisappear { youHaloRotation = 0 }
            } else {
                // Idle: a simple muted ring so the avatar still reads as
                // "you" without competing visual noise.
                Circle()
                    .stroke(
                        MobileTheme.Colors.border.opacity(0.45),
                        lineWidth: max(0.8, size * 0.04)
                    )
                    .frame(width: ringDiameter, height: ringDiameter)
            }

            // Avatar core. Photo if available, gradient + initials otherwise.
            Group {
                if let url = userPhotoURL {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            initialsAvatar
                        }
                    }
                } else {
                    initialsAvatar
                }
            }
            .frame(width: avatarDiameter, height: avatarDiameter)
            .clipShape(Circle())
            .overlay(
                Circle().stroke(
                    Color.white.opacity(colorScheme == .dark ? 0.22 : 0.55),
                    lineWidth: 0.5
                )
            )
        }
    }

    private var initialsAvatar: some View {
        ZStack {
            Circle().fill(MobileTheme.primaryGradient)
            Text(userInitials)
                .font(.system(size: size * 0.40, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.5)
        }
    }

    private var userInitials: String {
        // Build up to two-letter initials from `userDisplayName` (split on
        // whitespace, take first char of first two tokens). Fall back to a
        // single dot when the name is empty so the avatar still reads.
        let trimmed = (userDisplayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "•" }
        let parts = trimmed
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(2)
        let chars = parts.compactMap { $0.first }.map { String($0).uppercased() }
        return chars.isEmpty ? String(trimmed.prefix(1)).uppercased() : chars.joined()
    }

    private func startYouHalo() {
        guard !reduceMotion else { return }
        // Continuous slow spin — implicit, no value-driven animation needed.
        withAnimation(.linear(duration: 16).repeatForever(autoreverses: false)) {
            youHaloRotation = 360
        }
    }
}

// MARK: - Preview

#Preview("All Icons") {
    VStack(spacing: 28) {
        ForEach(AuroraNavDestination.allCases) { dest in
            HStack(spacing: 40) {
                VStack {
                    AuroraNavIcon(destination: dest, size: 44, isSelected: false, isPressed: false)
                    Text("Idle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                VStack {
                    AuroraNavIcon(destination: dest, size: 44, isSelected: true, isPressed: false)
                    Text("Selected")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
    .padding()
}
