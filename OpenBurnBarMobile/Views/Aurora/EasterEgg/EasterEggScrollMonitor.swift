import SwiftUI
import Combine

// MARK: - Easter Egg Scroll Monitor
//
// A tiny, app-scope detector that the primary scroll surfaces (Pulse / Burn /
// Streams) feed their live vertical offset into via `.trackEasterEggScroll()`.
// The root-mounted `EasterEggOverlay` observes the monitor and idles at zero
// cost until the monitor publishes an event:
//
// • `.summon`   — the user rapidly scrolled UP-and-DOWN (>= reversalThreshold
//   direction reversals inside reversalWindow). Throttled by summonCooldown so
//   it can't spam. Theme-resolved by the overlay (Logo Storm / Cloud Rain).
// • `.boundary` — the user is pinned at the very top or bottom and tried to
//   pull further. A small "you've reached the end" token bounce plays at that
//   edge. Throttled by boundaryCooldown, quick and elegant.
//
// Detection is deliberately offset-based (a `GeometryReader` + `PreferenceKey`
// reader inside each scroll view) rather than `onScrollGeometryChange`, which
// is iOS 18+. The iOS deployment target here is 17.0, so the preference-key
// path keeps the trigger working everywhere the app runs.

/// One theme-resolved easter-egg event. The overlay maps `.summon` to Logo
/// Storm (dark) or Cloud Token Rain (light) using the active color scheme, and
/// `.boundary` to the cute edge-token bounce.
enum EasterEggEvent: Equatable {
    /// Rapid up/down "shake" — fire the full celebration.
    case summon
    /// At-the-end over-pull. `atTop` picks which edge the tokens pop from.
    case boundary(atTop: Bool)
}

/// App-scope detector shared by every primary scroll surface. A single
/// instance keeps the reversal counter and cooldowns coherent even as the
/// user swaps tabs, so the gesture always means the same thing.
@MainActor
final class EasterEggScrollMonitor: ObservableObject {
    static let shared = EasterEggScrollMonitor()

    /// The most recent event. The overlay subscribes and plays it once, then
    /// the value lingers (events compare by payload, so an identical repeat
    /// still needs the `eventID` tiebreaker below to re-fire).
    @Published private(set) var event: EasterEggEvent?
    /// Monotonic id so the overlay re-triggers even when two consecutive
    /// events are equal (e.g. two summons in a row after the cooldown).
    @Published private(set) var eventID: Int = 0

    // MARK: Tuning

    /// Reversals needed inside `reversalWindow` to summon. ">= 5" per spec.
    private let reversalThreshold = 5
    /// Sliding window the reversals must land inside. "~1.5s" per spec.
    private let reversalWindow: TimeInterval = 1.5
    /// Minimum gap between two summons so the gesture can't spam. "~8s".
    private let summonCooldown: TimeInterval = 8.0
    /// Minimum gap between two edge bounces. "throttled, quick".
    private let boundaryCooldown: TimeInterval = 0.8
    /// A reversal only counts once the offset has travelled at least this far
    /// since the last pivot — filters out sub-pixel jitter / rubber-banding.
    private let reversalMinTravel: CGFloat = 14
    /// How far past the natural top/bottom resting offset the user must pull
    /// for an over-scroll to read as "reached the end".
    private let boundaryOverpull: CGFloat = 24

    // MARK: Per-surface tracking state

    /// Tracked separately per coordinate-space tag so switching tabs doesn't
    /// inject a phantom reversal from a different scroll view's offset.
    private struct SurfaceState {
        var lastOffset: CGFloat = .nan
        var pivotOffset: CGFloat = .nan
        var direction: Int = 0 // -1 up, +1 down, 0 unknown
        var reversalTimes: [Date] = []
        var lastBoundaryFire: Date = .distantPast
    }
    private var surfaces: [String: SurfaceState] = [:]
    private var lastSummon: Date = .distantPast

    private init() {}

    // MARK: Ingest

    /// Feed a fresh sample from a tracked scroll surface.
    ///
    /// - Parameters:
    ///   - offset: The scroll view's content offset in its own space. The
    ///     reader reports the negated min-Y of the content, so larger = farther
    ///     down. Resting position is ~`0` at the top.
    ///   - viewportHeight: Height of the visible scroll viewport.
    ///   - contentHeight: Height of the scrolled content.
    ///   - tag: Stable per-surface identity (the coordinate-space name).
    func ingest(offset: CGFloat, viewportHeight: CGFloat, contentHeight: CGFloat, tag: String) {
        var state = surfaces[tag] ?? SurfaceState()
        defer { surfaces[tag] = state }

        let now = Date()

        // First sample for this surface — seed and bail (no delta yet).
        guard state.lastOffset.isFinite else {
            state.lastOffset = offset
            state.pivotOffset = offset
            return
        }

        detectReversal(offset: offset, now: now, state: &state)
        detectBoundary(
            offset: offset,
            viewportHeight: viewportHeight,
            contentHeight: contentHeight,
            now: now,
            state: &state
        )

        state.lastOffset = offset
    }

    /// Drop a surface's tracking state when its scroll view disappears so a
    /// stale offset never seeds a false reversal on the next appearance.
    func forget(tag: String) {
        surfaces[tag] = nil
    }

    // MARK: Reversal → summon

    private func detectReversal(offset: CGFloat, now: Date, state: inout SurfaceState) {
        let delta = offset - state.lastOffset
        guard abs(delta) > 0.5 else { return } // ignore noise / still frames

        let newDirection = delta > 0 ? 1 : -1
        if state.direction == 0 {
            state.direction = newDirection
            state.pivotOffset = offset
            return
        }

        guard newDirection != state.direction else { return }

        // Direction flipped — only count it once the swing since the last
        // pivot cleared the jitter floor, so a real up/down shake registers
        // but rubber-band wobble does not.
        let travel = abs(offset - state.pivotOffset)
        state.direction = newDirection
        state.pivotOffset = offset
        guard travel >= reversalMinTravel else { return }

        state.reversalTimes.append(now)
        state.reversalTimes.removeAll { now.timeIntervalSince($0) > reversalWindow }

        guard state.reversalTimes.count >= reversalThreshold else { return }
        guard now.timeIntervalSince(lastSummon) >= summonCooldown else { return }

        lastSummon = now
        state.reversalTimes.removeAll()
        fire(.summon)
    }

    // MARK: Boundary → edge bounce

    private func detectBoundary(
        offset: CGFloat,
        viewportHeight: CGFloat,
        contentHeight: CGFloat,
        now: Date,
        state: inout SurfaceState
    ) {
        guard contentHeight > viewportHeight else { return } // nothing to scroll
        guard now.timeIntervalSince(state.lastBoundaryFire) >= boundaryCooldown else { return }

        let maxOffset = contentHeight - viewportHeight

        if offset < -boundaryOverpull {
            // Pulled past the top resting position.
            state.lastBoundaryFire = now
            fire(.boundary(atTop: true))
        } else if offset > maxOffset + boundaryOverpull {
            // Pulled past the bottom.
            state.lastBoundaryFire = now
            fire(.boundary(atTop: false))
        }
    }

    private func fire(_ event: EasterEggEvent) {
        self.event = event
        eventID &+= 1
    }
}

// MARK: - Tracking modifier

/// The named coordinate space every tracked scroll view shares so its content
/// offset reads against a stable frame.
private enum EasterEggScroll {
    static let coordinateSpace = "EasterEggScrollSpace"
}

/// PreferenceKey carrying the live offset + geometry of a tracked scroll view
/// up to the modifier, which forwards it to the shared monitor.
private struct EasterEggScrollSample: Equatable {
    var offset: CGFloat
    var viewportHeight: CGFloat
    var contentHeight: CGFloat
}

private struct EasterEggScrollPreferenceKey: PreferenceKey {
    static let defaultValue: EasterEggScrollSample? = nil
    static func reduce(value: inout EasterEggScrollSample?, nextValue: () -> EasterEggScrollSample?) {
        value = nextValue() ?? value
    }
}

private struct TrackEasterEggScrollModifier: ViewModifier {
    /// Distinct tag per surface so reversals don't bleed across tabs.
    let tag: String

    func body(content: Content) -> some View {
        content
            // A zero-size reader pinned to the scroll content reports the
            // content's min-Y against the viewport's coordinate space; negate
            // it so "scrolled down" reads as a growing positive offset.
            .background {
                GeometryReader { contentProxy in
                    let space = EasterEggScroll.coordinateSpace
                    let frame = contentProxy.frame(in: .named(space))
                    Color.clear.preference(
                        key: EasterEggScrollPreferenceKey.self,
                        value: EasterEggScrollSample(
                            offset: -frame.minY,
                            viewportHeight: viewportHeight(contentProxy, space: space),
                            contentHeight: frame.height
                        )
                    )
                }
            }
            .coordinateSpace(name: EasterEggScroll.coordinateSpace)
            .onPreferenceChange(EasterEggScrollPreferenceKey.self) { sample in
                guard let sample else { return }
                Task { @MainActor in
                    EasterEggScrollMonitor.shared.ingest(
                        offset: sample.offset,
                        viewportHeight: sample.viewportHeight,
                        contentHeight: sample.contentHeight,
                        tag: tag
                    )
                }
            }
            .onDisappear { EasterEggScrollMonitor.shared.forget(tag: tag) }
    }

    /// The viewport height is the height of the named coordinate space's own
    /// frame; reading the global frame's height through the same proxy keeps
    /// the boundary math self-contained without a second GeometryReader.
    private func viewportHeight(_ proxy: GeometryProxy, space: String) -> CGFloat {
        // The coordinate-space frame is anchored to the scroll view itself, so
        // its size equals the viewport. `proxy.size` reflects the content's
        // size; the viewport is recovered from the space's bounds.
        proxy.bounds(of: .named(space))?.height ?? proxy.size.height
    }
}

extension View {
    /// Feed this scroll view's live vertical offset into the app-scope
    /// `EasterEggScrollMonitor`, enabling the rapid up/down "summon" gesture
    /// and the top/bottom "you've reached the end" edge bounce on this surface.
    ///
    /// Apply directly to a `ScrollView`. The `tag` keeps each surface's
    /// reversal counter independent so switching tabs never injects a phantom
    /// flip from another scroll view's offset.
    func trackEasterEggScroll(tag: String) -> some View {
        modifier(TrackEasterEggScrollModifier(tag: tag))
    }
}
