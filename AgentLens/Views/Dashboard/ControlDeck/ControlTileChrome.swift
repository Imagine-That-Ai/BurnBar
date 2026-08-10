import OpenBurnBarKernel
import OpenBurnBarUI
import SwiftUI

// MARK: - Control Tile Chrome
//
// The plate every deck tile wears, and the six states it can be in.
//
// The plate is the shipped `ChartCardView.swift:52-72` recipe, copied rather
// than abstracted: on macOS 26 the accent wash is the *only* fill and it rides
// on top of real glass, because a material fill underneath glass blocks
// refraction and reads as frosted plastic. On macOS 14–15 the hand-tuned
// material stack takes over.
//
// The Editorial branch is not optional. `AppSkin.editorial` paints crisp paper,
// and `Color.adaptive(editorial:light:dark:)` resolves the editorial hex
// regardless of aqua/darkAqua — so a hard-coded glass plate looks wrong there.
// Shipping a new AgentLens surface without this branch is the single most
// common way one lands broken.

// MARK: - Group accent

extension ControlGroup {
    /// Six accents, one per band, every one already in `ChartKind.accent` or a
    /// documented sibling. Colour otherwise enters a tile only through its
    /// instrument ink and its status dots.
    ///
    /// `DesignSystem.Colors.warning` is deliberately absent: it is
    /// `C47800`/`FFA800` and byte-identical to `amber` in dark mode
    /// (`DesignSystem.swift:20,54`), so a band that claimed it would be
    /// indistinguishable from WATCH *and* would permanently occupy the alarm
    /// hue. `warning` belongs to the attention layer alone.
    var accent: Color {
        switch self {
        case .cast:  return DesignSystem.Colors.whimsy   // composition / mix
        case .spend: return DesignSystem.Colors.ember    // money
        case .know:  return DesignSystem.Colors.success  // data quality
        case .watch: return DesignSystem.Colors.amber    // time & attention
        case .reach: return DesignSystem.Colors.blaze    // high-consequence
        case .house: return DesignSystem.Colors.frost    // cooling spectrum
        }
    }
}

extension ControlKind {
    var accent: Color { group.accent }
}

// MARK: - Tile state

/// The six states, uniform across every tile. This uniformity is what makes a
/// wall of plates read as one instrument rather than a bag of tinted slabs.
enum ControlTileState: Equatable {
    /// The control is on and doing its job.
    case on
    /// Off, but **still live** — the headline shows the value it *would*
    /// control, never a blank.
    case off
    /// macOS has not granted something. The switch is replaced by a button
    /// that names the exact grant; it never presents a switch that cannot work.
    case needsPermission(String)
    /// The subsystem cannot answer. Carries the reason in the subsystem's own
    /// words, and the tile offers the repair action, not a dead link.
    case unavailable(String)
    /// The control works, but the effect is late or partial. An honest amber
    /// note beside a live control beats a switch that looks like it worked.
    case degraded(String)
    /// Membership-gated. The value stays readable; only the control is veiled.
    case locked(GatedFeatureID)

    /// Whether this state paints the attention plate (warning stroke + wash).
    var usesAttentionPlate: Bool {
        switch self {
        case .needsPermission, .degraded: return true
        case .on, .off, .unavailable, .locked: return false
        }
    }

    /// The word VoiceOver announces after the tile title.
    var accessibilityDescription: String {
        switch self {
        case .on: return "On"
        case .off: return "Off"
        case .needsPermission(let what): return "Needs \(what)"
        case .unavailable(let reason): return "Unavailable. \(reason)"
        case .degraded(let note): return "Degraded. \(note)"
        case .locked: return "Locked"
        }
    }

    /// The dot colour in the status ladder. Never the only carrier of meaning —
    /// every dot is paired with its label in words.
    var dotColor: Color {
        switch self {
        case .on: return DesignSystem.Colors.success
        case .off: return DesignSystem.Colors.textMuted.opacity(0.5)
        case .needsPermission, .degraded: return DesignSystem.Colors.warning
        case .unavailable: return DesignSystem.Colors.textMuted.opacity(0.5)
        case .locked: return DesignSystem.Colors.amber
        }
    }
}

// MARK: - Geometry

enum ControlDeckMetrics {
    /// Fixed collapsed content height → a 140pt plate once padded.
    ///
    /// Not cosmetic. `ChartCardView` gets row alignment for free from
    /// `.frame(height: 150)` on its chart body (`ChartCardView.swift:44`);
    /// without an equivalent rule, paired tiles with variable content bottom
    /// out ragged in every `HStack(alignment: .top)` row.
    static let collapsedContentHeight: CGFloat = 108
    static let contentMaxWidth: CGFloat = 1_180
    static let glyphWell: CGFloat = 26

    /// Columns the grid runs at for a given **content** width (the page width
    /// minus its 24pt padding on each side). Four is the design target at the
    /// full 1180pt clamp, which lands a tile at roughly 274pt — the width the
    /// 28-character headline budget assumes. Below that the deck steps down a
    /// column rather than shrinking tiles past legibility.
    static func columns(for contentWidth: CGFloat) -> Int {
        switch contentWidth {
        case ..<520: return 1
        case ..<820: return 2
        case ..<1_080: return 3
        default: return 4
        }
    }
}

// MARK: - Plate

/// The tile plate: glass + accent wash on Aurora, crisp paper on Editorial.
struct ControlTilePlate: ViewModifier {
    let accent: Color
    let state: ControlTileState

    @Environment(\.colorScheme) private var colorScheme

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
    }

    /// `.off` and `.unavailable` drop to the control-plate rung so a wall of
    /// off tiles recedes without going grey and dead.
    private var washOpacity: Double {
        switch state {
        case .off, .unavailable:
            return colorScheme == .dark ? 0.05 : 0.03
        case .needsPermission, .degraded:
            return colorScheme == .dark ? 0.10 : 0.06
        case .on, .locked:
            return colorScheme == .dark ? 0.08 : 0.04
        }
    }

    private var washColor: Color {
        state.usesAttentionPlate ? DesignSystem.Colors.warning : accent
    }

    private var strokeColor: Color {
        state.usesAttentionPlate
            ? DesignSystem.Colors.warning.opacity(0.55)
            : accent.opacity(0.22)
    }

    private var strokeWidth: CGFloat {
        state.usesAttentionPlate ? 1.0 : 0.75
    }

    func body(content: Content) -> some View {
        content
            .padding(DesignSystem.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { plate }
            .overlay(shape.stroke(strokeColor, lineWidth: strokeWidth))
            .clipShape(shape)
    }

    @ViewBuilder
    private var plate: some View {
        if AppSkin.current == .editorial {
            // Editorial is paper, explicitly glass-free — the same branch
            // `SidebarThemeGlass` takes at `Theme/ThemeGlassPalette.swift:106-148`.
            shape
                .fill(DesignSystem.Colors.surface)
                .overlay(shape.fill(washColor.opacity(washOpacity)))
        } else if #available(macOS 26, *) {
            // The wash is the only fill and it rides on top of the glass.
            // Nothing opaque underneath — see the type comment.
            shape
                .fill(washColor.opacity(washOpacity))
                .liquidGlassEffect(.regular, in: shape)
        } else {
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(DesignSystem.Colors.surface.opacity(colorScheme == .dark ? 0.45 : 0.55))
                shape.fill(washColor.opacity(washOpacity))
            }
        }
    }
}

extension View {
    func controlTilePlate(accent: Color, state: ControlTileState) -> some View {
        modifier(ControlTilePlate(accent: accent, state: state))
    }
}

// MARK: - Tile shell
//
// Every tile is: eyebrow row (glyph well · title · primary control), a live
// headline, a status ladder, and the "why it matters" footer. The shell owns
// the fixed height and the accessibility contract so no tile can forget them.

struct ControlTileShell<Control: View, Ladder: View>: View {
    let kind: ControlKind
    let state: ControlTileState
    let headline: String
    /// Composed into the VoiceOver label so the announcement carries the same
    /// facts the eye gets.
    let accessibilityHeadline: String
    @ViewBuilder let control: () -> Control
    @ViewBuilder let ladder: () -> Ladder

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            header

            Text(headline)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(
                    isMuted ? DesignSystem.Colors.textMuted : DesignSystem.Colors.textPrimary
                )
                .lineLimit(1)
                .truncationMode(.tail)
                .contentTransition(.numericText())

            ladder()

            Spacer(minLength: 0)

            Text(kind.whyItMatters)
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .lineLimit(2)
        }
        .frame(height: ControlDeckMetrics.collapsedContentHeight, alignment: .topLeading)
        .controlTilePlate(accent: kind.accent, state: state)
        // `contain`, not `ignore`: Charts cards ignore their children because
        // they are read-only, but deck tiles own controls and VoiceOver must be
        // able to reach and operate them.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(kind.title). \(state.accessibilityDescription). \(accessibilityHeadline).")
        .accessibilityIdentifier(OBBAccessibilityID.controlDeckTile(kind.rawValue))
    }

    private var isMuted: Bool {
        switch state {
        case .off, .unavailable: return true
        case .on, .needsPermission, .degraded, .locked: return false
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .fill(kind.accent.opacity(0.14))
                .frame(width: ControlDeckMetrics.glyphWell, height: ControlDeckMetrics.glyphWell)
                .overlay {
                    Image(systemName: kind.systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(kind.accent)
                }
                .accessibilityHidden(true)

            Text(kind.title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.1)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .lineLimit(1)

            Spacer(minLength: DesignSystem.Spacing.sm)

            control()
        }
    }
}

// MARK: - Status ladder

/// One rung of the status ladder: a dot, and the same fact in words. Status is
/// never conveyed by colour alone.
struct ControlStatusChip: View {
    let label: String
    var tint: Color = DesignSystem.Colors.textMuted.opacity(0.5)
    var help: String?

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .lineLimit(1)
        }
        .help(help ?? label)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}

/// A meter rung — used where the live fact is a ratio (spend against a
/// threshold). Draws the number as well as the bar.
struct ControlMeterBar: View {
    let fraction: Double
    let accent: Color

    var body: some View {
        GeometryReader { proxy in
            let clamped = min(1, max(0, fraction))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DesignSystem.Colors.textMuted.opacity(0.18))
                Capsule()
                    .fill(clamped >= 1 ? DesignSystem.Colors.warning : accent)
                    .frame(width: max(2, proxy.size.width * clamped))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}
