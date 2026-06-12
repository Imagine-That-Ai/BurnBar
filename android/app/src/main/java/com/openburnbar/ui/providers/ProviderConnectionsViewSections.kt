// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.providers

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.models.ProviderAccount
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.components.EmptyStateView
import com.openburnbar.ui.components.ProviderAvatar
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraTypography

internal data class ProviderConnectionsListModel(
    val innerPadding: PaddingValues,
    val isLoading: Boolean,
    val accounts: List<ProviderAccount>,
    val grouped: List<Pair<AgentProvider, List<ProviderAccount>>>,
    val availableProviders: List<AgentProvider>,
)

internal data class ProviderConnectionsListCallbacks(
    val onShowAddSheet: (AgentProvider?) -> Unit,
    val onRefresh: (ProviderAccount) -> Unit,
    val onDelete: (ProviderAccount) -> Unit,
)

@Composable
internal fun ProviderConnectionsList(
    model: ProviderConnectionsListModel,
    callbacks: ProviderConnectionsListCallbacks,
) {
    LazyColumn(
        modifier =
        Modifier
            .fillMaxSize()
            .padding(model.innerPadding),
        contentPadding = PaddingValues(AuroraSpacing.lg.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.lg.dp),
    ) {
        item {
            ProviderConnectionsSectionHeader(title = "Connected")
        }
        if (model.isLoading && model.accounts.isEmpty()) {
            items(2) {
                AuroraGlassCard(modifier = Modifier.padding(vertical = AuroraSpacing.sm.dp)) {
                    Box(modifier = Modifier.fillMaxWidth().height(72.dp))
                }
            }
        } else if (model.accounts.isEmpty()) {
            item {
                EmptyStateView(
                    title = "No provider accounts yet",
                    message = "Connect a provider with real quota or routing credentials.",
                    onRetry = { callbacks.onShowAddSheet(null) },
                )
            }
        } else {
            items(model.grouped, key = { it.first.key }) { (provider, providerAccounts) ->
                ProviderAccountGroupSection(
                    provider = provider,
                    accounts = providerAccounts,
                    onAddMore = { callbacks.onShowAddSheet(provider) },
                    onRefresh = callbacks.onRefresh,
                    onDelete = callbacks.onDelete,
                )
            }
        }
        item {
            Spacer(modifier = Modifier.height(AuroraSpacing.lg.dp))
            ProviderConnectionsSectionHeader(title = "Add Account")
        }
        items(model.availableProviders) { provider ->
            AvailableProviderRow(provider = provider, onTap = { callbacks.onShowAddSheet(provider) })
        }
    }
}

@Composable
private fun ProviderConnectionsSectionHeader(title: String) {
    Text(
        title.uppercase(),
        fontSize = AuroraTypography.tiny.sp,
        fontWeight = FontWeight.SemiBold,
        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
        modifier = Modifier.padding(bottom = AuroraSpacing.sm.dp),
    )
}

@Composable
internal fun ProviderAccountGroupSection(
    provider: AgentProvider,
    accounts: List<ProviderAccount>,
    onAddMore: () -> Unit,
    onRefresh: (ProviderAccount) -> Unit,
    onDelete: (ProviderAccount) -> Unit,
) {
    AuroraGlassCard {
        Column {
            ProviderAccountGroupHeader(provider = provider, accountCount = accounts.size, onAddMore = onAddMore)
            accounts.forEach { account ->
                HorizontalDivider(modifier = Modifier.padding(vertical = AuroraSpacing.sm.dp))
                AccountRow(
                    account = account,
                    onRefresh = { onRefresh(account) },
                    onDelete = { onDelete(account) },
                )
            }
        }
    }
}

@Composable
private fun ProviderAccountGroupHeader(provider: AgentProvider, accountCount: Int, onAddMore: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        ProviderAvatar(providerKey = provider.key, size = 40)
        Spacer(modifier = Modifier.width(AuroraSpacing.md.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(provider.displayName, fontWeight = FontWeight.SemiBold, fontSize = AuroraTypography.body.sp)
            Text(
                "$accountCount account${if (accountCount == 1) "" else "s"}",
                fontSize = AuroraTypography.caption.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        IconButton(onClick = onAddMore) {
            Icon(Icons.Filled.Add, null, tint = AuroraColors.ember)
        }
    }
}

@Composable
internal fun AccountRow(account: ProviderAccount, onRefresh: () -> Unit, onDelete: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        AccountStatusStripe(status = account.status ?: "unknown")
        Spacer(modifier = Modifier.width(AuroraSpacing.md.dp))
        AccountRowDetails(account = account, modifier = Modifier.weight(1f))
        AccountRowActions(onRefresh = onRefresh, onDelete = onDelete)
    }
}

@Composable
private fun AccountStatusStripe(status: String) {
    Box(
        modifier =
        Modifier
            .width(3.dp)
            .height(40.dp)
            .background(
                when (status) {
                    "active", "connected" -> AuroraColors.success
                    "error" -> AuroraColors.error
                    else -> AuroraColors.warning
                },
                CircleShape,
            ),
    )
}

@Composable
private fun AccountRowDetails(account: ProviderAccount, modifier: Modifier = Modifier) {
    Column(modifier = modifier) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                account.label,
                fontWeight = FontWeight.Medium,
                fontSize = AuroraTypography.body.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f, fill = false),
            )
            if (account.isDefault) {
                Text(
                    "Default",
                    fontSize = AuroraTypography.tiny.sp,
                    color = AuroraColors.success,
                    modifier = Modifier.padding(start = AuroraSpacing.sm.dp),
                )
            }
        }
        account.identityHint?.let {
            Text(
                it,
                fontSize = AuroraTypography.caption.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Text(
            "Stored in ${account.storageScope ?: "unknown"}",
            fontSize = AuroraTypography.tiny.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
        )
    }
}

@Composable
private fun AccountRowActions(onRefresh: () -> Unit, onDelete: () -> Unit) {
    Row {
        IconButton(onClick = onRefresh) {
            Icon(Icons.Filled.Refresh, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        IconButton(onClick = onDelete) {
            Icon(Icons.Filled.Delete, null, tint = AuroraColors.error)
        }
    }
}

@Composable
internal fun AvailableProviderRow(provider: AgentProvider, onTap: () -> Unit) {
    AuroraGlassCard {
        Row(
            modifier =
            Modifier
                .fillMaxWidth()
                .clickable(onClick = onTap)
                .padding(vertical = AuroraSpacing.sm.dp),
            verticalAlignment = Alignment.CenterVertically,
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
