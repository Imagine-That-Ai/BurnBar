package com.openburnbar.ui.navigation

// MARK: - AuroraNavGestureModel
//
// Pure, side-effect-free gesture math for root content-area swipes, ported
// from the iOS `OpenBurnBarMobile/Views/Navigation/AuroraNavGestureModel.swift`
// so both phones resolve the same drag to the same tab change. Keeping the
// resolution logic here (instead of inside pointer-input closures) makes
// direction mapping and edge clamping unit-testable without a Compose host.

object AuroraNavGestureModel {
    /**
     * Direction of a resolved horizontal swipe, in the iOS model's vocabulary:
     * - [LEADING]: finger moved toward the trailing edge (left swipe in LTR),
     *   advancing to the NEXT tab;
     * - [TRAILING]: finger moved toward the leading edge (right swipe in LTR),
     *   going to the PREVIOUS tab.
     */
    enum class SwipeDirection { LEADING, TRAILING }

    /**
     * The design contract's root-swipe threshold on Android (dp). iOS resolves
     * at 40pt; the Android shell commits at 30dp per
     * `docs/mobile-parity/NAV_CUSTOMIZATION_AND_FLEET_MIRROR_PLAN.md`.
     */
    const val MINIMUM_DISTANCE_DP = 30f

    /**
     * Whether a drag has enough horizontal intent to qualify as a tab change
     * (vs. vertical scrolling inside a tab). Mirrors the Swift
     * `swipeDirection(translation:minimumDistance:)`: the drag must be
     * predominantly horizontal (strictly `|dx| > |dy|`) and travel at least
     * [minimumDistance] on the x axis. Returns null for ambiguous gestures.
     */
    fun swipeDirection(translationX: Float, translationY: Float, minimumDistance: Float): SwipeDirection? {
        val absX = kotlin.math.abs(translationX)
        val absY = kotlin.math.abs(translationY)
        if (absX <= absY || absX < minimumDistance) return null
        return if (translationX < 0) SwipeDirection.LEADING else SwipeDirection.TRAILING
    }

    /**
     * The next or previous element for a root content swipe, or null when the
     * swipe would push past an edge (no wraparound) or [current] is not in
     * [elements]. Mirrors the Swift `adjacent(current:direction:destinations:)`.
     */
    fun <T> adjacent(current: T, direction: SwipeDirection, elements: List<T>): T? {
        val index = elements.indexOf(current)
        if (index < 0) return null
        val target = when (direction) {
            SwipeDirection.LEADING -> index + 1
            SwipeDirection.TRAILING -> index - 1
        }
        return elements.getOrNull(target)
    }
}
