import SwiftUI

// MARK: - Easter egg scroll probe
//
// The iOS scroll-input bridge for the easter egg. It walks up to the underlying
// `UIScrollView` of any tracked `ScrollView` and observes its real
// `contentOffset` via KVO, translating the offset into the same anchor
// convention the shared ``EasterEggController`` uses on every platform: `0` at
// the very top, growing negative as the user scrolls down.
//
// Observing the real `UIScrollView` — rather than a SwiftUI coordinate-space
// frame — keeps a single `.trackEasterEggScroll(tag:)` modifier attachable
// directly to the `ScrollView` (a SwiftUI `minY` reader would have to live
// inside the scroll content), works on the iOS 17 deployment target, and
// reports the live offset even during rubber-band over-scroll, which the
// top/bottom boundary effect needs. The probe adds no visible views and runs
// nothing until the scroll view actually moves.

#if canImport(UIKit)
import UIKit

/// A zero-size probe placed in a tracked `ScrollView`'s background. It finds its
/// enclosing `UIScrollView` once it lands in the hierarchy and forwards every
/// offset change to ``EasterEggController/shared``.
private struct EasterEggScrollProbe: UIViewRepresentable {
    let tag: String
    let isDark: Bool
    let reduceMotion: Bool

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.apply(tag: tag, isDark: isDark, reduceMotion: reduceMotion)
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.apply(tag: tag, isDark: isDark, reduceMotion: reduceMotion)
        // A SwiftUI update can mean the active ScrollView changed (e.g. a Streams
        // segment swap mounts a different scroll view under the same probe).
        // Re-validate so we always observe the live scroller.
        uiView.revalidate()
    }

    static func dismantleUIView(_ uiView: ProbeView, coordinator: ()) {
        uiView.detach()
    }

    /// The actual probe view. Finds the `UIScrollView` it should observe once it
    /// lands in the hierarchy and watches its scrolling state.
    ///
    /// Robust attachment is the whole point: depending on where
    /// `.trackEasterEggScroll` is applied, the target `UIScrollView` can be an
    /// ANCESTOR of the probe (when applied directly to a `ScrollView`, as in
    /// Burn/Pulse) or a DESCENDANT of the probe's host (when applied to a
    /// container whose children each hold a `ScrollView`, as in Streams' segment
    /// `Group`). We search ancestors first, then descendants, and retry a couple
    /// of times because the scroll view may mount a frame or two after the probe.
    final class ProbeView: UIView {
        private var surfaceTag = ""
        private var isDark = false
        private var reduceMotion = false
        private weak var scrollView: UIScrollView?
        private var observation: NSKeyValueObservation?
        private var attachAttempts = 0
        private let maxAttachAttempts = 8

        func apply(tag: String, isDark: Bool, reduceMotion: Bool) {
            surfaceTag = tag
            self.isDark = isDark
            self.reduceMotion = reduceMotion
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                attachAttempts = 0
                attachIfNeeded()
            } else {
                detach()
            }
        }

        private func attachIfNeeded() {
            guard window != nil, scrollView == nil else { return }
            if let scroll = locateScrollView() {
                bind(scroll)
                return
            }
            // The ScrollView may not be in the tree yet (SwiftUI mounts content
            // lazily / a frame later). Retry briefly before giving up.
            guard attachAttempts < maxAttachAttempts else { return }
            attachAttempts += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.attachIfNeeded()
            }
        }

        /// Search ancestors first (modifier on the ScrollView), then the nearest
        /// common host's descendant subtree (modifier on a container above the
        /// ScrollViews). Picks the largest descendant scroll view so we bind the
        /// real content scroller, not an incidental inner one.
        private func locateScrollView() -> UIScrollView? {
            var ancestor: UIView? = superview
            while let current = ancestor {
                if let scroll = current as? UIScrollView { return scroll }
                ancestor = current.superview
            }
            // Walk up to a host that has siblings/children beyond the probe, then
            // search that subtree downward for the active scroll view.
            var host: UIView? = superview ?? self
            while let current = host {
                if let scroll = largestScrollView(in: current) { return scroll }
                host = current.superview
            }
            return nil
        }

        private func largestScrollView(in root: UIView) -> UIScrollView? {
            var best: UIScrollView?
            var stack: [UIView] = root.subviews
            while let view = stack.popLast() {
                if let scroll = view as? UIScrollView, scroll !== self {
                    let area = scroll.bounds.width * scroll.bounds.height
                    let bestArea = best.map { $0.bounds.width * $0.bounds.height } ?? 0
                    if area > bestArea { best = scroll }
                }
                stack.append(contentsOf: view.subviews)
            }
            return best
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // Rebind opportunistically once the host has laid out its content,
            // which is when a freshly-mounted ScrollView first has real bounds.
            revalidate()
        }

        /// Re-attach if we lost our scroll view (it deallocated on a segment
        /// swap) or if a larger, now-active scroll view should be observed
        /// instead. Cheap and idempotent.
        func revalidate() {
            guard window != nil else { return }
            if scrollView == nil {
                attachAttempts = 0
                attachIfNeeded()
                return
            }
            // If a different scroll view is now the active content scroller,
            // switch the observation to it.
            if let active = locateScrollView(), active !== scrollView {
                rebind(active)
            }
        }

        private func bind(_ scroll: UIScrollView) {
            scrollView = scroll
            observation = scroll.observe(\.contentOffset, options: [.new]) { [weak self] scroll, _ in
                // KVO on `contentOffset` is delivered on the main thread, and
                // `ProbeView` is `@MainActor` (UIView), so this is safe to treat
                // as isolated — that also keeps `report` reading UI state directly.
                MainActor.assumeIsolated { self?.report(scroll) }
            }
        }

        private func rebind(_ scroll: UIScrollView) {
            observation?.invalidate()
            observation = nil
            bind(scroll)
        }

        private func report(_ scroll: UIScrollView) {
            // UIScrollView: `contentOffset.y + inset.top == 0` at rest at the
            // top, positive scrolling down. The controller wants the SwiftUI
            // convention (0 at top, negative scrolling down), so negate.
            let top = scroll.adjustedContentInset.top
            let bottom = scroll.adjustedContentInset.bottom
            let offset = -(scroll.contentOffset.y + top)
            let viewport = scroll.bounds.height - top - bottom
            let content = scroll.contentSize.height
            let tag = surfaceTag
            let dark = isDark
            let rm = reduceMotion
            Task { @MainActor in
                EasterEggController.shared.registerScrollMetrics(
                    tag: tag,
                    offset: offset,
                    contentHeight: content,
                    viewportHeight: viewport,
                    isDark: dark,
                    reduceMotion: rm
                )
            }
        }

        func detach() {
            let wasBound = scrollView != nil
            observation?.invalidate()
            observation = nil
            scrollView = nil
            guard wasBound else { return }
            let tag = surfaceTag
            Task { @MainActor in EasterEggController.shared.forget(tag: tag) }
        }
    }
}

private struct TrackEasterEggScrollModifier: ViewModifier {
    let tag: String
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.background {
            EasterEggScrollProbe(
                tag: tag,
                isDark: colorScheme == .dark,
                reduceMotion: reduceMotion
            )
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
    /// Feed this scroll view's live vertical offset into the shared
    /// ``EasterEggController``, enabling the rapid up/down "summon" gesture and
    /// the top/bottom "you've reached the end" edge bounce on this surface.
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
