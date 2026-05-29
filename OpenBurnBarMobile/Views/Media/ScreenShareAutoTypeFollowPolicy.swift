import Foundation
import OpenBurnBarCore

/// Pure open/close keyboard policy for Mercury screen-share auto-type.
enum ScreenShareAutoTypeFollowPolicy {
    static let staleAfter: TimeInterval = 1.5
    static let minimumConfidence: Double = 0.5

    /// Whether the Mac is currently reporting a focused text element on the selected
    /// display, fresh and confident enough to act on. Used to surface the
    /// "double-tap to type" coaching hint at the right moment.
    static func isActiveTextFocus(
        context: ScreenShareSmartZoomContext,
        selectedDisplayId: String?,
        now: Date
    ) -> Bool {
        guard context.targetKind == .focusedElement else { return false }
        guard now.timeIntervalSince(context.receivedAt) <= staleAfter else { return false }
        if let target = context.displayId,
           let selected = selectedDisplayId,
           target != selected {
            return false
        }
        if let confidence = context.confidence, confidence < minimumConfidence {
            return false
        }
        return true
    }
}
