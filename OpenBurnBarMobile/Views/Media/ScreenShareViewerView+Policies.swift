import SwiftUI
@preconcurrency import AVKit
@preconcurrency import MediaPlayer
#if canImport(UIKit)
import UIKit
#endif
import OpenBurnBarMedia
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

// Pure interaction policy + reducer types: smart-zoom, viewport, control-tray, trackpad, smart-text, gesture, control-input.
// Extracted from ScreenShareViewerView.swift (god-file decomposition) — same module, verbatim (incl. #if guards).

enum SmartZoomMode: String, CaseIterable, Identifiable, Sendable {
    case off
    case smart
    case text
    case window
    case cursor

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .smart: return "Smart"
        case .text: return "Text"
        case .window: return "Window"
        case .cursor: return "Cursor"
        }
    }

    var systemImage: String {
        switch self {
        case .off: return "rectangle.dashed"
        case .smart: return "sparkles.rectangle.stack"
        case .text: return "text.cursor"
        case .window: return "rectangle.inset.filled"
        case .cursor: return "cursorarrow"
        }
    }
}

struct ScreenShareSmartZoomContext: Equatable {
    var targetKind: HermesRealtimeRelayFocusTargetKind
    var displayId: String?
    var normalizedRect: HermesRealtimeRelayNormalizedRect?
    var normalizedPoint: HermesRealtimeRelayNormalizedPoint?
    var confidence: Double?
    var receivedAt: Date

    static func from(
        _ relay: HermesRealtimeRelayFocusContext,
        receivedAt: Date = Date()
    ) -> ScreenShareSmartZoomContext? {
        guard let targetKind = relay.targetKind else { return nil }
        return ScreenShareSmartZoomContext(
            targetKind: targetKind,
            displayId: relay.displayId,
            normalizedRect: relay.normalizedRect,
            normalizedPoint: relay.normalizedPoint,
            confidence: relay.confidence,
            receivedAt: receivedAt
        )
    }
}

enum ScreenShareSmartZoomReducer {
    static let staleAfter: TimeInterval = 1.5
    static let manualOverrideHold: TimeInterval = 5.0
    static let textFillRatio: CGFloat = 0.62
    static let windowFillRatio: CGFloat = 0.86
    static let agentFillRatio: CGFloat = 0.72
    static let textScaleRange: ClosedRange<CGFloat> = 1.4...4.0
    static let windowScaleRange: ClosedRange<CGFloat> = 1.0...2.4
    static let cursorEntryScale: CGFloat = 1.8
    static let agentScaleRange: ClosedRange<CGFloat> = 1.0...3.0
    /// Scale used when a double-tap optimistically zooms toward the tapped point,
    /// before the Mac's focused-element rect arrives to refine the framing.
    static let doubleTapEntryScale: CGFloat = 2.4

    struct Decision: Equatable {
        var scale: CGFloat
        var offset: CGSize
        var isAutoFollowing: Bool
    }

    static func reduce(
        viewportSize: CGSize,
        contentRect: CGRect,
        currentState: ScreenShareViewportState,
        context: ScreenShareSmartZoomContext?,
        mode: SmartZoomMode,
        selectedDisplayId: String?,
        manualOverrideUntil: Date?,
        now: Date,
        bottomInset: CGFloat = 0
    ) -> Decision {
        let idleDecision = Decision(
            scale: currentState.scale,
            offset: currentState.offset,
            isAutoFollowing: false
        )

        guard mode != .off else { return idleDecision }
        guard viewportSize.width > 0, viewportSize.height > 0 else { return idleDecision }
        guard contentRect.width > 0, contentRect.height > 0 else { return idleDecision }
        if let manualOverrideUntil, manualOverrideUntil > now { return idleDecision }
        guard let context else { return idleDecision }
        if now.timeIntervalSince(context.receivedAt) > staleAfter { return idleDecision }
        if let target = context.displayId,
           let selected = selectedDisplayId,
           target != selected {
            return idleDecision
        }
        guard targetMatches(mode: mode, kind: context.targetKind) else { return idleDecision }

        switch context.targetKind {
        case .focusedElement:
            guard let rect = context.normalizedRect else { return idleDecision }
            return fitRectDecision(
                normalizedRect: rect,
                viewportSize: viewportSize,
                contentRect: contentRect,
                fillRatio: textFillRatio,
                scaleRange: textScaleRange,
                bottomInset: bottomInset
            )
        case .focusedWindow:
            guard let rect = context.normalizedRect else { return idleDecision }
            return fitRectDecision(
                normalizedRect: rect,
                viewportSize: viewportSize,
                contentRect: contentRect,
                fillRatio: windowFillRatio,
                scaleRange: windowScaleRange,
                bottomInset: bottomInset
            )
        case .agentWorkspace:
            guard let rect = context.normalizedRect else { return idleDecision }
            return fitRectDecision(
                normalizedRect: rect,
                viewportSize: viewportSize,
                contentRect: contentRect,
                fillRatio: agentFillRatio,
                scaleRange: agentScaleRange,
                bottomInset: bottomInset
            )
        case .cursor:
            guard let point = context.normalizedPoint else { return idleDecision }
            let targetScale: CGFloat
            if currentState.isZoomed {
                targetScale = currentState.scale
            } else {
                targetScale = min(max(cursorEntryScale, ScreenShareViewportState.minimumScale), ScreenShareViewportState.maximumScale)
            }
            return centerPointDecision(
                normalizedPoint: point,
                viewportSize: viewportSize,
                contentRect: contentRect,
                scale: targetScale,
                bottomInset: bottomInset
            )
        }
    }

    static func targetMatches(mode: SmartZoomMode, kind: HermesRealtimeRelayFocusTargetKind) -> Bool {
        switch mode {
        case .off: return false
        case .smart: return true
        case .text: return kind == .focusedElement
        case .window: return kind == .focusedWindow
        case .cursor: return kind == .cursor
        }
    }

    static func fitRectDecision(
        normalizedRect rect: HermesRealtimeRelayNormalizedRect,
        viewportSize: CGSize,
        contentRect: CGRect,
        fillRatio: CGFloat,
        scaleRange: ClosedRange<CGFloat>,
        bottomInset: CGFloat = 0
    ) -> Decision {
        let rectWidthInContent = max(0.0001, CGFloat(rect.width)) * contentRect.width
        let rectHeightInContent = max(0.0001, CGFloat(rect.height)) * contentRect.height
        let shortRectAxis = min(rectWidthInContent, rectHeightInContent)
        let shortViewportAxis = min(viewportSize.width, max(1, viewportSize.height - bottomInset))
        let targetShortAxis = shortViewportAxis * fillRatio
        let rawScale = targetShortAxis / max(shortRectAxis, 0.0001)
        let scale = clamp(rawScale, range: scaleRange)
        let centerX = contentRect.minX + CGFloat(rect.x + rect.width / 2) * contentRect.width
        let centerY = contentRect.minY + CGFloat(rect.y + rect.height / 2) * contentRect.height
        let offset = offsetForCenter(
            centerInContent: CGPoint(x: centerX, y: centerY),
            scale: scale,
            viewportSize: viewportSize,
            bottomInset: bottomInset
        )
        return Decision(scale: scale, offset: offset, isAutoFollowing: true)
    }

    static func centerPointDecision(
        normalizedPoint point: HermesRealtimeRelayNormalizedPoint,
        viewportSize: CGSize,
        contentRect: CGRect,
        scale: CGFloat,
        bottomInset: CGFloat = 0
    ) -> Decision {
        let clampedScale = ScreenShareViewportState.clampScale(scale)
        let centerX = contentRect.minX + CGFloat(point.x) * contentRect.width
        let centerY = contentRect.minY + CGFloat(point.y) * contentRect.height
        let offset = offsetForCenter(
            centerInContent: CGPoint(x: centerX, y: centerY),
            scale: clampedScale,
            viewportSize: viewportSize,
            bottomInset: bottomInset
        )
        return Decision(scale: clampedScale, offset: offset, isAutoFollowing: true)
    }

    static func normalizedCenter(of rect: HermesRealtimeRelayNormalizedRect) -> CGPoint {
        CGPoint(
            x: CGFloat(rect.x + rect.width / 2),
            y: CGFloat(rect.y + rect.height / 2)
        )
    }

    /// Offset that puts `centerInContent` at the visual center of the
    /// viewport when the content is scaled by `scale`. Inverse of
    /// `ScreenShareViewportState.viewPoint(forNormalized:in:)`:
    ///
    ///   viewX = (cx - W/2) * scale + W/2 + offsetWidth
    ///   put viewX = W/2 ⇒ offsetWidth = (W/2 - cx) * scale.
    static func offsetForCenter(
        centerInContent: CGPoint,
        scale: CGFloat,
        viewportSize: CGSize,
        bottomInset: CGFloat = 0
    ) -> CGSize {
        let halfWidth = viewportSize.width / 2
        let halfHeight = viewportSize.height / 2
        // Aim for the center of the *visible* area (above any keyboard) so the target
        // lands in view and the content uses the top of the screen.
        let lift = max(0, bottomInset) / 2
        let proposedX = (halfWidth - centerInContent.x) * scale
        let proposedY = (halfHeight - centerInContent.y) * scale - lift
        return ScreenShareViewportState.clamp(
            offset: CGSize(width: proposedX, height: proposedY),
            scale: scale,
            in: viewportSize,
            bottomInset: bottomInset
        )
    }

    static func clamp(_ value: CGFloat, range: ClosedRange<CGFloat>) -> CGFloat {
        if value.isNaN { return range.lowerBound }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

struct ScreenShareViewportState: Equatable {
    static let minimumScale: CGFloat = 1
    static let maximumScale: CGFloat = 4
    static let quickZoomScale: CGFloat = 2

    var scale: CGFloat = minimumScale
    var offset: CGSize = .zero

    var isZoomed: Bool {
        scale > Self.minimumScale + 0.001
    }

    mutating func applyMagnification(_ magnification: CGFloat, in size: CGSize) {
        scale = Self.clampScale(scale * magnification)
        offset = Self.clamp(offset: offset, scale: scale, in: size)
    }

    mutating func zoom(by multiplier: CGFloat, in size: CGSize) {
        scale = Self.clampScale(scale * multiplier)
        offset = Self.clamp(offset: offset, scale: scale, in: size)
    }

    mutating func applyTranslation(_ translation: CGSize, in size: CGSize) {
        offset = Self.clamp(offset: offset + translation, scale: scale, in: size)
    }

    mutating func toggleQuickZoom(in size: CGSize) {
        if isZoomed {
            reset()
        } else {
            scale = Self.quickZoomScale
            offset = Self.clamp(offset: .zero, scale: scale, in: size)
        }
    }

    mutating func reclamp(in size: CGSize) {
        scale = Self.clampScale(scale)
        offset = Self.clamp(offset: offset, scale: scale, in: size)
    }

    mutating func reset() {
        scale = Self.minimumScale
        offset = .zero
    }

    func preview(magnification: CGFloat, translation: CGSize, in size: CGSize) -> ScreenShareViewportState {
        let previewScale = Self.clampScale(scale * magnification)
        return ScreenShareViewportState(
            scale: previewScale,
            offset: Self.clamp(offset: offset + translation, scale: previewScale, in: size)
        )
    }

    func normalizedPoint(for point: CGPoint, in size: CGSize, contentRect: CGRect? = nil) -> (x: Double, y: Double) {
        guard size.width > 0, size.height > 0 else { return (0, 0) }
        let baseX = ((point.x - (size.width / 2) - offset.width) / scale) + (size.width / 2)
        let baseY = ((point.y - (size.height / 2) - offset.height) / scale) + (size.height / 2)
        let rect = contentRect ?? CGRect(origin: .zero, size: size)
        guard rect.width > 0, rect.height > 0 else { return (0, 0) }
        let x = min(max((baseX - rect.minX) / rect.width, 0), 1)
        let y = min(max((baseY - rect.minY) / rect.height, 0), 1)
        return (Double(x), Double(y))
    }

    func viewPoint(forNormalized normalized: CGPoint, in size: CGSize) -> CGPoint {
        guard size.width > 0, size.height > 0 else { return .zero }
        let contentX = min(max(normalized.x, 0), 1) * size.width
        let contentY = min(max(normalized.y, 0), 1) * size.height
        let viewX = ((contentX - (size.width / 2)) * scale) + (size.width / 2) + offset.width
        let viewY = ((contentY - (size.height / 2)) * scale) + (size.height / 2) + offset.height
        return CGPoint(x: min(max(viewX, 0), size.width), y: min(max(viewY, 0), size.height))
    }

    static func clampScale(_ proposed: CGFloat) -> CGFloat {
        min(max(proposed, minimumScale), maximumScale)
    }

    static func clamp(offset proposed: CGSize, scale: CGFloat, in size: CGSize, bottomInset: CGFloat = 0) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }

        let horizontalLimit = max(0, size.width * (scale - 1) / 2)
        let verticalLimit = max(0, size.height * (scale - 1) / 2)
        // When a keyboard covers the bottom, allow the content to ride up by half the
        // covered height so the focused region sits in the visible area instead of
        // being centered behind the keyboard (and leaving the top of the screen black).
        let lift = max(0, bottomInset) / 2

        return CGSize(
            width: min(max(proposed.width, -horizontalLimit), horizontalLimit),
            height: min(max(proposed.height, -(verticalLimit + lift)), verticalLimit)
        )
    }
}

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
