package com.openburnbar.data.policy

/** Distinct Streams list states. Error must never render as empty. */
enum class MobileStreamsListPresentation(val wire: String) {
    LOADING("loading"),
    FAILED("failed"),
    EMPTY("empty"),
    LOCKED("locked"),
    READY("ready"),
    PAGINATING("paginating"),
}

data class MobileStreamsPageOutcome(
    val rowCount: Int,
    val hasMore: Boolean,
    val canLoadNext: Boolean,
    val presentation: MobileStreamsListPresentation,
)

/** Pagination / empty / error / lock for Streams. Source: iOS `ActivityStore`. */
object MobileStreamsListPolicy {
    fun presentation(
        isLoading: Boolean,
        failed: Boolean,
        isEmpty: Boolean,
        entitled: Boolean,
        hasMore: Boolean,
        isPaginating: Boolean,
        searchFailed: Boolean,
    ): MobileStreamsListPresentation = when {
        !entitled -> MobileStreamsListPresentation.LOCKED
        failed || searchFailed -> MobileStreamsListPresentation.FAILED
        isLoading && isEmpty -> MobileStreamsListPresentation.LOADING
        isEmpty -> MobileStreamsListPresentation.EMPTY
        isPaginating && hasMore -> MobileStreamsListPresentation.PAGINATING
        else -> MobileStreamsListPresentation.READY
    }

    fun pageOutcome(
        accumulatedCount: Int,
        pageCount: Int,
        pageSize: Int,
        lastCursorPresent: Boolean,
        failed: Boolean,
        entitled: Boolean = true,
        isLoading: Boolean = false,
    ): MobileStreamsPageOutcome {
        val hasMore = !failed && lastCursorPresent && pageCount == pageSize
        return MobileStreamsPageOutcome(
            rowCount = accumulatedCount,
            hasMore = hasMore,
            canLoadNext = hasMore && !isLoading && !failed,
            presentation = presentation(
                isLoading = isLoading,
                failed = failed,
                isEmpty = accumulatedCount == 0,
                entitled = entitled,
                hasMore = hasMore,
                isPaginating = false,
                searchFailed = false,
            ),
        )
    }
}
