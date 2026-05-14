import SwiftUI
import WidgetKit
import OpenBurnBarCore

// MARK: - Widget Design System

/// Self-contained design tokens for the widget extension.
/// Mirrors the main app's `DesignSystem` without creating a target dependency.
enum WidgetDesignSystem {

    // MARK: - Colors

    enum Colors {
        static let ember  = Color(hex: "F45B69")
        static let amber  = Color(hex: "F28C38")
        static let blaze  = Color(hex: "E86100")
        static let whimsy = Color(hex: "6A5ACD")

        static let backgroundLight = Color(hex: "F3E8E6")
        static let surfaceLight    = Color(hex: "FAF5F2")
        static let surfaceElevated = Color(hex: "FDF8F5")

        /// Canonical surface tokens. Today they shadow the `*Light`
        /// tokens; once the in-flight Warm Charcoal / Botanical Cream
        /// adaptive palette lands they will resolve to the system
        /// appearance-aware variants without touching any call site.
        /// This is the contract surface used by `containerBackground`,
        /// Live Activity chrome, and lock-screen surfaces — keep these
        /// names stable.
        static let background = backgroundLight
        static let surface    = surfaceLight

        /// Hairline stroke for the widget's card and lock-screen
        /// surfaces. `border` is sourced from DESIGN.md (Botanical
        /// Cream "Pressed sage" #C5CEB6) so widget chrome reads as a
        /// sibling of the in-app cards.
        static let border        = Color(hex: "C5CEB6")
        static let borderSubtle  = Color(hex: "D8E2CA")

        /// Hermes mercury gradient — used on Live Activity and lock
        /// screen accents that surface Hermes activity. Mirrors
        /// `UnifiedDesignSystem.Colors.mercuryGradient` in the main
        /// app without forcing a dependency on the design-system
        /// package from the widget target.
        static let hermesMercury  = Color(hex: "C8BFB5")
        static let hermesAureate  = Color(hex: "A2ACBA")
        static let mercuryGradient = LinearGradient(
            colors: [hermesMercury, hermesAureate],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        static let textPrimary   = Color.primary
        static let textSecondary = Color.secondary
        static let textMuted     = Color.secondary.opacity(0.7)

        static let success = Color.green
        static let warning = Color.orange

        static let primaryGradient = LinearGradient(
            colors: [ember.opacity(0.18), amber.opacity(0.12), blaze.opacity(0.08)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        static let headerGradient = LinearGradient(
            colors: [ember.opacity(0.10), amber.opacity(0.06)],
            startPoint: .leading,
            endPoint: .trailing
        )

        static let accentGradient = LinearGradient(
            colors: [ember, amber],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    // MARK: - Typography

    enum Typography {
        static let displayLarge = Font.system(size: 36, weight: .bold, design: .rounded)
        static let display      = Font.system(size: 28, weight: .bold, design: .rounded)
        static let title        = Font.system(size: 20, weight: .semibold, design: .rounded)
        static let headline     = Font.system(size: 16, weight: .semibold, design: .rounded)
        static let body         = Font.system(size: 14, weight: .regular, design: .rounded)
        static let caption      = Font.system(size: 12, weight: .medium, design: .rounded)
        static let tiny         = Font.system(size: 11, weight: .medium, design: .rounded)
        static let micro        = Font.system(size: 10, weight: .semibold, design: .rounded)
    }

    // MARK: - Spacing

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
    }

    // MARK: - Radius

    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 14
        static let full: CGFloat = 9999
    }
}

// MARK: - View Modifiers

extension View {
    func widgetCardBackground() -> some View {
        self.background(
            RoundedRectangle(cornerRadius: WidgetDesignSystem.Radius.md)
                .fill(WidgetDesignSystem.Colors.surfaceLight)
        )
    }

    func widgetGradientBackground() -> some View {
        self.background(WidgetDesignSystem.Colors.primaryGradient)
    }

    func widgetHeaderBackground() -> some View {
        self.background(
            Rectangle()
                .fill(WidgetDesignSystem.Colors.headerGradient)
        )
    }
}

// MARK: - Reusable Widget Components

struct WidgetProviderPill: View {
    let name: String
    let tokens: Int?
    /// In `compact` mode the pill drops the optional `· {tokens}`
    /// suffix and tightens its padding so it fits inside narrow
    /// dashboard footers (Extra Large widget secondary column).
    var compact: Bool = false

    var providerEnum: AgentProvider? {
        AgentProvider.fromPersistedToken(name)
    }

    var body: some View {
        HStack(spacing: 4) {
            if let providerEnum,
               UIImage(named: providerEnum.bundledLogoName) != nil {
                UnifiedProviderLogoView(provider: providerEnum, size: compact ? 10 : 12)
            } else {
                Image(systemName: "flame.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(WidgetDesignSystem.Colors.amber)
            }

            Text(name)
                .font(WidgetDesignSystem.Typography.tiny)
                .lineLimit(1)

            if !compact, let tokens {
                Text("· \(tokens.formatAsTokens())")
                    .font(WidgetDesignSystem.Typography.micro)
                    .foregroundStyle(WidgetDesignSystem.Colors.textMuted)
            }
        }
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 2 : 3)
        .background(
            Capsule()
                .fill(WidgetDesignSystem.Colors.amber.opacity(0.10))
        )
        .overlay(
            Capsule()
                .stroke(WidgetDesignSystem.Colors.amber.opacity(0.25), lineWidth: 1)
        )
        .foregroundStyle(WidgetDesignSystem.Colors.amber)
    }
}

struct WidgetMetricBadge: View {
    let icon: String
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(color)
                Text(label)
                    .font(WidgetDesignSystem.Typography.micro)
                    .foregroundStyle(WidgetDesignSystem.Colors.textMuted)
                    .textCase(.uppercase)
            }
            Text(value)
                .font(WidgetDesignSystem.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(WidgetDesignSystem.Colors.textPrimary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            // `.continuous` matches the rest of the widget surface
            // language (squircle corners, design-system aligned).
            RoundedRectangle(cornerRadius: WidgetDesignSystem.Radius.sm, style: .continuous)
                .fill(color.opacity(0.08))
        )
    }
}

struct WidgetProgressBar: View {
    let value: Double
    let total: Double
    let color: Color

    private var fraction: Double {
        guard total > 0 else { return 0 }
        return min(value / total, 1.0)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: WidgetDesignSystem.Radius.full)
                    .fill(color.opacity(0.12))
                    .frame(height: 5)

                RoundedRectangle(cornerRadius: WidgetDesignSystem.Radius.full)
                    .fill(
                        LinearGradient(
                            colors: [color, color.opacity(0.7)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geo.size.width * fraction, height: 5)
            }
        }
        .frame(height: 5)
    }
}

struct WidgetModelChip: View {
    let model: String

    var body: some View {
        Text(model)
            .font(WidgetDesignSystem.Typography.micro)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(WidgetDesignSystem.Colors.whimsy.opacity(0.10))
            )
            .overlay(
                Capsule()
                    .stroke(WidgetDesignSystem.Colors.whimsy.opacity(0.25), lineWidth: 1)
            )
            .foregroundStyle(WidgetDesignSystem.Colors.whimsy)
    }
}

struct WidgetFlameGlow: View {
    var body: some View {
        Image(systemName: "flame.fill")
            .font(.system(size: 64, weight: .bold))
            .foregroundStyle(
                LinearGradient(
                    colors: [
                        WidgetDesignSystem.Colors.ember.opacity(0.10),
                        WidgetDesignSystem.Colors.amber.opacity(0.06)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .blur(radius: 8)
    }
}

// MARK: - Editorial widget primitives
//
// The widget redesign that landed in `a1f72dd42` introduced four new
// design-system primitives that every dashboard surface relies on:
// `WidgetEyebrow`, `WidgetMiniSparkline`, `WidgetCompactShareBar`, and
// the `.widgetGlassCard / widgetGlassCardElevated / widgetAccentable`
// modifiers. The call sites shipped without the corresponding
// declarations, breaking the device build. These canonical
// implementations live here so every widget size shares one chrome
// language and the same DESIGN.md tokens — adding new sizes never
// requires re-inventing them.

/// Small all-caps caption used as the section eyebrow at the top of
/// each dashboard widget. When `showLiveDot` is `true`, a pulsing
/// dot signals that the snapshot is live-refreshing.
struct WidgetEyebrow: View {
    let text: String
    var showLiveDot: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            if showLiveDot {
                Circle()
                    .fill(WidgetDesignSystem.Colors.success)
                    .frame(width: 5, height: 5)
                    .shadow(color: WidgetDesignSystem.Colors.success.opacity(0.55), radius: 2)
                    .accessibilityHidden(true)
            }
            Text(text.uppercased())
                .font(WidgetDesignSystem.Typography.micro)
                .tracking(1.2)
                .foregroundStyle(WidgetDesignSystem.Colors.textSecondary)
                .lineLimit(1)
        }
    }
}

/// A compact line sparkline. Used by Dashboard Large + Extra Large to
/// show the rolling daily cost / token trend underneath the headline
/// number. Uses `Canvas` so it renders in the widget extension's
/// limited-functionality context (no `Chart`).
struct WidgetMiniSparkline: View {
    let data: [Double]
    let color: Color
    var height: CGFloat = 48

    var body: some View {
        Canvas { context, size in
            guard data.count >= 2 else { return }
            let maxValue = max(data.max() ?? 1, 0.0001)
            let minValue = min(data.min() ?? 0, maxValue)
            let valueRange = max(maxValue - minValue, 0.0001)
            let stride = data.count > 1 ? size.width / CGFloat(data.count - 1) : 0
            // Floor for stroke / area so we have a stable axis when
            // every value is identical.
            let floor: CGFloat = size.height
            func point(at idx: Int) -> CGPoint {
                let x = stride * CGFloat(idx)
                let normalized = (data[idx] - minValue) / valueRange
                let y = floor - CGFloat(normalized) * size.height
                return CGPoint(x: x, y: y)
            }

            // Filled area under the line — gives the sparkline weight
            // without overpowering the headline above it.
            var area = Path()
            area.move(to: CGPoint(x: 0, y: floor))
            area.addLine(to: point(at: 0))
            for idx in 1..<data.count {
                area.addLine(to: point(at: idx))
            }
            area.addLine(to: CGPoint(x: size.width, y: floor))
            area.closeSubpath()
            context.fill(
                area,
                with: .linearGradient(
                    Gradient(colors: [color.opacity(0.28), color.opacity(0.02)]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: floor)
                )
            )

            // Stroke
            var stroke = Path()
            stroke.move(to: point(at: 0))
            for idx in 1..<data.count {
                stroke.addLine(to: point(at: idx))
            }
            context.stroke(stroke, with: .color(color), lineWidth: 1.6)

            // Endpoint dot
            let endPoint = point(at: data.count - 1)
            let dotRect = CGRect(x: endPoint.x - 2.5, y: endPoint.y - 2.5, width: 5, height: 5)
            context.fill(Path(ellipseIn: dotRect), with: .color(color))
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// A compact "share of total" bar used in dashboard rows. Renders the
/// share that `value` represents of `total`, capping at 100% so a
/// drifting model summary never bleeds outside the row.
struct WidgetCompactShareBar: View {
    let value: Double
    let total: Double
    let color: Color
    var height: CGFloat = 3

    private var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, value / total))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(WidgetDesignSystem.Colors.textMuted.opacity(0.18))
                Capsule(style: .continuous)
                    .fill(color.opacity(0.85))
                    .frame(width: proxy.size.width * CGFloat(fraction))
            }
        }
        .frame(height: height)
        .accessibilityValue(Text("\(Int(fraction * 100)) percent"))
    }
}

// MARK: - Surface modifiers

extension View {
    /// Editorial card surface used by Large + Extra Large dashboards.
    /// Combines the warm `surfaceLight` fill with a hairline `border`
    /// stroke (DESIGN.md "pressed sage") so the card reads as a
    /// continuation of the in-app cards.
    func widgetGlassCard() -> some View {
        self
            .padding(WidgetDesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: WidgetDesignSystem.Radius.lg, style: .continuous)
                    .fill(WidgetDesignSystem.Colors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: WidgetDesignSystem.Radius.lg, style: .continuous)
                    .strokeBorder(WidgetDesignSystem.Colors.border.opacity(0.6), lineWidth: 0.5)
            )
    }

    /// Elevated variant of `widgetGlassCard()` — slightly brighter fill
    /// for the secondary column of the Extra Large dashboard so the two
    /// halves read with a clear primary / secondary hierarchy.
    func widgetGlassCardElevated() -> some View {
        self
            .padding(WidgetDesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: WidgetDesignSystem.Radius.lg, style: .continuous)
                    .fill(WidgetDesignSystem.Colors.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: WidgetDesignSystem.Radius.lg, style: .continuous)
                    .strokeBorder(WidgetDesignSystem.Colors.borderSubtle.opacity(0.8), lineWidth: 0.5)
            )
    }

    /// Adds the subtle ember accent glow that the dashboard widgets
    /// inherit on the primary surface. Kept as a modifier so individual
    /// widget sizes can mix and match (the medium widget skips it to
    /// stay calm; the large + extra large dashboards layer it on).
    func widgetAccentable() -> some View {
        self.overlay(alignment: .topTrailing) {
            Circle()
                .fill(WidgetDesignSystem.Colors.primaryGradient)
                .frame(width: 64, height: 64)
                .blur(radius: 28)
                .opacity(0.35)
                .offset(x: 16, y: -16)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .clipShape(RoundedRectangle(cornerRadius: WidgetDesignSystem.Radius.lg, style: .continuous))
    }
}

// MARK: - Color Hex Init

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Widget design-system canary
//
// A build-time guard that fails the widget extension compile if any of
// the design-system primitives the dashboard surfaces depend on
// disappear or change shape. This caught us once already (the
// `a1f72dd42` redesign committed call sites without declarations — the
// device build was broken at HEAD). Keeping a single struct that
// references every shared primitive turns "ship a half-finished
// redesign" from a runtime regression into a compiler error.
//
// New primitives **must** be referenced here so the contract is
// preserved across rolling agent work.
#if DEBUG
@available(iOS 17, *)
private struct _WidgetDesignSystemContractCanary: View {
    var body: some View {
        VStack {
            // Eyebrow / sparkline / share bar — the three new editorial
            // primitives that landed alongside the dashboard redesign.
            WidgetEyebrow(text: "BurnBar", showLiveDot: true)
            WidgetMiniSparkline(data: [0.2, 0.3, 0.8, 0.6, 0.9], color: WidgetDesignSystem.Colors.amber, height: 32)
            WidgetCompactShareBar(value: 4, total: 10, color: WidgetDesignSystem.Colors.ember)

            // Pre-existing primitives. Keeping them referenced here
            // prevents accidental deletion during a future redesign.
            WidgetMetricBadge(icon: "flame.fill", value: "$12", label: "TODAY", color: WidgetDesignSystem.Colors.ember)
            WidgetProviderPill(name: "anthropic", tokens: 2_410, compact: false)
            WidgetProviderPill(name: "openai", tokens: nil, compact: true)
            WidgetProgressBar(value: 3, total: 5, color: WidgetDesignSystem.Colors.amber)
        }
        // Surface modifiers — `widgetGlassCard`, `widgetGlassCardElevated`,
        // `widgetAccentable`, plus the legacy `widgetCardBackground` /
        // `widgetGradientBackground` / `widgetHeaderBackground`.
        .widgetGlassCard()
        .widgetGlassCardElevated()
        .widgetAccentable()
        .widgetCardBackground()
        .widgetGradientBackground()
        .widgetHeaderBackground()
        // Color tokens that the widget chrome depends on.
        .foregroundStyle(WidgetDesignSystem.Colors.textPrimary)
        .background(WidgetDesignSystem.Colors.background)
        .overlay(
            RoundedRectangle(cornerRadius: WidgetDesignSystem.Radius.lg, style: .continuous)
                .stroke(WidgetDesignSystem.Colors.border, lineWidth: 0.5)
        )
        .overlay {
            // Mercury gradient must remain available for the Hermes
            // live-activity accent.
            Capsule().fill(WidgetDesignSystem.Colors.mercuryGradient).frame(width: 1, height: 1)
        }
    }
}
#endif
