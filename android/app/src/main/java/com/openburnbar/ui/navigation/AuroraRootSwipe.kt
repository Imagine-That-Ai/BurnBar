package com.openburnbar.ui.navigation

import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.changedToUpIgnoreConsumed
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.unit.dp

// MARK: - Root content swipe (Android)
//
// A passive observer on the phone shell's content area that advances one
// adjacent tab per qualifying horizontal drag — the Android port of the iOS
// root-swipe in `RootTabView`. Passive is the load-bearing property: the
// modifier watches [PointerEventPass.Final], AFTER every child has had its
// turn, and commits only when no child consumed the drag. A horizontal pager,
// chart scrubber, or slider that claims the gesture wins automatically; plain
// vertical lists never claim horizontal drags, so the swipe works on top of
// them without stealing their scroll.

/**
 * Observes drags over this element and reports at most ONE resolved swipe per
 * gesture via [onSwipe]. Direction math lives in [AuroraNavGestureModel].
 * When [enabled] is false the modifier is a no-op (the user turned the
 * feature off in Settings → Navigation).
 */
fun Modifier.auroraRootSwipe(enabled: Boolean, onSwipe: (AuroraNavGestureModel.SwipeDirection) -> Unit): Modifier {
    if (!enabled) return this
    return pointerInput(onSwipe) {
        val minDistancePx = AuroraNavGestureModel.MINIMUM_DISTANCE_DP.dp.toPx()
        awaitEachGesture {
            val down = awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Final)
            var totalX = 0f
            var totalY = 0f
            var claimedByChild = false
            var tracking = true
            while (tracking) {
                val event = awaitPointerEvent(PointerEventPass.Final)
                val change = event.changes.firstOrNull { it.id == down.id }
                if (change == null) {
                    // Losing sight of the pointer (system cancel, pointer id
                    // gone) cancels the gesture without committing.
                    tracking = false
                } else {
                    if (change.isConsumed) claimedByChild = true
                    totalX += change.position.x - change.previousPosition.x
                    totalY += change.position.y - change.previousPosition.y
                    if (change.changedToUpIgnoreConsumed()) {
                        if (!claimedByChild) {
                            AuroraNavGestureModel.swipeDirection(totalX, totalY, minDistancePx)?.let(onSwipe)
                        }
                        tracking = false
                    }
                }
            }
        }
    }
}
