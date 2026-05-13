package com.openburnbar.data.stores

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.openburnbar.data.firebase.FirestoreRepository
import com.openburnbar.data.models.UsageRollups
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.time.Duration
import java.time.Instant

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
    private var lastRebuildAttempt: Instant = Instant.EPOCH

    fun load() {
        viewModelScope.launch {
            _isLoading.value = true
            try {
                _rollups.value = fetchFreshRollups()
                _error.value = null
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
                _rollups.value = fetchFreshRollups()
                _error.value = null
            } catch (e: Exception) {
                _error.value = e.message
            } finally {
                _isLoading.value = false
            }
        }
    }

    private suspend fun fetchFreshRollups(): UsageRollups {
        val rollups = repo.fetchRollups()
        if (!rollups.isEmpty() && !isRollupStale(rollups)) {
            return rollups
        }
        return if (maybeRebuild()) repo.fetchRollups() else rollups
    }

    /** Force a full server-side rollup rebuild from raw usage events. */
    fun forceRebuild() {
        viewModelScope.launch {
            _isLoading.value = true
            try {
                repo.rebuildUsageRollups()
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

    private suspend fun maybeRebuild(): Boolean {
        val now = Instant.now()
        if (Duration.between(lastRebuildAttempt, now).seconds < 60) return false
        lastRebuildAttempt = now
        return try {
            repo.rebuildUsageRollups()
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun isRollupStale(rollups: UsageRollups): Boolean {
        val computedAt = rollups.computedAt ?: return false
        return try {
            val computedInstant = Instant.parse(computedAt)
            Duration.between(computedInstant, Instant.now()).toMinutes() > 15
        } catch (_: Exception) {
            false
        }
    }
}
