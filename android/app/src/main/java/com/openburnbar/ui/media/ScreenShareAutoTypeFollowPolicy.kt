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
        if (!input.autoKeyboardEnabled) return false
        if (!input.standardControlEnabled) return false
        if (input.controlMode == ScreenMirrorControlMode.COPILOT) return false
        if (input.typingOpen) return false
        if (input.manualDismissUntilMillis != null && input.manualDismissUntilMillis > input.nowMillis) {
            return false
        }
        val context = input.context ?: return false
        return isFreshTextFocus(context, input.selectedDisplayId, input.nowMillis)
    }

    fun shouldClose(input: Input): Boolean {
        if (!input.typingOpen) return false
        if (!input.standardControlEnabled) return true
        val context = input.context ?: return true
        return !isFreshTextFocus(context, input.selectedDisplayId, input.nowMillis)
    }

    fun isFreshTextFocus(
        context: ScreenShareSmartZoomContext,
        selectedDisplayId: String?,
        nowMillis: Long,
    ): Boolean {
        if (context.targetKind != HermesRealtimeRelayFocusTargetKind.FOCUSED_ELEMENT) return false
        if (nowMillis - context.receivedAtMillis > STALE_AFTER_MILLIS) return false
        if (
            context.displayId != null &&
            selectedDisplayId != null &&
            context.displayId != selectedDisplayId
        ) {
            return false
        }
        val confidence = context.confidence
        if (confidence != null && confidence < MIN_CONFIDENCE) return false
        return true
    }

    fun hasActiveTextFocus(
        context: ScreenShareSmartZoomContext?,
        selectedDisplayId: String?,
        nowMillis: Long,
    ): Boolean {
        val ctx = context ?: return false
        return isFreshTextFocus(ctx, selectedDisplayId, nowMillis)
    }
}
