package com.openburnbar.data.stores

import android.content.Context
import androidx.lifecycle.ViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

data class SelfHostedConfig(
    val endpointUrl: String = "",
    val apiKey: String = "",
    val isEnabled: Boolean = false
)

class SelfHostedQuotaRunnerStore(context: Context) : ViewModel() {
    private val prefs = context.applicationContext.getSharedPreferences("selfHostedRunner", Context.MODE_PRIVATE)

    private val _config = MutableStateFlow(
        SelfHostedConfig(
            endpointUrl = prefs.getString("endpointUrl", "") ?: "",
            apiKey = prefs.getString("apiKey", "") ?: "",
            isEnabled = prefs.getBoolean("isEnabled", false)
        )
    )
    val config: StateFlow<SelfHostedConfig> = _config.asStateFlow()

    fun updateEndpoint(url: String) {
        _config.value = _config.value.copy(endpointUrl = url)
        prefs.edit().putString("endpointUrl", url).apply()
    }

    fun updateApiKey(key: String) {
        _config.value = _config.value.copy(apiKey = key)
        prefs.edit().putString("apiKey", key).apply()
    }

    fun setEnabled(enabled: Boolean) {
        _config.value = _config.value.copy(isEnabled = enabled)
        prefs.edit().putBoolean("isEnabled", enabled).apply()
    }
}
