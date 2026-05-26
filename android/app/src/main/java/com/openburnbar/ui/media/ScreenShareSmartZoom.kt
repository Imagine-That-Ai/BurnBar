package com.openburnbar.ui.media

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.unit.IntSize
import com.openburnbar.irohrelay.HermesRealtimeRelayFocusContext
import com.openburnbar.irohrelay.HermesRealtimeRelayFocusTargetKind
import com.openburnbar.irohrelay.HermesRealtimeRelayNormalizedPoint
import com.openburnbar.irohrelay.HermesRealtimeRelayNormalizedRect

/**
 * Mercury Smart Zoom — pure Android reducer that mirrors the iOS
 * `ScreenShareSmartZoomReducer` (see
 * `OpenBurnBarMobile/Views/Media/ScreenShareViewerView.swift`).
 *
 * The reducer is intentionally side-effect free so the JVM unit
 * suite (`./gradlew :app:testDebugUnitTest`) can exercise every
 * branch — clamping, stale context, manual override, display
 * filtering — without launching a Compose UI.
 */
enum class SmartZoomMode(val label: String) {
    OFF("Off"),
    SMART("Smart"),
    TEXT("Text"),
    WINDOW("Window"),
    CURSOR("Cursor"),
}

data class ScreenShareSmartZoomContext(
    val targetKind: HermesRealtimeRelayFocusTargetKind,
    val displayId: String?,
    val normalizedRect: HermesRealtimeRelayNormalizedRect?,
    val normalizedPoint: HermesRealtimeRelayNormalizedPoint?,
    val confidence: Double?,
    val receivedAtMillis: Long,
) {
    companion object {
        fun from(
            relay: HermesRealtimeRelayFocusContext,
            receivedAtMillis: Long = System.currentTimeMillis(),
        ): ScreenShareSmartZoomContext? {
            val kind = relay.targetKind ?: return null
            return ScreenShareSmartZoomContext(
                targetKind = kind,
                displayId = relay.displayId,
                normalizedRect = relay.normalizedRect,
                normalizedPoint = relay.normalizedPoint,
                confidence = relay.confidence,
                receivedAtMillis = receivedAtMillis,
            )
        }
    }
}

data class ScreenShareSmartZoomDecision(
    val scale: Float,
    val translation: Offset,
    val isAutoFollowing: Boolean,
) {
    companion object {
        val identity = ScreenShareSmartZoomDecision(scale = 1f, translation = Offset.Zero, isAutoFollowing = false)
    }
}

object ScreenShareSmartZoomReducer {
    const val STALE_AFTER_MILLIS: Long = 1_500L
    const val MANUAL_OVERRIDE_HOLD_MILLIS: Long = 5_000L
    const val TEXT_FILL_RATIO: Float = 0.62f
    const val WINDOW_FILL_RATIO: Float = 0.86f
    const val AGENT_FILL_RATIO: Float = 0.72f
    const val MIN_SCALE: Float = 1.0f
    const val MAX_SCALE: Float = 4.0f
    val TEXT_SCALE_RANGE: ClosedFloatingPointRange<Float> = 1.4f..4.0f
    val WINDOW_SCALE_RANGE: ClosedFloatingPointRange<Float> = 1.0f..2.4f
    val AGENT_SCALE_RANGE: ClosedFloatingPointRange<Float> = 1.0f..3.0f
    const val CURSOR_ENTRY_SCALE: Float = 1.8f

    fun reduce(
        viewportSize: IntSize,
        contentRect: Rect,
        currentScale: Float,
        currentTranslation: Offset,
        context: ScreenShareSmartZoomContext?,
        mode: SmartZoomMode,
        selectedDisplayId: String?,
        manualOverrideUntilMillis: Long?,
        nowMillis: Long,
    ): ScreenShareSmartZoomDecision {
        val idle = ScreenShareSmartZoomDecision(
            scale = currentScale,
            translation = currentTranslation,
            isAutoFollowing = false,
        )
        if (mode == SmartZoomMode.OFF) return idle
        if (viewportSize.width <= 0 || viewportSize.height <= 0) return idle
        if (contentRect.width <= 0f || contentRect.height <= 0f) return idle
        if (manualOverrideUntilMillis != null && manualOverrideUntilMillis > nowMillis) return idle
        val ctx = context ?: return idle
        if (nowMillis - ctx.receivedAtMillis > STALE_AFTER_MILLIS) return idle
        if (ctx.displayId != null && selectedDisplayId != null && ctx.displayId != selectedDisplayId) return idle
        if (!targetMatches(mode, ctx.targetKind)) return idle

        return when (ctx.targetKind) {
            HermesRealtimeRelayFocusTargetKind.FOCUSED_ELEMENT -> {
                val rect = ctx.normalizedRect ?: return idle
                fitRectDecision(rect, viewportSize, contentRect, TEXT_FILL_RATIO, TEXT_SCALE_RANGE)
            }
            HermesRealtimeRelayFocusTargetKind.FOCUSED_WINDOW -> {
                val rect = ctx.normalizedRect ?: return idle
                fitRectDecision(rect, viewportSize, contentRect, WINDOW_FILL_RATIO, WINDOW_SCALE_RANGE)
            }
            HermesRealtimeRelayFocusTargetKind.AGENT_WORKSPACE -> {
                val rect = ctx.normalizedRect ?: return idle
                fitRectDecision(rect, viewportSize, contentRect, AGENT_FILL_RATIO, AGENT_SCALE_RANGE)
            }
            HermesRealtimeRelayFocusTargetKind.CURSOR -> {
                val point = ctx.normalizedPoint ?: return idle
                val targetScale = if (currentScale > MIN_SCALE + 0.001f) currentScale else CURSOR_ENTRY_SCALE
                centerPointDecision(point, viewportSize, contentRect, targetScale)
            }
        }
    }

    fun targetMatches(mode: SmartZoomMode, kind: HermesRealtimeRelayFocusTargetKind): Boolean = when (mode) {
        SmartZoomMode.OFF -> false
        SmartZoomMode.SMART -> true
        SmartZoomMode.TEXT -> kind == HermesRealtimeRelayFocusTargetKind.FOCUSED_ELEMENT
        SmartZoomMode.WINDOW -> kind == HermesRealtimeRelayFocusTargetKind.FOCUSED_WINDOW
        SmartZoomMode.CURSOR -> kind == HermesRealtimeRelayFocusTargetKind.CURSOR
    }

    fun fitRectDecision(
        rect: HermesRealtimeRelayNormalizedRect,
        viewportSize: IntSize,
        contentRect: Rect,
        fillRatio: Float,
        scaleRange: ClosedFloatingPointRange<Float>,
    ): ScreenShareSmartZoomDecision {
        val rectW = (rect.width.toFloat().coerceAtLeast(0.0001f)) * contentRect.width
        val rectH = (rect.height.toFloat().coerceAtLeast(0.0001f)) * contentRect.height
        val shortRectAxis = minOf(rectW, rectH)
        val shortViewportAxis = minOf(viewportSize.width.toFloat(), viewportSize.height.toFloat())
        val targetShortAxis = shortViewportAxis * fillRatio
        val rawScale = targetShortAxis / shortRectAxis.coerceAtLeast(0.0001f)
        val scale = clamp(rawScale, scaleRange.start, scaleRange.endInclusive)
        val centerX = contentRect.left + ((rect.x + rect.width / 2.0).toFloat()) * contentRect.width
        val centerY = contentRect.top + ((rect.y + rect.height / 2.0).toFloat()) * contentRect.height
        val translation = offsetForCenter(centerX, centerY, scale, viewportSize)
        return ScreenShareSmartZoomDecision(scale = scale, translation = translation, isAutoFollowing = true)
    }

    fun centerPointDecision(
        point: HermesRealtimeRelayNormalizedPoint,
        viewportSize: IntSize,
        contentRect: Rect,
        scale: Float,
    ): ScreenShareSmartZoomDecision {
        val clampedScale = clamp(scale, MIN_SCALE, MAX_SCALE)
        val centerX = contentRect.left + point.x.toFloat() * contentRect.width
        val centerY = contentRect.top + point.y.toFloat() * contentRect.height
        val translation = offsetForCenter(centerX, centerY, clampedScale, viewportSize)
        return ScreenShareSmartZoomDecision(scale = clampedScale, translation = translation, isAutoFollowing = true)
    }

    /**
     * Inverse of `applySmartZoomTransform(point)`:
     *
     *   viewX = (cx - W/2) * scale + W/2 + translationX
     *   to put viewX at W/2 ⇒ translationX = (W/2 - cx) * scale.
     */
    fun offsetForCenter(centerX: Float, centerY: Float, scale: Float, viewportSize: IntSize): Offset {
        val halfWidth = viewportSize.width / 2f
        val halfHeight = viewportSize.height / 2f
        val tx = (halfWidth - centerX) * scale
        val ty = (halfHeight - centerY) * scale
        val clampedTx = clampTranslation(tx, scale, viewportSize.width.toFloat())
        val clampedTy = clampTranslation(ty, scale, viewportSize.height.toFloat())
        return Offset(clampedTx, clampedTy)
    }

    /** Inverse-maps a viewport-space point back into the un-zoomed surface. */
    fun unzoomedPosition(position: Offset, scale: Float, translation: Offset, viewportSize: IntSize): Offset {
        val halfWidth = viewportSize.width / 2f
        val halfHeight = viewportSize.height / 2f
        if (scale <= 0.0001f) return position
        val baseX = ((position.x - halfWidth - translation.x) / scale) + halfWidth
        val baseY = ((position.y - halfHeight - translation.y) / scale) + halfHeight
        return Offset(baseX, baseY)
    }

    private fun clampTranslation(value: Float, scale: Float, dimension: Float): Float {
        if (scale <= MIN_SCALE || dimension <= 0f) return 0f
        val limit = dimension * (scale - 1f) / 2f
        return value.coerceIn(-limit, limit)
    }

    fun clamp(value: Float, min: Float, max: Float): Float {
        if (value.isNaN()) return min
        return value.coerceIn(min, max)
    }
}
