package com.openburnbar.data.stores

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.openburnbar.data.firebase.FirestoreRepository
import com.openburnbar.data.models.ProviderQuotaSnapshot
import com.openburnbar.data.models.RollupSummary
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

data class ProviderDashboard(
    val providerSummaries: List<RollupSummary> = emptyList(),
    val quotaSnapshots: List<ProviderQuotaSnapshot> = emptyList(),
    val totalCost: Double = 0.0,
    val totalTokens: Long = 0
)

class ProviderDashboardStore(
    private val repo: FirestoreRepository = FirestoreRepository()
) : ViewModel() {
    private val _dashboard = MutableStateFlow(ProviderDashboard())
    val dashboard: StateFlow<ProviderDashboard> = _dashboard.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    fun load() {
        viewModelScope.launch {
            _isLoading.value = true
            _error.value = null
            try {
                val rollups = repo.fetchRollups()
                val quotas = repo.fetchQuotaSnapshots()
                _dashboard.value = ProviderDashboard(
                    providerSummaries = rollups.providerSummaries,
                    quotaSnapshots = quotas,
                    totalCost = rollups.allTime,
                    totalTokens = rollups.totals["tokens"]?.toLong() ?: 0L
                )
            } catch (e: Exception) {
                _error.value = e.message
            } finally {
                _isLoading.value = false
            }
        }
    }

    fun refresh() {
        load()
    }
}
