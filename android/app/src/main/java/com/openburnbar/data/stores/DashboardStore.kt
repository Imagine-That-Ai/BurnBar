package com.openburnbar.data.stores

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.google.firebase.FirebaseException
import com.openburnbar.data.firebase.FirestoreRepository
import com.openburnbar.data.models.UsageRollups
import java.time.Duration
import java.time.Instant
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.launch

private const val SECONDS = 60

class DashboardStore(
    private val repo: FirestoreRepository = FirestoreRepository(),
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
            } catch (e: FirebaseException) {
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
            } catch (e: FirebaseException) {
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
                repo.rebuildUsageRollups(force = true)
                _rollups.value = repo.fetchRollups()
                _error.value = null
            } catch (e: FirebaseException) {
                _error.value = e.message
            } finally {
                _isLoading.value = false
            }
        }
    }

    fun startListening() {
        listenJob?.cancel()
        listenJob =
            viewModelScope.launch {
                // See ActivityStore.startListening for the rationale —
                // Firestore listener errors must NEVER reach
                // Dispatchers.Main.immediate as unhandled exceptions, or
                // the host activity crashes on PERMISSION_DENIED.
                repo.listenToRollups()
                    .catch { e -> _error.value = e.message ?: e::class.simpleName }
                    .collect { rollups -> _rollups.value = rollups }
            }
    }

    fun stopListening() {
        listenJob?.cancel()
        listenJob = null
    }

    private suspend fun maybeRebuild(): Boolean {
        val now = Instant.now()
        if (Duration.between(lastRebuildAttempt, now).seconds < SECONDS) return false
        lastRebuildAttempt = now
        return try {
            repo.rebuildUsageRollups()
            true
        } catch (_: Exception) {
            false
        }
    }

    /**
     * Rollups are stale only when a raw usage event is newer than
     * `computedAt` — i.e. they are genuinely missing usage (worker stalled or
     * not yet run). One limit-1 query; a failed read counts as fresh.
     * Wall-clock age alone is NOT staleness: an idle user's rollups stay
     * legitimately old, and treating them as stale fired a full server-side
     * rollup rebuild on every app open.
     */
    private suspend fun isRollupStale(rollups: UsageRollups): Boolean {
        val computedAt = rollups.computedAt ?: return false
        return try {
            val computedInstant = Instant.parse(computedAt)
            val newestUsage = repo.fetchNewestUsageEndTime() ?: return false
            newestUsage.isAfter(computedInstant)
        } catch (_: Exception) {
            false
        }
    }
}
