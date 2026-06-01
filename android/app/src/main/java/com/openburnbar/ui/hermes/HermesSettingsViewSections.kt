@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.hermes

import com.openburnbar.ui.components.AuroraGlassCard
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AddCircle
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.DeleteOutline
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.NetworkCheck
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material.icons.filled.Router
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.StarBorder
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Divider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.hermes.HermesConnectionRecord
import com.openburnbar.data.hermes.HermesConnectionStatus
import com.openburnbar.data.hermes.HermesRuntimeModelOption
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraTypography

internal data class HermesSettingsUiState(
    val connections: List<HermesConnectionRecord>,
    val selectedConnection: HermesConnectionRecord,
    val modelOptions: List<HermesRuntimeModelOption>,
    val selectedModelID: String?,
    val favoriteModelIDs: Set<String>,
    val isReachable: Boolean,
    val runtimeErrorText: String?,
    val isLoadingRuntime: Boolean,
)

internal data class HermesSettingsDialogState(
    val showAddDirect: Boolean = false,
    val newDirectName: String = "",
    val newDirectURL: String = "",
    val deleteTarget: HermesConnectionRecord? = null,
)

internal data class HermesSettingsCallbacks(
    val onDismiss: () -> Unit,
    val onSelectConnection: (HermesConnectionRecord) -> Unit,
    val onRequestDeleteConnection: (HermesConnectionRecord) -> Unit,
    val onRequestAddDirect: () -> Unit,
    val onSelectModel: (HermesRuntimeModelOption) -> Unit,
    val onToggleFavoriteModel: (HermesRuntimeModelOption) -> Unit,
    val onDialogStateChange: (HermesSettingsDialogState) -> Unit,
    val onAddDirectConnection: (String, String) -> Unit,
)

@Composable
internal fun HermesSettingsBody(
    uiState: HermesSettingsUiState,
    callbacks: HermesSettingsCallbacks,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier =
        modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .padding(horizontal = AuroraSpacing.lg.dp),
    ) {
        HermesSettingsHeader(onDismiss = callbacks.onDismiss)
        HermesSettingsScrollContent(uiState = uiState, callbacks = callbacks)
    }
}

@Composable
internal fun HermesSettingsHeader(onDismiss: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier =
        Modifier
            .fillMaxWidth()
            .padding(vertical = AuroraSpacing.lg.dp),
    ) {
        IconButton(onClick = onDismiss) {
            Icon(Icons.Filled.Close, contentDescription = "Close")
        }
        Text(
            text = "Hermes Settings",
            fontSize = AuroraTypography.headline.sp,
            fontWeight = FontWeight.Bold,
            modifier = Modifier.weight(1f),
        )
    }
}

@Composable
internal fun HermesSettingsScrollContent(
    uiState: HermesSettingsUiState,
    callbacks: HermesSettingsCallbacks,
) {
    Column(
        modifier =
        Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.lg.dp),
    ) {
        HermesSettingsStatusCard(isReachable = uiState.isReachable)
        HermesSettingsConnectionsSection(uiState = uiState, callbacks = callbacks)
        HermesSettingsModelsSection(uiState = uiState, callbacks = callbacks)
        HermesSettingsDisplaySection()
        HermesSettingsGatewaySection(
            selectedConnection = uiState.selectedConnection,
            selectedModelID = uiState.selectedModelID,
        )
        HermesSettingsRuntimeSection(uiState = uiState)
        Spacer(modifier = Modifier.height(AuroraSpacing.xxxl.dp))
    }
}

@Composable
internal fun HermesSettingsStatusCard(isReachable: Boolean) {
    AuroraGlassCard(cornerRadius = AuroraRadius.lg) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                modifier =
                Modifier
                    .size(52.dp)
                    .clip(CircleShape)
                    .background(AuroraColors.hermesMercury.copy(alpha = 0.25f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.Filled.NetworkCheck,
                    contentDescription = null,
                    tint = AuroraColors.hermesAureate,
                    modifier = Modifier.size(28.dp),
                )
            }
            Spacer(modifier = Modifier.width(AuroraSpacing.lg.dp))
            Column {
                Text(
                    text = "Hermes",
                    fontSize = AuroraTypography.title.sp,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onSurface,
                )
                Text(
                    text = if (isReachable) "Connected" else "Disconnected",
                    fontSize = AuroraTypography.caption.sp,
                    color = if (isReachable) AuroraColors.success else AuroraColors.error,
                )
            }
        }
    }
}

@Composable
internal fun HermesSettingsConnectionsSection(
    uiState: HermesSettingsUiState,
    callbacks: HermesSettingsCallbacks,
) {
    SettingsSection(title = "Connections", icon = Icons.Filled.NetworkCheck) {
        uiState.connections.forEach { connection ->
            ConnectionRow(
                connection = connection,
                isSelected = connection.id == uiState.selectedConnection.id,
                onSelect = { callbacks.onSelectConnection(connection) },
                onDelete = {
                    if (connection.id != HermesConnectionRecord.localDefault.id) {
                        callbacks.onRequestDeleteConnection(connection)
                    }
                },
            )
        }
        TextButton(onClick = callbacks.onRequestAddDirect) {
            Icon(Icons.Filled.AddCircle, contentDescription = null, modifier = Modifier.size(18.dp))
            Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
            Text("Add direct Hermes URL", fontSize = AuroraTypography.body.sp)
        }
    }
}

@Composable
internal fun HermesSettingsModelsSection(
    uiState: HermesSettingsUiState,
    callbacks: HermesSettingsCallbacks,
) {
    SettingsSection(title = "Models", icon = Icons.Filled.Psychology) {
        if (uiState.modelOptions.isEmpty()) {
            Text(
                text = "No models discovered yet.",
                fontSize = AuroraTypography.caption.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        } else {
            uiState.modelOptions.forEach { option ->
                ModelRow(
                    option = option,
                    isSelected = option.modelID == uiState.selectedModelID,
                    isFavorite = uiState.favoriteModelIDs.contains(option.modelID),
                    onSelect = { callbacks.onSelectModel(option) },
                    onToggleFavorite = { callbacks.onToggleFavoriteModel(option) },
                )
            }
        }
    }
}

@Composable
internal fun HermesSettingsDisplaySection() {
    SettingsSection(title = "Display", icon = Icons.Filled.Speed) {
        var showTps by remember { mutableStateOf(false) }
        var showRich by remember { mutableStateOf(true) }
        HermesSettingsDisplayToggle(
            title = "Show tokens/sec",
            subtitle = "Adds generation-speed footer below assistant messages.",
            checked = showTps,
            onCheckedChange = { showTps = it },
        )
        Divider(modifier = Modifier.padding(vertical = AuroraSpacing.sm.dp))
        HermesSettingsDisplayToggle(
            title = "Rich text rendering",
            subtitle = "Renders @mentions and code spans as inline chips.",
            checked = showRich,
            onCheckedChange = { showRich = it },
        )
    }
}

@Composable
private fun HermesSettingsDisplayToggle(
    title: String,
    subtitle: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(title, fontSize = AuroraTypography.body.sp)
            Text(
                subtitle,
                fontSize = AuroraTypography.tiny.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Switch(checked = checked, onCheckedChange = onCheckedChange)
    }
}

@Composable
internal fun HermesSettingsGatewaySection(
    selectedConnection: HermesConnectionRecord,
    selectedModelID: String?,
) {
    SettingsSection(title = "Gateway", icon = Icons.Filled.Router) {
        val baseUrl = selectedConnection.endpointURL ?: "http://localhost:8642"
        InfoRow(label = "Base URL", value = baseUrl)
        InfoRow(label = "Selected Model", value = selectedModelID ?: "hermes")
    }
}

@Composable
internal fun HermesSettingsRuntimeSection(uiState: HermesSettingsUiState) {
    SettingsSection(title = "Status", icon = Icons.Filled.Info) {
        if (uiState.isLoadingRuntime) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
                Text("Probing runtime…", fontSize = AuroraTypography.caption.sp)
            }
        }
        uiState.runtimeErrorText?.let { error ->
            Text(
                text = error,
                fontSize = AuroraTypography.caption.sp,
                color = AuroraColors.error,
            )
        }
        uiState.selectedConnection.advertisedModel?.let {
            InfoRow(label = "Advertised Model", value = it)
        }
        if (uiState.selectedConnection.capabilities.isNotEmpty()) {
            InfoRow(
                label = "Capabilities",
                value = uiState.selectedConnection.capabilities.joinToString(", "),
            )
        }
        uiState.selectedConnection.lastSeenAt?.let {
            InfoRow(
                label = "Last Seen",
                value = java.text.DateFormat.getDateTimeInstance().format(java.util.Date(it)),
            )
        }
    }
}

@Composable
internal fun HermesSettingsDialogs(
    dialogState: HermesSettingsDialogState,
    callbacks: HermesSettingsCallbacks,
) {
    if (dialogState.showAddDirect) {
        HermesSettingsAddDirectDialog(
            fields = HermesDirectDialogFields(name = dialogState.newDirectName, url = dialogState.newDirectURL),
            callbacks =
            HermesDirectDialogCallbacks(
                onNameChange = { callbacks.onDialogStateChange(dialogState.copy(newDirectName = it)) },
                onUrlChange = { callbacks.onDialogStateChange(dialogState.copy(newDirectURL = it)) },
                onDismiss = { callbacks.onDialogStateChange(dialogState.copy(showAddDirect = false)) },
                onSave = {
                    if (dialogState.newDirectName.isNotBlank() && dialogState.newDirectURL.isNotBlank()) {
                        callbacks.onAddDirectConnection(dialogState.newDirectName, dialogState.newDirectURL)
                        callbacks.onDialogStateChange(
                            HermesSettingsDialogState(),
                        )
                    }
                },
            ),
            canSave = dialogState.newDirectName.isNotBlank() && dialogState.newDirectURL.isNotBlank(),
        )
    }

    dialogState.deleteTarget?.let { connection ->
        HermesSettingsDeleteConfirmDialog(
            connection = connection,
            onDismiss = { callbacks.onDialogStateChange(dialogState.copy(deleteTarget = null)) },
            onConfirm = { callbacks.onDialogStateChange(dialogState.copy(deleteTarget = null)) },
        )
    }
}

private data class HermesDirectDialogFields(val name: String, val url: String)

private data class HermesDirectDialogCallbacks(
    val onNameChange: (String) -> Unit,
    val onUrlChange: (String) -> Unit,
    val onDismiss: () -> Unit,
    val onSave: () -> Unit,
)

@Composable
private fun HermesSettingsAddDirectDialog(
    fields: HermesDirectDialogFields,
    callbacks: HermesDirectDialogCallbacks,
    canSave: Boolean,
) {
    AlertDialog(
        onDismissRequest = callbacks.onDismiss,
        title = { Text("Add Direct Hermes") },
        text = {
            Column {
                OutlinedTextField(
                    value = fields.name,
                    onValueChange = callbacks.onNameChange,
                    label = { Text("Name (e.g. Home Mac)") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                Spacer(modifier = Modifier.height(AuroraSpacing.sm.dp))
                OutlinedTextField(
                    value = fields.url,
                    onValueChange = callbacks.onUrlChange,
                    label = { Text("URL (e.g. http://192.168.1.42:8642)") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        },
        confirmButton = {
            TextButton(onClick = callbacks.onSave, enabled = canSave) {
                Text("Save")
            }
        },
        dismissButton = {
            TextButton(onClick = callbacks.onDismiss) { Text("Cancel") }
        },
    )
}

@Composable
private fun HermesSettingsDeleteConfirmDialog(
    connection: HermesConnectionRecord,
    onDismiss: () -> Unit,
    onConfirm: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Delete connection?") },
        text = { Text(connection.displayName) },
        confirmButton = {
            TextButton(onClick = onConfirm) {
                Text("Delete", color = AuroraColors.error)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        },
    )
}

@Composable
private fun SettingsSection(
    title: String,
    icon: ImageVector,
    content: @Composable ColumnScope.() -> Unit,
) {
    AuroraGlassCard(cornerRadius = AuroraRadius.lg) {
        Column {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    modifier =
                    Modifier
                        .size(28.dp)
                        .clip(RoundedCornerShape(7.dp))
                        .background(AuroraColors.hermesAureate.copy(alpha = 0.18f)),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        imageVector = icon,
                        contentDescription = null,
                        tint = AuroraColors.hermesAureate,
                        modifier = Modifier.size(16.dp),
                    )
                }
                Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
                Text(
                    text = title,
                    fontSize = AuroraTypography.headline.sp,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onSurface,
                )
            }
            Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))
            content()
        }
    }
}

@Composable
internal fun ConnectionRow(
    connection: HermesConnectionRecord,
    isSelected: Boolean,
    onSelect: () -> Unit,
    onDelete: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier =
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onSelect)
            .padding(vertical = 6.dp),
    ) {
        ConnectionRowStatusDot(status = connection.status)
        Spacer(modifier = Modifier.width(AuroraSpacing.md.dp))
        ConnectionRowDetails(connection = connection)
        ConnectionRowTrailing(
            isSelected = isSelected,
            canDelete = connection.id != HermesConnectionRecord.localDefault.id,
            onDelete = onDelete,
        )
    }
}

@Composable
private fun ConnectionRowStatusDot(status: HermesConnectionStatus) {
    Box(
        modifier =
        Modifier
            .size(10.dp)
            .clip(CircleShape)
            .background(connectionStatusColor(status)),
    )
}

@Composable
private fun RowScope.ConnectionRowDetails(connection: HermesConnectionRecord) {
    Column(modifier = Modifier.weight(1f)) {
        Text(
            text = connection.displayName,
            fontSize = AuroraTypography.body.sp,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Text(
            text = connectionSubtitle(connection),
            fontSize = AuroraTypography.tiny.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun ConnectionRowTrailing(
    isSelected: Boolean,
    canDelete: Boolean,
    onDelete: () -> Unit,
) {
    if (isSelected) {
        Icon(
            Icons.Filled.CheckCircle,
            contentDescription = "Selected",
            tint = AuroraColors.hermesAureate,
            modifier = Modifier.size(20.dp),
        )
    }
    if (canDelete) {
        IconButton(onClick = onDelete, modifier = Modifier.size(32.dp)) {
            Icon(
                Icons.Filled.DeleteOutline,
                contentDescription = "Delete",
                tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                modifier = Modifier.size(16.dp),
            )
        }
    }
}

@Composable
private fun connectionStatusColor(status: HermesConnectionStatus): Color =
    when (status) {
        HermesConnectionStatus.ONLINE -> AuroraColors.success
        HermesConnectionStatus.OFFLINE -> MaterialTheme.colorScheme.onSurfaceVariant
        HermesConnectionStatus.PENDING -> AuroraColors.amber
        HermesConnectionStatus.UNAUTHORIZED -> AuroraColors.warning
        HermesConnectionStatus.REVOKED -> AuroraColors.error
        HermesConnectionStatus.DEGRADED -> AuroraColors.warning
    }

private fun connectionSubtitle(connection: HermesConnectionRecord): String =
    buildString {
        append(connection.mode.name.replace("_", " "))
        connection.endpointURL?.let { append(" · $it") }
        append(" · ${connection.status.name.lowercase().replaceFirstChar { it.uppercase() }}")
    }

@Composable
private fun ModelRow(
    option: HermesRuntimeModelOption,
    isSelected: Boolean,
    isFavorite: Boolean,
    onSelect: () -> Unit,
    onToggleFavorite: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier =
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onSelect)
            .padding(vertical = 6.dp),
    ) {
        Box(
            modifier =
            Modifier
                .size(30.dp)
                .clip(CircleShape)
                .background(colorForModel(option.modelID)),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text = option.providerName.take(2).uppercase(),
                color = Color.White,
                fontSize = 10.sp,
                fontWeight = FontWeight.Bold,
            )
        }
        Spacer(modifier = Modifier.width(AuroraSpacing.md.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = option.displayName,
                fontSize = AuroraTypography.body.sp,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Text(
                text = option.modelID,
                fontSize = AuroraTypography.tiny.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        if (isSelected) {
            Icon(
                Icons.Filled.CheckCircle,
                contentDescription = "Selected",
                tint = AuroraColors.whimsy,
                modifier = Modifier.size(20.dp),
            )
        }
        IconButton(onClick = onToggleFavorite, modifier = Modifier.size(32.dp)) {
            Icon(
                imageVector = if (isFavorite) Icons.Filled.Star else Icons.Filled.StarBorder,
                contentDescription = if (isFavorite) "Unfavorite" else "Favorite",
                tint = if (isFavorite) AuroraColors.amber else MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(18.dp),
            )
        }
    }
}

@Composable
private fun InfoRow(label: String, value: String) {
    Row(
        modifier =
        Modifier
            .fillMaxWidth()
            .padding(vertical = 2.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(
            text = label,
            fontSize = AuroraTypography.caption.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text(
            text = value,
            fontSize = AuroraTypography.caption.sp,
            color = MaterialTheme.colorScheme.onSurface,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
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
