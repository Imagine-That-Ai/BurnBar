package com.openburnbar.ui.media

import com.openburnbar.irohrelay.HermesRealtimeRelayFocusTargetKind
import com.openburnbar.irohrelay.HermesRealtimeRelayNormalizedRect
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ScreenShareAutoTypeFollowPolicyTest {

    private val nowMillis = 10_000L

    @Test
    fun shouldOpen_whenFocusedElementAndPreferenceEnabled() {
        assertTrue(
            ScreenShareAutoTypeFollowPolicy.shouldOpen(
                baseInput(context = textContext(receivedAtMillis = nowMillis)),
            ),
        )
    }

    @Test
    fun shouldOpen_blockedWhenPreferenceOff() {
        assertFalse(
            ScreenShareAutoTypeFollowPolicy.shouldOpen(
                baseInput(
                    autoKeyboardEnabled = false,
                    context = textContext(receivedAtMillis = nowMillis),
                ),
            ),
        )
    }

    @Test
    fun shouldOpen_blockedWhenControlDisabled() {
        assertFalse(
            ScreenShareAutoTypeFollowPolicy.shouldOpen(
                baseInput(
                    standardControlEnabled = false,
                    context = textContext(receivedAtMillis = nowMillis),
                ),
            ),
        )
    }

    @Test
    fun shouldOpen_blockedWhenStale() {
        assertFalse(
            ScreenShareAutoTypeFollowPolicy.shouldOpen(
                baseInput(
                    context = textContext(
                        receivedAtMillis = nowMillis - ScreenShareAutoTypeFollowPolicy.STALE_AFTER_MILLIS - 1,
                    ),
                ),
            ),
        )
    }

    @Test
    fun shouldOpen_blockedWhenWrongDisplay() {
        assertFalse(
            ScreenShareAutoTypeFollowPolicy.shouldOpen(
                baseInput(
                    selectedDisplayId = "display-2",
                    context = textContext(receivedAtMillis = nowMillis, displayId = "display-1"),
                ),
            ),
        )
    }

    @Test
    fun shouldOpen_allowedWhenDisplayIdsMatch() {
        assertTrue(
            ScreenShareAutoTypeFollowPolicy.shouldOpen(
                baseInput(
                    selectedDisplayId = "display-1",
                    context = textContext(receivedAtMillis = nowMillis, displayId = "display-1"),
                ),
            ),
        )
    }

    @Test
    fun shouldOpen_allowedWhenEitherDisplayMissing() {
        assertTrue(
            ScreenShareAutoTypeFollowPolicy.shouldOpen(
                baseInput(
                    selectedDisplayId = null,
                    context = textContext(receivedAtMillis = nowMillis, displayId = "display-1"),
                ),
            ),
        )
    }

    @Test
    fun shouldOpen_blockedWhenCoPilot() {
        assertFalse(
            ScreenShareAutoTypeFollowPolicy.shouldOpen(
                baseInput(
                    controlMode = ScreenMirrorControlMode.COPILOT,
                    context = textContext(receivedAtMillis = nowMillis),
                ),
            ),
        )
    }

    @Test
    fun shouldOpen_blockedWhenManualDismissActive() {
        assertFalse(
            ScreenShareAutoTypeFollowPolicy.shouldOpen(
                baseInput(
                    manualDismissUntilMillis = nowMillis + 1_000L,
                    context = textContext(receivedAtMillis = nowMillis),
                ),
            ),
        )
    }

    @Test
    fun shouldOpen_allowedWhenManualDismissExpired() {
        assertTrue(
            ScreenShareAutoTypeFollowPolicy.shouldOpen(
                baseInput(
                    manualDismissUntilMillis = nowMillis - 1L,
                    context = textContext(receivedAtMillis = nowMillis),
                ),
            ),
        )
    }

    @Test
    fun shouldOpen_blockedWhenAlreadyTyping() {
        assertFalse(
            ScreenShareAutoTypeFollowPolicy.shouldOpen(
                baseInput(
                    typingOpen = true,
                    context = textContext(receivedAtMillis = nowMillis),
                ),
            ),
        )
    }

    @Test
    fun shouldOpen_blockedWhenLowConfidence() {
        assertFalse(
            ScreenShareAutoTypeFollowPolicy.shouldOpen(
                baseInput(
                    context = textContext(
                        receivedAtMillis = nowMillis,
                        confidence = 0.49,
                    ),
                ),
            ),
        )
    }

    @Test
    fun shouldOpen_allowedWhenConfidenceNull() {
        assertTrue(
            ScreenShareAutoTypeFollowPolicy.shouldOpen(
                baseInput(
                    context = textContext(
                        receivedAtMillis = nowMillis,
                        confidence = null,
                    ),
                ),
            ),
        )
    }

    @Test
    fun shouldOpen_blockedWhenNonTextFocus() {
        assertFalse(
            ScreenShareAutoTypeFollowPolicy.shouldOpen(
                baseInput(
                    context = cursorContext(receivedAtMillis = nowMillis),
                ),
            ),
        )
    }

    @Test
    fun shouldOpen_blockedWhenContextMissing() {
        assertFalse(
            ScreenShareAutoTypeFollowPolicy.shouldOpen(
                baseInput(context = null),
            ),
        )
    }

    @Test
    fun shouldClose_whenFocusLeavesText() {
        assertTrue(
            ScreenShareAutoTypeFollowPolicy.shouldClose(
                baseInput(
                    typingOpen = true,
                    context = cursorContext(receivedAtMillis = nowMillis),
                ),
            ),
        )
    }

    @Test
    fun shouldClose_whenContextStale() {
        assertTrue(
            ScreenShareAutoTypeFollowPolicy.shouldClose(
                baseInput(
                    typingOpen = true,
                    context = textContext(
                        receivedAtMillis = nowMillis - ScreenShareAutoTypeFollowPolicy.STALE_AFTER_MILLIS - 1,
                    ),
                ),
            ),
        )
    }

    @Test
    fun shouldClose_whenContextMissing() {
        assertTrue(
            ScreenShareAutoTypeFollowPolicy.shouldClose(
                baseInput(
                    typingOpen = true,
                    context = null,
                ),
            ),
        )
    }

    @Test
    fun shouldClose_whenControlDisabled() {
        assertTrue(
            ScreenShareAutoTypeFollowPolicy.shouldClose(
                baseInput(
                    typingOpen = true,
                    standardControlEnabled = false,
                    context = textContext(receivedAtMillis = nowMillis),
                ),
            ),
        )
    }

    @Test
    fun shouldClose_falseWhenTypingClosed() {
        assertFalse(
            ScreenShareAutoTypeFollowPolicy.shouldClose(
                baseInput(
                    typingOpen = false,
                    context = cursorContext(receivedAtMillis = nowMillis),
                ),
            ),
        )
    }

    @Test
    fun shouldClose_falseWhileFreshTextFocus() {
        assertFalse(
            ScreenShareAutoTypeFollowPolicy.shouldClose(
                baseInput(
                    typingOpen = true,
                    context = textContext(receivedAtMillis = nowMillis),
                ),
            ),
        )
    }

    @Test
    fun hasActiveTextFocus_trueForFreshTextFocus() {
        assertTrue(
            ScreenShareAutoTypeFollowPolicy.hasActiveTextFocus(
                context = textContext(receivedAtMillis = nowMillis),
                selectedDisplayId = "display-1",
                nowMillis = nowMillis,
            ),
        )
    }

    private fun baseInput(
        autoKeyboardEnabled: Boolean = true,
        standardControlEnabled: Boolean = true,
        controlMode: ScreenMirrorControlMode = ScreenMirrorControlMode.TOUCH,
        typingOpen: Boolean = false,
        context: ScreenShareSmartZoomContext? = null,
        selectedDisplayId: String? = "display-1",
        manualDismissUntilMillis: Long? = null,
    ): ScreenShareAutoTypeFollowPolicy.Input =
        ScreenShareAutoTypeFollowPolicy.Input(
            autoKeyboardEnabled = autoKeyboardEnabled,
            standardControlEnabled = standardControlEnabled,
            controlMode = controlMode,
            typingOpen = typingOpen,
            context = context,
            selectedDisplayId = selectedDisplayId,
            manualDismissUntilMillis = manualDismissUntilMillis,
            nowMillis = nowMillis,
        )

    private fun textContext(
        receivedAtMillis: Long,
        displayId: String? = "display-1",
        confidence: Double? = 0.95,
    ): ScreenShareSmartZoomContext {
        val rect = HermesRealtimeRelayNormalizedRect(x = 0.4, y = 0.45, width = 0.2, height = 0.05)
        return ScreenShareSmartZoomContext(
            targetKind = HermesRealtimeRelayFocusTargetKind.FOCUSED_ELEMENT,
            displayId = displayId,
            normalizedRect = rect,
            normalizedPoint = null,
            confidence = confidence,
            receivedAtMillis = receivedAtMillis,
        )
    }

    private fun cursorContext(receivedAtMillis: Long): ScreenShareSmartZoomContext =
        ScreenShareSmartZoomContext(
            targetKind = HermesRealtimeRelayFocusTargetKind.CURSOR,
            displayId = "display-1",
            normalizedRect = null,
            normalizedPoint = null,
            confidence = 0.95,
            receivedAtMillis = receivedAtMillis,
        )
}
