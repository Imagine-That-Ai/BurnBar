package com.openburnbar.ui.providers

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.models.ProviderAccount
import com.openburnbar.data.stores.AccountStore
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.components.EmptyStateView
import com.openburnbar.ui.components.ProviderAvatar
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraTypography

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProviderConnectionsView(
    showsDoneButton: Boolean = false,
    onNavigateBack: () -> Unit = {},
    accountStore: AccountStore = viewModel()
) {
    val accounts by accountStore.providerAccounts.collectAsState()
    val isLoading by accountStore.isLoading.collectAsState()
    var showAddSheet by remember { mutableStateOf(false) }
    var selectedProvider by remember { mutableStateOf<AgentProvider?>(null) }

    val grouped = accounts.filter { it.status != "deleted" }
        .groupBy { AgentProvider.fromKey(it.providerId) ?: AgentProvider.FACTORY }
        .toList()
        .sortedBy { it.first.displayName }

    val availableProviders = AgentProvider.entries.filter { provider ->
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
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Color.Transparent)
            )
        },
        containerColor = Color.Transparent
    ) { innerPadding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding),
            contentPadding = PaddingValues(AuroraSpacing.lg.dp),
            verticalArrangement = Arrangement.spacedBy(AuroraSpacing.lg.dp)
        ) {
            // Connected accounts section
            item {
                Text(
                    "Connected".uppercase(),
                    fontSize = AuroraTypography.tiny.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
                    modifier = Modifier.padding(bottom = AuroraSpacing.sm.dp)
                )
            }

            if (isLoading && accounts.isEmpty()) {
                items(2) {
                    AuroraGlassCard(modifier = Modifier.padding(vertical = AuroraSpacing.sm.dp)) {
                        Box(modifier = Modifier.fillMaxWidth().height(72.dp))
                    }
                }
            } else if (accounts.isEmpty()) {
                item {
                    EmptyStateView(
                        title = "No provider accounts yet",
                        message = "Connect a provider with real quota or routing credentials.",
                        onRetry = { showAddSheet = true }
                    )
                }
            } else {
                items(grouped, key = { it.first.key }) { (provider, providerAccounts) ->
                    ProviderAccountGroupSection(
                        provider = provider,
                        accounts = providerAccounts,
                        onAddMore = {
                            selectedProvider = provider
                            showAddSheet = true
                        },
                        onRefresh = { /* TODO */ },
                        onDelete = { /* TODO */ }
                    )
                }
            }

            // Available providers section
            item {
                Spacer(modifier = Modifier.height(AuroraSpacing.lg.dp))
                Text(
                    "Add Account".uppercase(),
                    fontSize = AuroraTypography.tiny.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
                    modifier = Modifier.padding(bottom = AuroraSpacing.sm.dp)
                )
            }

            items(availableProviders) { provider ->
                AvailableProviderRow(
                    provider = provider,
                    onTap = {
                        selectedProvider = provider
                        showAddSheet = true
                    }
                )
            }
        }
    }

    if (showAddSheet) {
        AddProviderConnectionView(
            provider = selectedProvider,
            onDismiss = { showAddSheet = false }
        )
    }
}

@Composable
private fun ProviderAccountGroupSection(
    provider: AgentProvider,
    accounts: List<ProviderAccount>,
    onAddMore: () -> Unit,
    onRefresh: (ProviderAccount) -> Unit,
    onDelete: (ProviderAccount) -> Unit
) {
    AuroraGlassCard {
        Column {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically
            ) {
                ProviderAvatar(providerKey = provider.key, size = 40)
                Spacer(modifier = Modifier.width(AuroraSpacing.md.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(provider.displayName, fontWeight = FontWeight.SemiBold, fontSize = AuroraTypography.body.sp)
                    Text("${accounts.size} account${if (accounts.size == 1) "" else "s"}", fontSize = AuroraTypography.caption.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                IconButton(onClick = onAddMore) {
                    Icon(Icons.Filled.Add, null, tint = AuroraColors.ember)
                }
            }

            accounts.forEach { account ->
                HorizontalDivider(modifier = Modifier.padding(vertical = AuroraSpacing.sm.dp))
                AccountRow(
                    account = account,
                    onRefresh = { onRefresh(account) },
                    onDelete = { onDelete(account) }
                )
            }
        }
    }
}

@Composable
private fun AccountRow(
    account: ProviderAccount,
    onRefresh: () -> Unit,
    onDelete: () -> Unit
) {
    Column(modifier = Modifier.fillMaxWidth()) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                modifier = Modifier
                    .width(3.dp)
                    .height(40.dp)
                    .background(
                        when (account.status) {
                            "active", "connected" -> AuroraColors.success
                            "error" -> AuroraColors.error
                            else -> AuroraColors.warning
                        },
                        androidx.compose.foundation.shape.CircleShape
                    )
            )
            Spacer(modifier = Modifier.width(AuroraSpacing.md.dp))
            Column(modifier = Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        account.label,
                        fontWeight = FontWeight.Medium,
                        fontSize = AuroraTypography.body.sp,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false)
                    )
                    if (account.isDefault) {
                        Text(
                            "Default",
                            fontSize = AuroraTypography.tiny.sp,
                            color = AuroraColors.success,
                            modifier = Modifier.padding(start = AuroraSpacing.sm.dp)
                        )
                    }
                }
                account.identityHint?.let {
                    Text(it, fontSize = AuroraTypography.caption.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                Text(
                    "Stored in ${account.storageScope ?: "unknown"}",
                    fontSize = AuroraTypography.tiny.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f)
                )
            }
            Row {
                IconButton(onClick = onRefresh) {
                    Icon(Icons.Filled.Refresh, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                IconButton(onClick = onDelete) {
                    Icon(Icons.Filled.Delete, null, tint = AuroraColors.error)
                }
            }
        }
    }
}

@Composable
private fun AvailableProviderRow(provider: AgentProvider, onTap: () -> Unit) {
    AuroraGlassCard {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable(onClick = onTap)
                .padding(vertical = AuroraSpacing.sm.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            ProviderAvatar(providerKey = provider.key, size = 40)
            Spacer(modifier = Modifier.width(AuroraSpacing.md.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(provider.displayName, fontWeight = FontWeight.SemiBold, fontSize = AuroraTypography.body.sp)
                Text("Tap to connect", fontSize = AuroraTypography.caption.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Icon(Icons.Filled.Add, null, tint = AuroraColors.ember)
        }
    }
}
