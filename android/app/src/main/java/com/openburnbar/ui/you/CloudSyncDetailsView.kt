package com.openburnbar.ui.you

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.openburnbar.data.stores.CloudSyncHealth
import com.openburnbar.data.stores.CloudSyncHealthStore
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraTypography
import java.text.SimpleDateFormat
import java.util.Locale

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CloudSyncDetailsView(
    syncStore: CloudSyncHealthStore = viewModel()
) {
    val health by syncStore.health.collectAsState()
    val isLoading by syncStore.isLoading.collectAsState()
    val lastPublishedAt by syncStore.lastPublishedAt.collectAsState()
    val lastReadAt by syncStore.lastReadAt.collectAsState()
    val publisher by syncStore.publisher.collectAsState()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Cloud Sync", fontWeight = FontWeight.Bold) },
                actions = {
                    IconButton(onClick = { syncStore.refresh() }, enabled = !isLoading) {
                        Icon(Icons.Filled.Refresh, contentDescription = "Refresh")
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
            item { StatusCard(health = health, isLoading = isLoading, onRefresh = { syncStore.refresh() }) }
            item { TimestampsCard(lastPublishedAt = lastPublishedAt, lastReadAt = lastReadAt) }
            item { PublisherCard(publisher = publisher) }
        }
    }
}

@Composable
private fun StatusCard(health: CloudSyncHealth, isLoading: Boolean, onRefresh: () -> Unit) {
    val (icon, tint) = when (health) {
        CloudSyncHealth.HEALTHY -> "✓" to AuroraColors.success
        CloudSyncHealth.SYNCING -> "↻" to AuroraColors.amber
        CloudSyncHealth.OFFLINE -> "✕" to AuroraColors.warning
        CloudSyncHealth.FIREBASE_UNAVAILABLE, CloudSyncHealth.APP_CHECK_BLOCKED -> "!" to AuroraColors.error
        CloudSyncHealth.PERMISSION_DENIED -> "🔒" to AuroraColors.error
        CloudSyncHealth.DEGRADED -> "~" to AuroraColors.warning
        CloudSyncHealth.UNKNOWN -> "?" to MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f)
    }

    val detailText = when (health) {
        CloudSyncHealth.UNKNOWN -> "Tap refresh to check the latest cloud state."
        CloudSyncHealth.HEALTHY -> "Your mobile app can read the latest synced usage data."
        CloudSyncHealth.SYNCING -> "Checking Firestore for the newest sync snapshot."
        CloudSyncHealth.OFFLINE -> "Network unavailable. Check your connection."
        CloudSyncHealth.PERMISSION_DENIED -> "You don't have permission to access this data."
        CloudSyncHealth.APP_CHECK_BLOCKED -> "App Check verification failed."
        CloudSyncHealth.FIREBASE_UNAVAILABLE -> "Firebase service is temporarily unavailable."
        CloudSyncHealth.DEGRADED -> "Sync is slower than usual."
    }

    AuroraGlassCard {
        Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    modifier = Modifier
                        .size(44.dp)
                        .background(tint.copy(alpha = 0.16f), CircleShape),
                    contentAlignment = Alignment.Center
                ) {
                    Text(icon, color = tint, fontWeight = FontWeight.Bold, fontSize = AuroraTypography.headline.sp)
                }
                Spacer(modifier = Modifier.width(12.dp))
                Column {
                    Text(health.label, fontWeight = FontWeight.SemiBold, fontSize = AuroraTypography.headline.sp)
                    Text(detailText, fontSize = AuroraTypography.caption.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Spacer(modifier = Modifier.weight(1f))
                if (isLoading) {
                    CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
                }
            }
            Button(onClick = onRefresh, modifier = Modifier.fillMaxWidth(), enabled = !isLoading) {
                Text("Refresh now")
            }
        }
    }
}

@Composable
private fun TimestampsCard(lastPublishedAt: java.util.Date?, lastReadAt: java.util.Date?) {
    val sdf = SimpleDateFormat("MMM d, h:mm a", Locale.getDefault())
    AuroraGlassCard {
        Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp)) {
            Text("Activity", fontWeight = FontWeight.SemiBold, fontSize = AuroraTypography.caption.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            DetailRow("Last Mac write", lastPublishedAt?.let { sdf.format(it) } ?: "Never")
            DetailRow("Last mobile read", lastReadAt?.let { sdf.format(it) } ?: "Never")
        }
    }
}

@Composable
private fun PublisherCard(publisher: com.openburnbar.data.stores.CloudPublisherDevice?) {
    AuroraGlassCard {
        Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp)) {
            Text("Publishing device", fontWeight = FontWeight.SemiBold, fontSize = AuroraTypography.caption.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (publisher != null) {
                DetailRow("Name", publisher.displayName.ifEmpty { "Unknown" })
                DetailRow("Platform", publisher.platform)
                DetailRow("Last seen", publisher.lastSeen?.let {
                    SimpleDateFormat("MMM d, h:mm a", Locale.getDefault()).format(it)
                } ?: "Never")
            } else {
                Text("No publishing device has written sync data yet.", fontSize = AuroraTypography.body.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@Composable
private fun DetailRow(title: String, value: String) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(title, fontSize = AuroraTypography.body.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(value, fontSize = AuroraTypography.caption.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurface)
    }
}
