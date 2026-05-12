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
import androidx.compose.ui.unit.sp
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.openburnbar.data.models.AgentProvider
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

    val selectedProvider = provider ?: AgentProvider.FACTORY

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
                        Text(selectedProvider.displayName, fontWeight = FontWeight.SemiBold, fontSize = AuroraTypography.headline.sp)
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
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Done)
                    )

                    if (error != null) {
                        Text(error!!, color = AuroraColors.error, fontSize = AuroraTypography.caption.sp)
                    }

                    Button(
                        onClick = {
                            isLoading = true
                            error = null
                            // In a real implementation, call FunctionsRepository.addProviderConnection
                            // For now, just simulate
                            isLoading = false
                            onDismiss()
                        },
                        modifier = Modifier.fillMaxWidth(),
                        enabled = label.isNotBlank() && apiKey.isNotBlank() && !isLoading,
                        colors = ButtonDefaults.buttonColors(containerColor = AuroraColors.ember)
                    ) {
                        if (isLoading) {
                            CircularProgressIndicator(modifier = Modifier.size(20.dp), color = MaterialTheme.colorScheme.onPrimary)
                        } else {
                            Text("Connect")
                        }
                    }
                }
            }
        }
    }
}
