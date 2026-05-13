package com.openburnbar.ui.hermes

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.hermes.AssistantRuntimeID
import com.openburnbar.data.hermes.ChatTilePreferences
import com.openburnbar.data.hermes.HermesSubProvider
import com.openburnbar.ui.theme.AuroraSpacing

@Composable
fun ChatTilesSettingsScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    var prefs by remember { mutableStateOf(loadPrefs(context).sanitized()) }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .verticalScroll(rememberScrollState())
    ) {
        Header(onBack = onBack)

        SectionHeader(
            title = "Chat tiles",
            subtitle = "Choose which assistants appear in the Chat tab's runtime pill. Hermes always stays available."
        )
        AssistantRuntimeID.values().forEach { runtime ->
            TileToggleRow(
                title = runtime.displayName,
                subtitle = tileSubtitle(runtime),
                glyph = runtime.glyph,
                checked = prefs.enabledTiles.contains(runtime),
                onCheckedChange = { enabled ->
                    val next = prefs.withTile(runtime, enabled)
                    prefs = next
                    savePrefs(context, next)
                }
            )
        }

        Spacer(modifier = Modifier.height(AuroraSpacing.lg.dp))

        SectionHeader(
            title = "Hermes models",
            subtitle = "Each toggle hides or shows a sub-provider in the Hermes model picker."
        )
        HermesSubProvider.values().forEach { sub ->
            TileToggleRow(
                title = sub.displayName,
                subtitle = "Routes Hermes traffic through ${sub.displayName}.",
                glyph = sub.glyph,
                checked = prefs.enabledHermesSubProviders.contains(sub),
                onCheckedChange = { enabled ->
                    val next = prefs.withHermesSubProvider(sub, enabled)
                    prefs = next
                    savePrefs(context, next)
                }
            )
        }

        SelectedHermesModelRow(
            selectedModel = prefs.selectedHermesModelOverride,
            onReset = {
                val next = prefs.setSelectedHermesModel(null)
                prefs = next
                savePrefs(context, next)
            }
        )

        Spacer(modifier = Modifier.height(AuroraSpacing.xl.dp))
    }
}

@Composable
private fun Header(onBack: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = AuroraSpacing.md.dp, vertical = AuroraSpacing.sm.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        IconButton(onClick = onBack) {
            Icon(
                imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                contentDescription = "Back",
                tint = MaterialTheme.colorScheme.onSurface
            )
        }
        Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
        Text(
            text = "Chat tiles",
            fontSize = 22.sp,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurface
        )
    }
}

@Composable
private fun SectionHeader(title: String, subtitle: String) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = AuroraSpacing.lg.dp, vertical = AuroraSpacing.sm.dp)
    ) {
        Text(
            text = title,
            fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Text(
            text = subtitle,
            fontSize = 12.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
            modifier = Modifier.padding(top = 2.dp)
        )
    }
}

@Composable
private fun TileToggleRow(
    title: String,
    subtitle: String,
    glyph: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable { onCheckedChange(!checked) }
            .padding(horizontal = AuroraSpacing.lg.dp, vertical = AuroraSpacing.sm.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
            modifier = Modifier
                .size(28.dp)
                .clip(RoundedCornerShape(7.dp))
                .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.6f)),
            contentAlignment = Alignment.Center
        ) {
            Text(text = glyph, fontSize = 14.sp, fontWeight = FontWeight.Bold)
        }
        Spacer(modifier = Modifier.width(AuroraSpacing.md.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(text = title, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurface)
            Text(text = subtitle, fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.75f))
        }
        Switch(checked = checked, onCheckedChange = onCheckedChange)
    }
}

@Composable
private fun SelectedHermesModelRow(
    selectedModel: String?,
    onReset: () -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = AuroraSpacing.lg.dp, vertical = AuroraSpacing.sm.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = "Selected: ${selectedModel?.takeIf { it.isNotBlank() } ?: "Automatic"}",
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface
            )
            Text(
                text = "Automatic lets Hermes use the gateway default.",
                fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.75f)
            )
        }
        Text(
            text = "Reset",
            fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold,
            color = if (selectedModel.isNullOrBlank()) {
                MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.45f)
            } else {
                MaterialTheme.colorScheme.primary
            },
            modifier = Modifier
                .clip(RoundedCornerShape(7.dp))
                .clickable(enabled = !selectedModel.isNullOrBlank()) { onReset() }
                .padding(horizontal = AuroraSpacing.sm.dp, vertical = AuroraSpacing.xs.dp)
        )
    }
}

private fun tileSubtitle(runtime: AssistantRuntimeID): String = when (runtime) {
    AssistantRuntimeID.HERMES -> "Hosted AI assistant connected to your Mac."
    AssistantRuntimeID.PI -> "On-device Pi runtime, paired via gateway."
    AssistantRuntimeID.CODEX -> "Codex chat bridged from your Mac."
    AssistantRuntimeID.CLAUDE -> "Claude Code chat bridged from your Mac."
    AssistantRuntimeID.OPEN_CLAW -> "OpenClaw local agent bridged from your Mac."
}

private fun loadPrefs(context: Context): ChatTilePreferences {
    val prefs = context.getSharedPreferences("chat.tile_preferences", Context.MODE_PRIVATE)
    return ChatTilePreferences.fromJsonString(prefs.getString(ChatTilePreferences.USER_DEFAULTS_KEY, null))
}

private fun savePrefs(context: Context, value: ChatTilePreferences) {
    val prefs = context.getSharedPreferences("chat.tile_preferences", Context.MODE_PRIVATE)
    prefs.edit().putString(ChatTilePreferences.USER_DEFAULTS_KEY, value.toJsonString()).apply()
}
