package com.openburnbar.data.stores

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.openburnbar.BurnBarApplication
import com.openburnbar.data.cloud.CloudConversationSearchService
import com.openburnbar.data.firebase.ConversationQueryAggregates
import com.openburnbar.data.firebase.FunctionsRepository
import com.openburnbar.data.models.AgentProvider
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** Sort axes the cockpit can order by; each maps 1:1 to a plaintext facet the server can index. */
enum class ConversationSortField(val field: String, val label: String) {
    UPDATED_AT("updatedAt", "Recently updated"),
    START_TIME("startTime", "Start time"),
    END_TIME("endTime", "End time"),
    COST("costUSD", "Cost"),
    TOKENS("totalTokens", "Tokens"),
    ;

    companion object {
        fun fromField(value: String?): ConversationSortField = entries.firstOrNull { it.field == value } ?: UPDATED_AT
    }
}

enum class ConversationSortDirection(val token: String, val label: String) {
    DESC("desc", "Highest first"),
    ASC("asc", "Lowest first"),
    ;

    companion object {
        fun fromToken(value: String?): ConversationSortDirection = entries.firstOrNull { it.token == value } ?: DESC
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
    val dateToMs: Long?,
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
    val bodyHash: String?,
) {
    val providerEnum: AgentProvider? get() = AgentProvider.fromKey(provider)

    val displayTitle: String
        get() =
            title?.takeIf { it.isNotBlank() }
                ?: providerEnum?.displayName
                ?: "Encrypted session"

    val activityDateMs: Long get() = updatedAtMs ?: startTimeMs ?: 0L

    val hasDecryptedTitle: Boolean get() = !title.isNullOrBlank()
}

/**
 * Drives the Streams "Cockpit" — a faceted, paginated database view over the user's encrypted
 * session-log manifests. Filtering and sorting run server-side only on operational facets via the
 * `queryConversations` callable; text/project/path search uses keyed encrypted search hashes and
 * local decryption. Aggregates feed the KPI header and saved queries persist locally.
 */
class ConversationCockpitStore(
    private val functions: FunctionsRepository = FunctionsRepository(),
    private val searchService: CloudConversationSearchService = CloudConversationSearchService(),
) : ViewModel() {
    internal val filters = ConversationCockpitFilterActions(this)
    internal val queries = ConversationCockpitQueryActions(this)
    internal val bindings = Bindings()

    // ── Filters (mutating any of these bumps `signature`, which the UI keys its query to) ──
    internal val mutableSelectedProviders = MutableStateFlow<Set<String>>(emptySet())
    val selectedProviders = mutableSelectedProviders.asStateFlow()

    internal val mutableSelectedModel = MutableStateFlow<String?>(null)
    val selectedModel = mutableSelectedModel.asStateFlow()

    internal val mutableProjectQuery = MutableStateFlow("")
    val projectQuery = mutableProjectQuery.asStateFlow()

    internal val mutableDateFromMs = MutableStateFlow<Long?>(null)
    val dateFromMs = mutableDateFromMs.asStateFlow()

    internal val mutableDateToMs = MutableStateFlow<Long?>(null)
    val dateToMs = mutableDateToMs.asStateFlow()

    internal val mutableSortField = MutableStateFlow(ConversationSortField.UPDATED_AT)
    val sortField = mutableSortField.asStateFlow()

    internal val mutableSortDirection = MutableStateFlow(ConversationSortDirection.DESC)
    val sortDirection = mutableSortDirection.asStateFlow()

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

    internal val mutableSavedQueries = MutableStateFlow<List<SavedConversationQuery>>(emptyList())
    val savedQueries = mutableSavedQueries.asStateFlow()

    private val _discoveredProviders = MutableStateFlow<List<String>>(emptyList())
    val discoveredProviders = _discoveredProviders.asStateFlow()

    private val _discoveredModels = MutableStateFlow<List<String>>(emptyList())
    val discoveredModels = _discoveredModels.asStateFlow()

    internal var nextCursor: String? = null
    internal var vaultKey: ByteArray? = null
    internal var queryToken = 0

    private val queryRunner = ConversationCockpitQueryRunner(functions, searchService)

    private val prefs by lazy {
        BurnBarApplication.appContext.getSharedPreferences(PREFS, android.content.Context.MODE_PRIVATE)
    }

    init {
        bindings.bumpSignature()
        bindings.loadSavedQueries()
    }

    val hasActiveFilters: Boolean
        get() =
            mutableSelectedProviders.value.isNotEmpty() ||
                mutableSelectedModel.value != null ||
                mutableDateFromMs.value != null ||
                mutableDateToMs.value != null

    internal fun runQueryInternal(reset: Boolean) {
        if (reset) {
            queryToken += 1
            nextCursor = null
            _isLoading.value = true
            _error.value = null
        } else {
            val cannotPaginate =
                !_hasMore.value || _isPaginating.value || _isLoading.value || nextCursor == null
            if (cannotPaginate) return
            _isPaginating.value = true
        }
        val token = queryToken
        viewModelScope.launch {
            try {
                queryRunner.executeQuery(this@ConversationCockpitStore, reset, token)
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

    internal suspend fun loadTranscriptInternal(row: CockpitConversationRow): String = queryRunner.loadTranscript(row)

    internal inner class Bindings {
        fun setRows(value: List<CockpitConversationRow>) {
            _rows.value = value
        }

        fun setAggregates(value: ConversationQueryAggregates?) {
            _aggregates.value = value
        }

        fun setHasMore(value: Boolean) {
            _hasMore.value = value
        }

        fun setError(value: String?) {
            _error.value = value
        }

        fun setVaultLocked(value: Boolean) {
            _vaultLocked.value = value
        }

        fun setDiscoveredProviders(value: List<String>) {
            _discoveredProviders.value = value
        }

        fun setDiscoveredModels(value: List<String>) {
            _discoveredModels.value = value
        }

        fun mutateSelectedProviders(block: (Set<String>) -> Set<String>) {
            mutableSelectedProviders.value = block(mutableSelectedProviders.value)
            bumpSignature()
        }

        fun setSelectedModel(model: String?) {
            mutableSelectedModel.value = model
        }

        fun setProjectQueryValue(query: String) {
            mutableProjectQuery.value = query
        }

        fun setDateRangeValues(fromMs: Long?, toMs: Long?) {
            mutableDateFromMs.value = fromMs
            mutableDateToMs.value = toMs
        }

        fun setSortValues(field: ConversationSortField, direction: ConversationSortDirection) {
            mutableSortField.value = field
            mutableSortDirection.value = direction
        }

        fun clearFilterValues() {
            mutableSelectedProviders.value = emptySet()
            mutableSelectedModel.value = null
            mutableProjectQuery.value = ""
            mutableDateFromMs.value = null
            mutableDateToMs.value = null
            mutableSortField.value = ConversationSortField.UPDATED_AT
            mutableSortDirection.value = ConversationSortDirection.DESC
        }

        fun replaceSavedQueries(queries: List<SavedConversationQuery>) {
            mutableSavedQueries.value = queries
        }

        fun applySavedQueryValues(query: SavedConversationQuery) {
            mutableSelectedProviders.value = query.providers.toSet()
            mutableSelectedModel.value = query.model
            mutableProjectQuery.value = ""
            mutableSortField.value = ConversationSortField.fromField(query.sortField)
            mutableSortDirection.value = ConversationSortDirection.fromToken(query.sortDirection)
            mutableDateFromMs.value = query.dateFromMs
            mutableDateToMs.value = query.dateToMs
        }

        fun bumpSignature() {
            _signature.value = computeSignature()
        }

        fun persistSavedQueries() {
            ConversationCockpitSavedQueryPersistence.persist(prefs, SAVED_QUERIES_KEY, mutableSavedQueries.value)
        }

        fun loadSavedQueries() {
            mutableSavedQueries.value = ConversationCockpitSavedQueryPersistence.load(prefs, SAVED_QUERIES_KEY)
        }
    }

    private fun computeSignature(): String {
        val providers = mutableSelectedProviders.value.sorted().joinToString(",")
        val from = mutableDateFromMs.value?.toString() ?: "-"
        val to = mutableDateToMs.value?.toString() ?: "-"
        return "$providers|${mutableSelectedModel.value ?: "-"}|" +
            "${mutableSortField.value.field}|${mutableSortDirection.value.token}|$from|$to"
    }

    companion object {
        private const val PREFS = "openburnbar_cockpit"
        private const val SAVED_QUERIES_KEY = "savedQueries.v1"
    }
}
