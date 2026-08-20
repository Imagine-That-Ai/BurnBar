import SwiftUI

// MARK: - Tray inset
//
// The floating navigation tray is a `ZStack` overlay, not a `safeAreaInset`, so
// nothing below it is inset automatically and every scrolling screen has to
// reserve the space itself. That reservation was a magic number, copied by hand,
// four times and never the same twice:
//
//     BurnView              .padding(.bottom, 100)   // unconditional
//     PulseView             .padding(.bottom, xxl)
//     the tray itself       62 + 14 = 76, in two `private let`s
//
// Two bugs fell out of that. On iPhone the reservations disagreed with the real
// 76pt, so the last card either floated above the tray or hid under it. On iPad
// there is no tray at all — `RootNavigationView` uses a sidebar — and the
// unconditional 100pt became a guaranteed 100pt of dead space at the bottom of
// every screen, on the platform with the most room to waste.
//
// One number, published by whichever root actually draws a tray. A screen asks
// the environment instead of guessing, and the iPad answer is `0` because the
// default is `0` and the sidebar root never sets it.

/// Geometry of the floating navigation tray.
enum MobileTrayMetrics {
    /// Height of the pill itself.
    static let pillHeight: CGFloat = 62
    /// Gap between the pill and the bottom safe area.
    static let pillBottomInset: CGFloat = 14
    /// What a screen must reserve so its last row clears the tray.
    static var occupiedHeight: CGFloat { pillHeight + pillBottomInset }
}

private struct MobileTrayInsetKey: EnvironmentKey {
    /// No tray unless a root says otherwise — which is exactly the iPad answer.
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// Bottom space reserved by the floating navigation tray, or `0` where no
    /// tray is drawn.
    var mobileTrayInset: CGFloat {
        get { self[MobileTrayInsetKey.self] }
        set { self[MobileTrayInsetKey.self] = newValue }
    }
}
