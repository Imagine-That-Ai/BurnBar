package com.openburnbar.ui.providers

import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.lifecycle.viewmodel.compose.viewModel
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.stores.AccountStore

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProviderConnectionsView(showsDoneButton: Boolean = false, onNavigateBack: () -> Unit = {}, accountStore: AccountStore = viewModel()) {
    val accounts by accountStore.providerAccounts.collectAsState()
    val isLoading by accountStore.isLoading.collectAsState()
    var showAddSheet by remember { mutableStateOf(false) }
    var selectedProvider by remember { mutableStateOf<AgentProvider?>(null) }

    val grouped =
        accounts.filter { it.status != "deleted" }
            .groupBy { AgentProvider.fromKey(it.providerId) ?: AgentProvider.FACTORY }
            .toList()
            .sortedBy { it.first.displayName }

    val availableProviders =
        AgentProvider.entries.filter { provider ->
            provider != AgentProvider.FACTORY && accounts.none { it.providerId == provider.key && it.status != "deleted" }
        }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Provider Accounts", fontWeight = FontWeight.Bold) },
                actions = {
                    if (showsDoneButton) {
                        TextButton(onClick = onNavigateBack) { Text("Done") }
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Color.Transparent),
            )
        },
        containerColor = Color.Transparent,
    ) { innerPadding ->
        ProviderConnectionsList(
            model =
            ProviderConnectionsListModel(
                innerPadding = innerPadding,
                isLoading = isLoading,
                accounts = accounts,
                grouped = grouped,
                availableProviders = availableProviders,
            ),
            callbacks =
            ProviderConnectionsListCallbacks(
                onShowAddSheet = { provider ->
                    selectedProvider = provider
                    showAddSheet = true
                },
                onRefresh = accountStore::refreshProviderAccount,
                onDelete = accountStore::removeProviderAccount,
            ),
        )
    }

    if (showAddSheet) {
        AddProviderConnectionView(
            provider = selectedProvider,
            onDismiss = { showAddSheet = false },
        )
    }
}
