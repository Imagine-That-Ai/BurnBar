package com.openburnbar.data.stores

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.openburnbar.data.firebase.FirestoreRepository
import com.openburnbar.data.models.UsageRollups
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

class DashboardStore(
    private val repo: FirestoreRepository = FirestoreRepository()
) : ViewModel() {
    private val _rollups = MutableStateFlow<UsageRollups?>(null)
    val rollups = _rollups.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading = _isLoading.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error = _error.asStateFlow()

    private var listenJob: Job? = null

    fun load() {
        viewModelScope.launch {
            _isLoading.value = true
            try {
                _rollups.value = repo.fetchRollups()
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
                _rollups.value = repo.fetchRollups()
                _error.value = null
            } catch (e: Exception) {
                _error.value = e.message
            } finally {
                _isLoading.value = false
            }
        }
    }

    fun startListening() {
        listenJob?.cancel()
        listenJob = viewModelScope.launch {
            repo.listenToRollups().collect { rollups ->
                _rollups.value = rollups
            }
        }
    }

    fun stopListening() {
        listenJob?.cancel()
        listenJob = null
    }
}
