// Pure interaction / control-input policies (mode, tray, smart-text, double-tap).
// Extracted from ScreenShareViewerView.swift (behavior-preserving split).
import SwiftUI
@preconcurrency import AVKit
@preconcurrency import MediaPlayer
#if canImport(UIKit)
import UIKit
#endif
import OpenBurnBarMedia
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

enum ScreenShareInteractionMode: Equatable {
    case view
    case control
    case trackpad
    case coPilot
}

enum ScreenShareInteractionModePolicy {
    /// Controller viewers should enter control mode immediately so direct taps
    /// become signed Mac input intents. Watchers stay in view mode for pan/zoom.
    static func defaultMode(controlInputEnabled: Bool) -> ScreenShareInteractionMode {
        controlInputEnabled ? .control : .view
    }
}

/// Orientation of the floating mirror-control tray: a vertical (upward) stack
/// or a horizontal (sideways) row.
enum ScreenShareControlTrayOrientation: String, CaseIterable, Sendable {
    case vertical
    case horizontal
}

enum ScreenShareControlTrayPolicy {
    /// Flips the tray between its vertical and horizontal layouts.
    static func toggled(_ orientation: ScreenShareControlTrayOrientation) -> ScreenShareControlTrayOrientation {
        orientation == .vertical ? .horizontal : .vertical
    }

    /// Resolves a tray orientation from a chevron drag once it clears the activation
    /// threshold. A dominant horizontal drag opens the horizontal menu; an upward drag
    /// opens the vertical menu. Small or downward drags resolve to `nil` (no change).
    static func orientation(
        forDragWidth dx: CGFloat,
        height dy: CGFloat,
        threshold: CGFloat
    ) -> ScreenShareControlTrayOrientation? {
        if abs(dx) > abs(dy), abs(dx) > threshold {
            return .horizontal
        }
        if dy < -threshold {
            return .vertical
        }
        return nil
    }
}

enum ScreenShareTrackpadViewportPolicy {
    /// In trackpad mode the user is actively nudging the pointer, so auto-follow
    /// re-framing would pan the mirror on every pointer delta. The viewport stays put
    /// while the trackpad drives the cursor; other modes keep smart auto-follow.
    static func allowsAutoFollowOnFocusChange(interactionMode: ScreenShareInteractionMode) -> Bool {
        interactionMode != .trackpad
    }
}

enum ScreenShareSmartTextActivationPolicy {
    /// Decides whether to surface the "double-tap to type" coaching hint. The hint
    /// teaches the fast path at the exact moment it pays off: a text field is focused
    /// on the Mac, control is live, and the keyboard is still down. It retires once the
    /// user has performed the gesture (`learned`) or starts typing.
    static func shouldShowDoubleTapCoach(
        learned: Bool,
        controlInputEnabled: Bool,
        isTyping: Bool,
        isCoPilotMode: Bool,
        hasActiveTextFocus: Bool
    ) -> Bool {
        guard learned == false else { return false }
        guard controlInputEnabled else { return false }
        guard isCoPilotMode == false else { return false }
        guard isTyping == false else { return false }
        return hasActiveTextFocus
    }
}

enum ScreenShareSmartTextFramingTarget: Equatable {
    case focusedRect(HermesRealtimeRelayNormalizedRect)
    case tappedPoint(CGPoint)
}

enum ScreenShareSmartTextTargetPolicy {
    static let focusContextGestureGrace: TimeInterval = 0.08
    static let applyScaleEpsilon: CGFloat = 0.001
    static let applyOffsetEpsilon: CGFloat = 0.5
    static let genericSmartZoomDelay: TimeInterval = ScreenShareControlInputPolicy.doubleTapMaxInterval + 0.03
    static var genericSmartZoomDelayNanoseconds: UInt64 {
        UInt64((genericSmartZoomDelay * 1_000_000_000).rounded())
    }

    static func preferredTarget(
        focusedRect: HermesRealtimeRelayNormalizedRect?,
        tappedPoint: CGPoint?
    ) -> ScreenShareSmartTextFramingTarget? {
        if let focusedRect {
            return .focusedRect(focusedRect)
        }
        if let tappedPoint {
            return .tappedPoint(tappedPoint)
        }
        return nil
    }

    static func acceptsFocusContext(receivedAt: Date, gestureStartedAt: Date?) -> Bool {
        guard let gestureStartedAt else { return true }
        return receivedAt >= gestureStartedAt.addingTimeInterval(-focusContextGestureGrace)
    }

    static func shouldDeferGenericSmartZoom(
        interactionMode: ScreenShareInteractionMode,
        lastControlClickAt: Date?,
        now: Date
    ) -> Bool {
        guard interactionMode == .control,
              let lastControlClickAt else {
            return false
        }
        let elapsed = now.timeIntervalSince(lastControlClickAt)
        return elapsed >= 0 && elapsed <= genericSmartZoomDelay
    }

    static func shouldApply(
        currentScale: CGFloat,
        currentOffset: CGSize,
        nextScale: CGFloat,
        nextOffset: CGSize
    ) -> Bool {
        abs(currentScale - nextScale) > applyScaleEpsilon ||
        abs(currentOffset.width - nextOffset.width) > applyOffsetEpsilon ||
        abs(currentOffset.height - nextOffset.height) > applyOffsetEpsilon
    }
}

enum ScreenShareViewportGesturePolicy {
    static func allowsQuickZoom(interactionMode: ScreenShareInteractionMode) -> Bool {
        interactionMode == .view
    }
}

enum ScreenShareControlInputPolicy {
    static let rightClickHoldDuration: TimeInterval = 0.55
    static let trackpadTapTravelLimit: CGFloat = 8
    static let doubleTapMaxInterval: TimeInterval = 0.4
    static var rightClickHoldDelayNanoseconds: UInt64 {
        UInt64((rightClickHoldDuration * 1_000_000_000).rounded())
    }

    static func controlClickMouseButton(heldDuration: TimeInterval) -> Int {
        heldDuration >= rightClickHoldDuration ? 1 : 0
    }

    static func shouldCancelPendingControlRightClick(
        distance: CGFloat,
        panStartDistance: CGFloat,
        isEdgeScrollGesture: Bool,
        hasResolvedClickPoint: Bool
    ) -> Bool {
        isEdgeScrollGesture || (distance > panStartDistance && hasResolvedClickPoint == false)
    }

    static func trackpadClickMouseButton(heldDuration: TimeInterval, travelDistance: CGFloat) -> Int? {
        if heldDuration >= rightClickHoldDuration {
            return 1
        }
        return travelDistance < trackpadTapTravelLimit ? 0 : nil
    }

    /// Detects whether the current control-surface tap completes a double-tap relative
    /// to the previously resolved tap. The double-tap is the gesture that jumps the
    /// viewer straight into a text field — zooming in and raising the keyboard
    /// immediately, rather than waiting for the Mac's focus context to round-trip back.
    static func isDoubleTap(
        previousAt: Date?,
        previousPoint: CGPoint?,
        currentPoint: CGPoint,
        now: Date,
        maxDistance: CGFloat,
        maxInterval: TimeInterval = doubleTapMaxInterval
    ) -> Bool {
        guard let previousAt, let previousPoint else { return false }
        let elapsed = now.timeIntervalSince(previousAt)
        guard elapsed >= 0, elapsed <= maxInterval else { return false }
        return hypot(currentPoint.x - previousPoint.x, currentPoint.y - previousPoint.y) <= maxDistance
    }

    static func initialCursorPoint(in bounds: CGRect) -> CGPoint? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        return CGPoint(x: bounds.midX, y: bounds.midY)
    }

    static func movedCursorPoint(current: CGPoint?, delta: CGSize, bounds: CGRect) -> CGPoint? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let base = current ?? CGPoint(x: bounds.midX, y: bounds.midY)
        return CGPoint(
            x: min(max(base.x + delta.width, bounds.minX), bounds.maxX),
            y: min(max(base.y + delta.height, bounds.minY), bounds.maxY)
        )
    }
}
