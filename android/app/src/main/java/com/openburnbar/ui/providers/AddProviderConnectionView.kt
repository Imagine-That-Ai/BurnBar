package com.openburnbar.ui.providers

import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.lifecycle.viewmodel.compose.viewModel
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.models.MimoEndpointRegion
import com.openburnbar.data.models.MimoTokenPlanBillingCycle
import com.openburnbar.data.models.MimoTokenPlanTier
import com.openburnbar.data.stores.AccountStore

@Composable
fun AddProviderConnectionView(provider: AgentProvider?, onDismiss: () -> Unit, accountStore: AccountStore = viewModel()) {
    var label by remember { mutableStateOf("") }
    var apiKey by remember { mutableStateOf("") }
    var isLoading by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var mimoRegion by remember { mutableStateOf(MimoEndpointRegion.SGP) }
    var mimoTier by remember { mutableStateOf(MimoTokenPlanTier.STANDARD) }
    var mimoBillingCycle by remember { mutableStateOf(MimoTokenPlanBillingCycle.MONTHLY) }

    val selectedProvider = provider ?: AgentProvider.FACTORY
    val formState =
        AddProviderConnectionState(
            label = label,
            apiKey = apiKey,
            isLoading = isLoading,
            error = error,
            mimoRegion = mimoRegion,
            mimoTier = mimoTier,
            mimoBillingCycle = mimoBillingCycle,
        )

    AddProviderConnectionSheet(
        selectedProvider = selectedProvider,
        state = formState,
        callbacks =
        AddProviderConnectionCallbacks(
            onLabelChange = { label = it },
            onApiKeyChange = { apiKey = it },
            onMimoRegionChange = { mimoRegion = it },
            onMimoTierChange = { mimoTier = it },
            onConnect = {
                isLoading = true
                error = null
                val submittingState = formState.copy(isLoading = true)
                accountStore.connectFromAddProviderForm(
                    selectedProvider = selectedProvider,
                    state = submittingState,
                    payload = buildAddProviderConnectPayload(selectedProvider, submittingState),
                    onSuccess = {
                        isLoading = false
                        onDismiss()
                    },
                    onFailure = { message ->
                        isLoading = false
                        error = message
                    },
                )
            },
        ),
        onDismiss = onDismiss,
    )
}
