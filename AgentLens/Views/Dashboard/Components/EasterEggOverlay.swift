import OpenBurnBarCore
import SwiftUI

// MARK: - Easter egg overlay
//
// A single full-bleed, hit-test-DISABLED overlay mounted ABOVE the dashboard
// scroll content. It IDLES at zero cost — no `TimelineView`, no `Canvas`, no
// timers, no particles — until the controller fires an event, then it mounts a
// `TimelineView(.animation)` + `Canvas` for the event's lifetime and tears the
// whole thing down when the event ends.
//
// Triggers (the "summon"), mirrored verbatim across web + native so every
// surface feels identical:
//   * Rapid up/down scroll (>= 5 direction reversals within ~1.5s) fires ONE
//     theme-appropriate event, then a ~8s cooldown so it can't spam.
//       - Dark appearance  -> "Logo storm": elegant repeated bursts of the
//         BurnBar crests + provider logos popping in, drifting outward,
//         twinkling, and fading over ~4.5s.
//       - Light appearance -> "Cloud token rain": soft grey clouds wearing
//         cloud-tier crests drift across the top and rain golden + silver token
//         coins that fall with gravity and BOUNCE off the screen boundaries,
//         then settle and fade over ~5.5s.
//   * Boundary "you've reached the end": overscrolling at the very TOP or
//     BOTTOM pops a cute little row of gold/silver tokens that bounce once with
//     a soft squash (~0.8s, throttled).
//
// Reduce Motion is honoured: rapid-scroll events collapse to a single calm
// frame and the boundary tap is skipped.
//
// Asset reuse: the logo marks are the SAME bundled imagesets the constellation
// background draws — resolved through `AgentProvider.bundledLogoName` and the
// `CloudTierCrest*` / `AppLogo` crest imagesets — loaded via `NSImage(named:)`,
// exactly like ``UnifiedProviderLogoView`` and ``SwarmCanvasView``. No invented
// asset names.

struct EasterEggOverlay: View {
    @Bindable var controller: EasterEggController

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            // Idle: render nothing at all. No TimelineView, no Canvas, no work.
            if let event = controller.activeEvent {
                EasterEggEventCanvas(
                    event: event,
                    size: proxy.size,
                    colorScheme: colorScheme,
                    reduceMotion: reduceMotion,
                    onFinished: { controller.eventDidFinish(event.id) }
                )
                .id(event.id)
                .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Event model

/// One in-flight easter egg. The controller mints exactly one of these per
/// summon; the overlay renders it and reports back when it has played out.
struct EasterEggEvent: Identifiable, Equatable {
    enum Kind: Equatable {
        /// Dark-appearance celebration: provider-logo + crest fireworks.
        case logoStorm
        /// Light-appearance shower: cloud crests raining gold/silver coins.
        case cloudTokenRain
        /// Edge feedback at the top or bottom of the scroll view.
        case boundary(edge: VerticalEdge)
    }

    let id = UUID()
    let kind: Kind
    /// Wall-clock start so the canvas can compute elapsed time without storing
    /// a baseline of its own.
    let startedAt: Date

    /// Total lifetime of the effect; the canvas fades out and the controller
    /// tears the overlay down once elapsed exceeds this.
    var duration: TimeInterval {
        switch kind {
        case .logoStorm: return 4.6
        case .cloudTokenRain: return 5.6
        case .boundary: return 0.8
        }
    }

    static func == (lhs: EasterEggEvent, rhs: EasterEggEvent) -> Bool {
        lhs.id == rhs.id
    }
}

enum VerticalEdge: Equatable {
    case top
    case bottom
}

// MARK: - Controller

/// Owns scroll-reversal tracking, cooldown gating, the boundary throttle, and
/// the single active event. Lives as long as the dashboard route; costs nothing
/// while idle (it holds plain values, not timers).
@MainActor
@Observable
final class EasterEggController {

    /// The currently playing event, or `nil` when idle. Driving the overlay off
    /// this single optional is what lets the overlay tear down to zero cost.
    private(set) var activeEvent: EasterEggEvent?

    /// Whether rapid-scroll storms are enabled at all (mirrors the website's
    /// motion-respecting summon). The boundary tap is gated separately because
    /// it is a tiny, calm affordance.
    var isEnabled = true

    // Rapid-scroll reversal tracking ------------------------------------------
    private var lastOffset: CGFloat?
    private var lastDirection: Int = 0  // -1 up, +1 down, 0 unknown
    private var reversalTimestamps: [Date] = []

    private let reversalWindow: TimeInterval = 1.5
    private let reversalsToSummon = 5
    private let summonCooldown: TimeInterval = 8.0
    /// Ignore offset jitter below this so a trackpad's micro-noise can't be
    /// mistaken for a reversal.
    private let minReversalDelta: CGFloat = 6

    private var lastSummonAt: Date?

    // Boundary throttle -------------------------------------------------------
    private var lastBoundaryAt: Date?
    private let boundaryCooldown: TimeInterval = 1.2

    // MARK: Scroll input

    /// Feed the overview ScrollView's vertical content offset. `offset` follows
    /// SwiftUI's anchor convention from the preference (more negative = scrolled
    /// further down); only the sign of the delta matters here.
    func registerScrollOffset(_ offset: CGFloat, isDark: Bool) {
        guard isEnabled else { return }
        defer { lastOffset = offset }

        guard let previous = lastOffset else { return }
        let delta = offset - previous
        guard abs(delta) >= minReversalDelta else { return }

        let direction = delta < 0 ? 1 : -1
        defer { lastDirection = direction }
        guard lastDirection != 0, direction != lastDirection else { return }

        // A genuine reversal: record it and prune anything older than the window.
        let now = Date()
        reversalTimestamps.append(now)
        reversalTimestamps.removeAll { now.timeIntervalSince($0) > reversalWindow }

        if reversalTimestamps.count >= reversalsToSummon {
            summonStorm(isDark: isDark)
            reversalTimestamps.removeAll()
        }
    }

    /// Called when the user is pinned at an edge and pushes further. `edge`
    /// names which end they hit.
    func registerBoundaryOverscroll(_ edge: VerticalEdge, reduceMotion: Bool) {
        guard isEnabled, !reduceMotion else { return }
        let now = Date()
        if let last = lastBoundaryAt, now.timeIntervalSince(last) < boundaryCooldown {
            return
        }
        // A storm already in flight owns the screen; don't stack a boundary tap.
        guard activeEvent == nil else { return }
        lastBoundaryAt = now
        present(EasterEggEvent(kind: .boundary(edge: edge), startedAt: now))
    }

    // MARK: Summon + teardown

    private func summonStorm(isDark: Bool) {
        let now = Date()
        if let last = lastSummonAt, now.timeIntervalSince(last) < summonCooldown {
            return
        }
        guard activeEvent == nil else { return }
        lastSummonAt = now
        let kind: EasterEggEvent.Kind = isDark ? .logoStorm : .cloudTokenRain
        present(EasterEggEvent(kind: kind, startedAt: now))
    }

    private func present(_ event: EasterEggEvent) {
        withAnimation(.easeOut(duration: 0.2)) {
            activeEvent = event
        }
    }

    /// The overlay calls this once an event has played out so the controller can
    /// drop back to the zero-cost idle state.
    func eventDidFinish(_ id: UUID) {
        guard activeEvent?.id == id else { return }
        withAnimation(.easeIn(duration: 0.25)) {
            activeEvent = nil
        }
    }
}

// MARK: - Scroll offset reporting

/// Reports the overview ScrollView's vertical content offset up the tree.
/// Mirrors the canonical SwiftUI "named-coordinate-space minY" pattern so the
/// detector reads one monotonic number per frame.
struct EasterEggScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

extension View {
    /// Drop this inside a `ScrollView`'s content `.background` to publish its
    /// scroll offset (and content height) for easter egg detection. `space` is
    /// the name of the `.coordinateSpace` placed on the `ScrollView`.
    func easterEggScrollProbe(space: String) -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: EasterEggScrollOffsetKey.self,
                    value: geo.frame(in: .named(space)).minY
                )
            }
        )
    }
}
