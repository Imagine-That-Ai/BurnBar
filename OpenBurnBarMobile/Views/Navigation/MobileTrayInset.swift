import SwiftUI

// MARK: - Tray geometry
//
// The floating navigation tray remains a ZStack overlay so its glass and
// higher-priority live stages keep their existing composition order. RootTabView
// now publishes one clear `safeAreaInset` beneath the primary content, however,
// so every iPhone tab receives the same reservation automatically:
//
//     tray visible   -> pillHeight + pillBottomInset
//     tray hidden    -> 0
//     iPad sidebar   -> no RootTabView, therefore no reservation
//
// Keeping this policy beside the rendered geometry prevents another set of
// per-screen 70/76/96pt guesses from drifting apart.

/// Geometry of the floating navigation tray.
enum MobileTrayMetrics {
    /// Height of the pill itself.
    static let pillHeight: CGFloat = 62
    /// Gap between the pill and the bottom safe area.
    static let pillBottomInset: CGFloat = 14
    /// Minimum space between the floating pill and either screen edge.
    static let minimumEdgeMargin: CGFloat = 12
    /// Horizontal breathing room inside the glass capsule.
    static let pillSidePadding: CGFloat = 6
    /// What a screen must reserve so its last row clears the tray.
    static var occupiedHeight: CGFloat { pillHeight + pillBottomInset }

    /// The rendered capsule width for a given compact-width container.
    static func pillWidth(containerWidth: CGFloat) -> CGFloat {
        max(0, containerWidth - minimumEdgeMargin * 2)
    }

    /// Equal-width destination slot derived from the real available width.
    static func tabWidth(containerWidth: CGFloat, destinationCount: Int) -> CGFloat {
        guard destinationCount > 0 else { return 0 }
        let contentWidth = max(0, pillWidth(containerWidth: containerWidth) - pillSidePadding * 2)
        return contentWidth / CGFloat(destinationCount)
    }

    /// The root-level safe-area reservation for the current visibility state.
    static func reservedHeight(isVisible: Bool) -> CGFloat {
        isVisible ? occupiedHeight : 0
    }
}
