// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.hermes

import androidx.compose.ui.unit.dp
import androidx.compose.foundation.layout.padding
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import com.openburnbar.ui.components.BreathingDot
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraTypography

@Composable
internal fun HermesChatModelPickerDialog(
    visibleModels: List<String>,
    selectedModel: String,
    tilePreferences: com.openburnbar.data.hermes.ChatTilePreferences,
    onTilePreferencesChange: (com.openburnbar.data.hermes.ChatTilePreferences) -> Unit,
    onSelectModel: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Select Model") },
        text = {
            Column {
                visibleModels.forEach { model ->
                    HermesChatModelPickerRow(
                        model = model,
                        selected = model == selectedModel,
                        onSelect = {
                            applyModelSelection(model, tilePreferences, onTilePreferencesChange, onSelectModel)
                            onDismiss()
                        },
                    )
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Done") } },
    )
}

@Composable
private fun HermesChatModelPickerRow(model: String, selected: Boolean, onSelect: () -> Unit) {
    Surface(
        onClick = onSelect,
        modifier = Modifier.fillMaxWidth(),
        color = if (selected) AuroraColors.hermesMercury.copy(alpha = 0.15f) else Color.Transparent,
        shape = RoundedCornerShape(AuroraRadius.sm.dp),
    ) {
        Row(modifier = Modifier.padding(AuroraSpacing.sm.dp), verticalAlignment = Alignment.CenterVertically) {
            com.openburnbar.ui.components.ModelLogo(modelKey = model, size = 24.dp)
            Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
            Text(model, fontSize = AuroraTypography.body.sp, modifier = Modifier.weight(1f))
            if (selected) {
                androidx.compose.material3.Icon(
                    Icons.Filled.Check,
                    contentDescription = null,
                    modifier = Modifier.size(16.dp),
                    tint = AuroraColors.hermesMercury,
                )
            }
        }
    }
}

@Composable
internal fun HermesChatConnectionDialog(
    isConnected: Boolean,
    runtimeInfo: Map<String, String>,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Connection") },
        text = {
            Column {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    BreathingDot(color = if (isConnected) AuroraColors.success else AuroraColors.error, size = 8)
                    Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
                    Text(
                        text = if (isConnected) "Connected" else "Disconnected",
                        fontSize = AuroraTypography.body.sp,
                        color = if (isConnected) AuroraColors.success else AuroraColors.error,
                    )
                }
                runtimeInfo.forEach { (key, value) ->
                    Spacer(modifier = Modifier.height(AuroraSpacing.sm.dp))
                    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                        Text(key, fontSize = AuroraTypography.caption.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Text(value.take(40), fontSize = AuroraTypography.caption.sp, fontWeight = FontWeight.Medium)
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Close") } },
    )
}
