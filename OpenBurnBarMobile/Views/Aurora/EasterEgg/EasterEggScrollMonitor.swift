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
    }

    static func dismantleUIView(_ uiView: ProbeView, coordinator: ()) {
        uiView.detach()
    }

    /// The actual probe view. Finds its `UIScrollView` ancestor once it lands in
    /// the hierarchy and observes its scrolling state.
    final class ProbeView: UIView {
        private var surfaceTag = ""
        private var isDark = false
        private var reduceMotion = false
        private weak var scrollView: UIScrollView?
        private var observation: NSKeyValueObservation?

        func apply(tag: String, isDark: Bool, reduceMotion: Bool) {
            surfaceTag = tag
            self.isDark = isDark
            self.reduceMotion = reduceMotion
        }

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
            observation = scroll.observe(\.contentOffset, options: [.new]) { [weak self] scroll, _ in
                self?.report(scroll)
            }
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
