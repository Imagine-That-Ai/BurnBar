package com.openburnbar.data.stores

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.google.firebase.FirebaseException
import com.openburnbar.data.firebase.FirestoreRepository
import com.openburnbar.data.models.RollupSummary
import com.openburnbar.data.policy.MobileProviderAccountPolicy
import com.openburnbar.data.policy.MobileProviderErrorClass
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

class ProviderSummaryStore(
    private val repo: FirestoreRepository = FirestoreRepository(),
) : ViewModel() {
    private val _summaries = MutableStateFlow<List<RollupSummary>>(emptyList())
    val summaries: StateFlow<List<RollupSummary>> = _summaries.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    private val _errorClass = MutableStateFlow<MobileProviderErrorClass?>(null)
    val errorClass: StateFlow<MobileProviderErrorClass?> = _errorClass.asStateFlow()

    fun load() {
        viewModelScope.launch {
            _isLoading.value = true
            _error.value = null
            _errorClass.value = null
            try {
                val rollups = repo.fetchRollups()
                _summaries.value = rollups.providerSummaries
            } catch (e: FirebaseException) {
                val classified = MobileProviderAccountPolicy.classifyError(
                    code = e.javaClass.simpleName,
                    message = e.message,
                )
                _errorClass.value = classified
                _error.value = classified.userVisibleLabel
            } finally {
                _isLoading.value = false
            }
        }
    }

    fun refresh() {
        load()
    }
}
