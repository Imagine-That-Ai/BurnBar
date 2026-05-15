package com.openburnbar.data.stores

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.openburnbar.data.cloud.CloudConversationSearchRow
import com.openburnbar.data.cloud.CloudConversationSearchService
import com.openburnbar.data.firebase.FirestoreRepository
import com.openburnbar.data.models.*
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.launch

class ActivityStore(
    private val repo: FirestoreRepository = FirestoreRepository(),
    private val cloudSearch: CloudConversationSearchService = CloudConversationSearchService()
) : ViewModel() {
    private val _usages = MutableStateFlow<List<TokenUsage>>(emptyList())
    val usages = _usages.asStateFlow()

    private val _liveUsages = MutableStateFlow<List<TokenUsage>>(emptyList())
    val liveUsages = _liveUsages.asStateFlow()

    private val _projects = MutableStateFlow<List<ProjectSummary>>(emptyList())
    val projects = _projects.asStateFlow()

    private val _cloudSearchHits = MutableStateFlow<List<CloudConversationSearchRow>>(emptyList())
    val cloudSearchHits = _cloudSearchHits.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading = _isLoading.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error = _error.asStateFlow()

    private val _hasMore = MutableStateFlow(false)
    val hasMore = _hasMore.asStateFlow()

    private val _selectedSegment = MutableStateFlow(StreamsSegment.SESSIONS)
    val selectedSegment = _selectedSegment.asStateFlow()

    private var lastDoc: com.google.firebase.firestore.DocumentSnapshot? = null
    private var listenJob: Job? = null
    private var liveListenJob: Job? = null
    private var searchJob: Job? = null
    private var lastSearchQuery: String = ""

    fun loadInitial(pageSize: Int = 25) {
        viewModelScope.launch {
            _isLoading.value = true
            try {
                val (page, last) = repo.fetchUsagePage(pageSize = pageSize)
                _usages.value = page
                if (_liveUsages.value.isEmpty()) {
                    _liveUsages.value = page
                }
                lastDoc = last
                _hasMore.value = last != null
            } catch (e: Exception) {
                _error.value = e.message
            } finally {
                _isLoading.value = false
            }
        }
    }

    fun loadNext() {
        if (!_hasMore.value || _isLoading.value) return
        viewModelScope.launch {
            _isLoading.value = true
            try {
                val (page, last) = repo.fetchUsagePage(after = lastDoc)
                _usages.value = _usages.value + page
                lastDoc = last
                _hasMore.value = last != null
            } catch (e: Exception) {
                _error.value = e.message
            } finally {
                _isLoading.value = false
            }
        }
    }

    fun refresh() {
        viewModelScope.launch {
            _isLoading.value = true
            try {
                val (page, last) = repo.fetchUsagePage()
                _usages.value = page
                lastDoc = last
                _hasMore.value = last != null
            } catch (e: Exception) {
                _error.value = e.message
            } finally {
                _isLoading.value = false
            }
        }
    }

    fun updateSearch(query: String) {
        val trimmed = query.trim()
        lastSearchQuery = trimmed
        searchJob?.cancel()
        if (trimmed.length < 2) {
            _cloudSearchHits.value = emptyList()
            return
        }
        searchJob = viewModelScope.launch {
            try {
                kotlinx.coroutines.delay(250)
                if (lastSearchQuery != trimmed) return@launch
                _cloudSearchHits.value = cloudSearch.search(trimmed)
            } catch (_: Exception) {
                _cloudSearchHits.value = emptyList()
            }
        }
    }

    fun setSegment(segment: StreamsSegment) {
        _selectedSegment.value = segment
        if (segment == StreamsSegment.PROJECTS) {
            viewModelScope.launch {
                try {
                    _projects.value = repo.fetchProjects()
                } catch (e: Exception) {
                    _error.value = e.message
                }
            }
        }
    }

    fun startListening() {
        listenJob?.cancel()
        listenJob = viewModelScope.launch {
            // `.catch` is critical: the underlying Firestore snapshot
            // listener flow propagates `PERMISSION_DENIED`,
            // `UNAVAILABLE`, App Check rejections, etc. as exceptions.
            // Without this guard the exception bubbles up the
            // viewModelScope on `Dispatchers.Main.immediate` and
            // crashes the entire activity. We surface the error into
            // `_error` so the UI can render a real degraded state
            // (banner / retry) instead of dying.
            repo.listenToUsagePage()
                .catch { e -> _error.value = e.message ?: e::class.simpleName }
                .collect { items -> _usages.value = items }
        }
    }

    fun startLiveUsageListening(startDate: Long) {
        liveListenJob?.cancel()
        liveListenJob = viewModelScope.launch {
            repo.listenToUsageSince(startDate)
                .catch { e -> _error.value = e.message ?: e::class.simpleName }
                .collect { items -> _liveUsages.value = items }
        }
    }

    fun stopListening() {
        listenJob?.cancel()
        listenJob = null
        liveListenJob?.cancel()
        liveListenJob = null
    }
}

enum class StreamsSegment(val label: String) {
    SESSIONS("Sessions"),
    MODELS("Models"),
    PROJECTS("Projects")
}
