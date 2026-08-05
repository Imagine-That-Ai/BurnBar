package com.openburnbar.ui.media

import com.openburnbar.irohrelay.HermesRealtimeRelayFocusTargetKind

/**
 * Pure open/close policy for Mercury auto keyboard on Mac text focus.
 *
 * Mirrors iOS `ScreenShareAutoTypeFollowPolicy` — keep logic identical
 * across platforms so the JVM unit suite can exercise every branch.
 */
internal object ScreenShareAutoTypeFollowPolicy {
    const val STALE_AFTER_MILLIS: Long = ScreenShareSmartZoomReducer.STALE_AFTER_MILLIS
    const val MANUAL_DISMISS_HOLD_MILLIS: Long = ScreenShareSmartZoomReducer.MANUAL_OVERRIDE_HOLD_MILLIS
    const val MIN_CONFIDENCE: Double = 0.5

    data class Input(
        val autoKeyboardEnabled: Boolean,
        val standardControlEnabled: Boolean,
        val controlMode: ScreenMirrorControlMode,
        val typingOpen: Boolean,
        val context: ScreenShareSmartZoomContext?,
        val selectedDisplayId: String?,
        val manualDismissUntilMillis: Long?,
        val nowMillis: Long,
    )

    fun shouldOpen(input: Input): Boolean {
        val context = input.context
        return input.autoKeyboardEnabled &&
            input.standardControlEnabled &&
            input.controlMode != ScreenMirrorControlMode.COPILOT &&
            !input.typingOpen &&
            (input.manualDismissUntilMillis == null || input.manualDismissUntilMillis <= input.nowMillis) &&
            context != null &&
            isFreshTextFocus(context, input.selectedDisplayId, input.nowMillis)
    }

    fun shouldClose(input: Input): Boolean {
        if (!input.typingOpen) return false
        if (!input.standardControlEnabled) return true
        val context = input.context ?: return true
        return !isFreshTextFocus(context, input.selectedDisplayId, input.nowMillis)
    }

    fun shouldCloseAutomatically(input: Input, openedAutomatically: Boolean): Boolean = openedAutomatically && shouldClose(input)

    /**
     * One auto-type step: whether typing should open/close and how the
     * opened-automatically marker evolves. `typingOpen == null` means the
     * keyboard state is left untouched (a manually opened keyboard stays
     * open even without Mac text focus).
     */
    data class Transition(
        val openedAutomatically: Boolean,
        val typingOpen: Boolean?,
        val promoteControlModeToTouch: Boolean,
    )

    fun transition(input: Input, openedAutomatically: Boolean): Transition = when {
        shouldOpen(input) -> Transition(
            openedAutomatically = true,
            typingOpen = true,
            promoteControlModeToTouch = input.controlMode == ScreenMirrorControlMode.VIEW,
        )
        input.typingOpen && !input.standardControlEnabled -> Transition(
            openedAutomatically = false,
            typingOpen = false,
            promoteControlModeToTouch = false,
        )
        shouldCloseAutomatically(input, openedAutomatically) -> Transition(
            openedAutomatically = false,
            typingOpen = false,
            promoteControlModeToTouch = false,
        )
        !input.typingOpen -> Transition(
            openedAutomatically = false,
            typingOpen = null,
            promoteControlModeToTouch = false,
        )
        else -> Transition(
            openedAutomatically = openedAutomatically,
            typingOpen = null,
            promoteControlModeToTouch = false,
        )
    }

    fun isFreshTextFocus(context: ScreenShareSmartZoomContext, selectedDisplayId: String?, nowMillis: Long): Boolean {
        val confidence = context.confidence
        val displayMatches =
            context.displayId == null ||
                selectedDisplayId == null ||
                context.displayId == selectedDisplayId
        return context.targetKind == HermesRealtimeRelayFocusTargetKind.FOCUSED_ELEMENT &&
            nowMillis - context.receivedAtMillis <= STALE_AFTER_MILLIS &&
            displayMatches &&
            (confidence == null || confidence >= MIN_CONFIDENCE)
    }

    fun hasActiveTextFocus(context: ScreenShareSmartZoomContext?, selectedDisplayId: String?, nowMillis: Long): Boolean {
        val ctx = context ?: return false
        return isFreshTextFocus(ctx, selectedDisplayId, nowMillis)
    }
}
