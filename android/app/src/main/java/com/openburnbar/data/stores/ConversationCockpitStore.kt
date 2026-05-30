package com.openburnbar.data.stores

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.openburnbar.BuildConfig
import com.openburnbar.BurnBarApplication
import com.openburnbar.data.cloud.CloudConversationSearchService
import com.openburnbar.data.cloud.CloudVaultCrypto
import com.openburnbar.data.firebase.ConversationFacetRow
import com.openburnbar.data.firebase.ConversationQueryAggregates
import com.openburnbar.data.firebase.ConversationQueryResponse
import com.openburnbar.data.firebase.FunctionsRepository
import com.openburnbar.data.models.AgentProvider
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

/** Sort axes the cockpit can order by; each maps 1:1 to a plaintext facet the server can index. */
enum class ConversationSortField(val field: String, val label: String) {
    UPDATED_AT("updatedAt", "Recently updated"),
    START_TIME("startTime", "Start time"),
    END_TIME("endTime", "End time"),
    COST("costUSD", "Cost"),
    TOKENS("totalTokens", "Tokens");

    companion object {
        fun fromField(value: String?): ConversationSortField =
            entries.firstOrNull { it.field == value } ?: UPDATED_AT
    }
}

enum class ConversationSortDirection(val token: String, val label: String) {
    DESC("desc", "Highest first"),
    ASC("asc", "Lowest first");

    companion object {
        fun fromToken(value: String?): ConversationSortDirection =
            entries.firstOrNull { it.token == value } ?: DESC
    }
}

/** A persisted faceted query the user can recall from the cockpit's saved-query rail. */
data class SavedConversationQuery(
    val id: String,
    val name: String,
    val providers: List<String>,
    val model: String?,
    val projectQuery: String,
    val sortField: String,
    val sortDirection: String,
    val dateFromMs: Long?,
    val dateToMs: Long?
)

/**
 * A decrypted cockpit row: plaintext facets for browsing plus the opened title/preview. The
 * `storagePath`/`bodyHash` allow on-demand full-transcript retrieval; everything else renders
 * without touching Cloud Storage.
 */
data class CockpitConversationRow(
    val id: String,
    val provider: String?,
    val projectName: String?,
    val model: String?,
    val sourceType: String?,
    val messageCount: Int,
    val inputTokens: Int,
    val outputTokens: Int,
    val totalTokens: Int,
    val costUSD: Double,
    val workingDirectory: String?,
    val toolTags: List<String>,
    val durationSeconds: Int?,
    val startTimeMs: Long?,
    val updatedAtMs: Long?,
    val title: String?,
    val preview: String?,
    val storagePath: String?,
    val bodyHash: String?
) {
    val providerEnum: AgentProvider? get() = AgentProvider.fromKey(provider)

    val displayTitle: String
        get() = title?.takeIf { it.isNotBlank() }
            ?: projectName?.takeIf { it.isNotBlank() }
            ?: providerEnum?.displayName
            ?: "Encrypted session"

    val activityDateMs: Long get() = updatedAtMs ?: startTimeMs ?: 0L

    val hasDecryptedTitle: Boolean get() = !title.isNullOrBlank()
}

/**
 * Drives the Streams "Cockpit" — a faceted, paginated database view over the user's encrypted
 * session-log manifests. Filtering and sorting run server-side on plaintext facets via the
 * `queryConversations` callable; titles, previews, and full transcripts are opened locally with the
 * vault key so conversation content never leaves the device in the clear. Aggregates feed the KPI
 * header and saved queries persist locally.
 */
class ConversationCockpitStore(
    private val functions: FunctionsRepository = FunctionsRepository(),
    private val searchService: CloudConversationSearchService = CloudConversationSearchService()
) : ViewModel() {

    // ── Filters (mutating any of these bumps `signature`, which the UI keys its query to) ──
    private val _selectedProviders = MutableStateFlow<Set<String>>(emptySet())
    val selectedProviders = _selectedProviders.asStateFlow()

    private val _selectedModel = MutableStateFlow<String?>(null)
    val selectedModel = _selectedModel.asStateFlow()

    private val _projectQuery = MutableStateFlow("")
    val projectQuery = _projectQuery.asStateFlow()

    private val _dateFromMs = MutableStateFlow<Long?>(null)
    val dateFromMs = _dateFromMs.asStateFlow()

    private val _dateToMs = MutableStateFlow<Long?>(null)
    val dateToMs = _dateToMs.asStateFlow()

    private val _sortField = MutableStateFlow(ConversationSortField.UPDATED_AT)
    val sortField = _sortField.asStateFlow()

    private val _sortDirection = MutableStateFlow(ConversationSortDirection.DESC)
    val sortDirection = _sortDirection.asStateFlow()

    private val _signature = MutableStateFlow("")
    val signature = _signature.asStateFlow()

    // ── Results + status ──
    private val _rows = MutableStateFlow<List<CockpitConversationRow>>(emptyList())
    val rows = _rows.asStateFlow()

    private val _aggregates = MutableStateFlow<ConversationQueryAggregates?>(null)
    val aggregates = _aggregates.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading = _isLoading.asStateFlow()

    private val _isPaginating = MutableStateFlow(false)
    val isPaginating = _isPaginating.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error = _error.asStateFlow()

    private val _vaultLocked = MutableStateFlow(false)
    val vaultLocked = _vaultLocked.asStateFlow()

    private val _hasMore = MutableStateFlow(false)
    val hasMore = _hasMore.asStateFlow()

    private val _hasLoadedOnce = MutableStateFlow(false)
    val hasLoadedOnce = _hasLoadedOnce.asStateFlow()

    private val _savedQueries = MutableStateFlow<List<SavedConversationQuery>>(emptyList())
    val savedQueries = _savedQueries.asStateFlow()

    private val _discoveredProviders = MutableStateFlow<List<String>>(emptyList())
    val discoveredProviders = _discoveredProviders.asStateFlow()

    private val _discoveredModels = MutableStateFlow<List<String>>(emptyList())
    val discoveredModels = _discoveredModels.asStateFlow()

    private var nextCursor: String? = null
    private var vaultKey: ByteArray? = null
    private var queryToken = 0

    private val prefs by lazy {
        BurnBarApplication.appContext.getSharedPreferences(PREFS, android.content.Context.MODE_PRIVATE)
    }

    init {
        _signature.value = computeSignature()
        loadSavedQueries()
    }

    val hasActiveFilters: Boolean
        get() = _selectedProviders.value.isNotEmpty() ||
            _selectedModel.value != null ||
            _projectQuery.value.isNotEmpty() ||
            _dateFromMs.value != null ||
            _dateToMs.value != null

    // ── Query ──

    fun runQuery(reset: Boolean) {
        if (reset) {
            queryToken += 1
            nextCursor = null
            _isLoading.value = true
            _error.value = null
        } else {
            if (!_hasMore.value || _isPaginating.value || _isLoading.value || nextCursor == null) return
            _isPaginating.value = true
        }
        val token = queryToken
        viewModelScope.launch {
            try {
                if (!searchService.prepareCallableAuth()) {
                    if (reset) {
                        _rows.value = emptyList()
                        _aggregates.value = null
                    }
                    _vaultLocked.value = false
                    _hasMore.value = false
                    _error.value = "Sign in to load cloud conversations."
                    return@launch
                }

                if (vaultKey == null) {
                    vaultKey = runCatching { searchService.unlockVaultKeyOrNull() }.getOrNull()
                }
                if (token != queryToken) return@launch
                _vaultLocked.value = vaultKey == null

                val response = queryConversationsPage(reset)
                if (token != queryToken) return@launch

                applyResponse(response, reset)
            } catch (_: CancellationException) {
                // Cooperative cancellation — leave state as-is for the next query.
            } catch (e: Exception) {
                if (token != queryToken) return@launch
                if (isUnauthenticated(e) && searchService.prepareCallableAuth(forceRefresh = true)) {
                    try {
                        val response = queryConversationsPage(reset)
                        if (token != queryToken) return@launch
                        applyResponse(response, reset)
                        return@launch
                    } catch (_: CancellationException) {
                        return@launch
                    } catch (retryError: Exception) {
                        if (token != queryToken) return@launch
                        handleQueryFailure(retryError, reset)
                        return@launch
                    }
                }
                handleQueryFailure(e, reset)
            } finally {
                if (token == queryToken) {
                    if (reset) {
                        _isLoading.value = false
                        _hasLoadedOnce.value = true
                    } else {
                        _isPaginating.value = false
                    }
                }
            }
        }
    }

    private suspend fun queryConversationsPage(reset: Boolean) =
        functions.queryConversations(
            providers = _selectedProviders.value.toList(),
            models = _selectedModel.value?.let { listOf(it) } ?: emptyList(),
            projectName = _projectQuery.value.ifBlank { null },
            dateFromIso = _dateFromMs.value?.isoString(),
            dateToIso = _dateToMs.value?.isoString(),
            sort = _sortField.value.field,
            direction = _sortDirection.value.token,
            limit = PAGE_SIZE,
            cursorDocId = if (reset) null else nextCursor,
            includeAggregates = reset
        )

    private fun applyResponse(response: ConversationQueryResponse, reset: Boolean) {
        val mapped = response.rows.map(::decodeRow)
        _rows.value = if (reset) mapped else _rows.value + mapped
        response.aggregates?.let { _aggregates.value = it }
        nextCursor = response.nextCursor
        _hasMore.value = response.nextCursor != null
        _error.value = null
        refreshFacetOptions()
    }

    private fun handleQueryFailure(error: Exception, reset: Boolean) {
        if (reset) {
            _rows.value = emptyList()
            _aggregates.value = null
        }
        _hasMore.value = false
        _error.value = presentableQueryError(error)
    }

    fun loadNextPage() = runQuery(reset = false)

    suspend fun loadTranscript(row: CockpitConversationRow): String {
        val storagePath = row.storagePath?.takeIf { it.isNotBlank() }
            ?: throw IllegalStateException("This conversation has no encrypted body on file.")
        val bodyHash = row.bodyHash?.takeIf { it.isNotBlank() }
            ?: throw IllegalStateException("This conversation has no encrypted body on file.")
        return searchService.loadBodyAt(storagePath, bodyHash)
    }

    // ── Filter mutation ──

    fun toggleProvider(provider: String) {
        _selectedProviders.value = _selectedProviders.value.toMutableSet().apply {
            if (!add(provider)) remove(provider)
        }
        bumpSignature()
    }

    fun setModel(model: String?) {
        _selectedModel.value = model
        bumpSignature()
    }

    fun setProjectQuery(query: String) {
        _projectQuery.value = query
        bumpSignature()
    }

    fun setDateRange(fromMs: Long?, toMs: Long?) {
        _dateFromMs.value = fromMs
        _dateToMs.value = toMs
        bumpSignature()
    }

    fun setSort(field: ConversationSortField, direction: ConversationSortDirection) {
        _sortField.value = field
        _sortDirection.value = direction
        bumpSignature()
    }

    fun clearFilters() {
        _selectedProviders.value = emptySet()
        _selectedModel.value = null
        _projectQuery.value = ""
        _dateFromMs.value = null
        _dateToMs.value = null
        _sortField.value = ConversationSortField.UPDATED_AT
        _sortDirection.value = ConversationSortDirection.DESC
        bumpSignature()
    }

    // ── Saved queries ──

    fun saveCurrentQuery(name: String) {
        val trimmed = name.trim()
        if (trimmed.isEmpty()) return
        val query = SavedConversationQuery(
            id = java.util.UUID.randomUUID().toString(),
            name = trimmed,
            providers = _selectedProviders.value.sorted(),
            model = _selectedModel.value,
            projectQuery = _projectQuery.value,
            sortField = _sortField.value.field,
            sortDirection = _sortDirection.value.token,
            dateFromMs = _dateFromMs.value,
            dateToMs = _dateToMs.value
        )
        _savedQueries.value = listOf(query) +
            _savedQueries.value.filterNot { it.name.equals(trimmed, ignoreCase = true) }
        persistSavedQueries()
    }

    fun applySavedQuery(query: SavedConversationQuery) {
        _selectedProviders.value = query.providers.toSet()
        _selectedModel.value = query.model
        _projectQuery.value = query.projectQuery
        _sortField.value = ConversationSortField.fromField(query.sortField)
        _sortDirection.value = ConversationSortDirection.fromToken(query.sortDirection)
        _dateFromMs.value = query.dateFromMs
        _dateToMs.value = query.dateToMs
        bumpSignature()
    }

    fun deleteSavedQuery(query: SavedConversationQuery) {
        _savedQueries.value = _savedQueries.value.filterNot { it.id == query.id }
        persistSavedQueries()
    }

    // ── Private ──

    private fun decodeRow(row: ConversationFacetRow): CockpitConversationRow {
        var title: String? = null
        var preview: String? = null
        val key = vaultKey
        if (key != null) {
            row.sealedTitle?.let { sealed -> title = runCatching { CloudVaultCrypto.openText(sealed, key) }.getOrNull() }
            row.sealedBodyPreview?.let { sealed -> preview = runCatching { CloudVaultCrypto.openText(sealed, key) }.getOrNull() }
        }
        return CockpitConversationRow(
            id = row.id,
            provider = row.provider,
            projectName = row.projectName,
            model = row.model,
            sourceType = row.sourceType,
            messageCount = row.messageCount ?: 0,
            inputTokens = row.inputTokens ?: 0,
            outputTokens = row.outputTokens ?: 0,
            totalTokens = row.totalTokens ?: 0,
            costUSD = row.costUSD ?: 0.0,
            workingDirectory = row.workingDirectory,
            toolTags = row.toolTags,
            durationSeconds = row.durationSeconds,
            startTimeMs = row.startTimeMs,
            updatedAtMs = row.updatedAtMs,
            title = title,
            preview = preview,
            storagePath = row.storagePath,
            bodyHash = row.bodyHash
        )
    }

    private fun refreshFacetOptions() {
        val providers = _discoveredProviders.value.toMutableSet()
        val models = _discoveredModels.value.toMutableSet()
        for (row in _rows.value) {
            row.provider?.takeIf { it.isNotBlank() }?.let { providers.add(it) }
            row.model?.takeIf { it.isNotBlank() }?.let { models.add(it) }
        }
        _discoveredProviders.value = providers.sorted()
        _discoveredModels.value = models.sorted()
    }

    private fun computeSignature(): String {
        val providers = _selectedProviders.value.sorted().joinToString(",")
        val from = _dateFromMs.value?.toString() ?: "-"
        val to = _dateToMs.value?.toString() ?: "-"
        return "$providers|${_selectedModel.value ?: "-"}|${_projectQuery.value}|" +
            "${_sortField.value.field}|${_sortDirection.value.token}|$from|$to"
    }

    private fun bumpSignature() {
        _signature.value = computeSignature()
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

    private fun loadSavedQueries() {
        val json = prefs.getString(SAVED_QUERIES_KEY, null) ?: return
        val parsed = runCatching {
            val array = JSONArray(json)
            (0 until array.length()).mapNotNull { index ->
                val obj = array.optJSONObject(index) ?: return@mapNotNull null
                SavedConversationQuery(
                    id = obj.optString("id"),
                    name = obj.optString("name"),
                    providers = obj.optJSONArray("providers")?.let { arr ->
                        (0 until arr.length()).mapNotNull { arr.optString(it).takeIf { s -> s.isNotBlank() } }
                    } ?: emptyList(),
                    model = obj.optString("model").takeIf { it.isNotBlank() },
                    projectQuery = obj.optString("projectQuery"),
                    sortField = obj.optString("sortField", "updatedAt"),
                    sortDirection = obj.optString("sortDirection", "desc"),
                    dateFromMs = if (obj.has("dateFromMs") && !obj.isNull("dateFromMs")) obj.optLong("dateFromMs") else null,
                    dateToMs = if (obj.has("dateToMs") && !obj.isNull("dateToMs")) obj.optLong("dateToMs") else null
                )
            }
        }.getOrNull() ?: return
        _savedQueries.value = parsed
    }

    private fun persistSavedQueries() {
        val array = JSONArray()
        for (query in _savedQueries.value) {
            val obj = JSONObject()
            obj.put("id", query.id)
            obj.put("name", query.name)
            obj.put("providers", JSONArray(query.providers))
            obj.put("model", query.model ?: JSONObject.NULL)
            obj.put("projectQuery", query.projectQuery)
            obj.put("sortField", query.sortField)
            obj.put("sortDirection", query.sortDirection)
            obj.put("dateFromMs", query.dateFromMs ?: JSONObject.NULL)
            obj.put("dateToMs", query.dateToMs ?: JSONObject.NULL)
            array.put(obj)
        }
        prefs.edit().putString(SAVED_QUERIES_KEY, array.toString()).apply()
    }

    private fun Long.isoString(): String = java.time.Instant.ofEpochMilli(this).toString()

    companion object {
        private const val PAGE_SIZE = 30
        private const val PREFS = "openburnbar_cockpit"
        private const val SAVED_QUERIES_KEY = "savedQueries.v1"
    }
}
