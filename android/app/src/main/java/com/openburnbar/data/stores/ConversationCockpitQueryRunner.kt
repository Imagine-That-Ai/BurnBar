package com.openburnbar.data.stores

import com.google.firebase.FirebaseException
import com.google.firebase.functions.FirebaseFunctionsException
import com.openburnbar.BuildConfig
import com.openburnbar.data.cloud.CloudConversationSearchService
import com.openburnbar.data.cloud.CloudVaultCrypto
import com.openburnbar.data.firebase.ConversationFacetRow
import com.openburnbar.data.firebase.ConversationQueryResponse
import com.openburnbar.data.firebase.FunctionsRepository
import kotlinx.coroutines.CancellationException

internal class ConversationCockpitQueryRunner(
    private val functions: FunctionsRepository,
    private val searchService: CloudConversationSearchService,
) {
    suspend fun queryPage(store: ConversationCockpitStore, reset: Boolean): ConversationQueryResponse = functions.queryConversations(
        providers = store.selectedProviders.value.toList(),
        models = store.selectedModel.value?.let { listOf(it) } ?: emptyList(),
        dateFromIso = store.dateFromMs.value?.isoString(),
        dateToIso = store.dateToMs.value?.isoString(),
        sort = store.sortField.value.field,
        direction = store.sortDirection.value.token,
        limit = PAGE_SIZE,
        cursorDocId = if (reset) null else store.nextCursor,
        includeAggregates = reset,
    )

    fun applyResponse(store: ConversationCockpitStore, response: ConversationQueryResponse, reset: Boolean) {
        val bindings = store.bindings
        val mapped = response.rows.map { decodeRow(store, it) }
        bindings.setRows(if (reset) mapped else store.rows.value + mapped)
        response.aggregates?.let { bindings.setAggregates(it) }
        store.nextCursor = response.nextCursor
        bindings.setHasMore(response.nextCursor != null)
        bindings.setError(null)
        refreshFacetOptions(store)
    }

    fun handleFailure(store: ConversationCockpitStore, error: Exception, reset: Boolean) {
        val bindings = store.bindings
        if (reset) {
            bindings.setRows(emptyList())
            bindings.setAggregates(null)
        }
        bindings.setHasMore(false)
        bindings.setError(presentableQueryError(error))
    }

    suspend fun executeQuery(store: ConversationCockpitStore, reset: Boolean, token: Int) {
        if (!prepareCallableAuth(store, reset)) return
        try {
            if (store.vaultKey == null) {
                store.vaultKey = runCatching { searchService.unlockVaultKeyOrNull() }.getOrNull()
            }
            if (token != store.queryToken) return
            store.bindings.setVaultLocked(store.vaultKey == null)

            val response = queryPage(store, reset)
            if (token != store.queryToken) return
            applyResponse(store, response, reset)
        } catch (_: CancellationException) {
            // Cooperative cancellation — leave state as-is for the next query.
        } catch (e: FirebaseFunctionsException) {
            if (token != store.queryToken) return
            if (isUnauthenticated(e) && searchService.prepareCallableAuth(forceRefresh = true)) {
                retryAfterAuth(store, reset, token, e)
            } else {
                handleFailure(store, e, reset)
            }
        }
    }

    private suspend fun prepareCallableAuth(store: ConversationCockpitStore, reset: Boolean): Boolean {
        if (searchService.prepareCallableAuth()) return true
        val bindings = store.bindings
        if (reset) {
            bindings.setRows(emptyList())
            bindings.setAggregates(null)
        }
        bindings.setVaultLocked(false)
        bindings.setHasMore(false)
        bindings.setError("Sign in to load cloud conversations.")
        return false
    }

    @Suppress("UnusedParameter")
    private suspend fun retryAfterAuth(store: ConversationCockpitStore, reset: Boolean, token: Int, original: Exception) {
        try {
            val response = queryPage(store, reset)
            if (token != store.queryToken) return
            applyResponse(store, response, reset)
        } catch (_: CancellationException) {
            return
        } catch (retryError: FirebaseException) {
            if (token != store.queryToken) return
            handleFailure(store, retryError, reset)
        }
    }

    suspend fun loadTranscript(row: CockpitConversationRow): String {
        val storagePath =
            row.storagePath?.takeIf { it.isNotBlank() }
                ?: error("This conversation has no encrypted body on file.")
        val bodyHash =
            row.bodyHash?.takeIf { it.isNotBlank() }
                ?: error("This conversation has no encrypted body on file.")
        return searchService.loadBodyAt(storagePath, bodyHash)
    }

    private fun decodeRow(store: ConversationCockpitStore, row: ConversationFacetRow): CockpitConversationRow {
        var title: String? = null
        var preview: String? = null
        val key = store.vaultKey
        if (key != null) {
            row.sealedTitle?.let { sealed -> title = runCatching { CloudVaultCrypto.openText(sealed, key) }.getOrNull() }
            row.sealedBodyPreview?.let { sealed -> preview = runCatching { CloudVaultCrypto.openText(sealed, key) }.getOrNull() }
        }
        return CockpitConversationRow(
            id = row.id,
            provider = row.provider,
            projectName = null,
            model = row.model,
            sourceType = row.sourceType,
            messageCount = row.messageCount ?: 0,
            inputTokens = row.inputTokens ?: 0,
            outputTokens = row.outputTokens ?: 0,
            totalTokens = row.totalTokens ?: 0,
            costUSD = row.costUSD ?: 0.0,
            workingDirectory = null,
            toolTags = row.toolTags,
            durationSeconds = row.durationSeconds,
            startTimeMs = row.startTimeMs,
            updatedAtMs = row.updatedAtMs,
            title = title,
            preview = preview,
            storagePath = row.storagePath,
            bodyHash = row.bodyHash,
        )
    }

    private fun refreshFacetOptions(store: ConversationCockpitStore) {
        val bindings = store.bindings
        val providers = store.discoveredProviders.value.toMutableSet()
        val models = store.discoveredModels.value.toMutableSet()
        for (row in store.rows.value) {
            row.provider?.takeIf { it.isNotBlank() }?.let { providers.add(it) }
            row.model?.takeIf { it.isNotBlank() }?.let { models.add(it) }
        }
        bindings.setDiscoveredProviders(providers.sorted())
        bindings.setDiscoveredModels(models.sorted())
    }

    private fun presentableQueryError(error: Exception): String {
        val message = error.localizedMessage ?: "Could not load conversations."
        return if (isUnauthenticated(error)) {
            if (BuildConfig.DEBUG) {
                "Sign in again, or reinstall this debug build with a registered App Check token."
            } else {
                "Sign in again to load cloud conversations."
            }
        } else {
            message
        }
    }

    private fun isUnauthenticated(error: Exception): Boolean {
        val message = error.localizedMessage ?: return false
        return message.contains("unauthenticated", ignoreCase = true)
    }

    private fun Long.isoString(): String = java.time.Instant.ofEpochMilli(this).toString()

    companion object {
        private const val PAGE_SIZE = 30
    }
}
