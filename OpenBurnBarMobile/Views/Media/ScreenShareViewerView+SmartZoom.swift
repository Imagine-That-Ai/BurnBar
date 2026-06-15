// `ScreenShareViewerView` — smart-zoom and keyboard-aware text framing.
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
    func beginManualZoomOverride() {
        smartZoomManualOverrideUntil = Date().addingTimeInterval(ScreenShareSmartZoomReducer.manualOverrideHold)
        smartZoomAutoFollowing = false
    }

    /// Height of the on-screen keyboard that overlaps the viewport, capped so the
    /// remaining visible area can never collapse to nothing.
    func keyboardInset(in size: CGSize) -> CGFloat {
        ScreenShareKeyboardFramePolicy.cappedInset(rawOverlap: keyboardHeight, viewportHeight: size.height)
    }

    /// Re-frames the smart-text target whenever the keyboard appears, resizes, or
    /// dismisses — lifting the focused field into the visible area above the keyboard
    /// (and back to center when it goes away).
    func applyKeyboardAwareFraming() {
        guard let size = lastLayoutSize, size.width > 0, size.height > 0 else { return }
        let contentRect = renderedContentRect(in: size)
        let inset = keyboardInset(in: size)
        if let rect = activeTypingTargetRect() {
            lastSmartTextFocusedRect = rect
        }
        let target = ScreenShareSmartTextTargetPolicy.preferredTarget(
            focusedRect: lastSmartTextFocusedRect,
            tappedPoint: lastSmartTextNormalizedPoint
        )
        switch target {
        case .focusedRect(let rect):
            applyFocusedTextZoom(to: rect, in: size, contentRect: contentRect, bottomInset: inset)
        case .tappedPoint(let point):
            applyDoubleTapZoom(toNormalized: point, in: size, contentRect: contentRect, bottomInset: inset)
        case nil:
            guard isTyping else { return }
            // Keyboard opened without a specific target (e.g. the Type button): lift the
            // current framing above the keyboard so the top of the screen is used.
            withAnimation(Self.smartTextFramingAnimation) {
                viewport.offset = ScreenShareViewportState.clamp(
                    offset: CGSize(width: viewport.offset.width, height: -inset / 2),
                    scale: viewport.scale,
                    in: size,
                    bottomInset: inset
                )
            }
        }
    }

    func applyFocusedTextZoom(to rect: HermesRealtimeRelayNormalizedRect, in size: CGSize, contentRect: CGRect, bottomInset: CGFloat) {
        guard size.width > 0, size.height > 0, contentRect.width > 0, contentRect.height > 0 else { return }
        let decision = ScreenShareSmartZoomReducer.fitRectDecision(
            normalizedRect: rect,
            viewportSize: size,
            contentRect: contentRect,
            fillRatio: ScreenShareSmartZoomReducer.textFillRatio,
            scaleRange: ScreenShareSmartZoomReducer.textScaleRange,
            bottomInset: bottomInset
        )
        applySmartTextDecision(decision)
    }

    func applyDoubleTapZoom(toNormalized point: CGPoint, in size: CGSize, contentRect: CGRect, bottomInset: CGFloat) {
        guard size.width > 0, size.height > 0, contentRect.width > 0, contentRect.height > 0 else { return }
        let decision = ScreenShareSmartZoomReducer.centerPointDecision(
            normalizedPoint: HermesRealtimeRelayNormalizedPoint(x: Double(point.x), y: Double(point.y)),
            viewportSize: size,
            contentRect: contentRect,
            scale: max(viewport.scale, ScreenShareSmartZoomReducer.doubleTapEntryScale),
            bottomInset: bottomInset
        )
        applySmartTextDecision(decision)
    }

    func applySmartTextDecision(_ decision: ScreenShareSmartZoomReducer.Decision) {
        guard decision.isAutoFollowing else { return }
        guard ScreenShareSmartTextTargetPolicy.shouldApply(
            currentScale: viewport.scale,
            currentOffset: viewport.offset,
            nextScale: decision.scale,
            nextOffset: decision.offset
        ) else {
            smartZoomAutoFollowing = true
            return
        }
        withAnimation(Self.smartTextFramingAnimation) {
            viewport.scale = decision.scale
            viewport.offset = decision.offset
        }
        smartZoomAutoFollowing = true
    }

    func activeTypingTargetRect(now: Date = Date()) -> HermesRealtimeRelayNormalizedRect? {
        guard isTyping,
              let rect = activeTextFocusRect(now: now, requireGestureFreshness: true) else {
            return nil
        }
        return rect
    }

    func activeTextFocusRect(
        now: Date = Date(),
        requireGestureFreshness: Bool
    ) -> HermesRealtimeRelayNormalizedRect? {
        guard let context = coordinator.latestFocusContext,
              requireGestureFreshness == false ||
              ScreenShareSmartTextTargetPolicy.acceptsFocusContext(
                receivedAt: context.receivedAt,
                gestureStartedAt: lastSmartTextGestureStartedAt
              ),
              ScreenShareAutoTypeFollowPolicy.isActiveTextFocus(
                context: context,
                selectedDisplayId: selectedDisplayId,
                now: now
              ),
              let rect = context.normalizedRect else {
            return nil
        }
        return rect
    }

    func applySmartZoomDecisionUsingCurrentLayout() {
        guard let layoutSize = lastLayoutSize else { return }
        let contentRect = renderedContentRect(in: layoutSize)
        applySmartZoomDecision(viewportSize: layoutSize, contentRect: contentRect)
    }

    @MainActor
    func applySmartZoomDecision(viewportSize: CGSize, contentRect: CGRect) {
        let decision = ScreenShareSmartZoomReducer.reduce(
            viewportSize: viewportSize,
            contentRect: contentRect,
            currentState: viewport,
            context: coordinator.latestFocusContext,
            mode: smartZoomMode,
            selectedDisplayId: selectedDisplayId,
            manualOverrideUntil: smartZoomManualOverrideUntil,
            now: Date(),
            bottomInset: keyboardInset(in: viewportSize)
        )
        if decision.isAutoFollowing {
            withAnimation(.snappy) {
                viewport.scale = decision.scale
                viewport.offset = decision.offset
            }
            if !smartZoomAutoFollowing { smartZoomAutoFollowing = true }
        } else if smartZoomAutoFollowing {
            smartZoomAutoFollowing = false
        }
    }

    @MainActor
    func triggerSmartTextDoubleTap(normalized target: CGPoint, in size: CGSize, contentRect: CGRect, gestureStartedAt: Date) {
        guard controlInputEnabled else { return }
        deferredControlTapSmartZoomTask?.cancel()
        deferredControlTapSmartZoomTask = nil
        smartTextDoubleTapLearned = true
        if smartTextCoachVisible {
            withAnimation(.snappy) { smartTextCoachVisible = false }
        }
        lastSmartTextGestureStartedAt = gestureStartedAt
        lastSmartTextFocusedRect = activeTextFocusRect(requireGestureFreshness: false)
        if size.width > 0, size.height > 0,
           contentRect.width > 0, contentRect.height > 0 {
            // The first frame uses the user's tapped point. The Mac's focused-element
            // rect then refines this to exact field geometry as soon as it arrives.
            lastSmartTextNormalizedPoint = target
        }
        interactionMode = .control
        isTyping = true
        applyKeyboardAwareFraming()
        focusTypingBar()
    }

    func scheduleGenericSmartZoomAfterControlTap(_ tappedAt: Date) {
        deferredControlTapSmartZoomTask?.cancel()
        deferredControlTapSmartZoomTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: ScreenShareSmartTextTargetPolicy.genericSmartZoomDelayNanoseconds)
            guard Task.isCancelled == false else { return }
            guard lastControlClickAt == tappedAt,
                  isTyping == false,
                  lastSmartTextNormalizedPoint == nil else {
                return
            }
            applySmartZoomDecisionUsingCurrentLayout()
        }
    }

    func recomputeSmartTextCoach() {
        let hasActiveTextFocus: Bool = {
            guard let context = coordinator.latestFocusContext else { return false }
            return ScreenShareAutoTypeFollowPolicy.isActiveTextFocus(
                context: context,
                selectedDisplayId: selectedDisplayId,
                now: Date()
            )
        }()
        let shouldShow = ScreenShareSmartTextActivationPolicy.shouldShowDoubleTapCoach(
            learned: smartTextDoubleTapLearned,
            controlInputEnabled: standardControlInputEnabled,
            isTyping: isTyping,
            isCoPilotMode: interactionMode == .coPilot,
            hasActiveTextFocus: hasActiveTextFocus
        )
        guard shouldShow != smartTextCoachVisible else { return }
        withAnimation(.snappy) { smartTextCoachVisible = shouldShow }
    }
}
