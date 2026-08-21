import OpenBurnBarUI
import SwiftUI

// MARK: - Dashboard Section
//
// The single container primitive every dashboard layout composes from.
//
// Before this existed each layout assembled its own glass boxes out of
// `GlassCard`, `.ultraThinMaterial` capsules, and bare `VStack`s, which produced
// two problems at once. Visually the page became a mosaic — a dozen plates of
// slightly different radius, gutter, and opacity, none of which told you where
// one idea ended and the next began. Legibility-wise the ad-hoc plates never
// picked up `BackdropLegiblePlate`, so the moment a live kernel was switched on
// their contents were sitting on an animated gradient.
//
// A section is: an eyebrow that names the idea, an optional accessory on the
// same baseline, the content, one gutter, and a backdrop-legible plate. Layouts
// choose *composition* — how many sections, in what axis, at what weight. They
// do not choose plate recipes. That is what makes eight layouts read as eight
// arrangements of one product rather than eight unrelated screens.
//
// Density is the one visual dial, and it is deliberately coarse:
//
//   * `.comfortable` — reading surfaces. One 16pt gutter all around.
//   * `.compact` — dense ladders and KPI strips where the content is already
//     tabular and a fat gutter just wastes rows.
//   * `.flush` — content that must reach the plate edge (charts, the kernel
//     window, full-bleed row lists). The header keeps its gutter; the body
//     bleeds.

/// How tight a section's gutter is, and whether its body reaches the plate edge.
///
/// Top-level rather than nested in the generic `DashboardSection` so a layout's
/// own helper can take one as a parameter without having to name the section's
/// content and accessory types.
enum DashboardSectionDensity {
    case comfortable
    case compact
    /// Header padded, body bleeding to the plate edge.
    case flush
}

/// Visual weight. Affects the wash and the eyebrow, never the geometry —
/// emphasis must not change how big a section is, or layouts stop being
/// comparable.
enum DashboardSectionEmphasis {
    case quiet
    case standard
    case featured
}

struct DashboardSection<Content: View, Accessory: View>: View {
    let eyebrow: String
    var title: String?
    var accent: Color
    var density: DashboardSectionDensity
    var emphasis: DashboardSectionEmphasis
    /// Stretch to fill the height offered by the parent. Off by default so a
    /// section in a scroll column hugs its content.
    var fillsHeight: Bool

    private let accessory: Accessory
    private let content: Content

    @Environment(\.backdropInk) private var ink
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.burnBarGlassSpec) private var glassSpec
    @AppStorage(AppSkin.storageKey) private var rawSkin: String = AppSkin.aurora.rawValue
    private var skin: AppSkin { AppSkin(rawValue: rawSkin) ?? .aurora }

    init(
        _ eyebrow: String,
        title: String? = nil,
        accent: Color = DesignSystem.Colors.ember,
        density: DashboardSectionDensity = .comfortable,
        emphasis: DashboardSectionEmphasis = .standard,
        fillsHeight: Bool = false,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.accent = accent
        self.density = density
        self.emphasis = emphasis
        self.fillsHeight = fillsHeight
        self.accessory = accessory()
        self.content = content()
    }

    private var gutter: CGFloat {
        switch density {
        case .comfortable: return DesignSystem.Spacing.lg
        case .compact, .flush: return DesignSystem.Spacing.md
        }
    }

    private var headerSpacing: CGFloat {
        switch density {
        case .comfortable: return DesignSystem.Spacing.md
        case .compact: return DesignSystem.Spacing.sm
        case .flush: return DesignSystem.Spacing.sm
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: headerSpacing) {
            header
                .padding(.horizontal, density == .flush ? gutter : 0)
                .padding(.top, density == .flush ? gutter : 0)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(density == .flush ? 0 : gutter)
        .padding(.bottom, density == .flush ? gutter : 0)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
        .background {
            if emphasis == .featured {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .fill(
                        RadialGradient(
                            colors: [accent.opacity(0.12), Color.clear],
                            center: .topLeading,
                            startRadius: 0,
                            endRadius: 280
                        )
                    )
            }
        }
        // A section holds data, so it is the *content* layer. `role: .content` strips
        // the optics to an opaque substrate no matter which theme is in force — which
        // is exactly the rule that keeps charts and ladders readable. What the theme
        // still contributes is character: scrim weight, rim strength, and how much
        // ambient light it takes.
        .burnBarGlass(
            glassSpec,
            role: .content,
            tint: accent,
            cornerRadius: DesignSystem.Radius.lg
        )
        .overlay { specularEdge }
        .shadow(
            color: Color.black.opacity(skin == .editorial ? 0.04 : (colorScheme == .dark ? 0.20 : 0.07)),
            radius: 8,
            y: 3
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title ?? eyebrow)
    }

    /// The rim gradient, per scheme. Dark mode catches light along the top edge;
    /// light mode cannot (white on white is nothing), so it darkens toward the
    /// bottom instead and lets the shadow do the lifting.
    private var specularColors: [Color] {
        if colorScheme == .dark {
            return [
                Color.white.opacity(skin == .editorial ? 0.35 : 0.22),
                DesignSystem.Colors.border.opacity(0.35),
                DesignSystem.Colors.border.opacity(0.12)
            ]
        }
        return [
            Color.white.opacity(0.80),
            Color.black.opacity(0.10),
            Color.black.opacity(0.18)
        ]
    }

    private var specularEdge: some View {
        RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
            .stroke(
                LinearGradient(
                    colors: specularColors,
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 0.75
            )
    }

    @ViewBuilder
    private var header: some View {
        if eyebrow.isEmpty, title == nil, Accessory.self == EmptyView.self {
            EmptyView()
        } else {
            HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    if !eyebrow.isEmpty {
                        Text(eyebrow)
                            .font(DesignSystem.Typography.tiny)
                            .textCase(.uppercase)
                            .tracking(1.2)
                            .foregroundStyle(emphasis == .quiet ? ink.subtle : accent)
                    }
                    if let title {
                        Text(title)
                            .font(DesignSystem.Typography.headline)
                            .foregroundStyle(ink.primary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                accessory
            }
        }
    }
}

extension DashboardSection where Accessory == EmptyView {
    init(
        _ eyebrow: String,
        title: String? = nil,
        accent: Color = DesignSystem.Colors.ember,
        density: DashboardSectionDensity = .comfortable,
        emphasis: DashboardSectionEmphasis = .standard,
        fillsHeight: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            eyebrow,
            title: title,
            accent: accent,
            density: density,
            emphasis: emphasis,
            fillsHeight: fillsHeight,
            accessory: { EmptyView() },
            content: content
        )
    }
}

// MARK: - Section furniture

/// The hairline a section uses between its own rows.
///
/// Sections divide their contents with a rule rather than by nesting more
/// plates — that is the whole anti-mosaic rule, expressed as one view.
struct DashboardSectionRule: View {
    @Environment(\.backdropInk) private var ink

    var body: some View {
        Rectangle()
            .fill(ink.hairline)
            .frame(height: 0.5)
    }
}

/// A label/value pair on one baseline, monospaced on the value side.
///
/// The atom `Ledger`, `Atlas`, and `Cockpit` all build their rows from, so a
/// number means the same thing and sits in the same column in all three.
struct DashboardSectionMetric: View {
    let label: String
    let value: String
    var accent: Color?
    var caption: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.backdropInk) private var ink

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.sm) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(ink.secondary)
                    .lineLimit(1)
                if let caption {
                    Text(caption)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(ink.subtle)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: DesignSystem.Spacing.sm)
            Text(value)
                .font(DesignSystem.Typography.monoSmall)
                .foregroundStyle(accent ?? ink.primary)
                .lineLimit(1)
                .contentTransition(.numericText())
                .animation(MotionTokens.tick(reduceMotion: reduceMotion), value: value)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

/// A ladder of `DashboardSectionMetric` rows separated by rules.
///
/// The label/value counterpart to `DashboardRankedTable`: `Atelier`, `Aurora`,
/// and `Ledger` all render the window facts as this exact stack, and each
/// carried its own `ForEach` + interleaved rule before this existed.
struct DashboardMetricLadder: View {
    let facts: [(label: String, value: String, accent: Color)]
    /// Row breathing room. A parameter only because Atelier's ladder is the
    /// fallback arm of a `ViewThatFits` and sits one notch looser.
    var rowPadding: CGFloat = 7

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(facts.enumerated()), id: \.offset) { index, fact in
                if index > 0 { DashboardSectionRule() }
                DashboardSectionMetric(
                    label: fact.label,
                    value: fact.value,
                    accent: fact.accent
                )
                .padding(.vertical, rowPadding)
            }
        }
    }
}

/// A number sized to be read, not decorated.
///
/// `ConceptStatTile` bundles a value *with* a plate, which is exactly what
/// caused the mosaic — a KPI strip of four tiles is four plates. This is the
/// value alone, so a section can hold four of them inside one plate.
struct DashboardSectionValue: View {
    let label: String
    let value: String
    var caption: String?
    var accent: Color = DesignSystem.Colors.ember
    var size: CGFloat = 22
    var alignment: HorizontalAlignment = .leading

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.backdropInk) private var ink

    var body: some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(label)
                .font(DesignSystem.Typography.tiny)
                .textCase(.uppercase)
                .tracking(1.1)
                .foregroundStyle(ink.subtle)
                .lineLimit(1)
            Text(value)
                .font(.system(size: size, weight: .bold, design: .monospaced))
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .allowsTightening(true)
                .contentTransition(.numericText())
                .animation(MotionTokens.tick(reduceMotion: reduceMotion), value: value)
            if let caption {
                Text(caption)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(ink.subtle)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(
            maxWidth: .infinity,
            alignment: alignment == .leading
                ? .leading
                : (alignment == .trailing ? .trailing : .center)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}
