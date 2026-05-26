package com.openburnbar.ui.media

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.unit.IntSize
import com.openburnbar.irohrelay.HermesRealtimeRelayFocusTargetKind
import com.openburnbar.irohrelay.HermesRealtimeRelayNormalizedPoint
import com.openburnbar.irohrelay.HermesRealtimeRelayNormalizedRect
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ScreenShareSmartZoomReducerTest {

    private val viewport = IntSize(1000, 1000)
    private val contentRect = Rect(0f, 0f, 1000f, 1000f)
    private val baseScale = ScreenShareSmartZoomReducer.MIN_SCALE
    private val baseTranslation = Offset.Zero
    private val nowMillis = 10_000L

    @Test
    fun reduce_returnsIdleWhenModeOff() {
        val context = textContext(receivedAtMillis = nowMillis)
        val decision = ScreenShareSmartZoomReducer.reduce(
            viewportSize = viewport,
            contentRect = contentRect,
            currentScale = baseScale,
            currentTranslation = baseTranslation,
            context = context,
            mode = SmartZoomMode.OFF,
            selectedDisplayId = "display-1",
            manualOverrideUntilMillis = null,
            nowMillis = nowMillis,
        )
        assertEquals(baseScale, decision.scale)
        assertEquals(baseTranslation, decision.translation)
        assertFalse(decision.isAutoFollowing)
    }

    @Test
    fun reduce_ignoresStaleContext() {
        val context = textContext(receivedAtMillis = nowMillis - 2_000L)
        val decision = ScreenShareSmartZoomReducer.reduce(
            viewportSize = viewport,
            contentRect = contentRect,
            currentScale = baseScale,
            currentTranslation = baseTranslation,
            context = context,
            mode = SmartZoomMode.SMART,
            selectedDisplayId = "display-1",
            manualOverrideUntilMillis = null,
            nowMillis = nowMillis,
        )
        assertFalse(decision.isAutoFollowing)
    }

    @Test
    fun reduce_skipsContextForDifferentDisplay() {
        val context = textContext(receivedAtMillis = nowMillis, displayId = "display-other")
        val decision = ScreenShareSmartZoomReducer.reduce(
            viewportSize = viewport,
            contentRect = contentRect,
            currentScale = baseScale,
            currentTranslation = baseTranslation,
            context = context,
            mode = SmartZoomMode.SMART,
            selectedDisplayId = "display-1",
            manualOverrideUntilMillis = null,
            nowMillis = nowMillis,
        )
        assertFalse(decision.isAutoFollowing)
    }

    @Test
    fun reduce_holdsManualOverride() {
        val context = textContext(receivedAtMillis = nowMillis)
        val decision = ScreenShareSmartZoomReducer.reduce(
            viewportSize = viewport,
            contentRect = contentRect,
            currentScale = baseScale,
            currentTranslation = baseTranslation,
            context = context,
            mode = SmartZoomMode.SMART,
            selectedDisplayId = "display-1",
            manualOverrideUntilMillis = nowMillis + 100,
            nowMillis = nowMillis,
        )
        assertFalse(decision.isAutoFollowing)
    }

    @Test
    fun reduce_fitsTextTargetWithinTextScaleRange() {
        val context = textContext(receivedAtMillis = nowMillis)
        val decision = ScreenShareSmartZoomReducer.reduce(
            viewportSize = viewport,
            contentRect = contentRect,
            currentScale = baseScale,
            currentTranslation = baseTranslation,
            context = context,
            mode = SmartZoomMode.SMART,
            selectedDisplayId = "display-1",
            manualOverrideUntilMillis = null,
            nowMillis = nowMillis,
        )
        assertTrue(decision.isAutoFollowing)
        assertTrue("scale within text range, was=${decision.scale}",
            decision.scale in ScreenShareSmartZoomReducer.TEXT_SCALE_RANGE)
    }

    @Test
    fun reduce_fitsWindowTargetWithinWindowScaleRange() {
        val rect = HermesRealtimeRelayNormalizedRect(x = 0.1, y = 0.1, width = 0.8, height = 0.6)
        val context = ScreenShareSmartZoomContext(
            targetKind = HermesRealtimeRelayFocusTargetKind.FOCUSED_WINDOW,
            displayId = "display-1",
            normalizedRect = rect,
            normalizedPoint = null,
            confidence = 0.7,
            receivedAtMillis = nowMillis,
        )
        val decision = ScreenShareSmartZoomReducer.reduce(
            viewportSize = viewport,
            contentRect = contentRect,
            currentScale = baseScale,
            currentTranslation = baseTranslation,
            context = context,
            mode = SmartZoomMode.SMART,
            selectedDisplayId = "display-1",
            manualOverrideUntilMillis = null,
            nowMillis = nowMillis,
        )
        assertTrue(decision.isAutoFollowing)
        assertTrue("scale within window range, was=${decision.scale}",
            decision.scale in ScreenShareSmartZoomReducer.WINDOW_SCALE_RANGE)
    }

    @Test
    fun reduce_cursorScaleUsesEntryScaleWhenNotZoomed() {
        val context = ScreenShareSmartZoomContext(
            targetKind = HermesRealtimeRelayFocusTargetKind.CURSOR,
            displayId = "display-1",
            normalizedRect = null,
            normalizedPoint = HermesRealtimeRelayNormalizedPoint(x = 0.5, y = 0.5),
            confidence = 0.4,
            receivedAtMillis = nowMillis,
        )
        val decision = ScreenShareSmartZoomReducer.reduce(
            viewportSize = viewport,
            contentRect = contentRect,
            currentScale = baseScale,
            currentTranslation = baseTranslation,
            context = context,
            mode = SmartZoomMode.CURSOR,
            selectedDisplayId = "display-1",
            manualOverrideUntilMillis = null,
            nowMillis = nowMillis,
        )
        assertTrue(decision.isAutoFollowing)
        assertEquals(ScreenShareSmartZoomReducer.CURSOR_ENTRY_SCALE, decision.scale)
    }

    @Test
    fun reduce_textModeRejectsCursorContext() {
        val context = ScreenShareSmartZoomContext(
            targetKind = HermesRealtimeRelayFocusTargetKind.CURSOR,
            displayId = "display-1",
            normalizedRect = null,
            normalizedPoint = HermesRealtimeRelayNormalizedPoint(x = 0.5, y = 0.5),
            confidence = 0.4,
            receivedAtMillis = nowMillis,
        )
        val decision = ScreenShareSmartZoomReducer.reduce(
            viewportSize = viewport,
            contentRect = contentRect,
            currentScale = baseScale,
            currentTranslation = baseTranslation,
            context = context,
            mode = SmartZoomMode.TEXT,
            selectedDisplayId = "display-1",
            manualOverrideUntilMillis = null,
            nowMillis = nowMillis,
        )
        assertFalse(decision.isAutoFollowing)
    }

    @Test
    fun reduce_clampsTranslationsWithinViewport() {
        val rect = HermesRealtimeRelayNormalizedRect(x = 0.0, y = 0.0, width = 0.05, height = 0.05)
        val context = ScreenShareSmartZoomContext(
            targetKind = HermesRealtimeRelayFocusTargetKind.FOCUSED_ELEMENT,
            displayId = "display-1",
            normalizedRect = rect,
            normalizedPoint = null,
            confidence = 0.9,
            receivedAtMillis = nowMillis,
        )
        val decision = ScreenShareSmartZoomReducer.reduce(
            viewportSize = viewport,
            contentRect = contentRect,
            currentScale = baseScale,
            currentTranslation = baseTranslation,
            context = context,
            mode = SmartZoomMode.SMART,
            selectedDisplayId = "display-1",
            manualOverrideUntilMillis = null,
            nowMillis = nowMillis,
        )
        assertTrue(decision.isAutoFollowing)
        val limitX = viewport.width * (decision.scale - 1f) / 2f
        val limitY = viewport.height * (decision.scale - 1f) / 2f
        assertTrue(decision.translation.x in -limitX..limitX)
        assertTrue(decision.translation.y in -limitY..limitY)
    }

    @Test
    fun inverseSmartZoom_recoversUnzoomedPosition() {
        val bounds = ScreenMirrorSurfaceBounds(left = 0f, top = 0f, width = 1000f, height = 1000f)
        val centeredPoint = Offset(500f, 500f)
        val scale = 2f
        // Smart-zoom translation that keeps the center pixel at the
        // center of the viewport (no translation).
        val translation = Offset.Zero
        val unzoomed = ScreenMirrorInputPolicy.inverseSmartZoom(
            local = centeredPoint,
            bounds = bounds,
            smartZoomScale = scale,
            smartZoomTranslation = translation,
        )
        assertEquals(500f, unzoomed.x, 0.001f)
        assertEquals(500f, unzoomed.y, 0.001f)
    }

    @Test
    fun normalizedPoint_inverseMapsPositionThroughSmartZoom() {
        val root = IntSize(width = 1000, height = 1000)
        val aspect = 1f
        val bounds = ScreenMirrorInputPolicy.surfaceBounds(root, ScreenMirrorFit.FIT, aspect)!!
        val scale = 2f
        // Translation moves the rendered content so that the top-left
        // corner ends up at the viewport center.
        val translation = Offset(bounds.width, bounds.height)
        val normalized = ScreenMirrorInputPolicy.normalizedPoint(
            position = Offset(bounds.center.x, bounds.center.y),
            rootSize = root,
            fit = ScreenMirrorFit.FIT,
            aspect = aspect,
            smartZoomScale = scale,
            smartZoomTranslation = translation,
        )
        requireNotNull(normalized)
        assertEquals(0.0, normalized.first, 0.001)
        assertEquals(0.0, normalized.second, 0.001)
    }

    private fun textContext(
        receivedAtMillis: Long,
        displayId: String? = "display-1",
    ): ScreenShareSmartZoomContext {
        val rect = HermesRealtimeRelayNormalizedRect(x = 0.4, y = 0.45, width = 0.2, height = 0.05)
        return ScreenShareSmartZoomContext(
            targetKind = HermesRealtimeRelayFocusTargetKind.FOCUSED_ELEMENT,
            displayId = displayId,
            normalizedRect = rect,
            normalizedPoint = null,
            confidence = 0.95,
            receivedAtMillis = receivedAtMillis,
        )
    }
}
