package com.openburnbar.data.recap

import com.google.firebase.firestore.DocumentSnapshot
import com.openburnbar.data.firebase.FirestoreRepository
import com.openburnbar.data.models.TokenUsage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

interface RecapSource {
    suspend fun loadUsages(window: RecapWindow): Pair<List<TokenUsage>, Boolean>
}

class FirestoreRecapSource(
    private val repo: FirestoreRepository = FirestoreRepository(),
    private val pageSize: Int = DEFAULT_PAGE_SIZE,
    private val pageBudget: Int = DEFAULT_PAGE_BUDGET,
) : RecapSource {

    override suspend fun loadUsages(window: RecapWindow): Pair<List<TokenUsage>, Boolean> = withContext(Dispatchers.IO) {
        val startMillis = window.startEpochMillis()
        val endMillis = window.endEpochMillis()

        val collected = mutableListOf<TokenUsage>()
        var cursor: DocumentSnapshot? = null
        var isPartial = false
        var hasMore = true
        var pageIndex = 0

        while (hasMore && pageIndex < pageBudget) {
            val result = fetchPageSafe(startMillis, endMillis - 1, cursor)
            if (result == null) {
                isPartial = true
                hasMore = false
            } else {
                val (page, nextCursor) = result
                collected.addAll(page)
                cursor = nextCursor
                hasMore = nextCursor != null && page.size >= pageSize
                pageIndex++
                if (pageIndex >= pageBudget && hasMore) {
                    isPartial = true
                }
            }
        }

        val inWindow = collected.filter { it.startTime in startMillis until endMillis }
        inWindow to isPartial
    }

    private suspend fun fetchPageSafe(startMillis: Long, endMillis: Long, cursor: DocumentSnapshot?): Pair<List<TokenUsage>, DocumentSnapshot?>? {
        return try {
            repo.fetchUsagePage(
                pageSize = pageSize,
                after = cursor,
                startDate = startMillis,
                endDate = endMillis,
            )
        } catch (_: Exception) {
            null
        }
    }

    companion object {
        const val DEFAULT_PAGE_SIZE = 200
        const val DEFAULT_PAGE_BUDGET = 24
    }
}
