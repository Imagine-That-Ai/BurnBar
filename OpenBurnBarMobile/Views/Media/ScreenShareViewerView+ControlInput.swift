// `ScreenShareViewerView` — control-surface gestures and Mac input intents.
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

extension ScreenShareViewerView {
    func viewportGesture(in size: CGSize) -> some Gesture {
        SimultaneousGesture(
            MagnifyGesture()
                .updating($magnification) { value, state, _ in
                    guard interactionMode == .view else { return }
                    state = value.magnification
                }
                .onEnded { value in
                    guard interactionMode == .view else { return }
                    beginManualZoomOverride()
                    viewport.applyMagnification(value.magnification, in: size)
                },
            DragGesture(minimumDistance: 2)
                .updating($dragTranslation) { value, state, _ in
                    guard interactionMode == .view else { return }
                    state = value.translation
                }
                .onEnded { value in
                    guard interactionMode == .view else { return }
                    beginManualZoomOverride()
                    viewport.applyTranslation(value.translation, in: size)
                }
        )
    }

    func controlSurfaceGesture(in size: CGSize, contentRect: CGRect, viewport visibleViewport: ScreenShareViewportState) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if controlPressStartedAt == nil {
                    controlPressStartedAt = Date()
                    let normalized = visibleViewport.normalizedPoint(for: value.startLocation, in: size, contentRect: contentRect)
                    scheduleControlRightClick(
                        at: value.startLocation,
                        normalized: normalized
                    )
                }
                let distance = hypot(value.translation.width, value.translation.height)
                guard controlRightClickSentForCurrentPress == false else {
                    controlPanTranslation = .zero
                    return
                }
                let edgeScrollGesture = edgeScrollEnabled
                    && distance > 14
                    && isEdgeScrollStart(value.startLocation, in: size)
                let resolvedClickPoint = resolvedClickPoint(for: value, distance: distance, in: size)
                let shouldCancelRightClick = ScreenShareControlInputPolicy.shouldCancelPendingControlRightClick(
                    distance: distance,
                    panStartDistance: controlPanStartDistance(in: size),
                    isEdgeScrollGesture: edgeScrollGesture,
                    hasResolvedClickPoint: resolvedClickPoint != nil
                )
                if shouldCancelRightClick {
                    cancelPendingControlRightClick()
                }
                guard distance > controlPanStartDistance(in: size),
                      edgeScrollGesture == false,
                      resolvedClickPoint == nil else {
                    controlPanTranslation = .zero
                    return
                }
                controlPanTranslation = value.translation
            }
            .onEnded { value in
                defer {
                    controlPanTranslation = .zero
                    cancelPendingControlRightClick()
                    controlRightClickSentForCurrentPress = false
                }
                let pressStartedAt = controlPressStartedAt
                controlPressStartedAt = nil

                guard controlRightClickSentForCurrentPress == false else { return }

                let distance = hypot(value.translation.width, value.translation.height)
                if edgeScrollEnabled,
                   distance > 14,
                   isEdgeScrollStart(value.startLocation, in: size) {
                    let start = visibleViewport.normalizedPoint(for: value.startLocation, in: size, contentRect: contentRect)
                    let end = visibleViewport.normalizedPoint(for: value.location, in: size, contentRect: contentRect)
                    sendScrollIntent(start.x, start.y, end.x, end.y, selectedDisplayId)
                    return
                }

                if let clickPoint = resolvedClickPoint(for: value, distance: distance, in: size) {
                    let normalized = visibleViewport.normalizedPoint(for: clickPoint, in: size, contentRect: contentRect)
                    let tappedAt = Date()
                    let isDoubleTap = ScreenShareControlInputPolicy.isDoubleTap(
                        previousAt: lastControlClickAt,
                        previousPoint: lastControlClickPoint,
                        currentPoint: clickPoint,
                        now: tappedAt,
                        maxDistance: clickRadii(in: size).repeated
                    )
                    lastControlClickPoint = clickPoint
                    cursorPoint = clickPoint
                    showTapFeedback(at: clickPoint)
                    handleControlTap(
                        normalized: normalized,
                        at: clickPoint,
                        pressStartedAt: pressStartedAt
                    )
                    if isDoubleTap {
                        // Second tap of a double-tap: jump straight into the field now,
                        // instead of waiting for the Mac's focus context to round-trip.
                        // Reset the timestamp so a third tap starts a fresh pair.
                        let doubleTapStartedAt = lastControlClickAt ?? tappedAt
                        deferredControlTapSmartZoomTask?.cancel()
                        deferredControlTapSmartZoomTask = nil
                        lastControlClickAt = nil
                        triggerSmartTextDoubleTap(
                            normalized: CGPoint(x: normalized.x, y: normalized.y),
                            in: size,
                            contentRect: contentRect,
                            gestureStartedAt: doubleTapStartedAt
                        )
                    } else {
                        lastControlClickAt = tappedAt
                        scheduleGenericSmartZoomAfterControlTap(tappedAt)
                    }
                    return
                }

                guard distance > controlPanStartDistance(in: size) else { return }
                viewport.applyTranslation(value.translation, in: size)
            }
    }

    func scheduleControlRightClick(at point: CGPoint, normalized: (x: Double, y: Double)) {
        cancelPendingControlRightClick()
        controlRightClickSentForCurrentPress = false
        pendingControlRightClickTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: ScreenShareControlInputPolicy.rightClickHoldDelayNanoseconds)
            guard Task.isCancelled == false else { return }
            controlRightClickSentForCurrentPress = true
            controlPanTranslation = .zero
            lastControlClickPoint = point
            cursorPoint = point
            showTapFeedback(at: point)
            triggerControlRightClickHaptic()
            sendTapIntent(normalized.x, normalized.y, 1)
        }
    }

    func cancelPendingControlRightClick() {
        pendingControlRightClickTask?.cancel()
        pendingControlRightClickTask = nil
    }

    func triggerControlRightClickHaptic() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    func handleControlTap(normalized: (x: Double, y: Double), at point: CGPoint, pressStartedAt: Date?) {
        let heldDuration = pressStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        sendTapIntent(
            normalized.x,
            normalized.y,
            ScreenShareControlInputPolicy.controlClickMouseButton(heldDuration: heldDuration)
        )
    }

    func submitCoPilotIntent() {
        guard let target = coPilotTarget else { return }
        let instruction = coPilotInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }

        sendAgentContextTargetIntent(
            target.normalizedX,
            target.normalizedY,
            instruction,
            coPilotRuntime,
            nil
        )

        withAnimation(.snappy) {
            coPilotTarget = nil
            coPilotInstruction = ""
        }
    }

    func controlMagnifyGesture(in size: CGSize) -> some Gesture {
        MagnifyGesture()
            .updating($controlMagnification) { value, state, _ in
                guard interactionMode == .control else { return }
                state = value.magnification
            }
            .onEnded { value in
                guard interactionMode == .control else { return }
                viewport.applyMagnification(value.magnification, in: size)
            }
    }

    func resolvedClickPoint(for value: DragGesture.Value, distance: CGFloat, in size: CGSize) -> CGPoint? {
        let radii = clickRadii(in: size)
        if distance <= radii.precise {
            return value.location
        }
        if distance <= radii.forgiving {
            return value.location
        }
        if let lastControlClickPoint,
           distance <= radii.repeated,
           min(
                hypot(value.startLocation.x - lastControlClickPoint.x, value.startLocation.y - lastControlClickPoint.y),
                hypot(value.location.x - lastControlClickPoint.x, value.location.y - lastControlClickPoint.y)
           ) <= radii.repeated {
            return value.location
        }
        return nil
    }

    func clickRadii(in size: CGSize) -> (precise: CGFloat, forgiving: CGFloat, repeated: CGFloat) {
        let diagonal = max(1, hypot(size.width, size.height))
        return (
            precise: min(max(diagonal * 0.014, 12), 22),
            forgiving: min(max(diagonal * 0.026, 26), 48),
            repeated: min(max(diagonal * 0.034, 32), 64)
        )
    }

    func controlPanStartDistance(in size: CGSize) -> CGFloat {
        clickRadii(in: size).forgiving + 2
    }

    func isEdgeScrollStart(_ point: CGPoint, in size: CGSize) -> Bool {
        guard size.width > 0, size.height > 0 else { return false }
        let margin = max(28, min(size.width, size.height) * 0.07)
        return point.x <= margin
            || point.x >= size.width - margin
            || point.y <= margin
            || point.y >= size.height - margin
    }

    func sendTrackpadPointerDelta(_ delta: CGSize) {
        sendPointerMoveIntent(Double(delta.width), Double(delta.height))
    }

    func moveLocalCursorByTrackpadDelta(_ delta: CGSize, in bounds: CGRect) {
        cursorPoint = ScreenShareControlInputPolicy.movedCursorPoint(
            current: cursorPoint,
            delta: delta,
            bounds: bounds
        )
    }
}
