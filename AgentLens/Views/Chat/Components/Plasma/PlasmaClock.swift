import SwiftUI

// MARK: - One clock per surface
//
// Every plasma element is a pure function of time, which means a whole field of
// them can share a single `TimelineView` instead of each waking the display
// link on its own schedule. A twelve-orb constellation with twelve private
// timelines is twelve scheduler wake-ups and twelve view invalidations per
// frame for one visual result; with one clock it is one.
//
// The tick also carries whether motion is running at all, so Reduce Motion and
// the closed/idle case resolve to a *deterministic still pose* rather than to a
// paused-at-whatever-frame-we-stopped-on pose.

/// A single frame of plasma time.
struct PlasmaTick: Equatable {
    let date: Date
    let isAnimating: Bool

    /// The pose everything holds when motion is off. Time zero is the first
    /// keyframe of every track, so a still plasma orb is the silhouette the
    /// asset authored as its resting state — not an arbitrary sample.
    static let still = PlasmaTick(date: Date(timeIntervalSinceReferenceDate: 0), isAnimating: false)
}

/// Drives its content at 30fps while `isRunning`, and honours Reduce Motion.
///
/// 30fps rather than the display's native rate is deliberate: these are slow
/// 7–11 second organic drifts with no fast edges, where the extra frames are
/// invisible and the extra power is not.
struct PlasmaClock<Content: View>: View {
    var isRunning: Bool = true
    @ViewBuilder var content: (PlasmaTick) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var animates: Bool { isRunning && !reduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animates)) { context in
            content(animates ? PlasmaTick(date: context.date, isAnimating: true) : .still)
        }
    }
}
