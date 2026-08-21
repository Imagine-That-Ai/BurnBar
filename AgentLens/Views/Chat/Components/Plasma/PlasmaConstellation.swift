import SwiftUI

// MARK: - The constellation
//
// The asset's `.liquid-chamber`: a zero-gravity field of 52pt glass spheres,
// each drifting on its own period, each labelled underneath. It is how both
// rung 1 (routes) and rung 2 (providers) are chosen.
//
// A grid of rows would have been faster to write and worse to use. The field
// carries three things a list cannot: every option is visible at once with no
// scrolling for realistic counts, the drift makes each orb individually
// trackable by eye instead of by reading, and there is room *under* each orb
// for a status word — which for a gateway is the whole point of the rung.
//
// The whole field shares one clock. Twelve orbs, one display-link wake-up.

/// What is painted inside an orb.
///
/// Both real cases delegate to the app's existing marks — `AgentMark` for an
/// agent, `CatalogProviderLogoView` for a provider — so a plasma orb shows the
/// same logo, with the same asset-resolution and the same fallback, as every
/// other surface in the app. The asset's own flat SVG glyphs are not ported:
/// nine of its ten logos are for vendors BurnBar does not route to.
enum PlasmaMark: Equatable {
    case backend(ChatBackendID)
    case providerID(String)
}

/// The status light on an orb: hue plus shape, so neither carries the state
/// alone.
struct PlasmaOrbStatus: Equatable {
    var color: Color
    var style: PlasmaRouteStatus.DotStyle
}

/// One selectable orb.
struct PlasmaConstellationItem: Identifiable, Equatable {
    let id: String
    let name: String
    let mark: PlasmaMark
    let tint: Color
    /// The orb's deep shade, resolved at construction.
    ///
    /// `PlasmaShade.deep` costs two AppKit colour-space conversions and a
    /// blend. The grid rebuilds every orb on every tick, so computing it in
    /// `sphere` meant ~360 conversions a second for a value that only changes
    /// when the tint does — the exact waste `PlasmaOrb` documents itself as
    /// avoiding.
    let deepTint: Color
    /// The small caps line under the name — `":8642"`, `"12 models"`.
    var detail: String?
    /// The status light. `nil` draws no dot, which is the honest presentation
    /// for a provider (there is nothing to be reachable). The style is carried
    /// alongside the colour so the rung survives colourblindness.
    var status: PlasmaOrbStatus?
    /// Spoken instead of the visual composition when the status needs words.
    var statusWord: String?
    /// A route whose endpoint is refusing us stays visible and stays clickable
    /// — the user needs to see *why* — but reads as unavailable.
    var isImpaired: Bool = false

    init(
        id: String,
        name: String,
        mark: PlasmaMark,
        tint: Color,
        detail: String? = nil,
        status: PlasmaOrbStatus? = nil,
        statusWord: String? = nil,
        isImpaired: Bool = false
    ) {
        self.id = id
        self.name = name
        self.mark = mark
        self.tint = tint
        self.deepTint = PlasmaShade.deep(tint, fraction: 0.55)
        self.detail = detail
        self.status = status
        self.statusWord = statusWord
        self.isImpaired = isImpaired
    }
}

struct PlasmaConstellation: View {
    var items: [PlasmaConstellationItem]
    var selectedID: String?
    var isAnimating: Bool = true
    var onSelect: (PlasmaConstellationItem) -> Void

    /// 52pt orb + 4pt gap + two label lines. Fixed so the field does not reflow
    /// as statuses arrive.
    private let cellWidth: CGFloat = 92
    private let cellHeight: CGFloat = 108

    var body: some View {
        PlasmaClock(isRunning: isAnimating) { tick in
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: cellWidth, maximum: cellWidth), spacing: 6)],
                alignment: .center,
                spacing: 4
            ) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    PlasmaConstellationOrb(
                        item: item,
                        index: index,
                        isSelected: item.id == selectedID,
                        tick: tick,
                        onSelect: { onSelect(item) }
                    )
                    .frame(width: cellWidth, height: cellHeight)
                }
            }
        }
    }
}

// MARK: - One orb

private struct PlasmaConstellationOrb: View {
    var item: PlasmaConstellationItem
    var index: Int
    var isSelected: Bool
    var tick: PlasmaTick
    var onSelect: () -> Void

    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    private let orbSize: CGFloat = 52

    /// The asset rotates four drift tracks by `nth-child(4n+…)`. Reproduced
    /// here, plus a per-orb phase walk so two orbs sharing a track are still
    /// out of step with each other.
    private var motion: PlasmaBlobMotion { .constellationDrift(forIndex: index) }
    private var phaseOffset: CGFloat { CGFloat(index) * 0.137 }

    var body: some View {
        let blob = tick.isAnimating ? motion.state(at: tick.date, phaseOffset: phaseOffset) : .still
        let offset = motion.translation(blob, renderedSize: orbSize)

        Button(action: onSelect) {
            VStack(spacing: 5) {
                sphere
                    .offset(x: offset.width, y: offset.height)
                    .rotationEffect(.degrees(blob.rotationDegrees))
                    // Hover grows the orb, not the cell, so the field does not
                    // shove itself around under the cursor.
                    .scaleEffect(isHovering ? 1.18 : (isSelected ? 1.06 : 1))
                    .animation(DesignSystem.Animation.hover, value: isHovering)
                    .animation(DesignSystem.Animation.hover, value: isSelected)

                label
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Glass

    private var sphere: some View {
        ZStack {
            // The asset's `--glow-color` halo. This is the orb's identity at a
            // glance, so it survives Reduce Motion untouched.
            Circle()
                .fill(item.tint)
                .blur(radius: 11)
                .opacity(glowOpacity)
                .scaleEffect(1.05)

            Circle()
                .fill(.ultraThinMaterial)
                .overlay {
                    Circle().fill(
                        RadialGradient(
                            gradient: Gradient(stops: [
                                .init(color: .white.opacity(colorScheme == .dark ? 0.28 : 0.55), location: 0),
                                .init(color: item.tint.opacity(0.34), location: 0.45),
                                .init(color: item.deepTint.opacity(0.55), location: 1)
                            ]),
                            center: UnitPoint(x: 0.35, y: 0.30),
                            startRadius: 0,
                            endRadius: orbSize * 0.7
                        )
                    )
                }
                .overlay {
                    Circle().strokeBorder(
                        LinearGradient(
                            colors: [
                                .white.opacity(colorScheme == .dark ? 0.45 : 0.9),
                                .white.opacity(0.10),
                                .black.opacity(0.22)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                }
                .overlay {
                    // `is-selected`: a bright inner rim, so selection reads even
                    // when the orb has drifted away from the cursor.
                    Circle()
                        .strokeBorder(item.tint.opacity(isSelected ? 0.95 : 0), lineWidth: 2)
                        .padding(2)
                }
                .overlay { markView }
                .shadow(color: .black.opacity(0.35), radius: 6, y: 4)

            if let status = item.status {
                statusDot(status)
                    .frame(width: 8, height: 8)
                    .overlay { Circle().strokeBorder(DesignSystem.Colors.surface, lineWidth: 1.5) }
                    .offset(x: orbSize * 0.34, y: -orbSize * 0.34)
            }
        }
        .frame(width: orbSize, height: orbSize)
        .opacity(item.isImpaired ? 0.55 : 1)
        .saturation(item.isImpaired ? 0.4 : 1)
    }

    @ViewBuilder
    private func statusDot(_ status: PlasmaOrbStatus) -> some View {
        switch status.style {
        case .filled:
            Circle().fill(status.color)
        case .hollow:
            Circle().strokeBorder(status.color, lineWidth: 1.6)
        case .dashed:
            Circle().strokeBorder(status.color, style: StrokeStyle(lineWidth: 1.6, dash: [2, 1.6]))
        }
    }

    private var glowOpacity: Double {
        if item.isImpaired { return 0.14 }
        if isHovering { return 0.62 }
        return isSelected ? 0.52 : 0.34
    }

    @ViewBuilder
    private var markView: some View {
        PlasmaEmissiveMark(size: orbSize, isDimmed: item.isImpaired) {
            switch item.mark {
            case let .backend(backend):
                AgentMark(backend: backend, size: 22)
            case let .providerID(id):
                // The same resolver the pill body uses. `CatalogProviderLogoView`
                // falls back to an SF Symbol where this one falls back to a
                // monogram, so mixing them made one provider render two different
                // ways in two presentations of the same list.
                ProxyProviderLogoView(catalogProviderID: id, providerName: item.name, size: 22)
            }
        }
    }

    // MARK: Label

    private var label: some View {
        VStack(spacing: 1) {
            Text(item.name)
                .font(.system(size: 11, weight: isSelected ? .semibold : .medium, design: .rounded))
                .foregroundStyle(isSelected ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)

            if let detail = item.detail {
                Text(detail)
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(detailTint)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }

    /// The detail line is the only place a status colour becomes *text*. The
    /// Containment Law bars an identity tint from painting body copy, so this
    /// uses the semantic error/warning tokens the rest of the app uses for the
    /// same job, and falls back to muted for a healthy route.
    private var detailTint: Color {
        item.isImpaired ? DesignSystem.Colors.warning : DesignSystem.Colors.textMuted
    }

    private var helpText: String {
        [item.name, item.detail, item.statusWord].compactMap { $0 }.joined(separator: " · ")
    }

    private var accessibilityLabel: String {
        var parts = [item.name]
        if let statusWord = item.statusWord {
            parts.append(statusWord)
        } else if let detail = item.detail {
            parts.append(detail)
        }
        if isSelected { parts.append("selected") }
        return parts.joined(separator: ", ")
    }
}
