package com.openburnbar.data.stores

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.openburnbar.data.firebase.FirestoreRepository
import com.openburnbar.data.models.ProviderAccount
import com.openburnbar.data.models.ProviderQuotaSnapshot
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

class QuotaStore(
    private val repo: FirestoreRepository = FirestoreRepository()
) : ViewModel() {
    private val _snapshots = MutableStateFlow<List<ProviderQuotaSnapshot>>(emptyList())
    val snapshots = _snapshots.asStateFlow()

    private val _accounts = MutableStateFlow<List<ProviderAccount>>(emptyList())
    val accounts = _accounts.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading = _isLoading.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error = _error.asStateFlow()

    private var listenJob: Job? = null

    fun load() {
        viewModelScope.launch {
            _isLoading.value = true
            try {
                _snapshots.value = repo.fetchQuotaSnapshots()
                _accounts.value = repo.fetchProviderAccounts()
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
                _snapshots.value = repo.fetchQuotaSnapshots()
                _accounts.value = repo.fetchProviderAccounts()
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
            repo.listenToQuotaSnapshots().collect { snapshots ->
                _snapshots.value = snapshots
            }
        }
    }

    fun stopListening() {
        listenJob?.cancel()
        listenJob = null
    }
}
