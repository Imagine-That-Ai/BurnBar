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

#if canImport(UIKit)
import UIKit

/// A zero-size probe placed in a tracked `ScrollView`'s background. It walks up
/// to its enclosing `UIScrollView` and observes `contentOffset` (and the
/// content/bounds sizes) via KVO, forwarding every change to the shared
/// monitor.
///
/// Reading the real `UIScrollView` — rather than a SwiftUI coordinate-space
/// frame — works on the iOS 17 deployment target and reports the live offset
/// even during rubber-band over-scroll, which the top/bottom boundary effect
/// needs. The probe adds no views and runs nothing until the scroll view moves.
private struct EasterEggScrollProbe: UIViewRepresentable {
    let tag: String

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.tag2 = tag
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.tag2 = tag
    }

    static func dismantleUIView(_ uiView: ProbeView, coordinator: ()) {
        uiView.detach()
    }

    /// The actual probe view. Finds its `UIScrollView` ancestor once it lands in
    /// the hierarchy and observes its scrolling state.
    final class ProbeView: UIView {
        var tag2: String = ""
        private weak var scrollView: UIScrollView?
        private var observations: [NSKeyValueObservation] = []

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                attachIfNeeded()
            } else {
                detach()
            }
        }

        private func attachIfNeeded() {
            guard scrollView == nil else { return }
            var ancestor: UIView? = superview
            while let current = ancestor {
                if let scroll = current as? UIScrollView {
                    bind(scroll)
                    return
                }
                ancestor = current.superview
            }
        }

        private func bind(_ scroll: UIScrollView) {
            scrollView = scroll
            let report: (UIScrollView) -> Void = { [weak self] scroll in
                guard let self else { return }
                let monitorTag = self.tag2
                let offset = scroll.contentOffset.y + scroll.adjustedContentInset.top
                let viewport = scroll.bounds.height
                    - scroll.adjustedContentInset.top
                    - scroll.adjustedContentInset.bottom
                let content = scroll.contentSize.height
                Task { @MainActor in
                    EasterEggScrollMonitor.shared.ingest(
                        offset: offset,
                        viewportHeight: viewport,
                        contentHeight: content,
                        tag: monitorTag
                    )
                }
            }
            observations = [
                scroll.observe(\.contentOffset, options: [.new]) { scroll, _ in report(scroll) }
            ]
        }

        func detach() {
            let wasBound = scrollView != nil
            observations.forEach { $0.invalidate() }
            observations.removeAll()
            scrollView = nil
            guard wasBound else { return }
            let monitorTag = tag2
            Task { @MainActor in EasterEggScrollMonitor.shared.forget(tag: monitorTag) }
        }
    }
}

private struct TrackEasterEggScrollModifier: ViewModifier {
    /// Distinct tag per surface so reversals don't bleed across tabs.
    let tag: String

    func body(content: Content) -> some View {
        content.background {
            EasterEggScrollProbe(tag: tag)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
    }
}
#else
private struct TrackEasterEggScrollModifier: ViewModifier {
    let tag: String
    func body(content: Content) -> some View { content }
}
#endif

extension View {
    /// Feed this scroll view's live vertical offset into the app-scope
    /// `EasterEggScrollMonitor`, enabling the rapid up/down "summon" gesture
    /// and the top/bottom "you've reached the end" edge bounce on this surface.
    ///
    /// Apply directly to a `ScrollView`. The probe walks up to the underlying
    /// `UIScrollView` and observes its real offset, so over-scroll at the very
    /// top/bottom registers for the boundary effect. The `tag` keeps each
    /// surface's reversal counter independent so switching tabs never injects a
    /// phantom flip from another scroll view's offset.
    func trackEasterEggScroll(tag: String) -> some View {
        modifier(TrackEasterEggScrollModifier(tag: tag))
    }
}
