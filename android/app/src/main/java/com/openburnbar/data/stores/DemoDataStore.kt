package com.openburnbar.data.stores

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.openburnbar.data.firebase.FunctionsRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

class DemoDataStore(
    private val functions: FunctionsRepository = FunctionsRepository()
) : ViewModel() {
    private val _isSeeding = MutableStateFlow(false)
    val isSeeding = _isSeeding.asStateFlow()

    private val _message = MutableStateFlow<String?>(null)
    val message = _message.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error = _error.asStateFlow()

    fun seed(onSeeded: () -> Unit = {}) {
        if (_isSeeding.value) return
        viewModelScope.launch {
            _isSeeding.value = true
            _message.value = null
            _error.value = null
            try {
                val result = functions.seedAndroidDemoAccount()
                val usageCount = (result["usageCount"] as? Number)?.toInt() ?: 0
                _message.value = if (usageCount > 0) {
                    "Demo workspace loaded with $usageCount sessions."
                } else {
                    "Demo workspace loaded."
                }
                onSeeded()
            } catch (e: Exception) {
                _error.value = e.message ?: "Could not load demo data."
            } finally {
                _isSeeding.value = false
            }
        }
    }

    fun clearStatus() {
        _message.value = null
        _error.value = null
    }
}
