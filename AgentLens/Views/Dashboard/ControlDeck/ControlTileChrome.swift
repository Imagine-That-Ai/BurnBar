import OpenBurnBarKernel
import OpenBurnBarUI
import SwiftUI

// MARK: - Control Tile Chrome
//
// The plate every deck tile wears, and the six states it can be in.
//
// The plate delegates to `BackdropLegiblePlate` (`Theme/BackdropLegibleSurface.swift`)
// rather than owning a recipe. It used to own one — the `ChartCardView` recipe,
// copied verbatim — and that recipe has no opaque substrate, so with a live
// kernel backdrop switched on the animated mesh refracted straight through
// every tile and the deck became unreadable. Glass refracts; it does not
// darken. The shared plate puts a `surface` slab underneath.
//
// The other half of the same defect was the ink: this file used
// `DesignSystem.Colors.textMuted` for the eyebrow and the footer, and that
// token measures 3.77:1 against the app's own `surface`. It cannot clear 4.5:1
// on any background this app draws. Every text role here now comes from
// `\.backdropInk`. Page chrome keeps kernel-sampled adaptive ink; the plate
// overrides that to appearance tokens so tile copy contrasts with the
// `surface` slab. Both halves are pinned by `BackdropLegiblePlateTests`.

// MARK: - Deck ink constants

enum ControlDeckInk {
    /// The "not on" tint for status dots and inactive glyphs.
    ///
    /// Was `DesignSystem.Colors.textMuted.opacity(0.5)`. That is `#6E7681` at
    /// half alpha, which measures **1.89:1** against the app's own `surface` —
    /// far under the 3:1 non-text floor, and simply not visible once a kernel
    /// backdrop is animating behind it. An "off" dot still has to be *seen* to
    /// communicate off.
    ///
    /// Full opacity, not a fraction. Every fractional alpha that keeps the dot
    /// looking suitably quiet on the flat `surface` drops it back under 3:1 on a
    /// tile plate over a live backdrop, because that plate is the brighter of
    /// the two. `textSecondary` at full strength clears both (5.63:1 and
    /// 3.28:1) and still reads as obviously dimmer than the `success` green
    /// beside it, which is the whole job.
    static let inactive = DesignSystem.Colors.textSecondary
}

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
        case .off: return ControlDeckInk.inactive
        case .needsPermission, .degraded: return DesignSystem.Colors.warning
        case .unavailable: return ControlDeckInk.inactive
        case .locked: return DesignSystem.Colors.amber
        }
    }
}

// MARK: - Geometry

enum ControlDeckMetrics {
    /// Fixed collapsed content height → a 132pt plate once padded.
    ///
    /// Not cosmetic. `ChartCardView` gets row alignment for free from
    /// `.frame(height: 150)` on its chart body; without an equivalent rule,
    /// paired tiles with variable content bottom out ragged in every
    /// `HStack(alignment: .top)` row.
    ///
    /// Reduced from 108 because the old shell spent most of that height on a
    /// `Spacer` — a 15pt headline and a two-line footer inside a 140pt plate is
    /// what made a deck of eleven live controls read as a wall of empty slabs.
    /// The headline is now the hero and the footer is one line.
    static let collapsedContentHeight: CGFloat = 96
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

/// The tile plate. Wash and stroke are state-derived here; the substrate,
/// glass, and Editorial branches all live in `BackdropLegiblePlate`.
struct ControlTilePlate: ViewModifier {
    let accent: Color
    let state: ControlTileState

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dashboardLiveBackdropActive) private var liveBackdropActive

    /// `.off` and `.unavailable` drop a rung so a wall of off tiles recedes
    /// without going grey and dead.
    ///
    /// Over a live backdrop every rung is *lowered*, which is the opposite of
    /// the instinct.
    ///
    /// A full-plate wash strong enough to name its band turns muddy the moment
    /// it sits on a `surface` slab that is itself sitting on a saturated
    /// kernel: three tinted layers stacked, and the result reads as dirt rather
    /// than as colour. Rendered proof is in `ControlDeckSnapshotHarness` — the
    /// attention plate in particular went brown.
    ///
    /// So the band is carried by the two places accent looks good at full
    /// strength — the glyph well and the stroke — and the wash is left as a
    /// hint rather than a cast.
    private var washOpacity: Double {
        let dark = colorScheme == .dark
        switch state {
        case .off, .unavailable:
            if liveBackdropActive { return 0.035 }
            return dark ? 0.05 : 0.03
        case .needsPermission, .degraded:
            if liveBackdropActive { return 0.09 }
            return dark ? 0.10 : 0.06
        case .on, .locked:
            if liveBackdropActive { return 0.05 }
            return dark ? 0.08 : 0.04
        }
    }

    private var washColor: Color {
        state.usesAttentionPlate ? DesignSystem.Colors.warning : accent
    }

    private var strokeColor: Color {
        state.usesAttentionPlate
            ? DesignSystem.Colors.warning.opacity(0.55)
            : accent.opacity(liveBackdropActive ? 0.34 : 0.22)
    }

    private var strokeWidth: CGFloat {
        state.usesAttentionPlate ? 1.0 : 0.75
    }

    func body(content: Content) -> some View {
        content
            .padding(DesignSystem.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .backdropLegiblePlate(
                accent: washColor,
                washOpacity: washOpacity,
                strokeColor: strokeColor,
                strokeWidth: strokeWidth,
                cornerRadius: DesignSystem.Radius.lg,
                // Tiles carry the smallest type on the page — a 10pt tracked
                // eyebrow and a 10.5pt footer — so they take the elevated
                // substrate rather than the shared floor.
                substrate: BackdropSubstrate.liveElevated
            )
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
// headline, a status ladder, and a one-line "why it matters" footer. The shell
// owns the fixed height and the accessibility contract so no tile can forget
// them.

struct ControlTileShell<Control: View, Ladder: View>: View {
    let kind: ControlKind
    let state: ControlTileState
    let headline: String
    /// Composed into the VoiceOver label so the announcement carries the same
    /// facts the eye gets.
    let accessibilityHeadline: String
    @ViewBuilder let control: () -> Control
    @ViewBuilder let ladder: () -> Ladder

    @Environment(\.backdropInk) private var ink

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            header

            // The hero. Sized so the fact a tile exists to show is the first
            // thing the eye lands on, and `.numericText()` so a live value
            // rolls rather than snaps.
            Text(headline)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isMuted ? ink.secondary : ink.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .truncationMode(.tail)
                .contentTransition(.numericText())
                .padding(.top, 1)

            ladder()

            Spacer(minLength: 2)

            Text(kind.whyItMatters)
                .font(.system(size: 10.5, design: .rounded))
                .foregroundStyle(ink.subtle)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(height: ControlDeckMetrics.collapsedContentHeight, alignment: .topLeading)
        .controlTilePlate(accent: kind.accent, state: state)
        // The footer is clipped to one line to keep the deck dense, so the full
        // sentence has to remain reachable somewhere.
        .help(kind.whyItMatters)
        // `contain`, not `ignore`: Charts cards ignore their children because
        // they are read-only, but deck tiles own controls and VoiceOver must be
        // able to reach and operate them.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(kind.title). \(state.accessibilityDescription). \(accessibilityHeadline).")
        .accessibilityHint(kind.whyItMatters)
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
                .fill(kind.accent.opacity(0.18))
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
                .foregroundStyle(ink.secondary)
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
    var tint: Color = ControlDeckInk.inactive
    var help: String?

    @Environment(\.backdropInk) private var ink

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(ink.secondary)
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

    @Environment(\.backdropInk) private var ink

    var body: some View {
        GeometryReader { proxy in
            let clamped = min(1, max(0, fraction))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(ink.hairline)
                Capsule()
                    .fill(clamped >= 1 ? DesignSystem.Colors.warning : accent)
                    .frame(width: max(2, proxy.size.width * clamped))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}
