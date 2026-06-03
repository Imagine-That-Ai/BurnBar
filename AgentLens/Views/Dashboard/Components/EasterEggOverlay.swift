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
// Triggers (the "summon"), mirrored verbatim against the burnbar.ai `#bgFx`
// engine so every surface feels identical:
//   * Rapid up/down scroll (>= 5 direction REVERSALS within ~1.5s) fires ONE
//     theme-appropriate 5-second takeover, then a 9s cooldown so it can't spam.
//       - Dark appearance  -> "Logo storm": 96 BurnBar-crest + provider-logo
//         sprites explode as fireworks and periodically CONVERGE into typographic
//         shapes ($ :) </> { }) by spring-pulling each sprite to a glyph point,
//         over the spec's phase timeline.
//       - Light appearance -> "Cloud token rain": 7 large fluffy procedural
//         clouds drift overhead and rain gold + silver coins with real gravity,
//         air drag, restitution, wall/floor bounces, a settle phase, and an
//         edge-on FLIP coin render.
//   * Boundary "you've reached the end": overscrolling at the very TOP or BOTTOM
//     pops a row of 10 gold/silver coins that arc out under REVERSE gravity and
//     fall back (~0.95s, throttled), independent of theme and of any takeover.
//
// Reduce Motion is honoured: the storm, the rain, AND the boundary pop are all
// suppressed entirely (the simulation no-ops at `begin`).
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
                    // macOS has no DOM ledge geometry to mirror the website's
                    // `.btn/.card/h1…` rects; the spec permits an empty set, so
                    // rain coins bounce off the walls + floor only.
                    ledges: [],
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
        case boundary(edge: EasterEggEdge)
    }

    let id = UUID()
    let kind: Kind
    /// Wall-clock start so the canvas can compute elapsed time without storing
    /// a baseline of its own.
    let startedAt: Date

    /// Total lifetime of the effect; the canvas fades out and the controller
    /// tears the overlay down once elapsed exceeds this. The 5s takeover length
    /// (`EasterEggFX.duration`) plus each flavour's tail:
    ///   * storm  — sparks clear exactly at FXDUR; a short tail covers the fade.
    ///   * rain   — tokens are removed by FXDUR+800ms and the mode idles once the
    ///     field empties, so ~5.9s covers the longest fall.
    ///   * boundary — coins die at t > 0.95s (one ballistic arc).
    var duration: TimeInterval {
        switch kind {
        case .logoStorm: return EasterEggFX.duration + 0.3       // 5.3s
        case .cloudTokenRain: return EasterEggFX.duration + 0.9  // 5.9s
        case .boundary: return 1.0
        }
    }

    static func == (lhs: EasterEggEvent, rhs: EasterEggEvent) -> Bool {
        lhs.id == rhs.id
    }
}

enum EasterEggEdge: Equatable {
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
    private let summonCooldown: TimeInterval = 9.0  // matches the website's 9000ms
    /// Ignore offset jitter below this so a trackpad's micro-noise can't be
    /// mistaken for a reversal.
    private let minReversalDelta: CGFloat = 6

    private var lastSummonAt: Date?

    // Boundary throttle -------------------------------------------------------
    private var lastBoundaryAt: Date?
    private let boundaryCooldown: TimeInterval = 1.2
    /// Overscroll past the natural extent (in points) before a boundary tap
    /// fires, so resting exactly at an edge doesn't trigger it.
    private let boundaryOverscroll: CGFloat = 14

    // MARK: Scroll input

    /// Feed the overview ScrollView's scroll geometry once per frame. Handles
    /// both the rapid up/down reversal summon and the top/bottom boundary tap.
    ///
    /// `offset` follows SwiftUI's anchor convention: `0` at the very top and
    /// growing negative as the user scrolls down. `contentHeight` and
    /// `viewportHeight` let us recognise the bottom edge.
    func registerScrollMetrics(
        offset: CGFloat,
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        isDark: Bool,
        reduceMotion: Bool
    ) {
        guard isEnabled else { return }
        detectReversal(offset: offset, isDark: isDark, reduceMotion: reduceMotion)
        detectBoundary(
            offset: offset,
            contentHeight: contentHeight,
            viewportHeight: viewportHeight,
            reduceMotion: reduceMotion
        )
    }

    private func detectReversal(offset: CGFloat, isDark: Bool, reduceMotion: Bool) {
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
            // Reversal threshold reached: arm the cooldown and clear the window
            // even under Reduce Motion (so the spec's "abort before any takeover"
            // still consumes the gesture), then summon only when motion is allowed.
            reversalTimestamps.removeAll()
            summonStorm(isDark: isDark, reduceMotion: reduceMotion)
        }
    }

    private func detectBoundary(
        offset: CGFloat,
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        reduceMotion: Bool
    ) {
        guard !reduceMotion else { return }
        // Bouncy scroll views push `offset` positive at the top and below the
        // floor at the bottom once the user overscrolls.
        let scrollable = contentHeight - viewportHeight
        if offset > boundaryOverscroll {
            fireBoundary(.top)
        } else if scrollable > 1, offset < -(scrollable + boundaryOverscroll) {
            fireBoundary(.bottom)
        }
    }

    private func fireBoundary(_ edge: EasterEggEdge) {
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

    private func summonStorm(isDark: Bool, reduceMotion: Bool) {
        let now = Date()
        if let last = lastSummonAt, now.timeIntervalSince(last) < summonCooldown {
            return
        }
        guard activeEvent == nil else { return }
        lastSummonAt = now
        // Reduce Motion: the gesture is consumed (cooldown armed above) but no
        // takeover is presented, matching the website's reduced-motion abort.
        guard !reduceMotion else { return }
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

/// One frame's scroll geometry: the content's top offset within the scroll's
/// named coordinate space (≤ 0 once scrolled), plus the content height so the
/// detector can recognise the bottom boundary.
struct EasterEggScrollMetrics: Equatable, Sendable {
    var offset: CGFloat = 0
    var contentHeight: CGFloat = 0
}

/// Reports the overview ScrollView's scroll geometry up the tree. Mirrors the
/// canonical SwiftUI "named-coordinate-space minY" pattern so the detector
/// reads one monotonic number per frame.
struct EasterEggScrollMetricsKey: PreferenceKey {
    static let defaultValue = EasterEggScrollMetrics()
    static func reduce(value: inout EasterEggScrollMetrics, nextValue: () -> EasterEggScrollMetrics) {
        let next = nextValue()
        // Keep the meaningful (non-default) report.
        if next != EasterEggScrollMetrics() { value = next }
    }
}

extension View {
    /// Drop this inside a `ScrollView`'s content `.background` to publish its
    /// scroll offset + content height for easter egg detection. `space` is the
    /// name of the `.coordinateSpace` placed on the `ScrollView`.
    func easterEggScrollProbe(space: String) -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: EasterEggScrollMetricsKey.self,
                    value: EasterEggScrollMetrics(
                        offset: geo.frame(in: .named(space)).minY,
                        contentHeight: geo.size.height
                    )
                )
            }
        )
    }
}
