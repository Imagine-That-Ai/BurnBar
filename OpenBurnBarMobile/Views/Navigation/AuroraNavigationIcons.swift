import SwiftUI
import OpenBurnBarRecap

// MARK: - Aurora Navigation Icons
//
// Tray glyphs for the OpenBurnBar floating tab tray. Compact iPhone is four
// destinations: Inbox (launch), Agents, Quota, You. Pulse / Insights / Streams /
// Recap stay reachable via deep link or You overflow. Watch is an overlay,
// not a tab.
//
// The live tray and iPad sidebar use monochrome SF Symbols. `AuroraNavIcon`
// remains for the signed-in You avatar and previews.
//
// Design rules per icon:
//   • A clean, evocative silhouette readable at 22pt and 28pt
//   • A muted at-rest treatment (single neutral stroke / fill)
//   • A rich selected treatment with the destination's accent gradient
//   • A characteristic flourish driven by `animatableData` so the
//     selection spring IS the click animation (no extra timers)
//
// Selection animations per icon:
//   • Inbox:   tray fill brightens on the launch accent
//   • Pulse:   area under the curve fades in with a 3-stop ember gradient
//   • Quota:   inner hot core grows from the wick and glows
//   • Streams: three aurora ribbons phase-shift along their path
//   • Hermes:  twin wings spread outward and lift; orb radiates
//   • You:     a halo arc expands above the head

// MARK: - Destinations

enum AuroraNavDestination: Hashable, Identifiable, CaseIterable {
    case inbox
    case pulse
    case burn
    case insights
    case streams
    case hermes
    case you
    case recap

    var id: String { String(describing: self) }

    /// Compact iPhone tray: Inbox (launch) · Agents · Quota · You.
    /// Watch is `AgentWatchOverlaySingleton`, not a fifth tab.
    static let compactTrayDestinations: [AuroraNavDestination] = [
        .inbox, .hermes, .burn, .you
    ]

    /// Destinations the navigation tray shows.
    ///
    /// Compact (iPhone) is the four-tab remote-continuation shell. Regular
    /// width keeps Pulse, Insights, Streams, and Recap in the tray because
    /// there is room. Recap on compact is reached from You overflow or the
    /// Insights banner, not a permanent slot.
    static func trayDestinations(compact: Bool) -> [AuroraNavDestination] {
        compact ? compactTrayDestinations : allCases
    }

    var label: String {
        switch self {
        case .inbox:    return "Inbox"
        case .pulse:    return "Pulse"
        // Enum stays `.burn` so `burnbar://burn`, `burnbar://quota`, and
        // persisted selection values keep working. The screen title is Quota.
        case .burn:     return "Quota"
        case .insights: return "Insights"
        case .streams:  return "Streams"
        // Tab label is "Agents" but the enum case stays `.hermes` so existing
        // route strings, deep links, and persisted selection values keep working.
        case .hermes:   return "Agents"
        case .you:      return "You"
        case .recap:    return "Recap"
        }
    }

    var trayLabel: String { label }

    /// Compact tray and quiet sidebar glyphs. Ink, not destination gradients.
    var traySystemImage: String {
        switch self {
        case .inbox:    return "tray.fill"
        case .pulse:    return "waveform.path.ecg"
        case .burn:     return "gauge.with.needle"
        case .insights: return "chart.bar.fill"
        case .streams:  return "play.rectangle.fill"
        case .hermes:   return "bubble.left.and.bubble.right.fill"
        case .you:      return "person.crop.circle.fill"
        case .recap:    return "calendar.badge.clock"
        }
    }

    var accent: Color {
        switch self {
        case .inbox:    return MobileTheme.ember
        case .pulse:    return MobileTheme.ember
        case .burn:     return MobileTheme.amber
        case .insights: return MobileTheme.whimsy
        case .streams:  return MobileTheme.whimsy
        case .hermes:   return MobileTheme.hermesAureate
        case .you:      return MobileTheme.blaze
        case .recap:    return MobileTheme.amber
        }
    }

    var gradient: LinearGradient {
        switch self {
        case .inbox, .pulse:
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
        case .you:
            return LinearGradient(
                colors: [MobileTheme.blaze, MobileTheme.ember],
                startPoint: .top,
                endPoint: .bottom
            )
        case .recap:
            return LinearGradient(
                colors: [MobileTheme.amber, MobileTheme.ember],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
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

    /// Animation driver — 0 at rest, 1 when selected. Drives the
    /// `animatableData` of every shape so the spring on isSelected
    /// becomes the click animation for free.
    private var progress: CGFloat { isSelected ? 1.0 : 0.0 }

    /// Per-icon idle drivers for icons that benefit from a tiny ambient
    /// motion when selected (TV signal bars, robot eye blink). These are
    /// gated on `isSelected` and `reduceMotion` and use TimelineView so they
    /// don't drive view re-renders elsewhere.

    var body: some View {
        iconContent
            .scaleEffect(isPressed ? 0.88 : (isSelected ? 1.04 : 1.0))
            .animation(
                reduceMotion
                    ? .easeInOut(duration: 0.18)
                    : .spring(response: 0.36, dampingFraction: 0.70),
                value: isSelected
            )
            .animation(.spring(response: 0.18, dampingFraction: 0.65), value: isPressed)
            .frame(width: size, height: size)
            .accessibilityLabel(destination.label)
            .accessibilityHidden(true)
    }

    private var selectedInk: AnyShapeStyle { AnyShapeStyle(Color.primary) }
    private var restInk: AnyShapeStyle { AnyShapeStyle(Color.secondary) }

    // MARK: Per-icon foreground rendering

    @ViewBuilder
    private var iconContent: some View {
        switch destination {
        case .inbox:    inboxIcon
        case .pulse:    pulseIcon
        case .burn:     burnIcon
        case .insights: insightsIcon
        case .streams:  streamsIcon
        case .hermes:   hermesIcon
        case .you:      youIcon
        case .recap:    recapIcon
        }
    }

    private var inboxIcon: some View {
        Image(systemName: "tray.full.fill")
            .font(.system(size: size * 0.55, weight: isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? selectedInk : restInk)
    }

    /// Recap only appears in the iPad tray, where the system glyph reads
    /// correctly beside the hand-drawn ones.
    private var recapIcon: some View {
        Image(systemName: "calendar.badge.clock")
            .font(.system(size: size * 0.62, weight: isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? selectedInk : restInk)
    }

    private var insightsIcon: some View {
        Image(systemName: "sparkles.tv.fill")
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(isSelected ? selectedInk : restInk)
    }

    // MARK: 1. Pulse — heartbeat curve with a premium brand-gradient fill

    private var pulseIcon: some View {
        VitalisLineShape()
            .stroke(
                isSelected ? selectedInk : restInk,
                style: StrokeStyle(lineWidth: size * 0.085, lineCap: .round, lineJoin: .round)
            )
    }

    @ViewBuilder
    private var burnIcon: some View {
        IgnisOutlineShape()
            .fill(isSelected ? Color.primary : Color.secondary)
    }

    // MARK: 3. Streams — vintage antenna TV with vibrant RGB color bars

    private var streamsIcon: some View {
        let strokeStyle: AnyShapeStyle = isSelected ? selectedInk : restInk
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
                .fill(isSelected ? selectedInk : AnyShapeStyle(MobileTheme.Colors.textMuted.opacity(0.85)))
        }
    }

    // MARK: 4. Hermes — friendly detailed robot with headphones + smile

    private var hermesIcon: some View {
        // Outline color tracks selection. Mercury gradient when on, calm
        // muted gray when off. Stroke width is tuned so the icon reads
        // crisp at 22pt (tray) and 28pt (sidebar).
        let outlineStyle: AnyShapeStyle = isSelected ? selectedInk : restInk
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

    // MARK: 5. You — signed-in photo or initials, hairline ring

    private var youIcon: some View {
        let avatarDiameter = size * 0.84
        let ringInset: CGFloat = size * 0.06
        let ringDiameter = avatarDiameter + ringInset * 2

        return ZStack {
            Circle()
                .stroke(
                    isSelected ? Color.primary.opacity(0.35) : MobileTheme.Colors.border.opacity(0.45),
                    lineWidth: isSelected ? max(1.2, size * 0.05) : max(0.8, size * 0.04)
                )
                .frame(width: ringDiameter, height: ringDiameter)

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
            Circle().fill(Color.primary.opacity(0.12))
            Text(userInitials)
                .font(.system(size: size * 0.40, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.primary)
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
