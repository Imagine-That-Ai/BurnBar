package com.openburnbar.data.stores

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.openburnbar.data.firebase.FirestoreRepository
import com.openburnbar.data.models.*
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

class ActivityStore(
    private val repo: FirestoreRepository = FirestoreRepository()
) : ViewModel() {
    private val _usages = MutableStateFlow<List<TokenUsage>>(emptyList())
    val usages = _usages.asStateFlow()

    private val _projects = MutableStateFlow<List<ProjectSummary>>(emptyList())
    val projects = _projects.asStateFlow()

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

    fun loadInitial() {
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
            repo.listenToUsagePage().collect { items ->
                _usages.value = items
            }
        }
    }

    fun stopListening() {
        listenJob?.cancel()
        listenJob = null
    }
}

enum class StreamsSegment(val label: String) {
    SESSIONS("Sessions"),
    MODELS("Models"),
    PROJECTS("Projects")
}
