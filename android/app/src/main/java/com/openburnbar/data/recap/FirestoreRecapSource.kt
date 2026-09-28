package com.openburnbar.data.recap

import com.google.firebase.FirebaseException
import com.google.firebase.firestore.DocumentSnapshot
import com.openburnbar.data.firebase.FirestoreRepository
import com.openburnbar.data.models.TokenUsage
import java.io.IOException
import kotlinx.coroutines.CancellationException
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

        val (collected, isPartial) =
            RecapPagination.collect<DocumentSnapshot>(pageBudget) { cursor ->
                repo.fetchUsagePage(
                    pageSize = pageSize,
                    after = cursor,
                    startDate = startMillis,
                    endDate = endMillis - 1,
                )
            }

        val inWindow = collected.filter { it.startTime in startMillis until endMillis }
        inWindow to isPartial
    }

    companion object {
        const val DEFAULT_PAGE_SIZE = 200
        const val DEFAULT_PAGE_BUDGET = 24
    }
}

/**
 * Cursor pagination for the Recap source, independent of Firestore types so it
 * is JVM-testable.
 *
 * - Paging continues while the fetcher returns a cursor. The cursor is computed
 *   from the raw page, so a page that decoded short (malformed rows dropped)
 *   still leads to the next page.
 * - A failure on the first page propagates: the caller has no data and must show
 *   its failure state, not an empty month.
 * - A failure on a later page, or running out of [pageBudget] with a cursor still
 *   pending, keeps what was collected and marks the result partial.
 * - Cancellation always propagates.
 */
internal object RecapPagination {
    suspend fun <C : Any> collect(pageBudget: Int, fetchPage: suspend (cursor: C?) -> Pair<List<TokenUsage>, C?>): Pair<List<TokenUsage>, Boolean> {
        val collected = mutableListOf<TokenUsage>()
        var cursor: C? = null
        var pageIndex = 0

        while (pageIndex < pageBudget) {
            val result =
                if (pageIndex == 0) {
                    fetchPage(null)
                } else {
                    fetchLaterPage(cursor, fetchPage) ?: return collected to true
                }
            collected.addAll(result.first)
            cursor = result.second ?: return collected to false
            pageIndex++
        }
        return collected to true
    }

    private suspend fun <C : Any> fetchLaterPage(cursor: C?, fetchPage: suspend (cursor: C?) -> Pair<List<TokenUsage>, C?>): Pair<List<TokenUsage>, C?>? = try {
        fetchPage(cursor)
    } catch (e: CancellationException) {
        throw e
    } catch (_: IOException) {
        null
    } catch (_: FirebaseException) {
        null
    } catch (_: IllegalStateException) {
        null
    }
}
