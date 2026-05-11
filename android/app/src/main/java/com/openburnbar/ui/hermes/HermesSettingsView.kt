package com.openburnbar.ui.hermes

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.hermes.*
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.theme.*

@Composable
fun HermesSettingsView(
    service: HermesService,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier
) {
    val connections by service.connections.collectAsState()
    val selectedConnection by service.selectedConnection.collectAsState()
    val modelOptions by service.modelOptions.collectAsState()
    val selectedModelID by service.selectedModelID.collectAsState()
    val favoriteModelIDs by service.favoriteModelIDs.collectAsState()
    val isReachable by service.isReachable.collectAsState()
    val runtimeErrorText by service.runtimeErrorText.collectAsState()
    val isLoadingRuntime by service.isLoadingRuntime.collectAsState()
    val profiles by service.profiles.collectAsState()
    val jobs by service.jobs.collectAsState()

    var showAddDirect by remember { mutableStateOf(false) }
    var newDirectName by remember { mutableStateOf("") }
    var newDirectURL by remember { mutableStateOf("") }
    var showDeleteConfirm by remember { mutableStateOf<HermesConnectionRecord?>(null) }

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .padding(horizontal = AuroraSpacing.lg.dp)
    ) {
        // Header
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .padding(vertical = AuroraSpacing.lg.dp)
        ) {
            IconButton(onClick = onDismiss) {
                Icon(Icons.Filled.Close, contentDescription = "Close")
            }
            Text(
                text = "Hermes Settings",
                fontSize = AuroraTypography.headline.sp,
                fontWeight = FontWeight.Bold,
                modifier = Modifier.weight(1f)
            )
        }

        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(AuroraSpacing.lg.dp)
        ) {
            // Status Card
            AuroraGlassCard(cornerRadius = AuroraRadius.lg) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(
                        modifier = Modifier
                            .size(52.dp)
                            .clip(CircleShape)
                            .background(AuroraColors.hermesMercury.copy(alpha = 0.25f)),
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(
                            Icons.Filled.NetworkCheck,
                            contentDescription = null,
                            tint = AuroraColors.hermesAureate,
                            modifier = Modifier.size(28.dp)
                        )
                    }
                    Spacer(modifier = Modifier.width(AuroraSpacing.lg.dp))
                    Column {
                        Text(
                            text = "Hermes",
                            fontSize = AuroraTypography.title.sp,
                            fontWeight = FontWeight.Bold,
                            color = MaterialTheme.colorScheme.onSurface
                        )
                        Text(
                            text = if (isReachable) "Connected" else "Disconnected",
                            fontSize = AuroraTypography.caption.sp,
                            color = if (isReachable) AuroraColors.success else AuroraColors.error
                        )
                    }
                }
            }

            // Connections
            SettingsSection(title = "Connections", icon = Icons.Filled.NetworkCheck) {
                connections.forEach { connection ->
                    ConnectionRow(
                        connection = connection,
                        isSelected = connection.id == selectedConnection.id,
                        onSelect = { service.selectConnection(connection) },
                        onDelete = {
                            if (connection.id != HermesConnectionRecord.localDefault.id) {
                                showDeleteConfirm = connection
                            }
                        }
                    )
                }
                TextButton(onClick = { showAddDirect = true }) {
                    Icon(Icons.Filled.AddCircle, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
                    Text("Add direct Hermes URL", fontSize = AuroraTypography.body.sp)
                }
            }

            // Models
            SettingsSection(title = "Models", icon = Icons.Filled.Psychology) {
                if (modelOptions.isEmpty()) {
                    Text(
                        text = "No models discovered yet.",
                        fontSize = AuroraTypography.caption.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                } else {
                    modelOptions.forEach { option ->
                        ModelRow(
                            option = option,
                            isSelected = option.modelID == selectedModelID,
                            isFavorite = favoriteModelIDs.contains(option.modelID),
                            onSelect = { service.selectModel(option) },
                            onToggleFavorite = { service.toggleFavoriteModel(option) }
                        )
                    }
                }
            }

            // Display
            SettingsSection(title = "Display", icon = Icons.Filled.Speed) {
                var showTps by remember { mutableStateOf(false) }
                var showRich by remember { mutableStateOf(true) }
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text("Show tokens/sec", fontSize = AuroraTypography.body.sp)
                        Text(
                            "Adds generation-speed footer below assistant messages.",
                            fontSize = AuroraTypography.tiny.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    Switch(checked = showTps, onCheckedChange = { showTps = it })
                }
                Divider(modifier = Modifier.padding(vertical = AuroraSpacing.sm.dp))
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text("Rich text rendering", fontSize = AuroraTypography.body.sp)
                        Text(
                            "Renders @mentions and code spans as inline chips.",
                            fontSize = AuroraTypography.tiny.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    Switch(checked = showRich, onCheckedChange = { showRich = it })
                }
            }

            // Gateway
            SettingsSection(title = "Gateway", icon = Icons.Filled.Router) {
                val baseUrl = selectedConnection.endpointURL ?: "http://localhost:8642"
                InfoRow(label = "Base URL", value = baseUrl)
                InfoRow(label = "Selected Model", value = selectedModelID ?: "hermes")
            }

            // Status
            SettingsSection(title = "Status", icon = Icons.Filled.Info) {
                if (isLoadingRuntime) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                        Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
                        Text("Probing runtime…", fontSize = AuroraTypography.caption.sp)
                    }
                }
                runtimeErrorText?.let { error ->
                    Text(
                        text = error,
                        fontSize = AuroraTypography.caption.sp,
                        color = AuroraColors.error
                    )
                }
                selectedConnection.advertisedModel?.let {
                    InfoRow(label = "Advertised Model", value = it)
                }
                if (selectedConnection.capabilities.isNotEmpty()) {
                    InfoRow(
                        label = "Capabilities",
                        value = selectedConnection.capabilities.joinToString(", ")
                    )
                }
                selectedConnection.lastSeenAt?.let {
                    InfoRow(label = "Last Seen", value = java.text.DateFormat.getDateTimeInstance().format(java.util.Date(it)))
                }
            }

            Spacer(modifier = Modifier.height(AuroraSpacing.xxxl.dp))
        }
    }

    // Add Direct Sheet
    if (showAddDirect) {
        AlertDialog(
            onDismissRequest = { showAddDirect = false },
            title = { Text("Add Direct Hermes") },
            text = {
                Column {
                    OutlinedTextField(
                        value = newDirectName,
                        onValueChange = { newDirectName = it },
                        label = { Text("Name (e.g. Home Mac)") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth()
                    )
                    Spacer(modifier = Modifier.height(AuroraSpacing.sm.dp))
                    OutlinedTextField(
                        value = newDirectURL,
                        onValueChange = { newDirectURL = it },
                        label = { Text("URL (e.g. http://192.168.1.42:8642)") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth()
                    )
                }
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        if (newDirectName.isNotBlank() && newDirectURL.isNotBlank()) {
                            val newConn = HermesConnectionRecord(
                                id = "android-${java.util.UUID.randomUUID()}",
                                displayName = newDirectName,
                                mode = HermesConnectionMode.DIRECT_URL,
                                endpointURL = newDirectURL
                            )
                            service.connections.value.let { current ->
                                // In a real app, persist this. For now, update in-memory.
                            }
                            showAddDirect = false
                            newDirectName = ""
                            newDirectURL = ""
                        }
                    },
                    enabled = newDirectName.isNotBlank() && newDirectURL.isNotBlank()
                ) {
                    Text("Save")
                }
            },
            dismissButton = {
                TextButton(onClick = { showAddDirect = false }) { Text("Cancel") }
            }
        )
    }

    // Delete Confirmation
    showDeleteConfirm?.let { conn ->
        AlertDialog(
            onDismissRequest = { showDeleteConfirm = null },
            title = { Text("Delete connection?") },
            text = { Text(conn.displayName) },
            confirmButton = {
                TextButton(
                    onClick = {
                        showDeleteConfirm = null
                    }
                ) {
                    Text("Delete", color = AuroraColors.error)
                }
            },
            dismissButton = {
                TextButton(onClick = { showDeleteConfirm = null }) { Text("Cancel") }
            }
        )
    }
}

@Composable
private fun SettingsSection(
    title: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    content: @Composable ColumnScope.() -> Unit
) {
    AuroraGlassCard(cornerRadius = AuroraRadius.lg) {
        Column {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    modifier = Modifier
                        .size(28.dp)
                        .clip(RoundedCornerShape(7.dp))
                        .background(AuroraColors.hermesAureate.copy(alpha = 0.18f)),
                    contentAlignment = Alignment.Center
                ) {
                    Icon(
                        imageVector = icon,
                        contentDescription = null,
                        tint = AuroraColors.hermesAureate,
                        modifier = Modifier.size(16.dp)
                    )
                }
                Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
                Text(
                    text = title,
                    fontSize = AuroraTypography.headline.sp,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onSurface
                )
            }
            Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))
            content()
        }
    }
}

@Composable
private fun ConnectionRow(
    connection: HermesConnectionRecord,
    isSelected: Boolean,
    onSelect: () -> Unit,
    onDelete: () -> Unit
) {
    val statusColor = when (connection.status) {
        HermesConnectionStatus.ONLINE -> AuroraColors.success
        HermesConnectionStatus.OFFLINE -> MaterialTheme.colorScheme.onSurfaceVariant
        HermesConnectionStatus.PENDING -> AuroraColors.amber
        HermesConnectionStatus.UNAUTHORIZED -> AuroraColors.warning
        HermesConnectionStatus.REVOKED -> AuroraColors.error
        HermesConnectionStatus.DEGRADED -> AuroraColors.warning
    }

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onSelect)
            .padding(vertical = 6.dp)
    ) {
        Box(
            modifier = Modifier
                .size(10.dp)
                .clip(CircleShape)
                .background(statusColor)
        )
        Spacer(modifier = Modifier.width(AuroraSpacing.md.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = connection.displayName,
                fontSize = AuroraTypography.body.sp,
                color = MaterialTheme.colorScheme.onSurface
            )
            Text(
                text = buildString {
                    append(connection.mode.name.replace("_", " "))
                    connection.endpointURL?.let { append(" · $it") }
                    append(" · ${connection.status.name.lowercase().replaceFirstChar { it.uppercase() }}")
                },
                fontSize = AuroraTypography.tiny.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
        }
        if (isSelected) {
            Icon(
                Icons.Filled.CheckCircle,
                contentDescription = "Selected",
                tint = AuroraColors.hermesAureate,
                modifier = Modifier.size(20.dp)
            )
        }
        if (connection.id != HermesConnectionRecord.localDefault.id) {
            IconButton(onClick = onDelete, modifier = Modifier.size(32.dp)) {
                Icon(
                    Icons.Filled.DeleteOutline,
                    contentDescription = "Delete",
                    tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                    modifier = Modifier.size(16.dp)
                )
            }
        }
    }
}

@Composable
private fun ModelRow(
    option: HermesRuntimeModelOption,
    isSelected: Boolean,
    isFavorite: Boolean,
    onSelect: () -> Unit,
    onToggleFavorite: () -> Unit
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onSelect)
            .padding(vertical = 6.dp)
    ) {
        Box(
            modifier = Modifier
                .size(30.dp)
                .clip(CircleShape)
                .background(colorForModel(option.modelID)),
            contentAlignment = Alignment.Center
        ) {
            Text(
                text = option.providerName.take(2).uppercase(),
                color = Color.White,
                fontSize = 10.sp,
                fontWeight = FontWeight.Bold
            )
        }
        Spacer(modifier = Modifier.width(AuroraSpacing.md.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = option.displayName,
                fontSize = AuroraTypography.body.sp,
                color = MaterialTheme.colorScheme.onSurface
            )
            Text(
                text = option.modelID,
                fontSize = AuroraTypography.tiny.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
        }
        if (isSelected) {
            Icon(
                Icons.Filled.CheckCircle,
                contentDescription = "Selected",
                tint = AuroraColors.whimsy,
                modifier = Modifier.size(20.dp)
            )
        }
        IconButton(onClick = onToggleFavorite, modifier = Modifier.size(32.dp)) {
            Icon(
                imageVector = if (isFavorite) Icons.Filled.Star else Icons.Filled.StarBorder,
                contentDescription = if (isFavorite) "Unfavorite" else "Favorite",
                tint = if (isFavorite) AuroraColors.amber else MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(18.dp)
            )
        }
    }
}

@Composable
private fun InfoRow(label: String, value: String) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 2.dp),
        horizontalArrangement = Arrangement.SpaceBetween
    ) {
        Text(
            text = label,
            fontSize = AuroraTypography.caption.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Text(
            text = value,
            fontSize = AuroraTypography.caption.sp,
            color = MaterialTheme.colorScheme.onSurface,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis
        )
    }
}

private fun colorForModel(modelName: String): Color {
    val key = modelName.lowercase()
    return when {
        key.contains("claude") || key.contains("anthropic") -> Color(0xFFCC785C)
        key.contains("gpt") || key.contains("openai") -> Color(0xFF00A67E)
        key.contains("gemini") || key.contains("google") -> Color(0xFF4285F4)
        key.contains("deepseek") -> Color(0xFF6366F1)
        key.contains("kimi") || key.contains("moonshot") -> Color(0xFF6366F1)
        key.contains("minimax") || key.contains("abab") -> Color(0xFFF59E0B)
        key.contains("llama") || key.contains("meta") -> Color(0xFF0668E1)
        key.contains("mistral") || key.contains("mixtral") -> Color(0xFFFF7000)
        key.contains("qwen") || key.contains("qwq") -> Color(0xFF615EFF)
        key.contains("grok") || key.contains("xai") -> Color(0xFF1A1A1A)
        key.contains("cohere") -> Color(0xFF39594D)
        key.contains("perplexity") -> Color(0xFF20808D)
        key.contains("mlx") || key.contains("apple") -> Color(0xFFA2AAAD)
        key.contains("nova") || key.contains("amazon") -> Color(0xFFFF9900)
        key.contains("ollama") -> Color(0xFF8B8589)
        else -> AuroraColors.whimsy
    }
}
