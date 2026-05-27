package com.openburnbar.ui.providers

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
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

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AddProviderConnectionView(
    provider: AgentProvider?,
    onDismiss: () -> Unit,
    accountStore: AccountStore = viewModel()
) {
    var label by remember { mutableStateOf("") }
    var apiKey by remember { mutableStateOf("") }
    var isLoading by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var mimoRegion by remember { mutableStateOf(MimoEndpointRegion.SGP) }
    var mimoTier by remember { mutableStateOf(MimoTokenPlanTier.STANDARD) }
    var mimoBillingCycle by remember { mutableStateOf(MimoTokenPlanBillingCycle.MONTHLY) }

    val selectedProvider = provider ?: AgentProvider.FACTORY
    val trimmedKey = apiKey.trim().lowercase()
    val isMimoTokenPlan = selectedProvider == AgentProvider.MIMO &&
        trimmedKey.startsWith("tp-")
    val isMimoPayg = selectedProvider == AgentProvider.MIMO &&
        trimmedKey.startsWith("sk-")
    val mimoAuthMethod = if (selectedProvider == AgentProvider.MIMO) {
        MimoEndpointProfiles.resolveAuthMethodId(apiKey)
    } else {
        null
    }

    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(AuroraSpacing.lg.dp)
                .padding(bottom = AuroraSpacing.xxxl.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Text(
                    "Connect ${selectedProvider.displayName}",
                    fontSize = AuroraTypography.title.sp,
                    fontWeight = FontWeight.Bold
                )
                IconButton(onClick = onDismiss) {
                    Icon(Icons.Filled.Close, null)
                }
            }

            Spacer(modifier = Modifier.height(AuroraSpacing.lg.dp))

            AuroraGlassCard {
                Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp)) {
                    Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                        ProviderAvatar(providerKey = selectedProvider.key, size = 48)
                        Spacer(modifier = Modifier.width(AuroraSpacing.md.dp))
                        Text(
                            selectedProvider.displayName,
                            fontWeight = FontWeight.SemiBold,
                            fontSize = AuroraTypography.headline.sp
                        )
                    }

                    OutlinedTextField(
                        value = label,
                        onValueChange = { label = it },
                        label = { Text("Account label") },
                        modifier = Modifier.fillMaxWidth(),
                        singleLine = true
                    )

                    OutlinedTextField(
                        value = apiKey,
                        onValueChange = { apiKey = it },
                        label = { Text("API Key / Token") },
                        modifier = Modifier.fillMaxWidth(),
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(
                            keyboardType = KeyboardType.Password,
                            imeAction = ImeAction.Done
                        )
                    )

                    if (selectedProvider == AgentProvider.MIMO) {
                        Text(
                            "Token Plan keys start with tp- and require a cluster. PAYG keys start with sk-.",
                            fontSize = AuroraTypography.caption.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }

                    if (isMimoTokenPlan) {
                        Text(
                            "Token Plan cluster",
                            fontSize = AuroraTypography.caption.sp,
                            fontWeight = FontWeight.SemiBold
                        )
                        SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
                            MimoEndpointRegion.selectable.forEachIndexed { index, region ->
                                SegmentedButton(
                                    selected = mimoRegion == region,
                                    onClick = { mimoRegion = region },
                                    shape = SegmentedButtonDefaults.itemShape(
                                        index = index,
                                        count = MimoEndpointRegion.selectable.size
                                    )
                                ) {
                                    Text(region.displayName, fontSize = AuroraTypography.caption.sp)
                                }
                            }
                        }

                        Text(
                            "Subscription tier",
                            fontSize = AuroraTypography.caption.sp,
                            fontWeight = FontWeight.SemiBold
                        )
                        var tierExpanded by remember { mutableStateOf(false) }
                        ExposedDropdownMenuBox(
                            expanded = tierExpanded,
                            onExpandedChange = { tierExpanded = it }
                        ) {
                            OutlinedTextField(
                                value = mimoTier.displayName,
                                onValueChange = {},
                                readOnly = true,
                                modifier = Modifier
                                    .menuAnchor()
                                    .fillMaxWidth(),
                                trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = tierExpanded) }
                            )
                            ExposedDropdownMenu(
                                expanded = tierExpanded,
                                onDismissRequest = { tierExpanded = false }
                            ) {
                                MimoTokenPlanTier.all.forEach { tier ->
                                    DropdownMenuItem(
                                        text = { Text(tier.displayName) },
                                        onClick = {
                                            mimoTier = tier
                                            tierExpanded = false
                                        }
                                    )
                                }
                            }
                        }
                    }

                    if (isMimoPayg) {
                        Text(
                            "Pay-as-you-go keys route to api.xiaomimimo.com. Quota balance is unavailable on Android; routing validation only.",
                            fontSize = AuroraTypography.caption.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }

                    error?.let { message ->
                        Text(message, color = AuroraColors.error, fontSize = AuroraTypography.caption.sp)
                    }

                    val canConnect = label.isNotBlank() &&
                        apiKey.isNotBlank() &&
                        !isLoading &&
                        (selectedProvider != AgentProvider.MIMO || mimoAuthMethod != null)

                    Button(
                        onClick = {
                            isLoading = true
                            error = null
                            val endpointProfileId = when {
                                isMimoTokenPlan -> MimoEndpointProfiles.tokenPlanProfileId(mimoRegion)
                                isMimoPayg -> MimoEndpointProfiles.PAYG_PROFILE_ID
                                else -> null
                            }
                            val region = when {
                                isMimoTokenPlan -> mimoRegion.raw
                                isMimoPayg -> "global"
                                else -> null
                            }
                            accountStore.connectProviderAccount(
                                providerId = selectedProvider.key,
                                credential = apiKey,
                                label = label,
                                endpointProfileId = endpointProfileId,
                                region = region,
                                tokenPlanTier = if (isMimoTokenPlan) mimoTier.raw else null,
                                tokenPlanBillingCycle = if (isMimoTokenPlan) mimoBillingCycle.raw else null,
                                authMethodId = mimoAuthMethod,
                                onSuccess = {
                                    isLoading = false
                                    onDismiss()
                                },
                                onFailure = { message ->
                                    isLoading = false
                                    error = message
                                }
                            )
                        },
                        modifier = Modifier.fillMaxWidth(),
                        enabled = canConnect,
                        colors = ButtonDefaults.buttonColors(containerColor = AuroraColors.ember)
                    ) {
                        if (isLoading) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(20.dp),
                                color = MaterialTheme.colorScheme.onPrimary
                            )
                        } else {
                            Text("Connect")
                        }
                    }
                }
            }
        }
    }
}
