import SwiftUI

// MARK: - AuroraNavGestureModel
//
// Pure, side-effect-free gesture math for the swipe-through navigation
// system. Keeping the resolution logic here (instead of inside view
// gesture closures) makes destination mapping, edge clamping, preview
// transitions, and commit/cancel behavior fully unit-testable without a
// SwiftUI snapshot harness.
//
// Two consumers share this model:
//   • `AuroraNavigationTray` — finger-scrubbing across the bottom pill
//   • `RootTabView` — root-level horizontal page swipes on the content area
//
// The `AuroraNavDestination.allCases` order is the single source of truth:
//   .pulse → .burn → .insights → .streams → .hermes → .you

enum AuroraNavGestureModel {

    // MARK: - Destination index resolution (tray scrub)

    /// Maps a finger's local x-coordinate inside the tray to the nearest
    /// destination index. Edges clamp so dragging past the leftmost or
    /// rightmost tab keeps resolving to the boundary destination.
    ///
    /// - Parameters:
    ///   - x: Finger x-position in the tray's local coordinate space.
    ///   - trayWidth: Total width of the tray content area (the HStack of tabs).
    ///   - count: Number of destinations.
    /// - Returns: Clamped destination index, or `nil` if inputs are degenerate.
    static func destinationIndex(x: CGFloat, trayWidth: CGFloat, count: Int) -> Int? {
        guard count > 0, trayWidth > 0 else { return nil }
        let segmentWidth = trayWidth / CGFloat(count)
        guard segmentWidth > 0 else { return nil }
        // Floor division gives the segment the point falls in. For evenly-
        // spaced segments, the segment boundary equals the midpoint between
        // adjacent tab centers, so floor is equivalent to "nearest center."
        let rawIndex = Int((x / segmentWidth).rounded(.down))
        return clamped(index: rawIndex, count: count)
    }

    /// Convenience: resolve a destination from an x-coordinate.
    ///
    /// Generic over the element type so the same math serves both the legacy
    /// `[AuroraNavDestination]` call sites (tests) and the customizable
    /// `[AuroraNavItem]` tray, where duplicate kinds make identity per-item.
    static func destination<Element>(
        x: CGFloat,
        trayWidth: CGFloat,
        destinations: [Element]
    ) -> Element? {
        guard let index = destinationIndex(x: x, trayWidth: trayWidth, count: destinations.count) else {
            return nil
        }
        return destinations[safe: index]
    }

    // MARK: - Edge clamping

    /// Clamps an index to the valid range `[0, count - 1]`.
    static func clamped(index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index, 0), count - 1)
    }

    // MARK: - Root swipe adjacency

    /// Returns the next or previous destination for a root content swipe,
    /// or `nil` if the swipe direction would push past an edge.
    ///
    /// - Parameters:
    ///   - current: The currently selected destination.
    ///   - direction: `.leading` (swipe right → previous) or `.trailing`
    ///     (swipe left → next).
    ///   - destinations: Ordered destination list.
    /// - Returns: The adjacent destination, or `nil` at an edge.
    static func adjacent<Element: Equatable>(
        current: Element,
        direction: SwipeDirection,
        destinations: [Element]
    ) -> Element? {
        guard let currentIndex = destinations.firstIndex(of: current) else { return nil }
        switch direction {
        case .leading:  // swipe right-to-left visually moves forward? No.
            // Convention: `.leading` means the swipe started from the
            // leading edge and moved toward trailing (left swipe in LTR),
            // advancing to the NEXT tab.
            let next = currentIndex + 1
            return destinations[safe: next]
        case .trailing:
            // `.trailing` means the swipe started from the trailing edge
            // and moved toward leading (right swipe in LTR), going to the
            // PREVIOUS tab.
            let prev = currentIndex - 1
            return destinations[safe: prev]
        }
    }

    /// Determines whether a root swipe gesture has enough horizontal intent
    /// to qualify as a tab change (vs. vertical scrolling inside a tab).
    ///
    /// - Parameters:
    ///   - translation: The drag translation.
    ///   - minimumDistance: Minimum horizontal travel to be considered.
    /// - Returns: The resolved swipe direction, or `nil` if the gesture is
    ///   ambiguous or predominantly vertical.
    static func swipeDirection(
        translation: CGSize,
        minimumDistance: CGFloat = 40
    ) -> SwipeDirection? {
        let absWidth = abs(translation.width)
        let absHeight = abs(translation.height)
        // Must be predominantly horizontal and past the minimum distance.
        guard absWidth > absHeight, absWidth >= minimumDistance else { return nil }
        // Negative width = left swipe = advance forward (leading).
        // Positive width = right swipe = go back (trailing).
        return translation.width < 0 ? .leading : .trailing
    }

    // MARK: - Viewfinder geometry

    /// Computes the center-x of the viewfinder capsule for a given
    /// destination index, useful for the Liquid Glass tracking circle.
    static func viewfinderCenterX(
        index: Int,
        count: Int,
        trayWidth: CGFloat
    ) -> CGFloat {
        guard count > 0, trayWidth > 0 else { return 0 }
        let segmentWidth = trayWidth / CGFloat(count)
        return segmentWidth * (CGFloat(index) + 0.5)
    }

    // MARK: - Reduced-motion animation policy

    /// Returns the animation to use for tab transitions, respecting
    /// Reduce Motion. Under Reduce Motion, transitions are shorter and
    /// use opacity/position only (no spring bounce).
    static func transitionAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeInOut(duration: 0.18)
            : .spring(response: 0.36, dampingFraction: 0.80)
    }

    /// Returns the animation for the viewfinder tracking circle.
    static func viewfinderAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeInOut(duration: 0.12)
            : .spring(response: 0.28, dampingFraction: 0.82)
    }
}

// MARK: - SwipeDirection

extension AuroraNavGestureModel {
    /// Direction of a resolved horizontal swipe.
    ///
    /// - `.leading`: Swipe moves toward the trailing edge (left in LTR),
    ///   advancing to the next tab.
    /// - `.trailing`: Swipe moves toward the leading edge (right in LTR),
    ///   going to the previous tab.
    enum SwipeDirection {
        case leading
        case trailing
    }
}

// MARK: - Scrub gesture phase

/// The lifecycle phase of a tray scrub gesture. Used by both the view
/// layer and tests to reason about commit vs. cancel semantics.
enum AuroraScrubPhase: Equatable {
    /// No active gesture. The tray shows the resting selection.
    case idle
    /// Finger is down and moving across the tray. `preview` follows the
    /// finger; the committed selection has not changed yet.
    case scrubbing(preview: AuroraNavDestination)
    /// Finger released inside the tray with a resolved destination. The
    /// preview becomes the committed selection.
    case committed(AuroraNavDestination)
    /// Gesture cancelled or ended outside the tray. Reverts to the
    /// original resting selection.
    case cancelled
}

// MARK: - Collection safety

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
