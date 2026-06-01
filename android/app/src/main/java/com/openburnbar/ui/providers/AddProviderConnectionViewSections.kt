@file:Suppress("MagicNumber", "LongParameterList")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.providers

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.models.MimoEndpointProfiles
import com.openburnbar.data.models.MimoEndpointRegion
import com.openburnbar.data.models.MimoTokenPlanBillingCycle
import com.openburnbar.data.models.MimoTokenPlanTier
import com.openburnbar.data.stores.AccountStore
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.components.ProviderAvatar
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraTypography

internal data class AddProviderConnectionState(
    val label: String,
    val apiKey: String,
    val isLoading: Boolean,
    val error: String?,
    val mimoRegion: MimoEndpointRegion,
    val mimoTier: MimoTokenPlanTier,
    val mimoBillingCycle: MimoTokenPlanBillingCycle,
)

internal data class AddProviderConnectionCallbacks(
    val onLabelChange: (String) -> Unit,
    val onApiKeyChange: (String) -> Unit,
    val onMimoRegionChange: (MimoEndpointRegion) -> Unit,
    val onMimoTierChange: (MimoTokenPlanTier) -> Unit,
    val onConnect: () -> Unit,
)

internal data class AddProviderConnectPayload(
    val endpointProfileId: String?,
    val region: String?,
    val tokenPlanTier: String?,
    val tokenPlanBillingCycle: String?,
    val authMethodId: String?,
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun AddProviderConnectionSheet(
    selectedProvider: AgentProvider,
    state: AddProviderConnectionState,
    callbacks: AddProviderConnectionCallbacks,
    onDismiss: () -> Unit,
) {
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            modifier =
            Modifier
                .fillMaxWidth()
                .padding(AuroraSpacing.lg.dp)
                .padding(bottom = AuroraSpacing.xxxl.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text(
                    "Connect ${selectedProvider.displayName}",
                    fontSize = AuroraTypography.title.sp,
                    fontWeight = FontWeight.Bold,
                )
                IconButton(onClick = onDismiss) {
                    Icon(Icons.Filled.Close, null)
                }
            }
            Spacer(modifier = Modifier.height(AuroraSpacing.lg.dp))
            AddProviderConnectionForm(
                selectedProvider = selectedProvider,
                state = state,
                callbacks = callbacks,
            )
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun AddProviderConnectionForm(
    selectedProvider: AgentProvider,
    state: AddProviderConnectionState,
    callbacks: AddProviderConnectionCallbacks,
) {
    val trimmedKey = state.apiKey.trim().lowercase()
    val isMimoTokenPlan = selectedProvider == AgentProvider.MIMO && trimmedKey.startsWith("tp-")
    val isMimoPayg = selectedProvider == AgentProvider.MIMO && trimmedKey.startsWith("sk-")
    val mimoAuthMethod =
        if (selectedProvider == AgentProvider.MIMO) {
            MimoEndpointProfiles.resolveAuthMethodId(state.apiKey)
        } else {
            null
        }
    val canConnect =
        state.label.isNotBlank() &&
            state.apiKey.isNotBlank() &&
            !state.isLoading &&
            (selectedProvider != AgentProvider.MIMO || mimoAuthMethod != null)

    AuroraGlassCard {
        Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp)) {
            AddProviderHeader(selectedProvider = selectedProvider)
            AddProviderCredentialFields(
                label = state.label,
                apiKey = state.apiKey,
                onLabelChange = callbacks.onLabelChange,
                onApiKeyChange = callbacks.onApiKeyChange,
            )
            if (selectedProvider == AgentProvider.MIMO) {
                AddProviderMimoHints(isMimoPayg = isMimoPayg)
            }
            if (isMimoTokenPlan) {
                AddProviderMimoTokenPlanFields(
                    mimoRegion = state.mimoRegion,
                    mimoTier = state.mimoTier,
                    onMimoRegionChange = callbacks.onMimoRegionChange,
                    onMimoTierChange = callbacks.onMimoTierChange,
                )
            }
            state.error?.let { message ->
                Text(message, color = AuroraColors.error, fontSize = AuroraTypography.caption.sp)
            }
            AddProviderConnectButton(
                isLoading = state.isLoading,
                enabled = canConnect,
                onClick = callbacks.onConnect,
            )
        }
    }
}

@Composable
private fun AddProviderHeader(selectedProvider: AgentProvider) {
    Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
        ProviderAvatar(providerKey = selectedProvider.key, size = 48)
        Spacer(modifier = Modifier.width(AuroraSpacing.md.dp))
        Text(
            selectedProvider.displayName,
            fontWeight = FontWeight.SemiBold,
            fontSize = AuroraTypography.headline.sp,
        )
    }
}

@Composable
private fun AddProviderCredentialFields(
    label: String,
    apiKey: String,
    onLabelChange: (String) -> Unit,
    onApiKeyChange: (String) -> Unit,
) {
    OutlinedTextField(
        value = label,
        onValueChange = onLabelChange,
        label = { Text("Account label") },
        modifier = Modifier.fillMaxWidth(),
        singleLine = true,
    )
    OutlinedTextField(
        value = apiKey,
        onValueChange = onApiKeyChange,
        label = { Text("API Key / Token") },
        modifier = Modifier.fillMaxWidth(),
        singleLine = true,
        keyboardOptions =
        KeyboardOptions(
            keyboardType = KeyboardType.Password,
            imeAction = ImeAction.Done,
        ),
    )
}

@Composable
private fun AddProviderMimoHints(isMimoPayg: Boolean) {
    Text(
        "Token Plan keys start with tp- and require a cluster. PAYG keys start with sk-.",
        fontSize = AuroraTypography.caption.sp,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
    if (isMimoPayg) {
        Text(
            "Pay-as-you-go keys route to api.xiaomimimo.com. Quota balance is unavailable on Android; routing validation only.",
            fontSize = AuroraTypography.caption.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AddProviderMimoTokenPlanFields(
    mimoRegion: MimoEndpointRegion,
    mimoTier: MimoTokenPlanTier,
    onMimoRegionChange: (MimoEndpointRegion) -> Unit,
    onMimoTierChange: (MimoTokenPlanTier) -> Unit,
) {
    Text(
        "Token Plan cluster",
        fontSize = AuroraTypography.caption.sp,
        fontWeight = FontWeight.SemiBold,
    )
    SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
        MimoEndpointRegion.selectable.forEachIndexed { index, region ->
            SegmentedButton(
                selected = mimoRegion == region,
                onClick = { onMimoRegionChange(region) },
                shape =
                SegmentedButtonDefaults.itemShape(
                    index = index,
                    count = MimoEndpointRegion.selectable.size,
                ),
            ) {
                Text(region.displayName, fontSize = AuroraTypography.caption.sp)
            }
        }
    }
    Text(
        "Subscription tier",
        fontSize = AuroraTypography.caption.sp,
        fontWeight = FontWeight.SemiBold,
    )
    var tierExpanded by remember { mutableStateOf(false) }
    ExposedDropdownMenuBox(
        expanded = tierExpanded,
        onExpandedChange = { tierExpanded = it },
    ) {
        OutlinedTextField(
            value = mimoTier.displayName,
            onValueChange = {},
            readOnly = true,
            modifier =
            Modifier
                .menuAnchor()
                .fillMaxWidth(),
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = tierExpanded) },
        )
        ExposedDropdownMenu(
            expanded = tierExpanded,
            onDismissRequest = { tierExpanded = false },
        ) {
            MimoTokenPlanTier.all.forEach { tier ->
                DropdownMenuItem(
                    text = { Text(tier.displayName) },
                    onClick = {
                        onMimoTierChange(tier)
                        tierExpanded = false
                    },
                )
            }
        }
    }
}

@Composable
private fun AddProviderConnectButton(isLoading: Boolean, enabled: Boolean, onClick: () -> Unit) {
    Button(
        onClick = onClick,
        modifier = Modifier.fillMaxWidth(),
        enabled = enabled,
        colors = ButtonDefaults.buttonColors(containerColor = AuroraColors.ember),
    ) {
        if (isLoading) {
            CircularProgressIndicator(
                modifier = Modifier.size(20.dp),
                color = MaterialTheme.colorScheme.onPrimary,
            )
        } else {
            Text("Connect")
        }
    }
}

internal fun buildAddProviderConnectPayload(
    selectedProvider: AgentProvider,
    state: AddProviderConnectionState,
): AddProviderConnectPayload {
    val trimmedKey = state.apiKey.trim().lowercase()
    val isMimoTokenPlan = selectedProvider == AgentProvider.MIMO && trimmedKey.startsWith("tp-")
    val isMimoPayg = selectedProvider == AgentProvider.MIMO && trimmedKey.startsWith("sk-")
    val mimoAuthMethod =
        if (selectedProvider == AgentProvider.MIMO) {
            MimoEndpointProfiles.resolveAuthMethodId(state.apiKey)
        } else {
            null
        }
    return AddProviderConnectPayload(
        endpointProfileId =
        when {
            isMimoTokenPlan -> MimoEndpointProfiles.tokenPlanProfileId(state.mimoRegion)
            isMimoPayg -> MimoEndpointProfiles.PAYG_PROFILE_ID
            else -> null
        },
        region =
        when {
            isMimoTokenPlan -> state.mimoRegion.raw
            isMimoPayg -> "global"
            else -> null
        },
        tokenPlanTier = if (isMimoTokenPlan) state.mimoTier.raw else null,
        tokenPlanBillingCycle = if (isMimoTokenPlan) state.mimoBillingCycle.raw else null,
        authMethodId = mimoAuthMethod,
    )
}

internal fun AccountStore.connectFromAddProviderForm(
    selectedProvider: AgentProvider,
    state: AddProviderConnectionState,
    payload: AddProviderConnectPayload,
    onSuccess: () -> Unit,
    onFailure: (String) -> Unit,
) {
    connectProviderAccount(
        providerId = selectedProvider.key,
        credential = state.apiKey,
        label = state.label,
        endpointProfileId = payload.endpointProfileId,
        region = payload.region,
        tokenPlanTier = payload.tokenPlanTier,
        tokenPlanBillingCycle = payload.tokenPlanBillingCycle,
        authMethodId = payload.authMethodId,
        onSuccess = onSuccess,
        onFailure = onFailure,
    )
}
